import Foundation

public final class OllmlxConfig: Sendable {
    public static let shared = OllmlxConfig()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.defaultModel: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            Keys.publicPort: 11434,
            Keys.controlPort: 11435,
            Keys.maxTokens: 4096,
            Keys.launchAtLogin: false,
            Keys.autoResumeOnWake: false,
            Keys.allowExternalConnections: false,
        ])
    }

    // MARK: - Keys

    private enum Keys {
        static let pythonPath = "pythonPath"
        static let defaultModel = "defaultModel"
        static let publicPort = "publicPort"
        static let controlPort = "controlPort"
        static let maxTokens = "maxTokens"
        static let launchAtLogin = "launchAtLogin"
        static let autoResumeOnWake = "autoResumeOnWake"
        static let lastActiveModel = "lastActiveModel"
        static let allowExternalConnections = "allowExternalConnections"
    }

    // MARK: - Properties

    public var pythonPath: String {
        get { defaults.string(forKey: Keys.pythonPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.pythonPath) }
    }

    public var defaultModel: String {
        get { defaults.string(forKey: Keys.defaultModel) ?? "mlx-community/Llama-3.2-3B-Instruct-4bit" }
        set { defaults.set(newValue, forKey: Keys.defaultModel) }
    }

    public var publicPort: Int {
        get { defaults.integer(forKey: Keys.publicPort) }
        set { defaults.set(newValue, forKey: Keys.publicPort) }
    }

    public var controlPort: Int {
        get { defaults.integer(forKey: Keys.controlPort) }
        set { defaults.set(newValue, forKey: Keys.controlPort) }
    }

    public var maxTokens: Int {
        get { defaults.integer(forKey: Keys.maxTokens) }
        set { defaults.set(newValue, forKey: Keys.maxTokens) }
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    public var autoResumeOnWake: Bool {
        get { defaults.bool(forKey: Keys.autoResumeOnWake) }
        set { defaults.set(newValue, forKey: Keys.autoResumeOnWake) }
    }

    public var lastActiveModel: String? {
        get { defaults.string(forKey: Keys.lastActiveModel) }
        set { defaults.set(newValue, forKey: Keys.lastActiveModel) }
    }

    public var allowExternalConnections: Bool {
        get { defaults.bool(forKey: Keys.allowExternalConnections) }
        set { defaults.set(newValue, forKey: Keys.allowExternalConnections) }
    }

    // MARK: - API Key (Keychain only)

    public var apiKey: String? {
        get { Keychain.getAPIKey() }
    }

    public func setAPIKey(_ key: String?) throws {
        try Keychain.setAPIKey(key)
    }

    // MARK: - Derived paths

    public var venvPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ollmlx/venv"
    }

    public var logDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ollmlx/logs"
    }

    public var logFilePath: String {
        "\(logDirectory)/server.log"
    }

    public var previousLogFilePath: String {
        "\(logDirectory)/server.log.1"
    }
}
