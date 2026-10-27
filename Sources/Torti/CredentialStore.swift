import Foundation

/// 账号密码存储。
///
/// 只用一个权限 600 的本地凭据文件，不碰系统钥匙串：
/// 本应用是 ad-hoc 签名，每次重新构建签名都会变，钥匙串里的条目换签名后读不到（会弹系统授权框并卡住主线程），
/// 反而变成"密码存了却读不出来"。600 权限的凭据文件在重建后依然稳定可用。
enum CredentialStore {
    static let service = "cn.fuhao.Torti"

    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private static var directory: URL {
        supportBase.appendingPathComponent("Torti", isDirectory: true)
    }

    private static var fileURL: URL {
        let dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("credentials.json")
    }

    /// 老版本把凭据存在 Application Support/SVNVisualizer/ 下，改名后搬一次。
    /// 只在目标文件不存在时复制，原文件保留（用户可能还想回退到旧版本）。
    private static func migrateLegacyFileIfNeeded() {
        let fm = FileManager.default
        let target = directory.appendingPathComponent("credentials.json")
        let legacy = supportBase
            .appendingPathComponent("SVNVisualizer", isDirectory: true)
            .appendingPathComponent("credentials.json")
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacy.path) else { return }
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? fm.copyItem(at: legacy, to: target)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func read() -> [String: String] {
        migrateLegacyFileIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        if let flat = obj as? [String: String] { return flat }
        // 兼容早期格式 {"host": {"password": "..."}}，避免读不出来时把其它账号一起覆盖掉
        if let nested = obj as? [String: [String: String]] {
            var out: [String: String] = [:]
            for (key, value) in nested {
                if let pwd = value["password"] { out[key] = pwd }
            }
            return out
        }
        return [:]
    }

    private static func write(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    @discardableResult
    static func save(account: String, password: String) -> String? {
        var dict = read()
        dict[account] = password
        write(dict)
        return read()[account] != nil ? "本机凭据文件（权限 600）" : nil
    }

    static func password(for account: String) -> String? {
        read()[account]
    }

    static func delete(account: String) {
        var dict = read()
        dict.removeValue(forKey: account)
        write(dict)
    }

    static func location(of account: String) -> String? {
        read()[account] != nil ? "本机凭据文件（权限 600）" : nil
    }

    static var fileDescription: String {
        "~/Library/Application Support/Torti/credentials.json"
    }
}

/// 一条服务器凭据：按主机名匹配
struct Credential: Identifiable, Hashable, Codable {
    var host: String
    var username: String

    var id: String { host }
}

enum HostResolver {
    /// 从仓库地址里取出主机名（svn://host/path、http(s)://host/...、svn+ssh://user@host/...）
    static func host(of location: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }          // 本地路径 / file://
        var s = trimmed
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.range(of: "@") { s = String(s[at.upperBound...]) }
        if let slash = s.range(of: "/") { s = String(s[..<slash.lowerBound]) }
        if let colon = s.range(of: ":") { s = String(s[..<colon.lowerBound]) }
        return s.isEmpty ? nil : s.lowercased()
    }
}
