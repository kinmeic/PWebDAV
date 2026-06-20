import Foundation

enum ServerStatus: Equatable {
    case stopped
    case starting
    case running(port: Int)
    case stopping
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var menuTitle: String {
        switch self {
        case .stopped:
            return L.str("status.menu.stopped")
        case .starting:
            return L.str("status.menu.starting")
        case .running(let port):
            return L.fmt("status.menu.running", port)
        case .stopping:
            return L.str("status.menu.stopping")
        case .failed(let message):
            return L.fmt("status.menu.failed", message)
        }
    }

    var displayText: String {
        switch self {
        case .stopped:
            return L.str("status.display.stopped")
        case .starting:
            return L.str("status.display.starting")
        case .running(let port):
            return L.fmt("status.display.running", port)
        case .stopping:
            return L.str("status.display.stopping")
        case .failed(let message):
            return L.fmt("status.display.failed", message)
        }
    }

    var menuSymbolName: String {
        switch self {
        case .running:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .starting, .stopping:
            return "clock.fill"
        case .stopped:
            return "pause.circle.fill"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var port: Int
    var bindAddress: String
    var tlsEnabled: Bool
    var tlsCertificatePath: String
    var tlsPrivateKeyPath: String
    var uploadLimitEnabled: Bool
    var uploadLimitMB: Int
    var interfaceLanguage: InterfaceLanguage
    var autoStartServer: Bool
    var shares: [ShareDirectory]
    var accounts: [Account]

    static let `default` = AppSettings(
        port: 5005,
        bindAddress: "127.0.0.1",
        tlsEnabled: false,
        tlsCertificatePath: "",
        tlsPrivateKeyPath: "",
        uploadLimitEnabled: true,
        uploadLimitMB: 100,
        interfaceLanguage: .system,
        autoStartServer: false,
        shares: [],
        accounts: []
    )

    init(
        port: Int,
        bindAddress: String,
        tlsEnabled: Bool,
        tlsCertificatePath: String,
        tlsPrivateKeyPath: String,
        uploadLimitEnabled: Bool,
        uploadLimitMB: Int,
        interfaceLanguage: InterfaceLanguage,
        autoStartServer: Bool,
        shares: [ShareDirectory],
        accounts: [Account]
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.tlsEnabled = tlsEnabled
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.uploadLimitEnabled = uploadLimitEnabled
        self.uploadLimitMB = uploadLimitMB
        self.interfaceLanguage = interfaceLanguage
        self.autoStartServer = autoStartServer
        self.shares = shares
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.default.port
        bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress) ?? Self.default.bindAddress
        tlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .tlsEnabled) ?? Self.default.tlsEnabled
        tlsCertificatePath = try container.decodeIfPresent(String.self, forKey: .tlsCertificatePath) ?? Self.default.tlsCertificatePath
        tlsPrivateKeyPath = try container.decodeIfPresent(String.self, forKey: .tlsPrivateKeyPath) ?? Self.default.tlsPrivateKeyPath
        uploadLimitEnabled = try container.decodeIfPresent(Bool.self, forKey: .uploadLimitEnabled) ?? Self.default.uploadLimitEnabled
        uploadLimitMB = try container.decodeIfPresent(Int.self, forKey: .uploadLimitMB) ?? Self.default.uploadLimitMB
        interfaceLanguage = try container.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? Self.default.interfaceLanguage
        autoStartServer = try container.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? Self.default.autoStartServer
        shares = try container.decodeIfPresent([ShareDirectory].self, forKey: .shares) ?? Self.default.shares
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? Self.default.accounts
    }
}

enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var lprojName: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    var label: String {
        switch self {
        case .system:
            return L.str("language.system")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}

struct ShareDirectory: Codable, Identifiable, Hashable {
    var id: UUID
    var virtualName: String
    var localPath: String
    var bookmarkData: Data?
    var enabled: Bool
    var protectHiddenFiles: Bool

    init(id: UUID = UUID(), virtualName: String, localPath: String, bookmarkData: Data? = nil, enabled: Bool = true, protectHiddenFiles: Bool = true) {
        self.id = id
        self.virtualName = virtualName
        self.localPath = localPath
        self.bookmarkData = bookmarkData
        self.enabled = enabled
        self.protectHiddenFiles = protectHiddenFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        virtualName = try container.decode(String.self, forKey: .virtualName)
        localPath = try container.decode(String.self, forKey: .localPath)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        protectHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .protectHiddenFiles) ?? true
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id: UUID
    var username: String
    var passwordDigest: String
    var enabled: Bool
    var defaultPermission: PermissionLevel
    var directoryPermissions: [UUID: PermissionLevel]

    var hasPassword: Bool {
        !passwordDigest.isEmpty
    }

    init(
        id: UUID = UUID(),
        username: String,
        passwordDigest: String,
        enabled: Bool = true,
        defaultPermission: PermissionLevel = .readOnly,
        directoryPermissions: [UUID: PermissionLevel] = [:]
    ) {
        self.id = id
        self.username = username
        self.passwordDigest = passwordDigest
        self.enabled = enabled
        self.defaultPermission = defaultPermission
        self.directoryPermissions = directoryPermissions
    }
}

enum PermissionLevel: String, Codable, CaseIterable, Identifiable {
    case none
    case readOnly
    case readWrite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return L.str("permission.none")
        case .readOnly:
            return L.str("permission.readOnly")
        case .readWrite:
            return L.str("permission.readWrite")
        }
    }

    var canRead: Bool {
        self == .readOnly || self == .readWrite
    }

    var canWrite: Bool {
        self == .readWrite
    }
}

struct LogEntry: Identifiable, Hashable {
    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String
}
