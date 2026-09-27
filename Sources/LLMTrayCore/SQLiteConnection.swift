import Foundation
import SQLite3

/// A failed SQLite call: the extended result code and SQLite's message.
public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var primaryCode: Int32 { code & 0xFF }
    /// Another connection holds the lock (retry later).
    public var isBusy: Bool { primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED }
    public var description: String { "SQLite \(code): \(message)" }
}

/// A serial queue that owns connections: a connection bound to one refuses
/// (SQLITE_MISUSE) every call made anywhere else, so one that leaked out of
/// its queue -- through a closure's result or a capture -- can't be used
/// concurrently with its owner (the connections are SQLITE_OPEN_NOMUTEX).
/// `isCurrent` also tells the queue's own work that it's already on it.
public final class ConnectionQueue: @unchecked Sendable {
    public let queue: DispatchQueue
    private let key = DispatchSpecificKey<ObjectIdentifier>()

    public init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: ObjectIdentifier(self))
    }

    /// Running on `queue`.
    public var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == ObjectIdentifier(self) }
}

/// A value bound to a statement parameter.
public enum SQLValue: Equatable {
    case int(Int64), double(Double), text(String), blob(Data), null
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One connection to the system SQLite, used by one thread at a time
/// (Apple's build is multi-thread mode: a connection must never be shared
/// concurrently; ProjectIndexRegistry gives each its own serial queue).
/// Statements it hands out are finalized before it closes.
public final class SQLiteConnection {
    public let path: String
    public let isReadOnly: Bool
    private(set) var handle: OpaquePointer?
    private var cache: [String: SQLiteStatement] = [:]
    /// When set, every call must come from this queue.
    public var owner: ConnectionQueue?
    /// SQLite VM operations run by this connection's statements (tests: what
    /// a call costs, independent of the clock).
    var vmSteps: Int64 = 0

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = h
        self.path = path
        isReadOnly = readOnly
        sqlite3_extended_result_codes(h, 1)
    }

    deinit { close() }

    /// Finalizes every cached statement and closes. Statements prepared
    /// outside the cache must be gone already (sqlite3_close_v2 would
    /// otherwise keep the file open as a zombie until they are).
    public func close() {
        cache.values.forEach { $0.finalize() }
        cache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    public var isOpen: Bool { handle != nil }

    var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed" }

    private func live() throws -> OpaquePointer {
        try checkOwner()
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection closed") }
        return handle
    }

    func checkOwner() throws {
        if let owner, !owner.isCurrent { throw SQLiteError(code: SQLITE_MISUSE, message: "connection used outside its queue") }
    }

    public func exec(_ sql: String) throws {
        let h = try live()
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_extended_errcode(h), message: message)
        }
    }

    /// A new statement, finalized when released.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        let h = try live()
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else { throw SQLiteError(code: rc, message: "\(errorMessage) in: \(sql)") }
        return SQLiteStatement(st, connection: self)
    }

    /// A statement kept for the connection's life (the hot queries).
    public func cached(_ sql: String) throws -> SQLiteStatement {
        try checkOwner()
        if let st = cache[sql] {
            st.reset()
            return st
        }
        let st = try prepare(sql)
        cache[sql] = st
        return st
    }

    /// Runs a statement to completion, rows discarded.
    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let st = try cached(sql)
        defer { st.reset() }
        try st.bind(args)
        while try st.step() {}
    }

    public func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64? {
        let st = try cached(sql)
        defer { st.reset() }
        try st.bind(args)
        guard try st.step() else { return nil }
        return st.isNull(0) ? nil : st.int(0)
    }

    public func scalarText(_ sql: String, _ args: [SQLValue] = []) throws -> String? {
        let st = try cached(sql)
        defer { st.reset() }
        try st.bind(args)
        guard try st.step() else { return nil }
        return st.isNull(0) ? nil : st.text(0)
    }

    /// Every row, mapped while the statement is on it.
    public func rows<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLiteStatement) throws -> T) throws -> [T] {
        let st = try cached(sql)
        defer { st.reset() }
        try st.bind(args)
        var out: [T] = []
        while try st.step() { out.append(try map(st)) }
        return out
    }

    public var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    public var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }
    /// False inside BEGIN ... COMMIT.
    public var isAutocommit: Bool { handle.map { sqlite3_get_autocommit($0) != 0 } ?? true }

    /// `body` inside one transaction, committed when it returns, rolled back
    /// when it throws. Synchronous by construction: nothing may await while
    /// a write transaction is open (adr/0012, Concurrency).
    public func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        guard isAutocommit else { throw SQLiteError(code: SQLITE_MISUSE, message: "nested transaction") }
        try exec(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            if !isAutocommit { try? exec("ROLLBACK") }
            throw error
        }
    }

    public func setBusyTimeout(milliseconds: Int32) {
        if let handle { sqlite3_busy_timeout(handle, milliseconds) }
    }

    /// sqlite3_wal_checkpoint_v2; throws on BUSY and errors.
    @discardableResult
    public func checkpoint(truncate: Bool) throws -> (logFrames: Int32, checkpointed: Int32) {
        let h = try live()
        var log: Int32 = -1, done: Int32 = -1
        let rc = sqlite3_wal_checkpoint_v2(h, nil, truncate ? SQLITE_CHECKPOINT_TRUNCATE : SQLITE_CHECKPOINT_PASSIVE, &log, &done)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: errorMessage) }
        return (log, done)
    }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }
    public static var libraryVersionNumber: Int32 { sqlite3_libversion_number() }
    public static func compileOptionUsed(_ name: String) -> Bool { sqlite3_compileoption_used(name) == 1 }
}

