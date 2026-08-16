import Foundation
import SQLite3

// Wraps OpaquePointer so deinit can close SQLite without triggering actor-isolation warnings
private final class StateMachineDBHandle: @unchecked Sendable {
    var ptr: OpaquePointer?
    deinit { if let ptr { sqlite3_close(ptr) } }
}

// Durable, recoverable state machine for a single remediation attempt, keyed by
// failure fingerprint (or fingerprint+commit for finer-grained idempotency).
//
// This intentionally only models states this codebase can actually reach today:
// patch proposal, sandbox validation, and PR creation. It does not model
// deployment/canary/rollback states, because xctriage has no deployment or
// cluster integration yet (see docs/architecture/PART_B section 37 for the
// full target state machine once continuous deployment exists).
//
// Every transition is a row in SQLite, not just an in-memory field, so a crashed
// or restarted process can recover exactly where a given fingerprint left off
// instead of re-running (and potentially re-PRing) an attempt already in flight.
public actor RemediationStateMachine {

    public enum State: String, Sendable, Codable, CaseIterable {
        case patchProposed
        case validating
        case sandboxPassed
        case sandboxFailed
        case policyRejected
        case prOpened
        case prFailed
    }

    public struct TransitionError: Error, Equatable, Sendable {
        public let from: State?
        public let to: State
        public let reason: String
    }

    public struct Transition: Sendable, Equatable {
        public let state: State
        public let occurredAt: Date
    }

    // Terminal states end the attempt for a given key: no further transitions allowed.
    private static let terminalStates: Set<State> = [.sandboxFailed, .policyRejected, .prOpened, .prFailed]

    // Which states a transition may legally originate from. `nil` origin means
    // "only valid as the very first transition for a key".
    private static let allowedPredecessors: [State: Set<State?>] = [
        .patchProposed: [nil],
        .validating: [.patchProposed],
        .sandboxPassed: [.validating],
        .sandboxFailed: [.validating],
        // Policy can reject before any patch exists (category/confidence ineligible)
        // or after a patch was proposed but before it's sent to the sandbox.
        .policyRejected: [nil, .patchProposed],
        .prOpened: [.sandboxPassed],
        .prFailed: [.sandboxPassed],
    ]

    private let handle = StateMachineDBHandle()
    private var db: OpaquePointer? { handle.ptr }

    private static let schemaDDL = """
        CREATE TABLE IF NOT EXISTS remediation_transitions (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            key          TEXT NOT NULL,
            state        TEXT NOT NULL,
            occurred_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_key ON remediation_transitions(key);
        PRAGMA journal_mode=WAL;
    """

    public init(dbPath: String = "~/.xctriage/remediation_state.db") throws {
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

    // Applies a transition, or throws if it isn't legal from the key's current state.
    // Re-applying the same state the key is already in is a no-op (idempotent retry).
    public func transition(key: String, to newState: State) throws {
        let current = try currentState(for: key)
        if current == newState {
            return
        }
        if let current, Self.terminalStates.contains(current) {
            throw TransitionError(from: current, to: newState, reason: "\(key) is already in terminal state \(current.rawValue)")
        }
        guard let allowedFrom = Self.allowedPredecessors[newState], allowedFrom.contains(current) else {
            throw TransitionError(from: current, to: newState, reason: "\(newState.rawValue) is not reachable from \(current?.rawValue ?? "no prior state")")
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let sql = "INSERT INTO remediation_transitions(key, state, occurred_at) VALUES (?,?,?)"
        try execute(sql, bindings: [key, newState.rawValue, now])
    }

    public func currentState(for key: String) throws -> State? {
        let sql = """
            SELECT state FROM remediation_transitions
            WHERE key = ? ORDER BY id DESC LIMIT 1
        """
        let rows = try query(sql, bindings: [key])
        guard let raw = rows.first?.first as? String else { return nil }
        return State(rawValue: raw)
    }

    public func history(for key: String) throws -> [Transition] {
        let sql = """
            SELECT state, occurred_at FROM remediation_transitions
            WHERE key = ? ORDER BY id ASC
        """
        let rows = try query(sql, bindings: [key])
        let formatter = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard
                let raw = row[0] as? String,
                let state = State(rawValue: raw),
                let dateString = row[1] as? String,
                let date = formatter.date(from: dateString)
            else { return nil }
            return Transition(state: state, occurredAt: date)
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

    private func dbError() -> String {
        guard let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }
}
