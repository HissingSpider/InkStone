import Foundation
import SQLite3

/// SQLite's "copy this buffer" sentinel. Not exposed to Swift by the SQLite3
/// module because it is a macro, so it has to be rebuilt here.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

/// Records for a page that has already been through the pipeline.
public struct PageRecord: Sendable, Equatable {
    public var documentPath: String
    public var pageIndex: Int
    /// Hash of the rendered page bitmap. Drives change detection.
    public var imageHash: String
    public var confidence: Double
    public var escalated: Bool
    /// The confidence gate's verdict, persisted so a cached page keeps its
    /// `needs_review` flag without being re-evaluated.
    public var needsReview: Bool
    /// The page's finished markdown, embeds included.
    ///
    /// Cached so an unchanged page never pays for OCR again: a daily run over a
    /// 200-page notebook with one new page costs one page of work, not 200.
    public var markdown: String
    /// Diagram crops belonging to this page, as written to the vault.
    public var diagrams: [DiagramCrop]
    public var transcribedAt: Date

    public init(documentPath: String, pageIndex: Int, imageHash: String, confidence: Double,
                escalated: Bool, needsReview: Bool = false, markdown: String,
                diagrams: [DiagramCrop], transcribedAt: Date) {
        self.documentPath = documentPath
        self.pageIndex = pageIndex
        self.imageHash = imageHash
        self.confidence = confidence
        self.escalated = escalated
        self.needsReview = needsReview
        self.markdown = markdown
        self.diagrams = diagrams
        self.transcribedAt = transcribedAt
    }
}

/// A note Inkstone wrote, plus the hash of exactly what it wrote.
///
/// The stored hash is the whole edit-protection mechanism: if the file on disk
/// no longer hashes to `contentHash`, a human changed it and we must not
/// clobber their work.
public struct NoteRecord: Sendable, Equatable {
    public var path: String
    public var contentHash: String
    public var writtenAt: Date
}

public struct RunSummary: Sendable, Equatable {
    public var id: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: String
    public var documentsScanned: Int
    public var pagesProcessed: Int
    public var pagesEscalated: Int
    public var notesWritten: Int
    public var notesSkipped: Int
    public var errorMessage: String?
}

