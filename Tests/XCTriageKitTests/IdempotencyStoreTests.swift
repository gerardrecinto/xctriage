import XCTest
@testable import XCTriageKit

final class IdempotencyStoreTests: XCTestCase {

    var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = makeTempDBPath()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        super.tearDown()
    }

    func test_unseenKey_isNotProcessed() async throws {
        let store = try IdempotencyStore(dbPath: dbPath)
        let existing = try await store.existingResult(operation: "create_pr", key: "fp-1")
        XCTAssertNil(existing)
    }

    func test_recordThenLookup_returnsStoredResult() async throws {
        let store = try IdempotencyStore(dbPath: dbPath)
        try await store.recordProcessed(operation: "create_pr", key: "fp-1", result: "https://github.com/x/y/pull/42")

        let existing = try await store.existingResult(operation: "create_pr", key: "fp-1")
        XCTAssertEqual(existing, "https://github.com/x/y/pull/42")
    }

    func test_recordingSameOperationKeyTwice_keepsFirstResult() async throws {
        // Duplicate delivery (e.g. a retried CI trigger) must not overwrite the
        // original outcome, or the caller could be misled about which run
        // actually opened the PR.
        let store = try IdempotencyStore(dbPath: dbPath)
        try await store.recordProcessed(operation: "create_pr", key: "fp-1", result: "https://github.com/x/y/pull/42")
        try await store.recordProcessed(operation: "create_pr", key: "fp-1", result: "https://github.com/x/y/pull/999")

        let existing = try await store.existingResult(operation: "create_pr", key: "fp-1")
        XCTAssertEqual(existing, "https://github.com/x/y/pull/42")
    }

    func test_sameKey_differentOperation_areIndependent() async throws {
        let store = try IdempotencyStore(dbPath: dbPath)
        try await store.recordProcessed(operation: "create_pr", key: "fp-1", result: "pr-result")
        try await store.recordProcessed(operation: "jira_ticket", key: "fp-1", result: "jira-result")

        let pr = try await store.existingResult(operation: "create_pr", key: "fp-1")
        let jira = try await store.existingResult(operation: "jira_ticket", key: "fp-1")
        XCTAssertEqual(pr, "pr-result")
        XCTAssertEqual(jira, "jira-result")
    }

    func test_differentKeys_areIndependent() async throws {
        let store = try IdempotencyStore(dbPath: dbPath)
        try await store.recordProcessed(operation: "create_pr", key: "fp-1", result: "pr-1")
        let other = try await store.existingResult(operation: "create_pr", key: "fp-2")
        XCTAssertNil(other)
    }

    func test_state_survivesReopeningSameDatabase() async throws {
        let store1 = try IdempotencyStore(dbPath: dbPath)
        try await store1.recordProcessed(operation: "create_pr", key: "fp-1", result: "pr-1")

        let store2 = try IdempotencyStore(dbPath: dbPath)
        let existing = try await store2.existingResult(operation: "create_pr", key: "fp-1")
        XCTAssertEqual(existing, "pr-1")
    }
}
