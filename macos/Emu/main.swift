// emu.app — a thin macOS shell around `emu hub` (docs/HUB.md §3).
// Built on this machine by `emu app install` (swiftc, no Xcode project).
import Cocoa

if CommandLine.arguments.contains("--self-test") {
    exit(Policy.selfTest() == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