/// SQLite-backed state for change detection, edit protection and run history.
///
/// Single-writer by design — the CLI takes an exclusive lock for a run and the
/// menu-bar app reads through the same store, so `busy_timeout` covers the
/// short overlap when a scheduled run and a manual read collide.
public final class StateStore: @unchecked Sendable {

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Inkstone/state.sqlite3")
            .expandingTildeInPath)
    }

    public init(url: URL = StateStore.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw InkstoneError.state("cannot open \(url.path): \(lastMessage)")
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private var lastMessage: String { String(cString: sqlite3_errmsg(db)) }

    // MARK: Schema

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS documents (
                path        TEXT PRIMARY KEY,
                base_name   TEXT NOT NULL,
                file_hash   TEXT NOT NULL,
                page_count  INTEGER NOT NULL DEFAULT 0,
                first_seen  REAL NOT NULL,
                last_seen   REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pages (
                document_path  TEXT NOT NULL,
                page_index     INTEGER NOT NULL,
                image_hash     TEXT NOT NULL,
                confidence     REAL NOT NULL,
                escalated      INTEGER NOT NULL DEFAULT 0,
                markdown       TEXT NOT NULL DEFAULT '',
                diagrams       TEXT NOT NULL DEFAULT '[]',
                transcribed_at REAL NOT NULL,
                PRIMARY KEY (document_path, page_index)
            );

            CREATE TABLE IF NOT EXISTS notes (
                path         TEXT PRIMARY KEY,
                content_hash TEXT NOT NULL,
                written_at   REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS runs (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at        REAL NOT NULL,
                finished_at       REAL,
                status            TEXT NOT NULL,
                documents_scanned INTEGER NOT NULL DEFAULT 0,
                pages_processed   INTEGER NOT NULL DEFAULT 0,
                pages_escalated   INTEGER NOT NULL DEFAULT 0,
                notes_written     INTEGER NOT NULL DEFAULT 0,
                notes_skipped     INTEGER NOT NULL DEFAULT 0,
                error_message     TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_pages_doc ON pages(document_path);
            """)

        // CREATE TABLE IF NOT EXISTS does nothing for a database that already
        // exists, so new columns need adding explicitly.
        try addColumnIfMissing(
            table: "pages", column: "needs_review", definition: "INTEGER NOT NULL DEFAULT 0")

        try addColumnIfMissing(table: "runs", column: "pid", definition: "INTEGER NOT NULL DEFAULT 0")
        try reapAbandonedRuns()
    }

    /// Closes out `running` rows whose process is gone.
    ///
    /// The PID check matters: the watcher, the daily agent and a hand-run CLI
    /// all share this database, and more than one can legitimately be running at
    /// once. Marking every `running` row stale on startup would have one process
    /// declare another one's live work abandoned.
    private func reapAbandonedRuns() throws {
        let candidates = try prepared("SELECT id, pid FROM runs WHERE status = 'running';") {
            statement -> [(Int64, pid_t)] in
            var rows: [(Int64, pid_t)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(statement, 0),
                             pid_t(sqlite3_column_int64(statement, 1))))
            }
            return rows
        }

        for (id, pid) in candidates {
            // pid 0 predates this column; treat it as abandoned. Otherwise
            // signal 0 asks "does this process exist" without touching it.
            let alive = pid > 0 && kill(pid, 0) == 0
            guard !alive else { continue }
            try run("""
                UPDATE runs SET status = 'interrupted', finished_at = started_at,
                    error_message = COALESCE(error_message, 'run did not finish')
                WHERE id = ?;
                """, [id])
        }
    }

    /// Idempotent `ALTER TABLE … ADD COLUMN`.
    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let existing = try prepared("PRAGMA table_info(\(table));") { statement -> Set<String> in
            var names: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                names.insert(Self.text(statement, 1))
            }
            return names
        }
        guard !existing.contains(column) else { return }
        log.debug("migrating: adding \(table).\(column)")
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    // MARK: Primitive helpers

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        try execLocked(sql)
    }

    private func execLocked(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(errorPointer)
            throw InkstoneError.state(message)
        }
    }

    /// Prepares `sql`, binds `params` positionally, and hands the statement to
    /// `body` for stepping. The statement is always finalised.
    private func prepared<T>(
        _ sql: String, _ params: [Any?] = [], _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InkstoneError.state("prepare failed: \(lastMessage) — \(sql)")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil:
                sqlite3_bind_null(statement, index)
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, index, number)
            case let flag as Bool:
                sqlite3_bind_int(statement, index, flag ? 1 : 0)
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            case let date as Date:
                sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            default:
                throw InkstoneError.state("unbindable parameter at index \(index)")
            }
        }
        return try body(statement)
    }

    private func run(_ sql: String, _ params: [Any?] = []) throws {
        try prepared(sql, params) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw InkstoneError.state("step failed: \(lastMessage) — \(sql)")
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let c = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: c)
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    // MARK: Documents

    public func recordDocument(path: String, baseName: String, fileHash: String, pageCount: Int) throws {
        let now = Date()
        try run("""
            INSERT INTO documents (path, base_name, file_hash, page_count, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                base_name = excluded.base_name,
                file_hash = excluded.file_hash,
                page_count = excluded.page_count,
                last_seen = excluded.last_seen;
            """, [path, baseName, fileHash, pageCount, now, now])
    }

    public func documentHash(path: String) throws -> String? {
        try prepared("SELECT file_hash FROM documents WHERE path = ?;", [path]) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Self.text(statement, 0) : nil
        }
    }

    // MARK: Pages

    public func pageRecord(documentPath: String, pageIndex: Int) throws -> PageRecord? {
        try prepared("""
            SELECT image_hash, confidence, escalated, markdown, diagrams, transcribed_at,
                   needs_review
            FROM pages WHERE document_path = ? AND page_index = ?;
            """, [documentPath, pageIndex]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let encoded = Self.text(statement, 4)
            let diagrams = (try? JSONDecoder().decode(
                [DiagramCrop].self, from: Data(encoded.utf8))) ?? []
            return PageRecord(
                documentPath: documentPath,
                pageIndex: pageIndex,
                imageHash: Self.text(statement, 0),
                confidence: sqlite3_column_double(statement, 1),
                escalated: sqlite3_column_int(statement, 2) == 1,
                needsReview: sqlite3_column_int(statement, 6) == 1,
                markdown: Self.text(statement, 3),
                diagrams: diagrams,
                transcribedAt: Self.date(statement, 5))
        }
    }

    public func upsertPage(_ record: PageRecord) throws {
        let diagrams = String(
            data: (try? JSONEncoder().encode(record.diagrams)) ?? Data("[]".utf8),
            encoding: .utf8) ?? "[]"
        try run("""
            INSERT INTO pages (document_path, page_index, image_hash, confidence, escalated,
                               needs_review, markdown, diagrams, transcribed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_path, page_index) DO UPDATE SET
                image_hash = excluded.image_hash,
                confidence = excluded.confidence,
                escalated = excluded.escalated,
                needs_review = excluded.needs_review,
                markdown = excluded.markdown,
                diagrams = excluded.diagrams,
                transcribed_at = excluded.transcribed_at;
            """, [record.documentPath, record.pageIndex, record.imageHash,
                  record.confidence, record.escalated, record.needsReview,
                  record.markdown, diagrams, record.transcribedAt])
    }

    /// Drops page rows past `pageCount`, so a notebook that shrank does not keep
    /// reporting stale pages as unchanged.
    public func trimPages(documentPath: String, to pageCount: Int) throws {
        try run("DELETE FROM pages WHERE document_path = ? AND page_index >= ?;",
                [documentPath, pageCount])
    }

    // MARK: Notes

    public func noteRecord(path: String) throws -> NoteRecord? {
        try prepared("SELECT content_hash, written_at FROM notes WHERE path = ?;", [path]) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return NoteRecord(path: path,
                              contentHash: Self.text(statement, 0),
                              writtenAt: Self.date(statement, 1))
        }
    }

    public func upsertNote(_ record: NoteRecord) throws {
        try run("""
            INSERT INTO notes (path, content_hash, written_at) VALUES (?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                content_hash = excluded.content_hash,
                written_at = excluded.written_at;
            """, [record.path, record.contentHash, record.writtenAt])
    }

    // MARK: Runs

    public func beginRun() throws -> Int64 {
        try run("INSERT INTO runs (started_at, status, pid) VALUES (?, 'running', ?);",
                [Date(), Int(ProcessInfo.processInfo.processIdentifier)])
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(db)
    }

    public func finishRun(
        id: Int64, status: String, documentsScanned: Int, pagesProcessed: Int,
        pagesEscalated: Int, notesWritten: Int, notesSkipped: Int, error: String?
    ) throws {
        try run("""
            UPDATE runs SET finished_at = ?, status = ?, documents_scanned = ?,
                pages_processed = ?, pages_escalated = ?, notes_written = ?,
                notes_skipped = ?, error_message = ?
            WHERE id = ?;
            """, [Date(), status, documentsScanned, pagesProcessed, pagesEscalated,
                  notesWritten, notesSkipped, error, id])
    }

    public func recentRuns(limit: Int = 10) throws -> [RunSummary] {
        try prepared("""
            SELECT id, started_at, finished_at, status, documents_scanned, pages_processed,
                   pages_escalated, notes_written, notes_skipped, error_message
            FROM runs ORDER BY id DESC LIMIT ?;
            """, [limit]) { statement in
            var results: [RunSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(RunSummary(
                    id: sqlite3_column_int64(statement, 0),
                    startedAt: Self.date(statement, 1),
                    finishedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil : Self.date(statement, 2),
                    status: Self.text(statement, 3),
                    documentsScanned: Int(sqlite3_column_int64(statement, 4)),
                    pagesProcessed: Int(sqlite3_column_int64(statement, 5)),
                    pagesEscalated: Int(sqlite3_column_int64(statement, 6)),
                    notesWritten: Int(sqlite3_column_int64(statement, 7)),
                    notesSkipped: Int(sqlite3_column_int64(statement, 8)),
                    errorMessage: Self.optionalText(statement, 9)))
            }
            return results
        }
    }

    /// Forgets every page and note hash, so the next run re-transcribes
    /// everything. Documents and run history are kept.
    public func resetTranscriptionState() throws {
        try exec("DELETE FROM pages; DELETE FROM notes; DELETE FROM documents;")
    }
}
