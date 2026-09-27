import Darwin
import Foundation

// supervise [--timeout S] [--mem MB] [--max-out BYTES] [--poll-ms N]
//           [--jetsam MB] [--quiet] -- <child> [args...]
//
// The parent side of `LLMTray --extract`: posix_spawn the child in its own
// process group, read its stdout (capped), and kill the group on
//   - wall-clock timeout,
//   - phys_footprint over --mem (polled with proc_pid_rusage every --poll-ms),
//   - stdout over --max-out bytes.
// --jetsam MB additionally asks the kernel for a fatal per-process memory
// limit at spawn (private posix_spawnattr_setjetsam_ext, resolved by dlsym).
// Prints one JSON summary line on stderr.

var argv = Array(CommandLine.arguments.dropFirst())
guard let sep = argv.firstIndex(of: "--") else {
    FileHandle.standardError.write("usage: supervise [opts] -- child args...\n".data(using: .utf8)!)
    exit(64)
}
let child = Array(argv[(sep + 1)...])
argv = Array(argv[..<sep])
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let timeout = Double(opt("--timeout") ?? "30")!
let memMB = Int(opt("--mem") ?? "0")!
let maxOut = Int(opt("--max-out") ?? "0")!
let pollMs = Int(opt("--poll-ms") ?? "20")!
let jetsamMB = Int(opt("--jetsam") ?? "0")!
let quiet = argv.contains("--quiet")

var attr: posix_spawnattr_t?
posix_spawnattr_init(&attr)
// Own process group, so a kill reaches anything the child spawns too.
var flags = Int16(POSIX_SPAWN_SETPGROUP)
posix_spawnattr_setpgroup(&attr, 0)
posix_spawnattr_setflags(&attr, flags)
var jetsamResult = "not requested"
if jetsamMB > 0 {
    typealias SetJetsam = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int16, Int32, Int32, Int32) -> Int32
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_setjetsam_ext") {
        let f = unsafeBitCast(sym, to: SetJetsam.self)
        // POSIX_SPAWN_JETSAM_SET 0x8000 | MEMLIMIT_ACTIVE_FATAL 0x04 | MEMLIMIT_INACTIVE_FATAL 0x08; priority -1: unchanged
        let r = f(&attr, Int16(bitPattern: 0x8000 | 0x04 | 0x08), -1, Int32(jetsamMB), Int32(jetsamMB))
        jetsamResult = "setjetsam_ext=\(r)"
    } else {
        jetsamResult = "posix_spawnattr_setjetsam_ext not found"
    }
}
flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
posix_spawnattr_setflags(&attr, flags)

var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
pipe(&outPipe); pipe(&errPipe)
var fa: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&fa)
posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)

var pid: pid_t = 0
let cargs = child.map { strdup($0) } + [nil]
let t0 = Date()
let rc = posix_spawn(&pid, child[0], &fa, &attr, cargs, environ)
close(outPipe[1]); close(errPipe[1])
guard rc == 0 else {
    FileHandle.standardError.write("posix_spawn failed: \(String(cString: strerror(rc)))\n".data(using: .utf8)!)
    exit(70)
}

let lock = NSLock()
var outBytes = 0, lines = 0
var killedBy: String? = nil
var peakFootprint: UInt64 = 0
var errTail = Data()

func kill(_ why: String) {
    lock.lock()
    if killedBy == nil { killedBy = why }
    lock.unlock()
    Darwin.kill(-pid, SIGKILL)   // the whole group
}

// stdout reader: counts bytes and lines, enforces the output cap.
let outDone = DispatchSemaphore(value: 0)
Thread {
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    let sink = quiet ? nil : FileHandle.standardOutput
    while true {
        let n = read(outPipe[0], &buf, buf.count)
        if n <= 0 { break }
        lock.lock()
        outBytes += n
        lines += buf[0..<n].filter { $0 == 0x0A }.count
        let over = maxOut > 0 && outBytes > maxOut
        lock.unlock()
        sink?.write(Data(buf[0..<n]))
        if over { kill("output cap \(maxOut) bytes"); break }
    }
    outDone.signal()
}.start()
Thread {
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(errPipe[0], &buf, buf.count)
        if n <= 0 { break }
        lock.lock(); errTail.append(contentsOf: buf[0..<n]); if errTail.count > 2048 { errTail = errTail.suffix(2048) }; lock.unlock()
    }
}.start()

// Watchdog: wall clock + footprint polling.
var status: Int32 = 0
var exited = false
while !exited {
    let r = waitpid(pid, &status, WNOHANG)
    if r == pid { exited = true; break }
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if ok == 0 {
        peakFootprint = max(peakFootprint, info.ri_phys_footprint)
        if memMB > 0 && info.ri_phys_footprint > UInt64(memMB) << 20 { kill("memory \(info.ri_phys_footprint >> 20) MB > \(memMB) MB") }
    }
    if Date().timeIntervalSince(t0) > timeout { kill("timeout \(timeout) s") }
    usleep(useconds_t(pollMs * 1000))
}
_ = outDone.wait(timeout: .now() + 2)
let wall = Date().timeIntervalSince(t0)
var ru = rusage()
getrusage(RUSAGE_CHILDREN, &ru)
let sig: Int32 = (status & 0x7F) != 0 ? (status & 0x7F) : 0
let code: Int32 = sig == 0 ? (status >> 8) & 0xFF : -1
let summary: [String: Any] = [
    "exit": code, "signal": sig, "killed_by": killedBy ?? NSNull(),
    "wall_ms": Int(wall * 1000), "peak_footprint_mb": Int(peakFootprint >> 20),
    "max_rss_mb": Int(ru.ru_maxrss >> 20), "out_bytes": outBytes, "lines": lines,
    "jetsam": jetsamResult, "stderr_tail": String(decoding: errTail.suffix(300), as: UTF8.self),
]
let js = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
FileHandle.standardError.write(js + Data([0x0A]))
exit(0)
