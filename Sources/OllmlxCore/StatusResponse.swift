import Foundation

public struct StatusResponse: Codable, Sendable {
    public let state: ServerState
    public let memoryUsage: String?
    public let publicPort: Int
    public let controlPort: Int
    public let pythonPath: String?

    public init(state: ServerState, memoryUsage: String?, publicPort: Int, controlPort: Int, pythonPath: String?) {
        self.state = state
        self.memoryUsage = memoryUsage
        self.publicPort = publicPort
        self.controlPort = controlPort
        self.pythonPath = pythonPath
    }
}
