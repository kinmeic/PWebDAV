import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 540)
            .padding()

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(model: model)
                case .network:
                    NetworkSettingsView(model: model)
                case .shares:
                    ShareSettingsView(model: model)
                case .accounts:
                    AccountSettingsView(model: model)
                case .logs:
                    LogSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(model.localizationRevision)
        .frame(minWidth: 900, minHeight: 620)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case network
    case shares
    case accounts
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return L.str("tab.general")
        case .network:
            return L.str("tab.network")
        case .shares:
            return L.str("tab.shares")
        case .accounts:
            return L.str("tab.accounts")
        case .logs:
            return L.str("tab.logs")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section(L.str("section.general")) {
                HStack {
                    Text(L.str("label.interfaceLanguage"))

                    Spacer()

                    Picker("", selection: $model.settings.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: model.settings.interfaceLanguage) { _, _ in
                        model.saveSettings()
                    }
                }
            }

            Section(L.str("section.runtime")) {
                LabeledContent(L.str("label.status")) {
                    StatusBadge(status: model.status)
                }

                LabeledContent(L.str("label.accessURL")) {
                    Text(model.accessURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                Toggle(L.str("label.autoStartServer"), isOn: $model.settings.autoStartServer)
                    .onChange(of: model.settings.autoStartServer) { _, _ in
                        model.saveSettings()
                    }

                HStack(spacing: 8) {
                    Button {
                        model.startServer()
                    } label: {
                        Label(L.str("action.start"), systemImage: "play.fill")
                    }
                    .disabled(model.status.isRunning)

                    Button {
                        model.stopServer()
                    } label: {
                        Label(L.str("action.stop"), systemImage: "stop.fill")
                    }
                    .disabled(!model.status.isRunning)

                    Button {
                        model.restartServer()
                    } label: {
                        Label(L.str("action.restart"), systemImage: "arrow.clockwise")
                    }
                }
            }

            Section(L.str("section.version")) {
                LabeledContent("PWebDAV") {
                    Text(model.versionText)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear { model.saveSettings() }
    }
}

private struct NetworkSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section(L.str("section.port")) {
                LabeledContent(L.str("label.httpPort")) {
                    TextField("", value: $model.settings.port, formatter: NumberFormatter.integer)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { model.saveSettings() }
                }

                LabeledContent(L.str("label.bindAddress")) {
                    Picker("", selection: $model.settings.bindAddress) {
                        Text(L.str("bind.allInterfaces")).tag("0.0.0.0")
                        Text(L.str("bind.localOnly")).tag("127.0.0.1")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .onChange(of: model.settings.bindAddress) { _, _ in model.saveSettings() }
                }

                if model.settings.bindAddress == "0.0.0.0" {
                    Text(L.str("warning.allInterfacesHTTP"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(L.str("section.transfer")) {
                Toggle(L.str("label.enableUploadLimit"), isOn: $model.settings.uploadLimitEnabled)
                    .onChange(of: model.settings.uploadLimitEnabled) { _, _ in model.saveSettings() }

                LabeledContent(L.str("label.uploadLimitMB")) {
                    TextField("", value: $model.settings.uploadLimitMB, formatter: NumberFormatter.integer)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(!model.settings.uploadLimitEnabled)
                        .onSubmit { model.saveSettings() }
                }
            }

            Section(L.str("section.tls")) {
                Toggle(L.str("label.enableTLS"), isOn: $model.settings.tlsEnabled)
                    .onChange(of: model.settings.tlsEnabled) { _, _ in model.saveSettings() }

                LabeledContent(L.str("label.tlsCertificate")) {
                    PathPickerRow(
                        path: $model.settings.tlsCertificatePath,
                        pick: { model.pickTLSCertificate() }
                    )
                    .onChange(of: model.settings.tlsCertificatePath) { _, _ in model.saveSettings() }
                }

                LabeledContent(L.str("label.tlsPrivateKey")) {
                    PathPickerRow(
                        path: $model.settings.tlsPrivateKeyPath,
                        pick: { model.pickTLSPrivateKey() }
                    )
                    .onChange(of: model.settings.tlsPrivateKeyPath) { _, _ in model.saveSettings() }
                }

                if model.settings.tlsEnabled &&
                    (model.settings.tlsCertificatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                     model.settings.tlsPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Text(L.str("hint.tlsRequiresCertificate"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear { model.saveSettings() }
    }
}

private struct PathPickerRow: View {
    @Binding var path: String
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            Button {
                pick()
            } label: {
                Image(systemName: "folder")
            }
            .help(L.str("action.chooseFile"))
        }
    }
}

private struct ShareSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draftShareID: UUID?
    @State private var draftVirtualName = ""
    @State private var draftLocalPath = ""
    @State private var draftEnabled = true
    @State private var draftProtectHiddenFiles = true
    @State private var draftPermissions: [UUID: PermissionLevel] = [:]

    var body: some View {
        HSplitView {
            SidebarList(addAction: { model.addShareFromPanel() }, removeAction: {
                model.removeSelectedShare()
                loadSelectedShare()
            }, removeDisabled: model.selectedShareID == nil) {
                List(selection: $model.selectedShareID) {
                    ForEach(model.settings.shares) { share in
                        ShareRow(share: share)
                            .tag(share.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            Group {
                if let selectedShare {
                    ShareEditor(
                        model: model,
                        share: selectedShare,
                        draftVirtualName: $draftVirtualName,
                        draftLocalPath: $draftLocalPath,
                        draftEnabled: $draftEnabled,
                        draftProtectHiddenFiles: $draftProtectHiddenFiles,
                        draftPermissions: $draftPermissions,
                        hasChanges: shareHasChanges,
                        load: { loadShare(selectedShare) },
                        save: saveShare
                    )
                } else {
                    EmptyState(title: L.str("empty.noShares"), systemImage: "folder.badge.plus")
                }
            }
            .frame(minWidth: 420)
        }
        .onAppear {
            loadSelectedShare()
        }
        .onChange(of: model.selectedShareID) { _, _ in
            loadSelectedShare()
        }
    }

    private var selectedShare: ShareDirectory? {
        guard let id = model.selectedShareID else { return nil }
        return model.settings.shares.first { $0.id == id }
    }

    private var shareHasChanges: Bool {
        guard let share = selectedShare else { return false }
        let currentPermissions = Dictionary(uniqueKeysWithValues: model.settings.accounts.map { account in
            (account.id, account.directoryPermissions[share.id] ?? account.defaultPermission)
        })
        return draftShareID != share.id ||
            draftVirtualName != share.virtualName ||
            draftLocalPath != share.localPath ||
            draftEnabled != share.enabled ||
            draftProtectHiddenFiles != share.protectHiddenFiles ||
            draftPermissions != currentPermissions
    }

    private func loadSelectedShare() {
        guard let selectedShare else {
            draftShareID = nil
            draftVirtualName = ""
            draftLocalPath = ""
            draftEnabled = true
            draftProtectHiddenFiles = true
            draftPermissions = [:]
            return
        }
        loadShare(selectedShare)
    }

    private func loadShare(_ share: ShareDirectory) {
        draftShareID = share.id
        draftVirtualName = share.virtualName
        draftLocalPath = share.localPath
        draftEnabled = share.enabled
        draftProtectHiddenFiles = share.protectHiddenFiles
        draftPermissions = Dictionary(uniqueKeysWithValues: model.settings.accounts.map { account in
            (account.id, account.directoryPermissions[share.id] ?? account.defaultPermission)
        })
    }

    private func saveShare() {
        guard let id = model.selectedShareID, let index = model.settings.shares.firstIndex(where: { $0.id == id }) else { return }
        model.settings.shares[index].virtualName = draftVirtualName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.shares[index].enabled = draftEnabled
        model.settings.shares[index].protectHiddenFiles = draftProtectHiddenFiles

        for accountIndex in model.settings.accounts.indices {
            let accountID = model.settings.accounts[accountIndex].id
            if let permission = draftPermissions[accountID] {
                model.settings.accounts[accountIndex].directoryPermissions[id] = permission
            }
        }
        model.saveSettings()
        loadSelectedShare()
    }
}

private struct ShareEditor: View {
    @ObservedObject var model: AppModel
    let share: ShareDirectory
    @Binding var draftVirtualName: String
    @Binding var draftLocalPath: String
    @Binding var draftEnabled: Bool
    @Binding var draftProtectHiddenFiles: Bool
    @Binding var draftPermissions: [UUID: PermissionLevel]
    let hasChanges: Bool
    let load: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        Section(L.str("section.directory")) {
                            LabeledContent(L.str("label.localPath")) {
                                Text(draftLocalPath)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }

                            LabeledContent(L.str("label.virtualName")) {
                                TextField("", text: $draftVirtualName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 320)
                            }

                            Toggle(L.str("label.enabled"), isOn: $draftEnabled)

                            Toggle(L.str("label.protectHiddenFiles"), isOn: $draftProtectHiddenFiles)
                        }

                        Section(L.str("section.accountPermissions")) {
                            if model.settings.accounts.isEmpty {
                                Text(L.str("hint.noAccountsAccessDenied"))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(model.settings.accounts) { account in
                                    LabeledContent(account.username) {
                                        Picker("", selection: Binding(
                                            get: { draftPermissions[account.id] ?? account.defaultPermission },
                                            set: { draftPermissions[account.id] = $0 }
                                        )) {
                                            ForEach(PermissionLevel.allCases) { permission in
                                                Text(permission.label).tag(permission)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 260)
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(20)
            }

            Divider()

            SaveBar(
                hasChanges: hasChanges,
                canSave: hasChanges && !draftVirtualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                revert: load,
                save: save
            )
        }
    }
}

private struct AccountSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draftAccountID: UUID?
    @State private var draftUsername = ""
    @State private var draftEnabled = true
    @State private var draftDefaultPermission: PermissionLevel = .readOnly
    @State private var draftPassword = ""

    var body: some View {
        HSplitView {
            SidebarList(addAction: { model.addAccount() }, removeAction: {
                model.removeSelectedAccount()
                loadSelectedAccount()
            }, removeDisabled: model.selectedAccountID == nil) {
                List(selection: $model.selectedAccountID) {
                    ForEach(model.settings.accounts) { account in
                        AccountRow(account: account)
                            .tag(account.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            Group {
                if let selectedAccount {
                    AccountEditor(
                        account: selectedAccount,
                        draftUsername: $draftUsername,
                        draftEnabled: $draftEnabled,
                        draftDefaultPermission: $draftDefaultPermission,
                        draftPassword: $draftPassword,
                        hasChanges: accountHasChanges,
                        canSave: canSaveAccount,
                        load: { loadAccount(selectedAccount) },
                        save: saveAccount
                    )
                } else {
                    EmptyState(title: L.str("empty.noAccounts"), systemImage: "person.badge.plus")
                }
            }
            .frame(minWidth: 420)
        }
        .onAppear {
            loadSelectedAccount()
        }
        .onChange(of: model.selectedAccountID) { _, _ in
            loadSelectedAccount()
        }
    }

    private var selectedAccount: Account? {
        guard let id = model.selectedAccountID else { return nil }
        return model.settings.accounts.first { $0.id == id }
    }

    private var accountHasChanges: Bool {
        guard let account = selectedAccount else { return false }
        return draftAccountID != account.id ||
            draftUsername != account.username ||
            draftEnabled != account.enabled ||
            draftDefaultPermission != account.defaultPermission ||
            !draftPassword.isEmpty
    }

    private var canSaveAccount: Bool {
        guard let account = selectedAccount else { return false }
        let hasPasswordAfterSave = account.hasPassword || !draftPassword.isEmpty
        return !draftUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            accountHasChanges &&
            (!draftEnabled || hasPasswordAfterSave)
    }

    private func loadSelectedAccount() {
        guard let selectedAccount else {
            draftAccountID = nil
            draftUsername = ""
            draftEnabled = true
            draftDefaultPermission = .readOnly
            draftPassword = ""
            return
        }
        loadAccount(selectedAccount)
    }

    private func loadAccount(_ account: Account) {
        draftAccountID = account.id
        draftUsername = account.username
        draftEnabled = account.enabled
        draftDefaultPermission = account.defaultPermission
        draftPassword = ""
    }

    private func saveAccount() {
        guard let id = model.selectedAccountID, let index = model.settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        let username = draftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.accounts[index].enabled = draftEnabled
        model.settings.accounts[index].defaultPermission = draftDefaultPermission
        if !draftPassword.isEmpty {
            model.settings.accounts[index].passwordDigest = PasswordHasher.digest(username: username, password: draftPassword)
        }
        model.saveSettings()
        loadSelectedAccount()
    }
}

private struct AccountEditor: View {
    let account: Account
    @Binding var draftUsername: String
    @Binding var draftEnabled: Bool
    @Binding var draftDefaultPermission: PermissionLevel
    @Binding var draftPassword: String
    let hasChanges: Bool
    let canSave: Bool
    let load: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        Section(L.str("section.account")) {
                            LabeledContent(L.str("label.username")) {
                                Text(draftUsername)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            LabeledContent(L.str("label.newPassword")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    SecureField("", text: $draftPassword)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 320)

                                    Text(account.hasPassword ? L.str("hint.leaveBlankPassword") : L.str("hint.passwordRequiredBeforeEnable"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Toggle(L.str("label.enabled"), isOn: $draftEnabled)
                        }

                        Section(L.str("section.defaultPermission")) {
                            LabeledContent(L.str("label.newDirectoryPermission")) {
                                Picker("", selection: $draftDefaultPermission) {
                                    ForEach(PermissionLevel.allCases) { permission in
                                        Text(permission.label).tag(permission)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 260)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(20)
            }

            Divider()

            SaveBar(hasChanges: hasChanges, canSave: canSave, revert: load, save: save)
        }
    }
}

private struct LogSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var showInfo = true
    @State private var showWarnings = true
    @State private var showErrors = true
    @State private var autoScroll = true

    private var filteredLogs: [LogEntry] {
        model.logs.filter { entry in
            let levelVisible: Bool
            switch entry.level {
            case .info:
                levelVisible = showInfo
            case .warning:
                levelVisible = showWarnings
            case .error:
                levelVisible = showErrors
            }
            guard levelVisible else { return false }
            return searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L.str("placeholder.searchLogs"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Spacer()

                Toggle("INFO", isOn: $showInfo)
                    .toggleStyle(.checkbox)
                Toggle("WARN", isOn: $showWarnings)
                    .toggleStyle(.checkbox)
                Toggle("ERROR", isOn: $showErrors)
                    .toggleStyle(.checkbox)

                Divider()
                    .frame(height: 16)

                Toggle(L.str("label.autoScroll"), isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button(L.str("action.clear")) {
                    model.clearLogs()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLogs) { entry in
                            HStack(spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)

                                Text(entry.level.rawValue)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 44, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)

                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.logs.count) { _, _ in
                    if autoScroll, let last = filteredLogs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info:
            return .primary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct SidebarList<Content: View>: View {
    let addAction: () -> Void
    let removeAction: () -> Void
    let removeDisabled: Bool
    let content: Content

    init(
        addAction: @escaping () -> Void,
        removeAction: @escaping () -> Void,
        removeDisabled: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.addAction = addAction
        self.removeAction = removeAction
        self.removeDisabled = removeDisabled
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content

            Divider()

            HStack {
                Button(action: addAction) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(L.str("action.add"))

                Button(action: removeAction) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(removeDisabled)
                .help(L.str("action.delete"))

                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }
}

private struct ShareRow: View {
    let share: ShareDirectory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: share.enabled ? "folder.fill" : "folder")
                .foregroundStyle(share.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("/\(share.virtualName)")
                    .font(.body)
                    .lineLimit(1)
                Text(share.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.enabled ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.username)
                    .font(.body)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if !account.hasPassword {
            return L.str("account.passwordNotSet")
        }
        return account.enabled ? L.str("account.enabled") : L.str("account.disabled")
    }
}

private struct SaveBar: View {
    let hasChanges: Bool
    let canSave: Bool
    let revert: () -> Void
    let save: () -> Void

    var body: some View {
        HStack {
            if hasChanges {
                Text(L.str("status.unsavedChanges"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button(L.str("action.revert")) {
                revert()
            }
            .disabled(!hasChanges)

            Button(L.str("action.save")) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!canSave)
        }
        .padding()
    }
}

private struct StatusBadge: View {
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.menuSymbolName)
                .foregroundStyle(statusColor)
            Text(status.displayText)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running:
            return .green
        case .failed:
            return .red
        case .starting, .stopping:
            return .orange
        case .stopped:
            return .secondary
        }
    }
}

private struct EmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension NumberFormatter {
    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }()
}
