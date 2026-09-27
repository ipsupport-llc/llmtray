import Foundation

/// Why a project index can't be opened or changed.
public enum ProjectIndexError: Error, Equatable, CustomStringConvertible {
    /// The system SQLite lacks FTS5 or the trigram tokenizer (3.34+).
    case unsupportedSQLite(String)
    /// Written by a newer LLMTray: left untouched.
    case newerSchema(Int)
    /// An older schema with no migration in this version.
    case migrationUnavailable(from: Int)
    /// A file that isn't a project index (tables but no schema record).
    case notAnIndex
    case duplicate(existing: Int64)
    case noSuchDocument(Int64)
    /// The document changed state meanwhile (removed, re-staged, re-indexed).
    case stale(Int64)
    case insufficientDisk(needed: Int64, available: Int64)
    case integrity(String)
    case busy
    /// Not a regular file (a directory, device, socket, broken link).
    case notARegularFile(String)
    /// A linked file's path must stay inside its folder.
    case invalidRelativePath(String)
    /// Vectors that don't match their chunks (count × dimension).
    case vectorMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .unsupportedSQLite(let why): return "the system SQLite can't hold a project index: \(why)"
        case .newerSchema(let v): return "the index was written by a newer LLMTray (schema \(v))"
        case .migrationUnavailable(let v): return "no migration from index schema \(v)"
        case .notAnIndex: return "not a project index"
        case .duplicate(let doc): return "the same file is already in the project (document \(doc))"
        case .noSuchDocument(let doc): return "no document \(doc)"
        case .stale(let doc): return "document \(doc) changed meanwhile"
        case .insufficientDisk(let needed, let available): return "not enough free disk: \(needed) bytes needed, \(available) available"
        case .integrity(let why): return "index check failed: \(why)"
        case .busy: return "the index is busy"
        case .notARegularFile(let name): return "\(name) is not a regular file"
        case .invalidRelativePath(let path): return "invalid path in a linked folder: \(path)"
        case .vectorMismatch(let expected, let got): return "\(got) vector values for \(expected) expected"
        }
    }
}

/// The index's schema (adr/0012, The index), version 1, and the checks and
/// repairs that go with it. Everything is created in one transaction after
/// the page size (16 KB) and `auto_vacuum = INCREMENTAL` are set -- both
/// only take effect before the first table.
public enum IndexSchema {
    public static let version = 1
    public static let pageSize = 16384
    /// Keeps the WAL from staying hundreds of MB after a large ingest.
    public static let journalSizeLimit = 64 << 20
    /// The writer's busy timeout (checkpoints use a short one).
    static let writerBusyTimeout: Int32 = 5000
    /// trigram tokenizer: 3.34.0.
    static let minimumSQLite: Int32 = 3_034_000

    /// FTS5 and the trigram tokenizer, checked at run time (macOS 13.2
    /// shipped 3.39.5; the build flags aren't guaranteed).
    public static func checkRuntime() throws {
        guard SQLiteConnection.compileOptionUsed("ENABLE_FTS5") else { throw ProjectIndexError.unsupportedSQLite("no FTS5") }
        guard SQLiteConnection.libraryVersionNumber >= minimumSQLite else {
            throw ProjectIndexError.unsupportedSQLite("SQLite \(SQLiteConnection.libraryVersion) has no trigram tokenizer")
        }
    }

    /// Per-connection settings of the writer.
    static func configureWriter(_ db: SQLiteConnection) throws {
        db.setBusyTimeout(milliseconds: writerBusyTimeout)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("PRAGMA journal_size_limit=\(journalSizeLimit)")
        try db.exec("PRAGMA foreign_keys=OFF")
        try db.exec("PRAGMA temp_store=MEMORY")
        // A read-only connection can't open a WAL database whose -wal/-shm
        // don't exist yet (SQLITE_CANTOPEN) -- as after the compaction swap.
        // The writer's first read creates both; they stay while it's open.
        _ = try db.scalarInt("SELECT count(*) FROM sqlite_master")
    }

    /// The reader's page cache (KB) and memory map (bytes). Measured at 200k
    /// chunks (16 KB pages): a 256 MB map took the search p95 from 49 to
    /// 43 ms (words p95 9.4 → 6.5 ms), 1-4 GB no better; a 16 MB cache
    /// instead of SQLite's 2 MB changed nothing. Address space only: the
    /// pages are the OS file cache's.
    public static let readerCacheKB = 2000
    public static let readerMmapBytes = 256 << 20

    /// Per-connection settings of a search connection.
    public static func configureReader(_ db: SQLiteConnection, cacheKB: Int = readerCacheKB, mmapBytes: Int = readerMmapBytes) throws {
        try db.exec("PRAGMA cache_size=-\(max(0, cacheKB))")
        try db.exec("PRAGMA mmap_size=\(max(0, mmapBytes))")
    }

    static func isEmptyDatabase(_ db: SQLiteConnection) throws -> Bool {
        try db.scalarInt("SELECT count(*) FROM sqlite_master") == 0
    }

