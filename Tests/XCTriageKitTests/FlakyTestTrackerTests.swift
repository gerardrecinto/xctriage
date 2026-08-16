import XCTest
@testable import XCTriageKit

final class FlakyTestTrackerTests: XCTestCase {

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

    func test_scores_emptyDBReturnsZero() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        let scores = try await tracker.scores(for: ["SomeTests.test_a"])
        XCTAssertEqual(scores["SomeTests.test_a"], 0)
    }

    func test_scores_emptyInputReturnsEmptyDict() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        let scores = try await tracker.scores(for: [])
        XCTAssertTrue(scores.isEmpty)
    }

    func test_record_thenScores_reflectsFailureRatio() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)

        // 2 distinct builds; the flaky test fails in both, a stable test in neither.
        try await tracker.record(testName: "Suite.test_flaky", buildID: "build-1", source: "xcodebuild")
        try await tracker.record(testName: "Suite.test_flaky", buildID: "build-2", source: "xcodebuild")

        let scores = try await tracker.scores(for: ["Suite.test_flaky", "Suite.test_stable"])
        XCTAssertEqual(scores["Suite.test_flaky"], 1.0)
        XCTAssertEqual(scores["Suite.test_stable"], 0.0)
    }

    func test_record_withNilBuildID_doesNotThrow() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        try await tracker.record(testName: "Suite.test_a", buildID: nil, source: "xcodebuild")
        let scores = try await tracker.scores(for: ["Suite.test_a"])
        XCTAssertGreaterThan(scores["Suite.test_a"] ?? 0, 0)
    }

    func test_topFlaky_ordersByFailureCountDescending() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        for buildID in ["b1", "b2", "b3"] {
            try await tracker.record(testName: "Suite.test_veryFlaky", buildID: buildID, source: "xcodebuild")
        }
        try await tracker.record(testName: "Suite.test_slightlyFlaky", buildID: "b1", source: "xcodebuild")

        let top = try await tracker.topFlaky(n: 10)
        XCTAssertEqual(top.first?.name, "Suite.test_veryFlaky")
        XCTAssertGreaterThan(top.first?.score ?? 0, top.last?.score ?? 1)
    }

    func test_topFlaky_emptyHistoryReturnsEmpty() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        let top = try await tracker.topFlaky(n: 10)
        XCTAssertTrue(top.isEmpty)
    }

    func test_quarantineCandidates_returnsOnlyTestsAboveThreshold() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        // 3 distinct builds; test_alwaysFails fails in all 3 (score 1.0),
        // test_sometimesFails fails in 1 of 3 (score 0.33) — below the
        // default 0.70 quarantine threshold from the comment in
        // FlakyTestTracker.swift ("Score > 0.70 -> quarantine candidate").
        for buildID in ["b1", "b2", "b3"] {
            try await tracker.record(testName: "Suite.test_alwaysFails", buildID: buildID, source: "xcodebuild")
        }
        try await tracker.record(testName: "Suite.test_sometimesFails", buildID: "b1", source: "xcodebuild")

        let candidates = try await tracker.quarantineCandidates()
        XCTAssertEqual(candidates.map(\.name), ["Suite.test_alwaysFails"])
    }

    func test_quarantineCandidates_respectsCustomThreshold() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        for buildID in ["b1", "b2", "b3"] {
            try await tracker.record(testName: "Suite.test_alwaysFails", buildID: buildID, source: "xcodebuild")
        }
        try await tracker.record(testName: "Suite.test_sometimesFails", buildID: "b1", source: "xcodebuild")

        // 0.33 clears a threshold of 0.30, so both tests should qualify now.
        let candidates = try await tracker.quarantineCandidates(threshold: 0.30)
        XCTAssertEqual(Set(candidates.map(\.name)), ["Suite.test_alwaysFails", "Suite.test_sometimesFails"])
    }

    func test_quarantineCandidates_emptyHistoryReturnsEmpty() async throws {
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        let candidates = try await tracker.quarantineCandidates()
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_quarantineCandidates_exactlyAtThresholdIsNotIncluded() async throws {
        // "> 0.70", not ">=" — per the documented comment, a test scoring
        // exactly at the threshold is not yet a quarantine candidate.
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        try await tracker.record(testName: "Suite.test_exactlyHalf", buildID: "b1", source: "xcodebuild")
        // Registers b2 as a second distinct build without adding another
        // failure for test_exactlyHalf, so its score lands at exactly
        // 1 failure / 2 builds = 0.5.
        try await tracker.record(testName: "Suite.other", buildID: "b2", source: "xcodebuild")

        let candidates = try await tracker.quarantineCandidates(threshold: 0.5)
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_scores_capsAtOneEvenWithMoreFailuresThanBuilds() async throws {
        // A test can only fail once per recorded build in normal usage, but the
        // score formula divides by distinct build_id count, so guard against
        // it ever exceeding 1.0 if duplicate records land for the same build.
        let tracker = try FlakyTestTracker(dbPath: dbPath)
        try await tracker.record(testName: "Suite.test_dup", buildID: "b1", source: "xcodebuild")
        try await tracker.record(testName: "Suite.test_dup", buildID: "b1", source: "xcodebuild")

        let scores = try await tracker.scores(for: ["Suite.test_dup"])
        XCTAssertLessThanOrEqual(scores["Suite.test_dup"] ?? 0, 1.0)
    }
}
