import XCTest
@testable import XCTriageKit

final class DocsRuleCountTests: XCTestCase {
    private func repoFile(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    func testReadmeRuleCountsMatchTheClassifier() throws {
        let readme = try repoFile("README.md")
        let count = defaultRules.count
        XCTAssertTrue(readme.contains("\(count) weighted regex rules"), "README summary rule count is out of date")
        XCTAssertTrue(readme.contains("Patterns (\(count) total)"), "README category table rule count is out of date")
        XCTAssertTrue(readme.contains("\(count) NSRegularExpression rules"), "README diagram rule count is out of date")
    }

    func testArchitectureDocsDoNotQuoteAStaleRuleCount() throws {
        let doc = try repoFile("docs/architecture/HIGH_LEVEL_ARCHITECTURE.md")
        XCTAssertTrue(doc.contains("(\(defaultRules.count) rules, 8 categories"), "architecture rule count is out of date")
    }
}
