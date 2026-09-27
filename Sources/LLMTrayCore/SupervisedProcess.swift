import Darwin
import Foundation

/// A child that parses hostile input (adr/0012, Extraction): started with
/// `posix_spawn` in its own process group, since `Process` can set neither
/// that nor a memory limit, and watched from the parent side -- the
/// safety contract is these public mechanisms; the kernel's jetsam limit
/// only tightens it when its private symbol resolves.
extension ProcessRunner {
    public struct Supervision: Sendable {
        /// Wall clock, spawn to exit; past it the group is killed.
        public var timeout: TimeInterval
        /// Bytes read from stdout at most.
        public var maxStdoutBytes: Int
        /// Physical footprint, polled every `pollInterval`; nil: not polled.
        public var maxFootprintBytes: UInt64?
        /// The kernel's fatal memory limit, set at spawn when
        /// `posix_spawnattr_setjetsam_ext` (private) resolves; nil: not asked.
        public var jetsamLimitBytes: Int?
        public var pollInterval: TimeInterval = 0.02

        public init(timeout: TimeInterval, maxStdoutBytes: Int, maxFootprintBytes: UInt64? = nil, jetsamLimitBytes: Int? = nil) {
            self.timeout = timeout
            self.maxStdoutBytes = maxStdoutBytes
            self.maxFootprintBytes = maxFootprintBytes
            self.jetsamLimitBytes = jetsamLimitBytes
        }
    }

    /// Which limit ended the child.
    public enum SupervisedLimit: String, Sendable {
        case timeout
        case stdout
        /// The polled footprint, or a SIGKILL the parent didn't send while
        /// the jetsam limit was set.
        case memory
        /// SIGXCPU: the RLIMIT_CPU the child set on itself.
        case cpu
        /// `onLine` returned false.
        case stoppedByCaller
    }

    public struct SupervisedExit: Sendable {
        /// The exit code; nil when a signal ended it.
        public var status: Int32?
        public var signal: Int32?
        public var limit: SupervisedLimit?
        public var peakFootprint: UInt64
        public var jetsamApplied: Bool
        public var stdoutBytes: Int
        public var stderrTail: String
        public var wallTime: TimeInterval
    }

    /// Runs `executable` under `supervision`, handing each complete stdout
    /// line to `onLine` (on the supervising thread, in order); `onLine`
    /// returning false kills the group. Returns however the child ended --
    /// the caller reads `limit`, `status` and `signal`; throws only when it
    /// can't be started, or on cancellation (after the group is killed and
    /// the child reaped). stdin is /dev/null; no other descriptor of the app
    /// reaches the child.
    public static func runSupervised(
        _ executable: String, _ arguments: [String],
        environment: [String: String]? = nil,
        supervision: Supervision,
        onLine: @escaping @Sendable (String) -> Bool
    ) async throws -> SupervisedExit {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SupervisedExit, Error>) in
                let thread = Thread {
                    do {
                        let child = try SupervisedChild.spawn(executable, arguments, environment: environment,
                                                              jetsamLimitBytes: supervision.jetsamLimitBytes)
                        let exit = child.supervise(supervision, cancel: cancel, onLine: onLine)
                        if cancel.isSet { continuation.resume(throwing: CancellationError()) } else { continuation.resume(returning: exit) }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "LLMTray supervisor"
                thread.start()
            }
        } onCancel: {
            cancel.set()
        }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// One spawned child and the parent's ends of its pipes; used from the
/// supervising thread only.
private struct SupervisedChild {
    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32
    let jetsamApplied: Bool
    let started: UInt64

