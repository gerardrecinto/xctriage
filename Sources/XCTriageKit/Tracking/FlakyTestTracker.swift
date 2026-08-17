import Foundation
import SQLite3

// Wraps OpaquePointer so deinit can close SQLite without triggering actor-isolation warnings
private final class DBHandle: @unchecked Sendable {
    var ptr: OpaquePointer?
    deinit { if let ptr { sqlite3_close(ptr) } }
}

// Actor-based SQLite flaky test tracker.
// score = failures-in-window / max(1, total-builds-in-window). Score > 0.70 → quarantine candidate.
public actor FlakyTestTracker {

    private let handle = DBHandle()
    private var db: OpaquePointer? { handle.ptr }
    private let windowDays: Int

    private static let schemaDDL = """
        CREATE TABLE IF NOT EXISTS flaky_events (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            test_name TEXT NOT NULL,
            build_id  TEXT,
            source    TEXT NOT NULL,
            failed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_test ON flaky_events(test_name);
        CREATE INDEX IF NOT EXISTS idx_time ON flaky_events(failed_at);
        PRAGMA journal_mode=WAL;
    """

    public init(dbPath: String = "~/.xctriage/flaky.db", windowDays: Int = 90) throws {
        self.windowDays = windowDays

        let expanded = (dbPath as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var localDB: OpaquePointer?
        guard sqlite3_open(expanded, &localDB) == SQLITE_OK else {
            throw TriageError.parseError("Cannot open SQLite at \(expanded)")
        }
        handle.ptr = localDB

        guard sqlite3_exec(localDB, Self.schemaDDL, nil, nil, nil) == SQLITE_OK else {
            let errMsg = localDB.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            throw TriageError.parseError("Schema creation failed: \(errMsg)")
        }
    }

    public func record(testName: String, buildID: String?, source: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = "INSERT INTO flaky_events(test_name, build_id, source, failed_at) VALUES (?,?,?,?)"
        try execute(sql, bindings: [testName, buildID, source, now])
    }

    public func scores(for testNames: [String]) throws -> [String: Double] {
        guard !testNames.isEmpty else { return [:] }
        let cutoff = cutoffDate()
        let placeholders = testNames.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT test_name, COUNT(*) FROM flaky_events
            WHERE test_name IN (\(placeholders)) AND failed_at >= ?
            GROUP BY test_name
        """
        let allBindings: [Any?] = testNames.map { $0 as Any? } + [cutoff as Any?]
        let rows = try query(sql, bindings: allBindings)
        let countMap = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, Int)? in
                guard let name = row[0] as? String, let cnt = row[1] as? Int64 else { return nil }
                return (name, Int(cnt))
            }
        )
        let total = max(1, try totalBuilds(cutoff: cutoff))
        return Dictionary(
            uniqueKeysWithValues: testNames.map { name in
                (name, min(1.0, Double(countMap[name, default: 0]) / Double(total)))
            }
        )
    }

    // Tests whose failure ratio strictly exceeds `threshold` over the tracking
    // window — the decision this type's header comment has promised since it
    // was written ("Score > 0.70 -> quarantine candidate") but that nothing
    // previously computed. Strictly-greater, not >=: a test sitting exactly
    // at the threshold hasn't crossed it yet.
    public func quarantineCandidates(threshold: Double = 0.70, limit: Int = 50) throws -> [(name: String, score: Double)] {
        try topFlaky(n: limit).filter { $0.score > threshold }
    }

    // The one entry point callers with an optional --no-track flag should
    // use: score against prior history first, then optionally persist this
    // occurrence, so the two operations can't be wired up separately (and
    // inconsistently) at each call site. Swallows its own errors, matching
    // how callers already treated `scores`/`record` failures as non-fatal.
    public func recordAndScore(
        testNames: [String], buildID: String?, source: String, alsoRecord: Bool
    ) async -> [String: Double] {
        guard !testNames.isEmpty else { return [:] }
        let result = (try? scores(for: testNames)) ?? [:]
        if alsoRecord {
            for name in testNames {
                try? record(testName: name, buildID: buildID, source: source)
            }
        }
        return result
    }

    public func topFlaky(n: Int = 10) throws -> [(name: String, score: Double)] {
        let cutoff = cutoffDate()
        let sql = """
            SELECT test_name, COUNT(*) as cnt FROM flaky_events
            WHERE failed_at >= ? GROUP BY test_name ORDER BY cnt DESC LIMIT ?
        """
        let rows = try query(sql, bindings: [cutoff, n])
        let total = max(1, try totalBuilds(cutoff: cutoff))
        return rows.compactMap { row in
            guard let name = row[0] as? String, let cnt = row[1] as? Int64 else { return nil }
            return (name: name, score: min(1.0, Double(cnt) / Double(total)))
        }
    }

    // MARK: Private

    private func execute(_ sql: String, bindings: [Any?]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TriageError.parseError("Prepare failed: \(dbError())")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt: stmt, bindings: bindings)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TriageError.parseError("Execute failed: \(dbError())")
        }
    }

    private func query(_ sql: String, bindings: [Any?]) throws -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TriageError.parseError("Prepare failed: \(dbError())")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt: stmt, bindings: bindings)
        var rows: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for col in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_TEXT:    row.append(String(cString: sqlite3_column_text(stmt, col)))
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, col))
                default:             row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(stmt: OpaquePointer?, bindings: [Any?]) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case let s as String:  sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int:     sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64:   sqlite3_bind_int64(stmt, idx, n)
            default:               sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func totalBuilds(cutoff: String) throws -> Int {
        let rows = try query(
            "SELECT COUNT(DISTINCT build_id) FROM flaky_events WHERE failed_at >= ?",
            bindings: [cutoff]
        )
        return (rows.first?.first as? Int64).map(Int.init) ?? 0
    }

    private func cutoffDate() -> String {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
        return ISO8601DateFormatter().string(from: cutoff)
    }

    private func dbError() -> String {
        guard let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }
}
