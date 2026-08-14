public struct LogEntry: Sendable, Equatable {
    public let lineNumber: Int
    public let level: LogLevel?
    public let message: String
    public let raw: String

    public init(lineNumber: Int, level: LogLevel?, message: String, raw: String) {
        self.lineNumber = lineNumber
        self.level = level
        self.message = message
        self.raw = raw
    }
}

public enum LogLevel: String, Sendable, Equatable {
    case error   = "ERROR"
    case warning = "WARNING"
    case info    = "INFO"
    case note    = "NOTE"
}