/// A prepared statement of one connection.
public final class SQLiteStatement {
    private var st: OpaquePointer?
    private unowned let connection: SQLiteConnection

    init(_ st: OpaquePointer, connection: SQLiteConnection) {
        self.st = st
        self.connection = connection
    }

    deinit { finalize() }

    func finalize() {
        if let st { sqlite3_finalize(st) }
        st = nil
    }

    /// sqlite3_reset, counting the run's VM operations first.
    private func rewind(_ st: OpaquePointer) {
        connection.vmSteps += Int64(sqlite3_stmt_status(st, SQLITE_STMTSTATUS_VM_STEP, 1))
        sqlite3_reset(st)
    }

    /// Ends the current run (releases the read snapshot) and clears bindings.
    public func reset() {
        guard let st else { return }
        rewind(st)
        sqlite3_clear_bindings(st)
    }

    private func live() throws -> OpaquePointer {
        try connection.checkOwner()
        guard let st else { throw SQLiteError(code: SQLITE_MISUSE, message: "statement finalized") }
        return st
    }

    public func bind(_ args: [SQLValue]) throws {
        let st = try live()
        rewind(st)
        sqlite3_clear_bindings(st)
        for (i, value) in args.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(st, index, v)
            case .double(let v): rc = sqlite3_bind_double(st, index, v)
            case .text(let v): rc = sqlite3_bind_text(st, index, v, Int32(v.utf8.count), transientDestructor)   // all bytes, NULs too
            case .blob(let d):
                rc = d.withUnsafeBytes { p in
                    // A zero-length blob still binds as a blob, not NULL.
                    sqlite3_bind_blob(st, index, p.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(p.count), transientDestructor)
                }
            case .null: rc = sqlite3_bind_null(st, index)
            }
            if rc != SQLITE_OK { throw SQLiteError(code: rc, message: connection.errorMessage) }
        }
    }

    /// True: a row is available. At the end the statement is reset.
    @discardableResult
    public func step() throws -> Bool {
        let st = try live()
        let rc = sqlite3_step(st)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE {
            rewind(st)
            return false
        }
        let message = connection.errorMessage
        rewind(st)
        throw SQLiteError(code: rc, message: message)
    }

    public func int(_ i: Int32) -> Int64 { st.map { sqlite3_column_int64($0, i) } ?? 0 }
    public func double(_ i: Int32) -> Double { st.map { sqlite3_column_double($0, i) } ?? 0 }
    public func isNull(_ i: Int32) -> Bool { st.map { sqlite3_column_type($0, i) == SQLITE_NULL } ?? true }
    public func text(_ i: Int32) -> String {
        guard let st, let p = sqlite3_column_text(st, i) else { return "" }
        let n = Int(sqlite3_column_bytes(st, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
    public func optionalText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    /// Valid until the next step/reset.
    public func blob(_ i: Int32) -> UnsafeRawBufferPointer {
        guard let st, let p = sqlite3_column_blob(st, i) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(st, i)))
    }
    public func data(_ i: Int32) -> Data {
        let b = blob(i)
        return b.count == 0 ? Data() : Data(b)
    }
}
