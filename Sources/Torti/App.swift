import SwiftUI

@main
struct TortiApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // 最小宽度 = 固定 236 的侧边栏 + 详情区（文件树三条列 + 工具条）能正常显示的下限
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 580, height: 660)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var targets: [RepoTarget] = []
    @Published var selectedTargetId: UUID?
    @Published var svnPath: String
    @Published var credentials: [Credential] = []
    /// 没有为某台服务器单独配置凭据时使用的默认账号
    @Published var defaultUsername: String
    @Published var defaultPassword: String
    @Published var rememberDefaultPassword: Bool
    /// 仅本次会话有效的临时密码（不落盘）
    @Published var sessionPassword: String = ""

    private var models: [UUID: RepoModel] = [:]

    private enum Keys {
        static let svnPath = "svnPath"
        static let targets = "targets"
        static let credentials = "credentials"
        static let defaultUsername = "defaultUsername"
        static let rememberPassword = "rememberDefaultPassword"
    }

    private static let defaultAccountKey = "__default__"

    init() {
        // 必须在读任何设置之前跑：应用曾叫「SVN可视化」，Bundle ID 换成了 cn.fuhao.Torti，
        // 不迁移的话目标列表 / 账号设置会全部“消失”。
        SettingsMigrator.migrateIfNeeded()
        let defaults = UserDefaults.standard
        let detectedPath = AppState.detectSVNPath()
        let savedPath = defaults.string(forKey: Keys.svnPath) ?? ""
        // 保存的路径不可执行时（例如误把仓库地址填进来）自动回退，避免整个应用失灵
        if !savedPath.isEmpty, FileManager.default.isExecutableFile(atPath: savedPath) {
            self.svnPath = savedPath
        } else {
            self.svnPath = detectedPath
            defaults.set(detectedPath, forKey: Keys.svnPath)
        }
        // 兼容旧版本保存的 username 键
        let legacyUser = defaults.string(forKey: "username") ?? ""
        self.defaultUsername = defaults.string(forKey: Keys.defaultUsername) ?? legacyUser
        self.rememberDefaultPassword = defaults.bool(forKey: Keys.rememberPassword)

        let raw = defaults.data(forKey: Keys.targets) ?? defaults.string(forKey: Keys.targets)?.data(using: .utf8)
        if let data = raw, let list = try? JSONDecoder().decode([RepoTarget].self, from: data) {
            self.targets = list
            self.selectedTargetId = list.first?.id
        }
        let credRaw = defaults.data(forKey: Keys.credentials) ?? defaults.string(forKey: Keys.credentials)?.data(using: .utf8)
        if let data = credRaw, let list = try? JSONDecoder().decode([Credential].self, from: data) {
            self.credentials = list
        }

        // 记住过的默认密码，从本机凭据文件读回
        let remembered = defaults.bool(forKey: Keys.rememberPassword)
        self.defaultPassword = remembered ? (CredentialStore.password(for: Self.defaultAccountKey) ?? "") : ""
    }

    static func detectSVNPath() -> String {
        let candidates = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/opt/local/bin/svn", "/usr/bin/svn"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/opt/homebrew/bin/svn"
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(svnPath, forKey: Keys.svnPath)
        defaults.set(defaultUsername, forKey: Keys.defaultUsername)
        defaults.set(rememberDefaultPassword, forKey: Keys.rememberPassword)
        if let data = try? JSONEncoder().encode(targets) {
            defaults.set(data, forKey: Keys.targets)
        }
        if let data = try? JSONEncoder().encode(credentials) {
            defaults.set(data, forKey: Keys.credentials)
        }
    }

    // MARK: 凭据

    /// 默认密码保存位置说明（已保存 / 未保存）
    var defaultPasswordStorage: String? {
        CredentialStore.location(of: Self.defaultAccountKey)
    }

    func saveDefaultPassword() {
        guard rememberDefaultPassword, !defaultPassword.isEmpty else {
            CredentialStore.delete(account: Self.defaultAccountKey)
            return
        }
        CredentialStore.save(account: Self.defaultAccountKey, password: defaultPassword)
    }

    func credential(for location: String) -> (username: String?, password: String?, source: String) {
        if let host = HostResolver.host(of: location),
           let cred = credentials.first(where: { $0.host == host }),
           !cred.username.isEmpty {
            let pass = CredentialStore.password(for: cred.host) ?? sessionPassword
            return (cred.username, pass.isEmpty ? nil : pass, "服务器 \(host)")
        }
        let user = defaultUsername.isEmpty ? nil : defaultUsername
        let pass = defaultPassword.isEmpty ? sessionPassword : defaultPassword
        return (user, pass.isEmpty ? nil : pass, "默认账号")
    }

    func upsertCredential(host: String, username: String, password: String, remember: Bool) {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        credentials.removeAll { $0.host == key }
        credentials.append(Credential(host: key, username: username))
        if remember && !password.isEmpty {
            CredentialStore.save(account: key, password: password)
        } else {
            CredentialStore.delete(account: key)
        }
        persist()
    }

    func removeCredential(_ credential: Credential) {
        credentials.removeAll { $0.host == credential.host }
        CredentialStore.delete(account: credential.host)
        persist()
    }

    func passwordStorage(for credential: Credential) -> String? {
        CredentialStore.location(of: credential.host)
    }

    // MARK: 执行器

    func makeExecutor(for location: String) -> SVNExecutor {
        let cred = credential(for: location)
        return SVNExecutor(executablePath: svnPath, username: cred.username, password: cred.password)
    }

    var currentModel: RepoModel? {
        guard let id = selectedTargetId, targets.contains(where: { $0.id == id }) else { return nil }
        return model(for: id)
    }

    func model(for id: UUID) -> RepoModel {
        if let m = models[id] { return m }
        guard let target = targets.first(where: { $0.id == id }) else {
            fatalError("target not found")
        }
        let m = RepoModel(target: target) { [weak self] location in
            guard let self else {
                return SVNExecutor(executablePath: "/usr/bin/svn", username: nil, password: nil)
            }
            return self.makeExecutor(for: location)
        }
        models[id] = m
        return m
    }

    func addTarget(location: String, isRemote: Bool) {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if targets.contains(where: { $0.location == trimmed }) {
            selectedTargetId = targets.first(where: { $0.location == trimmed })?.id
            return
        }
        let target = RepoTarget(location: trimmed, isRemote: isRemote)
        targets.append(target)
        selectedTargetId = target.id
        persist()
        let m = model(for: target.id)
        Task { await m.refreshAll() }
    }

    /// 打开仓库 URL 时顺带保存凭据
    func addTarget(location: String, username: String, password: String, remember: Bool) {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let host = HostResolver.host(of: trimmed), !username.isEmpty {
            upsertCredential(host: host, username: username, password: password, remember: remember)
            if !remember { sessionPassword = password }
        } else if !username.isEmpty {
            defaultUsername = username
            defaultPassword = password          // 不记住时也留在内存里，本次会话可用
            rememberDefaultPassword = remember && !password.isEmpty
            saveDefaultPassword()
            persist()
        }
        addTarget(location: trimmed, isRemote: true)
    }

    func removeTarget(_ id: UUID) {
        targets.removeAll { $0.id == id }
        models.removeValue(forKey: id)
        if selectedTargetId == id { selectedTargetId = targets.first?.id }
        persist()
    }
}

