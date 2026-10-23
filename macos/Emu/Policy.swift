// Pure decisions of the app (no UI), so `emu.app/Contents/MacOS/emu --self-test`
// can check them: which URLs stay in the window, which session changes are
// worth a notification, how the menu bar title reads.
import Foundation

struct SessionInfo: Equatable {
    let id: String
    let name: String
    let project: String
    let port: Int
    let state: String
    let device: String?
}

struct RecentProject: Equatable {
    let project: String
    let name: String
}

struct HubSnapshot: Equatable {
    var sessions: [SessionInfo] = []
    var recent: [RecentProject] = []
    var starting: [String] = []
    var version: String = ""
}

struct SessionNotice: Equatable {
    let sessionId: String
    let title: String
    let body: String
}

enum Policy {
    /// `GET /api/sessions` of the hub.
    static func parseSnapshot(_ data: Data) -> HubSnapshot? {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var snap = HubSnapshot()
        snap.version = m["version"] as? String ?? ""
        for s in m["sessions"] as? [[String: Any]] ?? [] {
            guard let id = s["id"] as? String, let port = s["port"] as? Int else { continue }
            let device = s["device"] as? [String: Any]
            snap.sessions.append(SessionInfo(
                id: id,
                name: s["name"] as? String ?? id,
                project: s["project"] as? String ?? "",
                port: port,
                state: s["state"] as? String ?? "unknown",
                device: (device?["name"] as? String) ?? (device?["id"] as? String)))
        }
        for p in m["recent"] as? [[String: Any]] ?? [] {
            guard let project = p["project"] as? String else { continue }
            snap.recent.append(RecentProject(project: project, name: p["name"] as? String ?? project))
        }
        snap.starting = m["starting"] as? [String] ?? []
        return snap
    }

    /// Whether [url] may load inside the app: the hub and the session
    /// dashboards (loopback, their ports), and the blank/blob documents pages
    /// make for themselves. Everything else goes to the default browser.
    static func isInternal(_ url: URL, hubPort: Int, sessionPorts: Set<Int>) -> Bool {
        switch url.scheme {
        case "about":
            return true
        case "blob":
            // blob:<origin>/<uuid> — only blobs the hub or a session page made.
            let inner = String(url.absoluteString.dropFirst("blob:".count))
            guard let origin = URL(string: inner), origin.scheme == "http" else { return false }
            return isInternal(origin, hubPort: hubPort, sessionPorts: sessionPorts)
        case "http":
            guard let host = url.host, host == "127.0.0.1" || host == "localhost", let port = url.port else { return false }
            return port == hubPort || sessionPorts.contains(port)
        default:
            return false
        }
    }

    /// External links a person clicked open in the default browser; anything
    /// else leaving the app (scripts, redirects) is dropped.
    static func opensExternally(_ url: URL, userClicked: Bool) -> Bool {
        guard userClicked else { return false }
        return ["http", "https", "mailto"].contains(url.scheme ?? "")
    }

    /// What changed between two polls that is worth telling someone who is
    /// not looking: an app that stopped or failed, a session that came up.
    static func notices(previous: HubSnapshot?, next: HubSnapshot) -> [SessionNotice] {
        guard let previous = previous else { return [] } // first poll: no history
        var out: [SessionNotice] = []
        let before = Dictionary(uniqueKeysWithValues: previous.sessions.map { ($0.id, $0) })
        for s in next.sessions {
            guard let old = before[s.id] else {
                if previous.starting.contains(s.project) || s.state == "running" {
                    out.append(SessionNotice(sessionId: s.id, title: "\(s.name) is up", body: s.device.map { "on \($0)" } ?? s.project))
                }
                continue
            }
            if old.state == s.state { continue }
            if s.state == "failed" {
                out.append(SessionNotice(sessionId: s.id, title: "\(s.name) failed", body: "The app did not start — see its log."))
            } else if old.state == "running" && s.state == "stopped" {
                out.append(SessionNotice(sessionId: s.id, title: "\(s.name) stopped", body: "The app is no longer running."))
            }
        }
        return out
    }

