import Foundation
import CryptoKit

// Deterministic identity for a failure: same category + same normalized
// primary failure site → same fingerprint, independent of process/run.
// Deliberately not Swift's Hasher (randomly seeded per process) — this
// value must be stable across CI runs so recurrence can be detected.
public struct FailureFingerprint: Sendable, Equatable, Codable {
    public let value: String

    public init(category: FailureCategory, failureSites: [FailureSite]) {
        let signature = Self.normalizedSignature(category: category, failureSites: failureSites)
        let digest = SHA256.hash(data: Data(signature.utf8))
        value = String(digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func normalizedSignature(category: FailureCategory, failureSites: [FailureSite]) -> String {
        guard let primary = failureSites.first else {
            return "\(category.rawValue)|no-site"
        }
        let file = primary.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown-file"
        let test = primary.testName ?? "unknown-test"
        let message = normalize(primary.errorMessage)
        return "\(category.rawValue)|\(file)|\(test)|\(message)"
    }

    // Strips volatile tokens (UUIDs, memory addresses, long digit runs,
    // temp-dir paths) that vary run-to-run but don't change failure identity.
    private static func normalize(_ message: String) -> String {
        var result = message
        for (pattern, replacement) in volatilePatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    private static let volatilePatterns: [(String, String)] = [
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<uuid>"),
        (#"0x[0-9A-Fa-f]{4,}"#, "<addr>"),
        (#"/(var/folders|tmp)/[^\s]+"#, "<tmp>"),
        (#"\d{6,}"#, "<num>"),
    ]
}