// MARK: - 旧版设置迁移

/// 应用原来叫「SVN可视化」，Bundle ID 是 cn.fuhao.SVNVisualizer。
/// UserDefaults 是按 Bundle ID 分域的，改名后新域里一片空白 —— 目标列表、svn 路径、
/// 默认账号都会“丢掉”。这里在首次启动时把旧域整份搬过来，只补空位、不覆盖新值。
enum SettingsMigrator {
    static let newDomain = "cn.fuhao.Torti"
    private static let legacyDomain = "cn.fuhao.SVNVisualizer"
    private static let flagKey = "didMigrateFromLegacyDomain"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let legacy = defaults.persistentDomain(forName: legacyDomain)
            ?? UserDefaults(suiteName: legacyDomain)?.persistentDomain(forName: legacyDomain)
            ?? [:]

        if !legacy.isEmpty {
            var merged = defaults.persistentDomain(forName: newDomain) ?? [:]
            for (key, value) in legacy {
                // NS*/AK* 是系统与登录项自己写的键，不要跟着搬
                guard !key.hasPrefix("NS"), !key.hasPrefix("AK") else { continue }
                if merged[key] == nil { merged[key] = value }
            }
            defaults.setPersistentDomain(merged, forName: newDomain)
        }

        // setPersistentDomain 会整域替换，标记必须在它之后写
        defaults.set(true, forKey: flagKey)
    }
}
