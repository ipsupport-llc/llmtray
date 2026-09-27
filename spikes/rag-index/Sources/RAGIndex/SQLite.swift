import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal connection wrapper. One connection is used by one thread at a time
/// (Apple's build is THREADSAFE=2, multi-thread mode).
public final class Database {
    public let handle: OpaquePointer
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        self.path = path
        sqlite3_extended_result_codes(h, 1)
    }

    deinit { sqlite3_close_v2(handle) }

    var errmsg: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errmsg
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &st, nil)
        guard rc == SQLITE_OK, let st else { throw SQLiteError(code: rc, message: "\(errmsg) in: \(sql)") }
        return Statement(st, db: self)
    }

    /// Run a statement with bindings, discard rows.
    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let st = try prepare(sql)
        try st.bind(args)
        while try st.step() {}
    }

    public func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64? {
        let st = try prepare(sql)
        try st.bind(args)
        guard try st.step() else { return nil }
        return st.isNull(0) ? nil : st.int(0)
    }

    public func scalarText(_ sql: String, _ args: [SQLValue] = []) throws -> String? {
        let st = try prepare(sql)
        try st.bind(args)
        guard try st.step() else { return nil }
        return st.text(0)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        try exec(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func setBusyTimeout(ms: Int32) { sqlite3_busy_timeout(handle, ms) }

    /// sqlite3_wal_checkpoint_v2 result: (rc, frames in log, frames checkpointed).
    public func checkpoint(mode: Int32) -> (rc: Int32, log: Int32, ckpt: Int32) {
        var log: Int32 = -1, ck: Int32 = -1
        let rc = sqlite3_wal_checkpoint_v2(handle, nil, mode, &log, &ck)
        return (rc, log, ck)
    }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }
    public static func compileOptionUsed(_ name: String) -> Bool { sqlite3_compileoption_used(name) == 1 }
}

public enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral v: Int) { self = .int(Int64(v)) }
    public init(stringLiteral v: String) { self = .text(v) }
}

public final class Statement {
    let st: OpaquePointer
    unowned let db: Database
    init(_ st: OpaquePointer, db: Database) { self.st = st; self.db = db }
    deinit { sqlite3_finalize(st) }

    public func reset() { sqlite3_reset(st); sqlite3_clear_bindings(st) }

    public func bind(_ args: [SQLValue]) throws {
        sqlite3_reset(st)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch a {
            case .int(let v): rc = sqlite3_bind_int64(st, idx, v)
            case .double(let v): rc = sqlite3_bind_double(st, idx, v)
            case .text(let v): rc = sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT_)
            case .blob(let d):
                rc = d.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_) }
            case .null: rc = sqlite3_bind_null(st, idx)
            }
            if rc != SQLITE_OK { throw SQLiteError(code: rc, message: db.errmsg) }
        }
    }

    /// Bind a raw buffer as a blob without copying through Data.
    public func bindBlob(_ idx: Int32, _ p: UnsafeRawBufferPointer) {
        sqlite3_bind_blob(st, idx, p.baseAddress, Int32(p.count), SQLITE_TRANSIENT_)
    }

    /// true = row available.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(st)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { sqlite3_reset(st); return false }
        let msg = db.errmsg
        sqlite3_reset(st)
        throw SQLiteError(code: rc, message: msg)
    }

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
    public func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(st, i) else { return "" }
        return String(cString: p)
    }
    public func blob(_ i: Int32) -> UnsafeRawBufferPointer {
        let n = Int(sqlite3_column_bytes(st, i))
        guard let p = sqlite3_column_blob(st, i) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: p, count: n)
    }
}
