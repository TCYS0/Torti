import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("mainTab") private var mainTabRaw: String = MainTab.files.rawValue
    @State private var selection: UUID?
    @State private var showURLSheet = false
    @State private var showSettings = false
    /// 侧边栏展开状态。自己管，不走 NavigationSplitView —— 系统的分栏在窗口接近最小宽度时
    /// 会把侧边栏压成一条缝、内容从左边溢出，而且展开后自带的开关按钮还会跑位。
    @AppStorage("showSidebar") private var showSidebar = true

    private var tab: MainTab { MainTab(rawValue: mainTabRaw) ?? .files }

    private var tabBinding: Binding<MainTab> {
        Binding(get: { tab }, set: { mainTabRaw = $0.rawValue })
    }

    private let sidebarWidth: CGFloat = 236

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(tab: tabBinding)
                    .environmentObject(app)
                    .frame(width: sidebarWidth)
                    .background(SidebarBackground())
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1)
                            .ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading))
            }

            detailPane
                // minWidth: 0 很关键：允许详情区被压到任意宽度（超出的部分裁掉），
                // 否则它会把整个窗口撑宽、把侧边栏挤出可视区。
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(app.currentModel?.target.name ?? "Torti")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() }
                } label: {
                    Label(showSidebar ? "隐藏侧边栏" : "显示侧边栏",
                          systemImage: "sidebar.leading")
                }
                .help(showSidebar ? "隐藏侧边栏（⌃⌘S）" : "显示侧边栏（⌃⌘S）")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await app.currentModel?.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(app.currentModel == nil)

                Menu {
                    Button("打开本地工作副本…") { openLocal() }
                    Button("打开仓库 URL…") { showURLSheet = true }
                } label: {
                    Label("打开", systemImage: "folder.badge.plus")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("svn 路径、账号密码凭据、连通性测试")
            }
        }
        .sheet(isPresented: $showURLSheet) {
            URLSheet { url, user, pass, remember in
                app.addTarget(location: url, username: user, password: pass, remember: remember)
            }
        }
        .sheet(isPresented: $showSettings) {
            // 高度要留得比主窗口小，否则底部「完成」按钮会被窗口下沿裁掉
            SettingsView(showsDoneButton: true)
                .environmentObject(app)
                .frame(width: 580, height: 620)
        }
        .onAppear {
            // 调试用：SVNVIS_SETTINGS=1 启动时自动打开设置窗口
            if ProcessInfo.processInfo.environment["SVNVIS_SETTINGS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showSettings = true
                }
            }
            // 调试用：SVNVIS_WIN=980x620（或 defaults 写 debugWindowSize）启动后把内容区设成该尺寸
            let winSpec = ProcessInfo.processInfo.environment["SVNVIS_WIN"]
                ?? UserDefaults.standard.string(forKey: "debugWindowSize")
            if let spec = winSpec {
                let parts = spec.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.windows.first?.setContentSize(NSSize(width: parts[0], height: parts[1]))
                    }
                }
            }
            // 调试用：defaults 写 debugOpenLocal=<工作副本路径>，启动后直接打开它（截图验收用）
            if let path = UserDefaults.standard.string(forKey: "debugOpenLocal"), !path.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    app.addTarget(location: path, isRemote: false)
                }
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let model = app.currentModel {
                HeaderBar(model: model)
                Divider()
                Group {
                    switch tab {
                    case .files:
                        FileBrowserView(model: model, onShowLog: { path in
                            mainTabRaw = MainTab.log.rawValue
                            Task { await model.loadLog(for: path) }
                        }, onOpenSettings: { showSettings = true },
                        onOpenLocal: { app.addTarget(location: $0, isRemote: false) })
                        .onReceive(NotificationCenter.default.publisher(for: .openRemoteURL)) { note in
                            if let url = note.object as? String { app.addTarget(location: url, isRemote: true) }
                        }
                    case .log: LogView(model: model)
                    case .graph: RevisionGraphView(model: model)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .task(id: model.target.id) {
                    // 每个 target 切换只刷新一次（以前这里 + addTarget + onChange
                    // 三处同时触发，info/status/log 会并发跑两三遍）。
                    // 新目标走全套 refreshAll；切回已加载过的目标走轻量 manualRefresh。
                    if model.info == nil && model.changedFiles.isEmpty {
                        await model.refreshAll()
                    } else {
                        await model.manualRefresh()
                    }
                }
            } else {
                EmptyStateView(onOpenLocal: openLocal, onOpenURL: { showURLSheet = true })
            }
        }
    }

    private func openLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作副本"
        if panel.runModal() == .OK, let url = panel.url {
            app.addTarget(location: url.path, isRemote: false)
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.target.isRemote ? "globe" : "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.target.name)
                    .font(.headline)
                Text(model.target.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let info = model.info {
                HStack(spacing: 14) {
                    if let rev = info.revision { InfoChip(title: "版本", value: "r\(rev)") }
                    if let root = info.repositoryRoot { InfoChip(title: "版本库", value: root, isPath: true) }
                    if let author = info.lastChangedAuthor { InfoChip(title: "最后提交", value: author) }
                }
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            if let err = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(err)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct InfoChip: View {
    let title: String
    let value: String
    var isPath = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(isPath ? .middle : .tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// 侧边栏底色：用系统 sidebar 材质，深色/浅色模式下都和原生侧边栏一致
struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @Binding var tab: MainTab

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { app.selectedTargetId }, set: { app.selectedTargetId = $0 })) {
                Section("工作副本 / 仓库") {
                    ForEach(app.targets) { target in
                        HStack(spacing: 6) {
                            Image(systemName: target.isRemote ? "globe" : "folder.fill")
                                .foregroundStyle(target.isRemote ? .blue : .orange)
                            Text(target.name)
                                .lineLimit(1)
                            Spacer()
                            if let m = app.currentModel, m.target.id == target.id, !m.changedFiles.isEmpty {
                                Text("\(m.changedFiles.count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.red)
                            }
                        }
                        .tag(target.id as UUID?)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 120)

            Divider()

            List(selection: $tab) {
                Section("视图") {
                    ForEach(MainTab.allCases) { t in
                        Label(t.rawValue, systemImage: t.symbolName).tag(t)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 160)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.prompt = "选择工作副本"
                    if panel.runModal() == .OK, let url = panel.url {
                        app.addTarget(location: url.path, isRemote: false)
                    }
                } label: { Label("添加", systemImage: "plus") }
                .buttonStyle(.borderless)
                Button {
                    if let id = app.selectedTargetId { app.removeTarget(id) }
                } label: { Label("移除", systemImage: "minus") }
                .buttonStyle(.borderless)
                .disabled(app.selectedTargetId == nil)
                Spacer()
            }
            .padding(8)
        }
    }
}

struct EmptyStateView: View {
    let onOpenLocal: () -> Void
    let onOpenURL: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                Text("Torti")
                    .font(.largeTitle.bold())
                Text("macOS 上的 Subversion 客户端")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("选择本地工作副本或仓库 URL，开始浏览文件状态、提交日志与版本树。")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("打开本地工作副本…", action: onOpenLocal).buttonStyle(.borderedProminent)
                Button("打开仓库 URL…", action: onOpenURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct URLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    let onSubmit: (String, String, String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("打开 SVN 仓库 URL")
                .font(.headline)
            TextField("https://svn.example.com/svn/repo/trunk", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            Divider()
            Text("账号（可选）")
                .font(.subheadline.bold())
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle("记住密码（存本机凭据文件，权限 600）", isOn: $remember)
            Text("不填则使用 svn 已缓存的凭据；填了就按该服务器的主机名保存，下次自动带上。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("打开") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines),
                 username.trimmingCharacters(in: .whitespacesAndNewlines),
                 password,
                 remember && !username.isEmpty)
        dismiss()
    }
}