    /// The schema version recorded in `meta`; nil when there is no `meta`.
    static func recordedVersion(_ db: SQLiteConnection) throws -> Int? {
        guard try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") == 1 else { return nil }
        return try db.scalarInt("SELECT value FROM meta WHERE key = 'schema'").map(Int.init)
    }

    /// A new, empty database: page size and vacuum mode first, then WAL, then
    /// the tables.
    static func create(_ db: SQLiteConnection) throws {
        try db.exec("PRAGMA page_size=\(pageSize)")
        try db.exec("PRAGMA auto_vacuum=INCREMENTAL")
        try configureWriter(db)
        try db.transaction {
            try db.exec(v1)
            try db.run("INSERT INTO meta(key, value) VALUES ('schema', ?)", [.int(Int64(version))])
            try db.run("INSERT INTO meta(key, value) VALUES ('created_with', ?)", [.text(SQLiteConnection.libraryVersion)])
            try db.run("INSERT INTO meta(key, value) VALUES ('churn', 0), ('vec_epoch', 0)")
        }
    }

    /// Document states (adr/0012). `searchable` answers lexically, `embedded`
    /// also by meaning; `removing` is hidden before reconcile finishes it.
    static let statuses = ["staged", "extracting", "searchable", "embedded", "failed", "removing",
                           "empty", "unsupported", "not_indexed"]

    static let v1 = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID;

