// Finding, starting and asking the emu hub (`emu hub`, lib/src/hub.dart).
// The app never manages sessions itself — it reads the hub's API like the
// hub page does, with the token in ~/.emu/hub.json.
import Foundation

/// `Contents/Resources/app.json`, written by `emu app install`: the emu
/// binary and the PATH of the shell it was installed from (an app started
/// from Finder gets a minimal PATH, without flutter, adb or xcrun).
struct AppConfig {
    let emu: String
    let path: String
    let version: String

    static func load() -> AppConfig {
        let fallback = AppConfig(emu: "emu", path: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", version: "")
        guard let url = Bundle.main.url(forResource: "app", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
        return AppConfig(
            emu: m["emu"] as? String ?? fallback.emu,
            path: m["path"] as? String ?? fallback.path,
            version: m["version"] as? String ?? "")
    }
}

struct HubError: Error { let message: String }

final class HubClient {
    let config: AppConfig
    private(set) var port: Int = 0
    private(set) var token: String = ""
    /// Whether this app started the hub (then it stops it on quit).
    private(set) var startedByApp = false

    init(config: AppConfig) { self.config = config }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private var infoFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".emu/hub.json")
    }

    /// Re-read ~/.emu/hub.json (a restarted hub has a new port or token).
    @discardableResult
    func reload() -> Bool {
        guard let data = try? Data(contentsOf: infoFile),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = m["port"] as? Int else { return false }
        port = p
        token = m["token"] as? String ?? ""
        return true
    }

    /// Whether the recorded hub answers as a hub. Blocking; call off the main thread.
    func alive() -> Bool {
        guard reload(), let data = request("api/status", timeout: 1.5),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return m["hub"] as? Bool == true
    }

    /// The running hub, else start one with `emu hub --no-open`. Blocking.
    func ensure() -> Result<URL, HubError> {
        if alive() { return .success(url) }
        let r = run([config.emu, "hub", "--no-open", "--json"])
        if r.code != 0 {
            return .failure(HubError(message: r.output.isEmpty ? "emu hub exited with \(r.code)" : r.output))
        }
        startedByApp = true
        return alive() ? .success(url) : .failure(HubError(message: "The hub did not answer.\n\(r.output)"))
    }

    func snapshot() -> HubSnapshot? {
        request("api/sessions", timeout: 3).flatMap(Policy.parseSnapshot)
    }

    @discardableResult
    func post(_ path: String, json: [String: Any]? = nil) -> Bool {
        request(path, method: "POST", body: json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }, timeout: 120) != nil
    }

    /// Leave the hub running on quit, even one this app started.
    func disown() { startedByApp = false }

    /// Stop the hub — only one this app started; sessions are never touched.
    func stopIfOwned() {
        guard startedByApp else { return }
        _ = request("api/shutdown", method: "POST", timeout: 2)
    }

    // ---- plumbing ---------------------------------------------------------------

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval) -> Data? {
        guard port > 0, let u = URL(string: path, relativeTo: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(token, forHTTPHeaderField: "X-Emu-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { out = data }
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    /// Run a command with the recorded PATH; stdout + stderr.
    func run(_ argv: [String]) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
