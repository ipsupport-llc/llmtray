import Foundation

public struct IndexOptions {
    /// FTS5 `detail=` for the trigram table: full | column | none.
    public var trigramDetail: String = "full"
    public var pageSize: Int = 4096
    public init(trigramDetail: String = "full", pageSize: Int = 4096) {
        self.trigramDetail = trigramDetail
        self.pageSize = pageSize
    }
}

public enum Schema {
    public static let version = 1

    public static func runtimeInfo() -> (version: String, fts5: Bool, loadExtension: Bool) {
        (Database.libraryVersion,
         Database.compileOptionUsed("ENABLE_FTS5"),
         !Database.compileOptionUsed("OMIT_LOAD_EXTENSION"))
    }

    public static func configure(_ db: Database, pageSize: Int) throws {
        // page_size only takes effect before the first table is created (or on VACUUM).
        try db.exec("PRAGMA page_size=\(pageSize)")
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("PRAGMA foreign_keys=OFF")
        db.setBusyTimeout(ms: 5000)
    }

    public static func create(_ db: Database, options: IndexOptions) throws {
        guard Database.compileOptionUsed("ENABLE_FTS5") else {
            throw SQLiteError(code: -1, message: "SQLite built without FTS5")
        }
        try db.transaction {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS sources(
              id INTEGER PRIMARY KEY,
              kind TEXT NOT NULL CHECK (kind IN ('copy','folder')),
              bookmark BLOB, path TEXT);
            INSERT OR IGNORE INTO sources(id, kind) VALUES (1, 'copy');

            -- AUTOINCREMENT: a doc id is never reused, so a [doc:page] citation in an
            -- old chat can't silently point at a newer document.
            CREATE TABLE IF NOT EXISTS documents(
              doc INTEGER PRIMARY KEY AUTOINCREMENT,
              source INTEGER NOT NULL DEFAULT 1 REFERENCES sources(id),
              rev INTEGER NOT NULL DEFAULT 1,
              name TEXT NOT NULL, ext TEXT NOT NULL,
              sha256 TEXT NOT NULL, bytes INTEGER NOT NULL,
              added_at REAL NOT NULL,
              status TEXT NOT NULL CHECK (status IN
                ('staged','extracting','searchable','embedded','failed','removing')),
              pages INTEGER, error TEXT);
            CREATE INDEX IF NOT EXISTS documents_status ON documents(status);

            CREATE TABLE IF NOT EXISTS pages(
              id INTEGER PRIMARY KEY,
              doc INTEGER NOT NULL, rev INTEGER NOT NULL, page INTEGER NOT NULL,
              text TEXT NOT NULL, tier INTEGER NOT NULL DEFAULT 1,
              status TEXT NOT NULL DEFAULT 'ok', error TEXT,
              UNIQUE (doc, rev, page));

            -- body: normalized text (what both FTS tables index). The original
            -- text is pages.text; start/len (code points, SQL substr units) locate
            -- the chunk in it so a hit can be quoted verbatim without storing it twice.
            CREATE TABLE IF NOT EXISTS chunks(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc INTEGER NOT NULL, rev INTEGER NOT NULL, page INTEGER NOT NULL,
              ord INTEGER NOT NULL, heading TEXT,
              body TEXT NOT NULL,
              start INTEGER NOT NULL, len INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc, rev, ord);

            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
              body, content='chunks', content_rowid='id',
              tokenize='unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_tri USING fts5(
              body, content='chunks', content_rowid='id',
              tokenize='trigram', detail=\(options.trigramDetail));

            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
              INSERT INTO chunks_fts(rowid, body) VALUES (new.id, new.body);
              INSERT INTO chunks_tri(rowid, body) VALUES (new.id, new.body);
            END;
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
              INSERT INTO chunks_fts(chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
              INSERT INTO chunks_tri(chunks_tri, rowid, body) VALUES ('delete', old.id, old.body);
            END;
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE OF id, body ON chunks BEGIN
              INSERT INTO chunks_fts(chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
              INSERT INTO chunks_tri(chunks_tri, rowid, body) VALUES ('delete', old.id, old.body);
              INSERT INTO chunks_fts(rowid, body) VALUES (new.id, new.body);
              INSERT INTO chunks_tri(rowid, body) VALUES (new.id, new.body);
            END;

            CREATE TABLE IF NOT EXISTS vec_sets(
              id INTEGER PRIMARY KEY, model TEXT NOT NULL, dim INTEGER NOT NULL,
              prep TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 0);
            -- One row per embedding batch of one document: n vectors packed f16
            -- (n×dim×2 bytes) plus their chunk ids (n×8 bytes, little-endian Int64).
            -- Packing avoids the one-2 KB-blob-per-4 KB-page waste of a row per chunk.
            CREATE TABLE IF NOT EXISTS vec_blocks(
              id INTEGER PRIMARY KEY,
              set_id INTEGER NOT NULL, doc INTEGER NOT NULL, rev INTEGER NOT NULL,
              n INTEGER NOT NULL, chunk_ids BLOB NOT NULL, v BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS vec_blocks_doc ON vec_blocks(set_id, doc);
            """)
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', ?)", [.int(Int64(version))])
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('trigram_detail', ?)", [.text(options.trigramDetail)])
        }
    }

    /// FTS5 integrity-check with rank=1: also compares the index against the
    /// external content table. Throws (SQLITE_CORRUPT_VTAB) on mismatch.
    public static func integrityCheck(_ db: Database) throws {
        try db.exec("INSERT INTO chunks_fts(chunks_fts, rank) VALUES ('integrity-check', 1)")
        try db.exec("INSERT INTO chunks_tri(chunks_tri, rank) VALUES ('integrity-check', 1)")
    }

    public static func rebuild(_ db: Database) throws {
        try db.transaction {
            try db.exec("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
            try db.exec("INSERT INTO chunks_tri(chunks_tri) VALUES ('rebuild')")
        }
    }

    public static func optimize(_ db: Database) throws {
        try db.exec("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
        try db.exec("INSERT INTO chunks_tri(chunks_tri) VALUES ('optimize')")
    }
}