    typealias SetJetsam = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int16, Int32, Int32, Int32) -> Int32

    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String]?,
                      jetsamLimitBytes: Int?) throws -> SupervisedChild {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&errPipe) == 0 else {
            outPipe.forEach { close($0) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Not inherited by anything else the app starts meanwhile (the
        // child gets its ends through dup2, which clears the flag).
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own group, so one kill reaches whatever the child starts; no
        // descriptor but 0-2; the app ignores SIGPIPE, the child must not.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults: sigset_t = 1 << (UInt32(SIGPIPE) - 1)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask: sigset_t = 0
        posix_spawnattr_setsigmask(&attr, &mask)

        var jetsamApplied = false
        if let limit = jetsamLimitBytes,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_setjetsam_ext") {   // RTLD_DEFAULT
            let setJetsam = unsafeBitCast(symbol, to: SetJetsam.self)
            let megabytes = Int32(clamping: max(1, limit >> 20))
            // POSIX_SPAWN_JETSAM_SET | MEMLIMIT_ACTIVE_FATAL | MEMLIMIT_INACTIVE_FATAL;
            // priority -1 leaves the band as it is. Killed at the limit, no
            // overshoot (spike: 504 MB max RSS at a 500 MB limit).
            jetsamApplied = setJetsam(&attr, Int16(bitPattern: 0x8000 | 0x04 | 0x08), -1, megabytes, megabytes) == 0
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var env = ProcessInfo.processInfo.environment
        if let environment { env.merge(environment) { $1 } }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        return SupervisedChild(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0],
                               jetsamApplied: jetsamApplied, started: DispatchTime.now().uptimeNanoseconds)
    }

    /// Reads, polls and kills until the child is reaped and its pipes closed.
    func supervise(_ s: ProcessRunner.Supervision, cancel: CancelFlag,
                   onLine: (String) -> Bool) -> ProcessRunner.SupervisedExit {
        let pollMs = Int32(max(1, (s.pollInterval * 1000).rounded()))
        let deadline = started + UInt64(max(0, s.timeout) * 1e9)
        var fds = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        let lines = LineSplitter()
        var stderrTail = Data()
        var stdoutBytes = 0
        var limit: ProcessRunner.SupervisedLimit?
        var peak: UInt64 = 0
        var status: Int32 = 0
        var reapedAt: UInt64?
        var lastFootprintCheck: UInt64 = 0

        func fire(_ why: ProcessRunner.SupervisedLimit) {
            if limit == nil { limit = why }
            // The whole group -- only while it's ours: once the child is
            // reaped its pgid can belong to someone else.
            if reapedAt == nil { Darwin.kill(-pid, SIGKILL) }
        }

        while true {
            if fds.contains(where: { $0.fd >= 0 }) {
                if poll(&fds, 2, pollMs) > 0 {
                    for k in 0..<2 where fds[k].fd >= 0 && fds[k].revents != 0 {
                        let n = read(fds[k].fd, buffer, bufferSize)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 {
                            close(fds[k].fd)
                            fds[k].fd = -1
                            if k == 0, limit == nil, let last = lines.flush(), !onLine(last) { fire(.stoppedByCaller) }
                            continue
                        }
                        if k == 1 {
                            stderrTail.append(buffer, count: n)
                            if stderrTail.count > 8192 { stderrTail = Data(stderrTail.suffix(4096)) }
                            continue
                        }
                        stdoutBytes += n
                        if stdoutBytes > s.maxStdoutBytes { fire(.stdout) }
                        // Nothing more is delivered once a limit fired.
                        guard limit == nil else { continue }
                        for line in lines.append(Data(bytes: buffer, count: n)) where !onLine(line) {
                            fire(.stoppedByCaller)
                            break
                        }
                    }
                }
            } else if reapedAt == nil {
                usleep(useconds_t(pollMs) * 1000)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if reapedAt == nil {
                // Exited? Looked at without reaping, so the group can still be
                // killed by the child's pid (its grandchildren, if any).
                var info = siginfo_t()
                let waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if waited == 0, info.si_pid == pid {
                    Darwin.kill(-pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    reapedAt = now
                } else if waited < 0, errno == ECHILD {
                    // Reaped by someone else (nothing in the app does that
                    // today): no status to read, but no spinning either.
                    if limit == nil { limit = .stoppedByCaller }
                    reapedAt = now
                } else {
                    if now - lastFootprintCheck >= UInt64(pollMs) * 1_000_000 {
                        lastFootprintCheck = now
                        if let footprint = Self.footprint(pid) {
                            peak = max(peak, footprint)
                            if let max = s.maxFootprintBytes, footprint > max { fire(.memory) }
                        }
                    }
                    if now > deadline { fire(.timeout) }
                    if cancel.isSet { Darwin.kill(-pid, SIGKILL) }
                }
            }
            if let reapedAt {
                // Done once both pipes are at EOF -- or 2 s after the exit, if
                // something outside the group still holds them.
                if !fds.contains(where: { $0.fd >= 0 }) || now - reapedAt > 2_000_000_000 { break }
            }
        }
        for fd in fds where fd.fd >= 0 { close(fd.fd) }

        let signal: Int32? = status & 0x7F == 0 ? nil : status & 0x7F
        if limit == nil, let signal {
            if signal == SIGXCPU { limit = .cpu }
            // A SIGKILL nobody here sent: the kernel's memory limit.
            if signal == SIGKILL, jetsamApplied, !cancel.isSet { limit = .memory }
        }
        return ProcessRunner.SupervisedExit(
            status: signal == nil ? (status >> 8) & 0xFF : nil, signal: signal, limit: limit,
            peakFootprint: peak, jetsamApplied: jetsamApplied, stdoutBytes: stdoutBytes,
            stderrTail: String(decoding: stderrTail.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            wallTime: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
    }

    /// The child's physical footprint -- what jetsam and Activity Monitor count.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }
}
