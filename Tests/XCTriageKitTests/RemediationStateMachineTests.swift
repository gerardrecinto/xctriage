import XCTest
@testable import XCTriageKit

final class RemediationStateMachineTests: XCTestCase {

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

    func test_newKey_hasNoState() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        let state = try await machine.currentState(for: "fp-1")
        XCTAssertNil(state)
    }

    func test_transition_persistsNewState() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        let state = try await machine.currentState(for: "fp-1")
        XCTAssertEqual(state, .patchProposed)
    }

    func test_transition_followsPipelineOrder() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-1", to: .validating)
        try await machine.transition(key: "fp-1", to: .sandboxPassed)
        try await machine.transition(key: "fp-1", to: .prOpened)

        let state = try await machine.currentState(for: "fp-1")
        XCTAssertEqual(state, .prOpened)
    }

    func test_transition_recordsFullHistory() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-1", to: .validating)
        try await machine.transition(key: "fp-1", to: .sandboxFailed)

        let history = try await machine.history(for: "fp-1")
        XCTAssertEqual(history.map(\.state), [.patchProposed, .validating, .sandboxFailed])
    }

    func test_transition_intoTerminalState_rejectsFurtherTransitions() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-1", to: .validating)
        try await machine.transition(key: "fp-1", to: .sandboxPassed)
        try await machine.transition(key: "fp-1", to: .prOpened)

        do {
            try await machine.transition(key: "fp-1", to: .validating)
            XCTFail("expected transition out of a terminal state to throw")
        } catch is RemediationStateMachine.TransitionError {
            // expected
        }

        // Terminal state must not have been disturbed by the rejected attempt.
        let state = try await machine.currentState(for: "fp-1")
        XCTAssertEqual(state, .prOpened)
    }

    func test_transition_isIdempotent_reapplyingSameStateIsNoOp() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-1", to: .patchProposed)

        let history = try await machine.history(for: "fp-1")
        XCTAssertEqual(history.count, 1, "re-applying the same state must not append a duplicate row")
    }

    func test_transition_keysAreIndependent() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-2", to: .policyRejected)

        let state1 = try await machine.currentState(for: "fp-1")
        let state2 = try await machine.currentState(for: "fp-2")
        XCTAssertEqual(state1, .patchProposed)
        XCTAssertEqual(state2, .policyRejected)
    }

    func test_state_survivesReopeningSameDatabase() async throws {
        let machine1 = try RemediationStateMachine(dbPath: dbPath)
        try await machine1.transition(key: "fp-1", to: .patchProposed)
        try await machine1.transition(key: "fp-1", to: .validating)

        // Recovery after a process restart: a fresh instance over the same file
        // must see the same current state, not start over.
        let machine2 = try RemediationStateMachine(dbPath: dbPath)
        let state = try await machine2.currentState(for: "fp-1")
        XCTAssertEqual(state, .validating)
    }

    func test_invalidJump_skippingRequiredStage_throws() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        do {
            try await machine.transition(key: "fp-1", to: .prOpened)
            XCTFail("expected jumping straight to prOpened without a proposal to throw")
        } catch is RemediationStateMachine.TransitionError {
            // expected
        }
        let state = try await machine.currentState(for: "fp-1")
        XCTAssertNil(state)
    }

    func test_failureBranch_policyRejected_isTerminal() async throws {
        let machine = try RemediationStateMachine(dbPath: dbPath)
        try await machine.transition(key: "fp-1", to: .patchProposed)
        try await machine.transition(key: "fp-1", to: .policyRejected)

        do {
            try await machine.transition(key: "fp-1", to: .validating)
            XCTFail("expected transition out of policyRejected to throw")
        } catch is RemediationStateMachine.TransitionError {
            // expected
        }
    }
}
