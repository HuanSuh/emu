// The app: a menu bar item listing the sessions, the hub window, extra
// session windows, notifications and the ⌥⌘E shortcut. Quitting stops only
// a hub this app started — never a session (agents and terminals use them).
import Carbon
import Cocoa
import UserNotifications
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let config = AppConfig.load()
    private lazy var hub = HubClient(config: config)
    private var main: HubWindow?
    private var extra: [HubWindow] = []
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var poll: Timer?
    private var snap: HubSnapshot?
    private var notificationsOK = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "emu")
        statusItem?.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in self?.showHub() }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.notificationsOK = ok } // called on a background queue
        }
        showHub()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHub() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stopIfOwned()
    }

    // ---- hub window --------------------------------------------------------------

    @objc func showHub() {
        if let w = main {
            w.show()
            return
        }
        DispatchQueue.global().async {
            let r = self.hub.ensure()
            DispatchQueue.main.async {
                let url: URL
                switch r {
                case .success(let u): url = u
                case .failure: url = URL(string: "about:blank")!
                }
                let w = HubWindow(url: url, title: "emu", autosave: "emu.hub", hub: self.hub, isMain: true,
                                  sessionPorts: { [weak self] in Set(self?.snap?.sessions.map { $0.port } ?? []) })
                w.onOpenWindow = { [weak self] u in self?.openSessionWindow(u) }
                w.onClose = { [weak self] _ in self?.main = nil }
                w.onRelaunch = { [weak self] in self?.relaunch() }
                self.main = w
                w.show()
                if case .failure(let why) = r { w.showError("Could not start the hub", detail: why.message) }
                self.refresh()
            }
        }
    }

    /// Quit and open this bundle again — an update rebuilt it in place. The
    /// hub keeps running (the new app finds it), even one this app started.
    private func relaunch() {
        hub.disown()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }

    private func openSessionWindow(_ url: URL) {
        if let w = extra.first(where: { $0.webView.url?.port == url.port }) { return w.show() }
        let name = snap?.sessions.first { $0.port == url.port }?.name ?? "session"
        let w = HubWindow(url: url, title: "\(name) — emu", autosave: "emu.session.\(name)", hub: hub, isMain: false,
                          sessionPorts: { [weak self] in Set(self?.snap?.sessions.map { $0.port } ?? []) })
        w.onOpenWindow = { [weak self] u in self?.openSessionWindow(u) }
        w.onClose = { [weak self] closed in self?.extra.removeAll { $0 === closed } }
        extra.append(w)
        w.show()
    }

    private func showSession(_ id: String) {
        if let w = main { w.showSession(id) } else {
            showHub()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.main?.showSession(id) }
        }
    }

    // ---- polling -----------------------------------------------------------------

    private func refresh() {
        DispatchQueue.global().async {
            self.hub.reload()
            let next = self.hub.snapshot()
            DispatchQueue.main.async { self.apply(next) }
        }
    }

    private func apply(_ next: HubSnapshot?) {
        let previous = snap
        snap = next
        statusItem?.button?.title = Policy.statusTitle(next)
        guard let next = next else { return }
        if !NSApp.isActive && notificationsOK {
            for n in Policy.notices(previous: previous, next: next) { notify(n) }
        }
    }

    private func notify(_ n: SessionNotice) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.userInfo = ["session": n.sessionId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["session"] as? String {
            DispatchQueue.main.async { self.showSession(id) }
        }
        done()
    }

    // ---- menu bar ----------------------------------------------------------------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = snap?.sessions ?? []
        menu.addItem(withTitle: sessions.isEmpty ? "No running session" : "Sessions", action: nil, keyEquivalent: "")
        for s in sessions {
            let item = NSMenuItem(title: "\(Policy.stateDot(s.state))  \(s.name)  :\(s.port)\(s.device.map { "  ·  \($0)" } ?? "")",
                                  action: #selector(pickSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.toolTip = s.project
            menu.addItem(item)
        }
        let recent = snap?.recent ?? []
        if !recent.isEmpty {
            let sub = NSMenu()
            for p in recent {
                let starting = snap?.starting.contains(p.project) ?? false
                let item = NSMenuItem(title: starting ? "\(p.name) (starting…)" : p.name,
                                      action: starting ? nil : #selector(startProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.project
                item.toolTip = p.project
                sub.addItem(item)
            }
            let start = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
            start.submenu = sub
            menu.addItem(start)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open emu hub", action: #selector(showHub), keyEquivalent: "e")
        open.keyEquivalentModifierMask = [.command, .option]
        open.target = self
        menu.addItem(open)
        if !sessions.isEmpty {
            let stop = NSMenuItem(title: "Stop all sessions…", action: #selector(stopAll), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let ver = snap?.version.isEmpty == false ? snap!.version : config.version
        menu.addItem(withTitle: "emu \(ver)", action: nil, keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit emu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func pickSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { showSession(id) }
    }

    @objc private func startProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? String else { return }
        DispatchQueue.global().async {
            _ = self.hub.post("api/projects/start", json: ["project": project])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc private func stopAll() {
        let alert = NSAlert()
        alert.messageText = "Stop every emu session?"
        alert.informativeText = "Runs emu down for each of them. Agents or terminals using a session lose it too."
        alert.addButton(withTitle: "Stop all")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            _ = self.hub.run([self.config.emu, "down", "--all"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // ---- main menu (Edit is what makes ⌘C/⌘V work in a web view) ----------------

    private func buildMainMenu() {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            top.submenu = m
            bar.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let openHub = item("Open emu hub", #selector(showHub), "e", [.command, .option])
        openHub.target = self
        add("emu", [
            item("About emu", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            openHub,
            .separator(),
            item("Hide emu", #selector(NSApplication.hide(_:)), "h"),
            item("Quit emu", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("View", [
            item("Reload", #selector(WKWebView.reload(_:)), "r"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = bar
    }
}
