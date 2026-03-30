import Foundation

public enum ServerState: Equatable, Codable, Sendable {
    case stopped
    case downloading(model: String, progress: Double)
    case starting(model: String)
    case running(model: String, port: Int)
    case stopping
    case error(String)
}
