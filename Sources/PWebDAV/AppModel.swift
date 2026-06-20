import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var status: ServerStatus = .stopped
    @Published var logs: [LogEntry] = []
    @Published var selectedShareID: ShareDirectory.ID?
    @Published var selectedAccountID: Account.ID?
    @Published var localizationRevision = 0

    var onStatusChanged: (() -> Void)?

    private let store = SettingsStore()
    private let server = WebDAVServerManager()
    private let runtimeSettings: RuntimeSettings
    private let maxLogCount = 500

    init() {
        let loadedSettings = store.load()
        settings = loadedSettings
        runtimeSettings = RuntimeSettings(loadedSettings)
        L.setLanguage(loadedSettings.interfaceLanguage)
    }

    var versionText: String {
        "0.2.3"
    }

    var accessURL: String {
        settings.tlsEnabled ? httpsAccessURL : httpAccessURL
    }

    private var httpAccessURL: String {
        "http://\(displayHost):\(settings.port)"
    }

    private var httpsAccessURL: String {
        "https://\(displayHost):\(settings.httpsPort)"
    }

    private var accessURLs: String {
        settings.tlsEnabled ? "\(httpAccessURL), \(httpsAccessURL)" : httpAccessURL
    }

    private var displayHost: String {
        settings.bindAddress == "0.0.0.0" ? "localhost" : settings.bindAddress
    }

    func startServer() {
        guard canStartServer else { return }
        saveSettings()
        status = .starting
        onStatusChanged?()
        if settings.tlsEnabled {
            appendLog(.info, L.fmt("log.server.startingWithTLS", String(settings.port), String(settings.httpsPort)))
        } else {
            appendLog(.info, L.fmt("log.server.starting", String(settings.port)))
        }

        let snapshot = settings
        server.start(settings: snapshot, settingsProvider: { [runtimeSettings] in
            runtimeSettings.snapshot()
        }) { [weak self] event in
            Task { @MainActor in
                self?.handleServerEvent(event)
            }
        }
    }

    private var canStartServer: Bool {
        if status == .stopped { return true }
        if case .failed = status { return true }
        return false
    }

    func stopServer() {
        stopServer {
            self.status = .stopped
            self.appendLog(.info, L.str("log.server.stopped"))
            self.onStatusChanged?()
        }
    }

    private func stopServer(completion: @escaping () -> Void) {
        guard status != .stopped else { return }
        status = .stopping
        onStatusChanged?()
        appendLog(.info, L.str("log.server.stopping"))

        server.stop { [weak self] in
            Task { @MainActor in
                guard self != nil else { return }
                completion()
            }
        }
    }

    func restartServer() {
        if status.isRunning || status == .starting {
            stopServer {
                self.status = .stopped
                self.appendLog(.info, L.str("log.server.stopped"))
                self.onStatusChanged?()
                self.startServer()
            }
        } else if status == .stopping {
            server.stop { [weak self] in
                Task { @MainActor in
                    self?.status = .stopped
                    self?.onStatusChanged?()
                    self?.startServer()
                }
            }
        } else {
            startServer()
        }
    }

    func pickTLSCertificate() {
        if let path = pickFilePath(allowedExtensions: ["pem", "crt", "cer"]) {
            settings.tlsCertificatePath = path
            saveSettings()
        }
    }

    func pickTLSPrivateKey() {
        if let path = pickFilePath(allowedExtensions: ["pem", "key"]) {
            settings.tlsPrivateKeyPath = path
            saveSettings()
        }
    }

    private func pickFilePath(allowedExtensions: [String]) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if !allowedExtensions.isEmpty, !allowedExtensions.contains(url.pathExtension.lowercased()) {
            return url.path
        }
        return url.path
    }

    func saveSettings() {
        settings.port = min(max(1, settings.port), 65535)
        settings.httpsPort = min(max(1, settings.httpsPort), 65535)
        settings.uploadLimitMB = max(1, settings.uploadLimitMB)
        let previousLanguage = L.currentLanguage
        L.setLanguage(settings.interfaceLanguage)
        if previousLanguage != settings.interfaceLanguage {
            localizationRevision += 1
        }
        runtimeSettings.update(settings)
        do {
            try store.save(settings)
        } catch {
            appendLog(.error, L.fmt("log.settings.saveFailed", error.localizedDescription))
        }
        onStatusChanged?()
    }

    func addShareFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = uniqueVirtualName(from: url.lastPathComponent)
        let share = ShareDirectory(virtualName: name, localPath: url.path, bookmarkData: bookmark)
        settings.shares.append(share)
        selectedShareID = share.id
        saveSettings()
        appendLog(.info, L.fmt("log.share.added", name, url.path))
    }

    func removeSelectedShare() {
        guard let selectedShareID else { return }
        settings.shares.removeAll { $0.id == selectedShareID }
        for index in settings.accounts.indices {
            settings.accounts[index].directoryPermissions.removeValue(forKey: selectedShareID)
        }
        self.selectedShareID = nil
        saveSettings()
    }

    @discardableResult
    func addAccount() -> UUID {
        let base = "user"
        var username = base
        var suffix = 1
        let names = Set(settings.accounts.map(\.username))
        while names.contains(username) {
            suffix += 1
            username = "\(base)\(suffix)"
        }

        let account = Account(username: username, passwordDigest: "", enabled: false)
        settings.accounts.append(account)
        selectedAccountID = account.id
        saveSettings()
        appendLog(.info, L.fmt("log.account.added", username))
        return account.id
    }

    func removeSelectedAccount() {
        guard let selectedAccountID else { return }
        settings.accounts.removeAll { $0.id == selectedAccountID }
        self.selectedAccountID = nil
        saveSettings()
    }

    func updatePassword(for accountID: UUID, password: String) {
        guard let index = settings.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        settings.accounts[index].passwordDigest = PasswordHasher.digest(password: password)
        saveSettings()
    }

    func clearLogs() {
        logs.removeAll()
    }

    func appendLog(_ level: LogEntry.Level, _ message: String) {
        logs.append(LogEntry(timestamp: Date(), level: level, message: message))
        if logs.count > maxLogCount {
            logs.removeFirst(logs.count - maxLogCount)
        }
    }

    private func handleServerEvent(_ event: WebDAVServerEvent) {
        switch event {
        case .started(let httpPort, let httpsPort):
            status = .running(httpPort: httpPort, httpsPort: httpsPort)
            appendLog(.info, L.fmt("log.server.started", accessURLs))
        case .stopped:
            status = .stopped
            appendLog(.info, L.str("log.server.stopped"))
        case .failed(let message):
            status = .failed(message)
            appendLog(.error, message)
        case .request(let line):
            appendLog(.info, line)
        }
        onStatusChanged?()
    }

    private func uniqueVirtualName(from candidate: String) -> String {
        let cleaned = sanitizeVirtualName(candidate)
        var name = cleaned.isEmpty ? "Share" : cleaned
        var suffix = 1
        let existing = Set(settings.shares.map { $0.virtualName.lowercased() })
        while existing.contains(name.lowercased()) {
            suffix += 1
            name = "\(cleaned)-\(suffix)"
        }
        return name
    }

    private func sanitizeVirtualName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

final class RuntimeSettings {
    private let lock = NSLock()
    private var current: AppSettings

    init(_ settings: AppSettings) {
        current = settings
    }

    func update(_ settings: AppSettings) {
        lock.lock()
        current = settings
        lock.unlock()
    }

    func snapshot() -> AppSettings {
        lock.lock()
        let settings = current
        lock.unlock()
        return settings
    }
}
