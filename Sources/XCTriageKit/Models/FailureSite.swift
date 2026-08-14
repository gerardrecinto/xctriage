import Foundation

public struct FailureSite: Sendable, Equatable, Codable {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let testName: String?
    public let errorMessage: String

    public init(
        file: String?,
        line: Int?,
        column: Int?,
        testName: String?,
        errorMessage: String
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.testName = testName
        self.errorMessage = errorMessage
    }

    public var locationDescription: String {
        if let file, let line {
            let col = column.map { ":\($0)" } ?? ""
            let short = URL(fileURLWithPath: file).lastPathComponent
            return "\(short):\(line)\(col)"
        }
        if let testName { return testName }
        return "unknown"
    }
}
