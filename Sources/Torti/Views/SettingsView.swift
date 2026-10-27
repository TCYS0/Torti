import SwiftUI
import AppKit

struct SettingsView: View {
    /// 作为 sheet 弹出时需要自带的关闭入口（独立「设置」窗口有交通灯，不用显示）
    var showsDoneButton = false

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var detected = AppState.detectSVNPath()
    @State private var showCredentialSheet = false
    @State private var revealPassword = false
    @State private var testURL = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                svnSection
                credentialSection
                defaultAccountSection
                testSection
            }
            .formStyle(.grouped)
            .padding()

            if showsDoneButton {
                Divider()
                HStack(spacing: 10) {
                    Text("改动即时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            CredentialSheet(defaultHost: suggestedHost) { host, user, pass, remember in
                app.upsertCredential(host: host, username: user, password: pass, remember: remember)
            }
        }
        .onAppear {
            if testURL.isEmpty { testURL = app.currentModel?.target.location ?? "" }
        }
    }

    // MARK: SVN 命令行

    private var svnSection: some View {
        Section {
            HStack {
                TextField("svn 可执行文件路径", text: $app.svnPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: app.svnPath) { _ in app.persist() }
                Button("浏览…") { chooseSVN() }
                Button("自动检测") { app.svnPath = detected; app.persist() }
            }
            if app.svnPath.contains("://") || app.svnPath.hasPrefix("svn") && !app.svnPath.contains("/") {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("这里要填 svn **程序**的路径（如 /opt/homebrew/bin/svn），不是仓库地址。")
                            .font(.caption)
                        Text("仓库地址请用工具栏「打开 › 打开仓库 URL…」填写。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("改回 \(detected)") { app.svnPath = detected; app.persist() }
                            .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Image(systemName: FileManager.default.isExecutableFile(atPath: app.svnPath) ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(FileManager.default.isExecutableFile(atPath: app.svnPath) ? Color.green : Color.red)
                    Text(FileManager.default.isExecutableFile(atPath: app.svnPath) ? "svn 可用（检测到：\(detected)）" : "路径无效，命令将执行失败")
                        .font(.caption)
                }
            }
        } header: {
            Text("SVN 命令行")
        }
    }

    // MARK: 服务器凭据

    private var suggestedHost: String {
        if let loc = app.currentModel?.target.location, let host = HostResolver.host(of: loc) { return host }
        return ""
    }

    private var credentialSection: some View {
        Section {
            if app.credentials.isEmpty {
                Text("还没有为任何服务器保存账号。远程 svn/http(s) 仓库需要账号密码时，在这里按主机名保存，连接时会自动匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.credentials) { cred in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill.badge.checkmark")
                            .foregroundStyle(.blue)
                        Text(cred.host)
                            .font(.system(.body, design: .monospaced))
                        Text(cred.username)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(app.passwordStorage(for: cred) ?? "密码未保存")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            app.removeCredential(cred)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("添加服务器账号…") { showCredentialSheet = true }
                Spacer()
                Text("主机名形如 svn.example.com（不含协议与端口）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("服务器凭据（按主机名匹配）")
        }
    }

    // MARK: 默认账号

    private var defaultAccountSection: some View {
        Section {
            TextField("用户名", text: $app.defaultUsername)
                .textFieldStyle(.roundedBorder)
                .onChange(of: app.defaultUsername) { _ in app.persist() }
            HStack {
                Group {
                    if revealPassword {
                        TextField("密码", text: $app.defaultPassword)
                    } else {
                        SecureField("密码", text: $app.defaultPassword)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onChange(of: app.defaultPassword) { _ in
                    if app.rememberDefaultPassword { app.saveDefaultPassword() }
                }
                Button(action: { revealPassword.toggle() }) {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword ? "隐藏密码" : "显示密码")
            }
            Toggle("记住密码", isOn: $app.rememberDefaultPassword)
                .onChange(of: app.rememberDefaultPassword) { newValue in
                    app.persist()
                    if newValue {
                        app.saveDefaultPassword()
                    } else {
                        CredentialStore.delete(account: "__default__")
                        app.defaultPassword = ""
                    }
                }
            HStack(spacing: 6) {
                Image(systemName: app.defaultPasswordStorage == nil ? "questionmark.circle" : "lock.fill")
                    .foregroundStyle(app.defaultPasswordStorage == nil ? Color.secondary : Color.green)
                Text(app.defaultPasswordStorage == nil
                     ? "密码未保存（关闭应用后需要重新输入）"
                     : "密码已保存到\(app.defaultPasswordStorage ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("默认账号（未单独配置的服务器都用它）")
        } footer: {
            Text("命令会以 --username/--password --no-auth-cache 传给 svn；留空则使用 svn 自己缓存的凭据。")
        }
    }

    // MARK: 测试连接

    private var testSection: some View {
        Section {
            HStack {
                TextField("仓库路径或 URL", text: $testURL)
                    .textFieldStyle(.roundedBorder)
                Button("用当前选中") { testURL = app.currentModel?.target.location ?? "" }
                    .disabled(app.currentModel == nil)
                Button("测试连接") { runTest() }
                    .disabled(testURL.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if !testResult.isEmpty {
                ScrollView {
                    Text(testResult)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } header: {
            Text("连通性测试")
        }
    }

    private func runTest() {
        testing = true
        testResult = "正在测试…"
        Task {
            let location = testURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let executor = app.makeExecutor(for: location)
            do {
                let result = try await executor.run(["info", "--xml", location])
                if let info = try? SVNXMLParser.parseInfo(xml: Data(result.output.utf8)) {
                    var text = "连接成功：\(info.url ?? location)"
                    if let rev = info.revision { text += "\n最新版本：r\(rev)" }
                    if let root = info.repositoryRoot { text += "\n版本库根：\(root)" }
                    if let uuid = info.repositoryUUID { text += "\nUUID：\(uuid)" }
                    testResult = text
                } else {
                    testResult = "连接成功，但解析不到版本库信息。\n\(result.output.prefix(400))"
                }
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func chooseSVN() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            app.svnPath = url.path
            app.persist()
        }
    }
}

struct CredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    let defaultHost: String
    let onSubmit: (String, String, String, Bool) -> Void

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("服务器账号")
                .font(.headline)
            TextField("主机名，例如 svn.example.com", text: $host)
                .textFieldStyle(.roundedBorder)
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle("保存密码到本机凭据文件（权限 600）", isOn: $remember)
            Text("主机名不含 svn:// 与端口；svn+ssh 的地址会自动去掉 user@ 部分。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSubmit(host, username, password, remember)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if host.isEmpty { host = defaultHost }
        }
    }
}