    -- Where documents come from: 1 is the project's own copies; a linked
    -- folder is a row of its own (bookmark + last known path).
    CREATE TABLE sources(
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('copy','folder')),
      bookmark BLOB,
      path TEXT,
      removing INTEGER NOT NULL DEFAULT 0);
    INSERT INTO sources(id, kind) VALUES (1, 'copy');

    -- AUTOINCREMENT: a doc id is never reused, so an old [2:5] can't come to
    -- point at another document. rel_path/mtime: a linked folder's file as
    -- it was indexed. sha256 is '' until the copy is hashed.
    CREATE TABLE documents(
      doc INTEGER PRIMARY KEY AUTOINCREMENT,
      source INTEGER NOT NULL DEFAULT 1,
      rev INTEGER NOT NULL DEFAULT 1,
      name TEXT NOT NULL,
      ext TEXT NOT NULL,
      rel_path TEXT,
      mtime REAL,
      sha256 TEXT NOT NULL DEFAULT '',
      bytes INTEGER NOT NULL DEFAULT 0,
      added_at REAL NOT NULL,
      status TEXT NOT NULL CHECK (status IN (\(statuses.map { "'\($0)'" }.joined(separator: ",")))),
      kind TEXT,
      pages INTEGER,
      error TEXT);
    CREATE INDEX documents_status ON documents(status);
    CREATE INDEX documents_sha ON documents(sha256);

    -- The extracted text, verbatim: what a hit and read_project_file quote.
    -- A row whose (doc, rev) is no longer a document's current revision is a
    -- tombstone kept for citations until the sweep drops it.
    CREATE TABLE pages(
      id INTEGER PRIMARY KEY,
      doc INTEGER NOT NULL, rev INTEGER NOT NULL, page INTEGER NOT NULL,
      text TEXT NOT NULL,
      tier INTEGER NOT NULL DEFAULT 1,
      status TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','empty','failed')),
      error TEXT,
      UNIQUE (doc, rev, page));

    -- body: normalized (what both FTS tables index), heading path first.
    -- start/len: code points into pages.text (SQL substr units).
    CREATE TABLE chunks(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      doc INTEGER NOT NULL, rev INTEGER NOT NULL, page INTEGER NOT NULL,
      ord INTEGER NOT NULL,
      heading TEXT,
      start INTEGER NOT NULL, len INTEGER NOT NULL,
      body TEXT NOT NULL);
    CREATE INDEX chunks_doc ON chunks(doc, rev, ord);

    -- remove_diacritics 2 folds Latin only (not ё/е, not й/и). trigram needs
    -- detail=full: none/column break MATCH for any term of 4+ characters.
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
      body, content='chunks', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2');
    CREATE VIRTUAL TABLE chunks_tri USING fts5(
      body, content='chunks', content_rowid='id',
      tokenize='trigram', detail=full);

    CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
      INSERT INTO chunks_fts(rowid, body) VALUES (new.id, new.body);
      INSERT INTO chunks_tri(rowid, body) VALUES (new.id, new.body);
    END;
    CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
      INSERT INTO chunks_tri(chunks_tri, rowid, body) VALUES ('delete', old.id, old.body);
    END;
    CREATE TRIGGER chunks_au AFTER UPDATE OF id, body ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
      INSERT INTO chunks_tri(chunks_tri, rowid, body) VALUES ('delete', old.id, old.body);
      INSERT INTO chunks_fts(rowid, body) VALUES (new.id, new.body);
      INSERT INTO chunks_tri(rowid, body) VALUES (new.id, new.body);
    END;

    -- One set per embedder (model + preprocessing); exactly one active.
    CREATE TABLE vec_sets(
      set_id INTEGER PRIMARY KEY AUTOINCREMENT,
      model TEXT NOT NULL,
      dim INTEGER NOT NULL,
      prep_version INTEGER NOT NULL,
      active INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL);
    CREATE UNIQUE INDEX vec_sets_one_active ON vec_sets(active) WHERE active = 1;

    -- One row per embedding batch of one document (<= 64 vectors): n
    -- little-endian f16 vectors (n x dim x 2 bytes) and their chunk ids
    -- (n x 8 bytes, little-endian Int64). Packed, not a row each: one 2 KB
    -- blob per row left most of each page empty.
    CREATE TABLE vec_blocks(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      set_id INTEGER NOT NULL, doc INTEGER NOT NULL, rev INTEGER NOT NULL,
      n INTEGER NOT NULL, chunk_ids BLOB NOT NULL, v BLOB NOT NULL);
    CREATE INDEX vec_blocks_doc ON vec_blocks(set_id, doc, rev);
    """

    /// FTS5 integrity-check with rank = 1: also compares each index with its
    /// content table. Throws on a mismatch. A background job: 23 s at 200k chunks.
    public static func integrityCheck(_ db: SQLiteConnection) throws {
        try db.exec("INSERT INTO chunks_fts(chunks_fts, rank) VALUES ('integrity-check', 1)")
        try db.exec("INSERT INTO chunks_tri(chunks_tri, rank) VALUES ('integrity-check', 1)")
    }

    /// Rebuilds both FTS indexes from `chunks`: the repair (82 s at 200k).
    public static func rebuildFTS(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.exec("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
            try db.exec("INSERT INTO chunks_tri(chunks_tri) VALUES ('rebuild')")
        }
    }

    /// Merges FTS5 segments (5-8 s at 200k chunks).
    public static func optimizeFTS(_ db: SQLiteConnection) throws {
        try db.exec("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
        try db.exec("INSERT INTO chunks_tri(chunks_tri) VALUES ('optimize')")
    }

    /// `PRAGMA quick_check` on a connection: "ok" or the first problems.
    static func quickCheck(_ db: SQLiteConnection) throws {
        let rows = try db.rows("PRAGMA quick_check") { $0.text(0) }
        guard rows == ["ok"] else { throw ProjectIndexError.integrity(rows.prefix(3).joined(separator: "; ")) }
    }
}

/// Schema changes (adr/0012): a new database is built beside the old one
/// (`index.next.sqlite`) -- documents migrated by explicit statements,
/// derived tables rebuilt, cited revisions' pages carried over -- and
/// swapped in with the compaction swap once complete and checked; a crash
/// leaves the old one in use. Version 1 is the first schema, so no copier
/// exists yet: an older recorded version can only be a foreign or broken
/// file, and is refused.
public enum IndexMigration {
    public static let shadowName = "index.next.sqlite"

    /// Per older version: fills a new database of the current schema from
    /// the old one, attached as `old`. The next schema adds its entry here.
    static let copiers: [Int: (SQLiteConnection) throws -> Void] = [:]

    public static func canMigrate(from version: Int) -> Bool {
        version < IndexSchema.version && copiers[version] != nil
    }

    /// Builds the shadow, checks it, and swaps it in with the compaction
    /// swap. Every connection to the index must be closed.
    static func migrate(directory: URL, from version: Int, freeSpace: Int64? = nil) throws {
        guard canMigrate(from: version), let copy = copiers[version] else {
            throw ProjectIndexError.migrationUnavailable(from: version)
        }
        let live = directory.appendingPathComponent(ProjectIndex.databaseName)
        let size = ((try? FileManager.default.attributesOfItem(atPath: live.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let freeSpace, freeSpace < size * 6 / 5 {
            throw ProjectIndexError.insufficientDisk(needed: size * 6 / 5, available: freeSpace)
        }
        discardLeftovers(in: directory)
        let shadow = directory.appendingPathComponent(shadowName)
        do {
            let db = try SQLiteConnection(path: shadow.path)
            try IndexSchema.create(db)
            try db.run("ATTACH DATABASE ? AS old", [.text(live.path)])
            try db.transaction { try copy(db) }
            try db.exec("DETACH DATABASE old")
            try db.checkpoint(truncate: true)
            try IndexSchema.quickCheck(db)
            db.close()
            CompactionSwap.removeFamily(directory.appendingPathComponent(CompactionSwap.compactName))
            try FileManager.default.moveItem(at: shadow, to: directory.appendingPathComponent(CompactionSwap.compactName))
            discardLeftovers(in: directory)
            try CompactionSwap.writeMarker(in: directory)
        } catch {
            discardLeftovers(in: directory)
            throw error
        }
        try CompactionSwap.swap(in: directory)
    }

    /// A leftover shadow from a migration that crashed: the old file is
    /// still the one in use, so it goes.
    static func discardLeftovers(in directory: URL) {
        CompactionSwap.removeFamily(directory.appendingPathComponent(shadowName))
    }
}
