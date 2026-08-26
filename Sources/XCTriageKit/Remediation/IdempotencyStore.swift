import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

// Wraps OpaquePointer so deinit can close SQLite without triggering actor-isolation warnings
private final class IdempotencyDBHandle: @unchecked Sendable {
    var ptr: OpaquePointer?
    deinit { if let ptr { sqlite3_close(ptr) } }
}

// Durable at-least-once delivery guard (docs/architecture PART_B section 43).
// GitHub webhook retries, CI re-runs, and a crashed-and-restarted xctriage
// process can all cause the same remediation attempt to be triggered more
// than once. Rather than relying on GitHubPRWriter's deterministic branch
// name to fail loudly on a second attempt, callers check this store first:
// if (operation, key) was already processed, reuse the recorded result
// instead of repeating the side effect (opening a second PR, filing a
// second Jira ticket, etc).
//
// `key` is caller-defined — for PR creation this should be the failure
// fingerprint (optionally combined with a commit SHA for finer granularity).
public actor IdempotencyStore {

    private let handle = IdempotencyDBHandle()
    private var db: OpaquePointer? { handle.ptr }

    private static let schemaDDL = """
        CREATE TABLE IF NOT EXISTS processed_operations (
            operation    TEXT NOT NULL,
            key          TEXT NOT NULL,
            result       TEXT NOT NULL,
            occurred_at  TEXT NOT NULL,
            UNIQUE(operation, key)
        );
        PRAGMA journal_mode=WAL;
    """

    public init(dbPath: String = "~/.xctriage/idempotency.db") throws {
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

    // Returns the previously recorded result if (operation, key) was already
    // processed, or nil if this is the first time it's being seen.
    public func existingResult(operation: String, key: String) throws -> String? {
        let sql = "SELECT result FROM processed_operations WHERE operation = ? AND key = ? LIMIT 1"
        let rows = try query(sql, bindings: [operation, key])
        return rows.first?.first as? String
    }

    // Records the outcome of a (operation, key) pair. If it was already
    // recorded (a duplicate delivery racing or replaying a prior one), the
    // original result wins — "INSERT OR IGNORE" semantics — so a retry can
    // never clobber the true first outcome.
    public func recordProcessed(operation: String, key: String, result: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = "INSERT OR IGNORE INTO processed_operations(operation, key, result, occurred_at) VALUES (?,?,?,?)"
        try execute(sql, bindings: [operation, key, result, now])
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

    private func dbError() -> String {
        guard let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }
}
