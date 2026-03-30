import Foundation

public struct PullProgress: Codable, Sendable {
    public let modelID: String
    public let bytesDownloaded: Int64
    public let bytesTotal: Int64?
    public var fraction: Double? {
        guard let total = bytesTotal, total > 0 else { return nil }
        return Double(bytesDownloaded) / Double(total)
    }
    public let description: String

    public init(modelID: String, bytesDownloaded: Int64, bytesTotal: Int64?, description: String) {
        self.modelID = modelID
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case modelID, bytesDownloaded, bytesTotal, fraction, description
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(bytesDownloaded, forKey: .bytesDownloaded)
        try container.encodeIfPresent(bytesTotal, forKey: .bytesTotal)
        try container.encodeIfPresent(fraction, forKey: .fraction)
        try container.encode(description, forKey: .description)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        bytesDownloaded = try container.decode(Int64.self, forKey: .bytesDownloaded)
        bytesTotal = try container.decodeIfPresent(Int64.self, forKey: .bytesTotal)
        description = try container.decode(String.self, forKey: .description)
    }
}
