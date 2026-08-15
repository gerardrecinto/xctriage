import Foundation

// Single-file, minimal-diff remediation candidate. Deliberately single-file:
// RemediationPolicy's default maxFilesChanged is 1, so a proposal spanning
// multiple files has no representation here — the generator is constrained
// to the one failing file it was given.
public struct PatchProposal: Sendable, Codable, Equatable {
    public let filePath: String
    public let unifiedDiff: String
    public let rationale: String
    public let confidence: Double

    public init(filePath: String, unifiedDiff: String, rationale: String, confidence: Double) {
        self.filePath = filePath
        self.unifiedDiff = unifiedDiff
        self.rationale = rationale
        self.confidence = confidence
    }
}