    /// Menu bar title: the number of sessions, "!" when one failed.
    static func statusTitle(_ snap: HubSnapshot?) -> String {
        guard let snap = snap else { return "" }
        let failed = snap.sessions.contains { $0.state == "failed" }
        return snap.sessions.isEmpty ? "" : "\(snap.sessions.count)\(failed ? "!" : "")"
    }

    static func stateDot(_ state: String) -> String {
        switch state {
        case "running": return "🟢"
        case "starting", "restarting": return "🟡"
        case "failed": return "🔴"
        default: return "⚪️"
        }
    }

    // ---- self test --------------------------------------------------------------

    static func selfTest() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("✗ \(what)") }
        }
        let u = { (s: String) in URL(string: s)! }
        check(isInternal(u("http://127.0.0.1:4576/"), hubPort: 4576, sessionPorts: []), "hub is internal")
        check(isInternal(u("http://127.0.0.1:4578/x"), hubPort: 4576, sessionPorts: [4578]), "session is internal")
        check(!isInternal(u("http://127.0.0.1:9999/"), hubPort: 4576, sessionPorts: [4578]), "other port is not")
        check(!isInternal(u("http://evil.test:4576/"), hubPort: 4576, sessionPorts: []), "other host is not")
        check(!isInternal(u("https://127.0.0.1:4576/"), hubPort: 4576, sessionPorts: []), "https is not")
        check(isInternal(u("about:blank"), hubPort: 4576, sessionPorts: []), "about:blank is")
        check(!isInternal(u("file:///etc/passwd"), hubPort: 4576, sessionPorts: []), "file is not")
        check(isInternal(u("blob:http://127.0.0.1:4578/9f1c"), hubPort: 4576, sessionPorts: [4578]), "a session blob is")
        check(!isInternal(u("blob:http://127.0.0.1:9999/9f1c"), hubPort: 4576, sessionPorts: [4578]), "another origin's blob is not")
        check(!isInternal(u("blob:https://example.com/9f1c"), hubPort: 4576, sessionPorts: []), "a remote blob is not")
        check(!isInternal(u("data:text/html,hi"), hubPort: 4576, sessionPorts: []), "data is not")
        check(!isInternal(u("javascript:alert(1)"), hubPort: 4576, sessionPorts: []), "javascript is not")
        check(opensExternally(u("https://example.com"), userClicked: true), "clicked link opens")
        check(!opensExternally(u("https://example.com"), userClicked: false), "scripted one does not")
        check(!opensExternally(u("file:///x"), userClicked: true), "file never opens")

        let json = """
        {"version":"0.13.0","sessions":[{"id":"aaaaaaaaaaaa","name":"app","project":"/w/app","port":4578,
        "state":"running","device":{"id":"emulator-5554","name":"Pixel"}}],"starting":[],
        "recent":[{"project":"/w/other","name":"other","port":4580}]}
        """
        let snap = parseSnapshot(json.data(using: .utf8)!)
        check(snap?.sessions.first?.device == "Pixel", "parses device name")
        check(snap?.recent.first?.name == "other", "parses recent")
        check(statusTitle(snap) == "1", "title counts sessions")

        func s(_ state: String, id: String = "a", project: String = "/w/app") -> SessionInfo {
            SessionInfo(id: id, name: "app", project: project, port: 1, state: state, device: nil)
        }
        let running = HubSnapshot(sessions: [s("running")])
        check(notices(previous: nil, next: running).isEmpty, "no notice on the first poll")
        check(notices(previous: running, next: HubSnapshot(sessions: [s("failed")])).first?.title == "app failed", "failed")
        check(notices(previous: running, next: HubSnapshot(sessions: [s("stopped")])).first?.title == "app stopped", "stopped")
        check(notices(previous: running, next: running).isEmpty, "no change, no notice")
        check(notices(previous: HubSnapshot(starting: ["/w/b"]), next: HubSnapshot(sessions: [s("starting", id: "b", project: "/w/b")])).count == 1,
              "a started project is announced")
        check(statusTitle(HubSnapshot(sessions: [s("failed")])) == "1!", "title flags a failure")
        print(failures == 0 ? "✓ policy self-test passed" : "\(failures) failure(s)")
        return failures
    }
}
