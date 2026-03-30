import Foundation

public enum ServerError: Error, LocalizedError {
    case modelNotFound(String)
    case processDied
    case timeout
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let model):
            return "Model not found in local cache: \(model)"
        case .processDied:
            return "mlx_lm.server process died unexpectedly"
        case .timeout:
            return "Timed out waiting for mlx_lm.server to start"
        case .alreadyRunning:
            return "Server is already running"
        }
    }
}

public enum ControlClientError: Error, LocalizedError {
    case daemonNotRunning
    case unexpectedStatus(Int)
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running (connection refused on :11435)"
        case .unexpectedStatus(let code):
            return "Unexpected HTTP status: \(code)"
        case .decodingFailed:
            return "Failed to decode response from daemon"
        }
    }
}
