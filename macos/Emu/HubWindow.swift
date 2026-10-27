// One window around a web page of the hub: the hub itself (main window), or
// one session's dashboard ("Open in a new window"). Keeps navigation to the
// hub and session origins, hands links out to the default browser, saves
// downloads, shows JS dialogs as sheets, and notices when the hub goes away.
import Cocoa
import WebKit

/// Breaks the retain cycle WKUserContentController → handler → window.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

final class HubWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, WKDownloadDelegate {
    let webView: WKWebView
    private let hub: HubClient
    private let isMain: Bool
    private var startURL: URL
    /// Ports of the sessions the hub listed last — what may load in here.
    var sessionPorts: () -> Set<Int>
    /// "Open in a new window" from the hub page.
    var onOpenWindow: ((URL) -> Void)?
    /// "Reopen the app" from the hub page, after an update rebuilt it.
    var onRelaunch: (() -> Void)?
    var onClose: ((HubWindow) -> Void)?

    private var watch: Timer?
    private var failures = 0
    private var showingError = false

    init(url: URL, title: String, autosave: String, hub: HubClient, isMain: Bool, sessionPorts: @escaping () -> Set<Int>) {
        self.hub = hub
        self.isMain = isMain
        self.startURL = url
        self.sessionPorts = sessionPorts
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentView = webView
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        window.setFrameAutosaveName(autosave)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        config.userContentController.add(WeakHandler(self), name: "emu")
        // Which build this app is: the hub page compares it with the one on
        // disk to offer reopening after an update (web/hub/hub.js).
        config.userContentController.addUserScript(WKUserScript(
            source: "window.emuApp = \(HubWindow.appInfoJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = ProcessInfo.processInfo.arguments.contains("--debug") }
        webView.load(URLRequest(url: url))
        if isMain { startWatching() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `{"rev": …, "version": …}` of the running bundle (Info.plist, read at launch).
    static let appInfoJSON: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let m = ["rev": info["CFBundleVersion"] as? String ?? "", "version": info["CFBundleShortVersionString"] as? String ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: m), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }()

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pick a session in the hub page (menu bar, notification).
    func showSession(_ id: String) {
        show()
        let js = "location.hash = '#/s/\(id.filter { $0.isHexDigit })'"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func reload(to url: URL? = nil) {
        if let url = url { startURL = url }
        showingError = false
        webView.load(URLRequest(url: startURL))
    }

    func windowWillClose(_ notification: Notification) {
        watch?.invalidate()
        onClose?(self)
    }

    // ---- hub watch -------------------------------------------------------------

    private func startWatching() {
        watch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let alive = self.hub.alive()
            DispatchQueue.main.async {
                if alive {
                    self.failures = 0
                    let url = self.hub.url
                    if self.showingError || url.port != self.startURL.port { self.reload(to: url) }
                } else {
                    self.failures += 1
                    if self.failures == 3 { self.showError("The hub stopped", detail: "emu hub is not answering any more. Sessions keep running.") }
                }
            }
        }
    }

    func showError(_ title: String, detail: String) {
        showingError = true
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#0e1116;color:#c9d1d9;
        font:13px -apple-system,sans-serif}div{max-width:460px;text-align:center;line-height:1.6}
        h2{font-size:16px;margin:0 0 8px}pre{white-space:pre-wrap;text-align:left;background:#161b22;padding:10px;border-radius:6px;color:#768390}
        button{margin-top:12px;padding:6px 14px;border-radius:6px;border:0;background:#2f81f7;color:#fff;font:inherit;cursor:pointer}
        </style><div><h2>\(esc(title))</h2><pre>\(esc(detail))</pre>
        <button onclick="webkit.messageHandlers.emu.postMessage({type:'retry'})">Start the hub again</button></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func retry() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let r = self.hub.ensure()
            DispatchQueue.main.async {
                switch r {
                case .success(let url): self.failures = 0; self.reload(to: url)
                case .failure(let why): self.showError("Could not start the hub", detail: why.message)
                }
            }
        }
    }

    // ---- bridge (hub page → app) ------------------------------------------------

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the page itself: a dashboard framed inside the hub page must not drive the app.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open-window":
            if let s = body["url"] as? String, let url = URL(string: s), allowed(url) { onOpenWindow?(url) }
        case "retry":
            retry()
        case "relaunch":
            if isMain { onRelaunch?() }
        default:
            break
        }
    }

    // ---- navigation ------------------------------------------------------------

    private func allowed(_ url: URL) -> Bool {
        Policy.isInternal(url, hubPort: hub.port, sessionPorts: sessionPorts())
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload { return decisionHandler(.download) }
        if url.absoluteString == "about:blank" || url.scheme == "about" { return decisionHandler(.allow) }
        if showingError && action.targetFrame?.isMainFrame == true && url.scheme == nil { return decisionHandler(.allow) }
        if allowed(url) { return decisionHandler(.allow) }
        if Policy.opensExternally(url, userClicked: action.navigationType == .linkActivated) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isMain && !showingError { showError("Cannot reach the hub", detail: error.localizedDescription) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // window.open / target=_blank
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if allowed(url) {
            onOpenWindow?(url)
        } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url) // a link the page opened on purpose (DevTools)
        }
        return nil
    }

    // ---- downloads (▣ Shot and the like) ----------------------------------------

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let window = window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        sheet(text: "Download failed", info: error.localizedDescription, buttons: ["OK"]) { _ in }
    }

    // ---- JS dialogs as sheets --------------------------------------------------

    private func sheet(text: String, info: String, buttons: [String], done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = info
        for b in buttons { alert.addButton(withTitle: b) }
        if let window = window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        sheet(text: message, info: "", buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        sheet(text: message, info: "", buttons: ["OK", "Cancel"]) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let done = { (r: NSApplication.ModalResponse) in completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil) }
        if let window = window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }
}
