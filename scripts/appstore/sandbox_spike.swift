import AppKit
import Foundation

// Sandbox spike for adr/0018: a sandboxed app running the bundle's Python
// (app-sandbox + inherit) -- GPU, a localhost port, HF_HOME in the
// container, and a model from a folder the user grants in an open panel.
// Results go to ~/spike.log in the container and to stdout.

let home = NSHomeDirectory()
let logURL = URL(fileURLWithPath: home).appendingPathComponent("spike.log")
try? "".write(to: logURL, atomically: true, encoding: .utf8)
func log(_ s: String) {
    print(s); fflush(stdout)
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close() }
}

let res = Bundle.main.resourcePath!
let python = Bundle.main.privateFrameworksPath! + "/Python.framework/Versions/3.14/bin/python3.14"
let sitePackages = res + "/site-packages"

@discardableResult
func runPython(_ code: String, env extra: [String: String] = [:], timeout: TimeInterval = 180) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = ["-c", code]
    var env: [String: String] = [
        "PYTHONPATH": sitePackages, "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
        "HOME": home, "TMPDIR": NSTemporaryDirectory(), "HF_HOME": home + "/hf", "HF_HUB_OFFLINE": "1",
    ]
    extra.forEach { env[$0] = $1 }
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run() } catch { return (-1, "launch failed: \(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate(); return (-2, "timeout") }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func check(_ name: String, _ r: (Int32, String), expect: String? = nil) {
    let ok = r.0 == 0 && (expect == nil || r.1.contains(expect!))
    log("\(ok ? "PASS" : "FAIL") \(name): exit \(r.0)\n    " + r.1.split(separator: "\n").suffix(4).joined(separator: "\n    "))
}

func runTests(modelDir: URL?) {
    log("home (container): \(home)")
    log("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
    // 0. The sandbox is really on: a file outside the container is denied.
    let outside = NSHomeDirectory().components(separatedBy: "/Library/Containers").first! + "/.zshrc"
    let denied = runPython("open('\(outside)').read(1); print('READ')")
    log("\(denied.0 != 0 && denied.1.contains("PermissionError") ? "PASS" : "FAIL") sandbox denies ~/.zshrc to the child")
    // 1. Python + MLX on the GPU.
    check("python + mlx on GPU", runPython("import mlx.core as mx, sys; a=mx.random.normal((512,512)); print(sys.version.split()[0], mx.default_device(), float((a@a).sum())!=0)"), expect: "gpu")
    // 2. HF_HOME in the container.
    check("write HF_HOME in the container", runPython("import os; d=os.environ['HF_HOME']; os.makedirs(d, exist_ok=True); open(d+'/probe.txt','w').write('x'); print('wrote', d)"), expect: "wrote")
    // 3. A child binds a localhost port; the app connects.
    let server = Process()
    server.executableURL = URL(fileURLWithPath: python)
    server.arguments = ["-c", "import http.server, socketserver\nclass H(http.server.BaseHTTPRequestHandler):\n    def do_GET(self):\n        self.send_response(200); self.end_headers(); self.wfile.write(b'pong')\n    def log_message(self,*a): pass\nwith socketserver.TCPServer(('127.0.0.1', 18999), H) as s: s.handle_request()"]
    server.environment = ["PYTHONDONTWRITEBYTECODE": "1", "HOME": home]
    try? server.run()
    Thread.sleep(forTimeInterval: 1.5)
    let sem = DispatchSemaphore(value: 0); var body = ""
    URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:18999/")!) { d, r, e in
        body = d.flatMap { String(data: $0, encoding: .utf8) } ?? "error: \(e?.localizedDescription ?? "none")"; sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    log("\(body == "pong" ? "PASS" : "FAIL") child serves localhost, app connects: \(body)")
    server.terminate()
    // 4. A model from the user-granted folder, read by the child.
    guard let dir = modelDir else { log("SKIP model from a granted folder: none chosen"); return }
    let bookmark = try? dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    var stale = false
    let resolved = bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) }
    let accessing = resolved?.startAccessingSecurityScopedResource() ?? false
    log("bookmark: \(bookmark != nil), resolved: \(resolved?.path ?? "nil"), accessing: \(accessing)")
    let path = (resolved ?? dir).path
    check("child lists the granted folder", runPython("import os; print(sorted(os.listdir('\(path)'))[:3])"), expect: "config.json")
    check("child runs mlx_lm on the granted model", runPython("from mlx_lm import load, generate\nm,t=load('\(path)')\nprint('GEN', repr(generate(m,t,prompt='The capital of France is',max_tokens=6)))"), expect: "GEN")
    resolved?.stopAccessingSecurityScopedResource()
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "LLMTray sandbox test: choose the llmtray-spike-model folder, then Open"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory().components(separatedBy: "/Library/Containers").first! + "/Downloads/llmtray-spike-model")
        let dir = panel.runModal() == .OK ? panel.url : nil
        DispatchQueue.global().async {
            runTests(modelDir: dir)
            log("DONE")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
