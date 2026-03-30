import Foundation

public struct LocalModel: Identifiable, Codable, Sendable {
    public var id: String { repoID }
    public let repoID: String
    public let diskSize: Int64
    public let modifiedAt: Date
    public let quantisation: String?
    public let contextLength: Int?

    public init(repoID: String, diskSize: Int64, modifiedAt: Date, quantisation: String?, contextLength: Int?) {
        self.repoID = repoID
        self.diskSize = diskSize
        self.modifiedAt = modifiedAt
        self.quantisation = quantisation
        self.contextLength = contextLength
    }
}
