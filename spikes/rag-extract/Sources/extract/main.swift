import Darwin
import ExtractKit
import Foundation

// The stand-in for `LLMTray --extract <path>`: one JSON line per page on
// stdout, a summary on stderr, exit 0 on success, 2 on a handled failure
// (the error is also a JSON line: {"page":0,"error":...}).
//
//   extract <path> [--kind pdf|docx|...] [--max-text BYTES] [--rows-per-block N]
//           [--rlimit-cpu SECONDS] [--rlimit-as MB] [--rlimit-data MB] [--rlimit-fsize MB]
//           [--no-network]      (sandbox_init with the no-network profile)
//           [--kind-only]       (print the detected type and exit)

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

var limits = Limits()
let kindArg = opt("--kind").flatMap(Kind.init(rawValue:))
if let t = opt("--max-text").flatMap(Int.init) { limits.maxTextBytes = t }
if let r = opt("--rows-per-block").flatMap(Int.init) { limits.rowsPerBlock = r }
if let m = opt("--max-file").flatMap(Int.init) { limits.maxFileBytes = m }
if let m = opt("--max-pages").flatMap(Int.init) { limits.maxPages = m }
if flag("--no-zip-precheck") { limits.skipZipPrecheck = true }

// Self-applied resource limits: the parent can't set rlimits through
// Process/posix_spawn on macOS (no posix_spawnattr_setrlimit), so the trusted
// child code applies them to itself before touching the hostile file.
func setLimit(_ res: Int32, _ value: rlim_t, _ label: String) {
    var rl = rlimit(rlim_cur: value, rlim_max: value)
    if setrlimit(res, &rl) != 0 {
        FileHandle.standardError.write("setrlimit(\(label)) failed: \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
    }
}
if let v = opt("--rlimit-cpu").flatMap(UInt64.init) { setLimit(RLIMIT_CPU, v, "CPU") }
if let v = opt("--rlimit-as").flatMap(UInt64.init) { setLimit(RLIMIT_AS, v << 20, "AS") }
if let v = opt("--rlimit-data").flatMap(UInt64.init) { setLimit(RLIMIT_DATA, v << 20, "DATA") }
if let v = opt("--rlimit-fsize").flatMap(UInt64.init) { setLimit(RLIMIT_FSIZE, v << 20, "FSIZE") }
setLimit(RLIMIT_CORE, 0, "CORE")

if flag("--no-network") {
    // Deprecated but functional: the built-in "no network" profile.
    // sandbox.h isn't in Swift's Darwin module; resolve it at run time.
    typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    var err: UnsafeMutablePointer<CChar>?
    let profile = "no-network"   // kSBXProfileNoNetwork
    let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init")   // RTLD_DEFAULT
    let sandboxInit = unsafeBitCast(sym, to: SandboxInit.self)
    if sym == nil || sandboxInit(profile, 1 /* SANDBOX_NAMED */, &err) != 0 {
        FileHandle.standardError.write("sandbox_init failed: \(err.map { String(cString: $0) } ?? "?")\n".data(using: .utf8)!)
    }
}
let kindOnly = flag("--kind-only")

guard let path = args.first else {
    FileHandle.standardError.write("usage: extract <path> [options]\n".data(using: .utf8)!)
    exit(64)
}

if kindOnly {
    let d = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)) ?? Data()
    print(Detect.kind(of: d, limits: limits).rawValue)
    exit(0)
}

let emitter = Emitter(limits: limits)
let t0 = Date()
do {
    let kind = try Extract.run(path: path, limits: limits, emitter: emitter, forceKind: kindArg)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    FileHandle.standardError.write("kind=\(kind.rawValue) pages=\(emitter.count) ms=\(ms)\(emitter.capped ? " text-capped" : "")\n".data(using: .utf8)!)
    exit(0)
} catch {
    var p = PageOut(page: 0, text: "", error: "\(error)")
    p.junk_score = 1
    emitter.emit(p)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    FileHandle.standardError.write("failed ms=\(ms): \(error)\n".data(using: .utf8)!)
    exit(2)
}
