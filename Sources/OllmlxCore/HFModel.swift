import Foundation

public struct HFModel: Identifiable, Codable, Sendable {
    public let id: String
    public let downloads: Int
    public let tags: [String]
    public let lastModified: Date?

    public init(id: String, downloads: Int, tags: [String], lastModified: Date?) {
        self.id = id
        self.downloads = downloads
        self.tags = tags
        self.lastModified = lastModified
    }
}
