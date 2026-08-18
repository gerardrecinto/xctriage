// Shared category -> stable identifier / severity mapping used by both the
// SARIF (SARIFReporter) and GitHub Actions annotation (GitHubReporter)
// output formats, so the two agree on what counts as an error vs. a
// warning for a given failure category instead of drifting independently.
enum AnnotationSeverity: String {
    case error
    case warning
    case note

    // GitHub Actions workflow commands have no "note" level; its closest
    // equivalent is "notice".
    var githubCommand: String {
        switch self {
        case .error:   return "error"
        case .warning: return "warning"
        case .note:    return "notice"
        }
    }
}

enum FailureCategoryMapping {

    // Stable ruleId per category, namespaced under xctriage/<area>/<slug>
    // so it stays stable across xctriage releases and dedupable by
    // consumers (e.g. GitHub code scanning). FailureCategory is a closed,
    // CaseIterable enum and this switch covers every case, so the compiler
    // guarantees no category reaches here unmapped; `.unknown` itself is
    // the generic fallback ruleId for a category the classifier couldn't
    // pin down further.
    static func ruleID(for category: FailureCategory) -> String {
        switch category {
        case .compilationError:   return "xctriage/compiler/error"
        case .testFailure:        return "xctriage/test/failure"
        case .flakyTest:          return "xctriage/test/flaky"
        case .resourceExhaustion: return "xctriage/infra/resource-exhaustion"
        case .infraFailure:       return "xctriage/infra/failure"
        case .dependencyFailure:  return "xctriage/dependency/failure"
        case .timeout:            return "xctriage/infra/timeout"
        case .unknown:            return "xctriage/unknown"
        }
    }

    // Baseline severity by category, downgraded a notch when the
    // classifier itself wasn't confident -- an uncertain call shouldn't
    // carry the same weight in a PR's annotations/Security tab as a sure one.
    static func severity(for category: FailureCategory, confidence: Double) -> AnnotationSeverity {
        let base: AnnotationSeverity
        switch category {
        case .flakyTest: base = .warning
        case .unknown:   base = .note
        default:         base = .error
        }

        guard confidence < 0.5 else { return base }
        switch base {
        case .error:   return .warning
        case .warning: return .note
        case .note:    return .note
        }
    }
}
