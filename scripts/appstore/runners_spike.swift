import AppKit
import Foundation

// adr/0018: the App Store build's image, music and voice runners inside the
// sandbox. A sandboxed app with that build's Python and packages runs
// runners_spike_harness.py (app-sandbox + inherit, like the app's runners);
// the models come from the standalone LLMTray's folder through a read-only
// exception only this test app has. Results go to stdout.

let home = NSHomeDirectory()
let res = Bundle.main.resourcePath!
let versions = Bundle.main.privateFrameworksPath! + "/Python.framework/Versions"
let version = ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []).first { $0 != "Current" } ?? "3.14"
let python = "\(versions)/\(version)/bin/python\(version)"
let models = home.components(separatedBy: "/Library/Containers").first! + "/Library/Application Support/LLMTray"

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [res + "/runners_spike_harness.py", res + "/runtime", models]
            // What BundledRuntime.configureEnvironment sets.
            p.environment = [
                "PYTHONPATH": res + "/python-packages", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                "HOME": home, "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin",
            ]
            p.standardOutput = FileHandle.standardOutput
            p.standardError = FileHandle.standardError
            do { try p.run(); p.waitUntilExit() } catch { print("FAIL launch \(error)") }
            print("DONE exit \(p.terminationStatus)"); fflush(stdout)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
