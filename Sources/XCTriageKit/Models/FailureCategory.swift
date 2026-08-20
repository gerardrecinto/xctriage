public enum FailureCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case compilationError   = "compilation_error"
    case testFailure        = "test_failure"
    case flakyTest          = "flaky_test"
    case resourceExhaustion = "resource_exhaustion"
    case infraFailure       = "infra_failure"
    case dependencyFailure  = "dependency_failure"
    case timeout            = "timeout"
    case runtimeCrash       = "runtime_crash"
    case unknown            = "unknown"

    public var displayName: String {
        switch self {
        case .compilationError:   return "COMPILATION ERROR"
        case .testFailure:        return "TEST FAILURE"
        case .flakyTest:          return "FLAKY TEST"
        case .resourceExhaustion: return "RESOURCE EXHAUSTION"
        case .infraFailure:       return "INFRA FAILURE"
        case .dependencyFailure:  return "DEPENDENCY FAILURE"
        case .timeout:            return "TIMEOUT"
        case .runtimeCrash:       return "RUNTIME CRASH"
        case .unknown:            return "UNKNOWN"
        }
    }
}
