import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 右键菜单动作集合（递归行共享，全部由 FileBrowserView 注入）

struct FileActions {
    var update: ([String]) -> Void
    var commit: ([String]) -> Void
    var diff: ([String]) -> Void
    var add: ([String]) -> Void
    var revert: ([String]) -> Void
    var delete: ([String]) -> Void
    var cleanup: (String) -> Void
    var blame: (String) -> Void
    var info: (String) -> Void
    var showLog: (String) -> Void
    var switchRoot: () -> Void
    var reveal: (String) -> Void
    var copy: (String) -> Void
    /// 检出到指定本地目录（远程）
    var checkout: (String) -> Void
    /// 导出到本地目录
    var export: (String) -> Void
    /// 上传本地文件到这里
    var upload: (String) -> Void
    /// 新建子目录
    var mkdir: (String) -> Void
    /// 重命名 / 移动
    var rename: (String) -> Void
    /// 打开文件（本地直接用默认应用；远程先导出只读副本再打开）
    var open: (String) -> Void
    /// 挑选一个应用来打开
    var openWith: (String) -> Void
    /// 远程：把副本导出后在访达里选中
    var revealCopy: (String) -> Void
    /// 远程删除（直接提交）
    var deleteRemote: ([String]) -> Void
    /// 在本地工作副本里打开远程版本库根
    var openRemoteRoot: () -> Void
}

struct CommitRequest: Identifiable {
    let id = UUID()
    let paths: [String]
}

enum PendingAction: Identifiable {
    case revert([String])
    case delete([String])
    case cleanup(String)

    var id: String {
        switch self {
        case .revert(let p): return "revert-" + p.joined(separator: "|")
        case .delete(let p): return "delete-" + p.joined(separator: "|")
        case .cleanup(let p): return "cleanup-" + p
        }
    }

    var title: String {
        switch self {
        case .revert: return "还原本地改动？"
        case .delete: return "从版本库删除？"
        case .cleanup: return "清理工作副本？"
        }
    }

    var message: String {
        switch self {
        case .revert(let paths):
            return "将丢弃这 \(paths.count) 项的本地修改，操作不可撤销：\n" + paths.prefix(10).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        case .delete(let paths):
            return "这 \(paths.count) 项会从版本库标记删除，需再次提交才生效：\n" + paths.prefix(10).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        case .cleanup(let path):
            return "将执行 svn cleanup，清除「\((path as NSString).lastPathComponent)」里中断操作留下的锁。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .revert: return "还原"
        case .delete: return "删除"
        case .cleanup: return "清理"
        }
    }

    var paths: [String] {
        switch self {
        case .revert(let p), .delete(let p): return p
        case .cleanup(let p): return [p]
        }
    }
}

// MARK: - 文件树 + 操作

struct FileBrowserView: View {
    @ObservedObject var model: RepoModel
    /// 右键「查看提交日志」时切到日志页
    var onShowLog: (String) -> Void
    /// 加载失败时跳到设置页配置凭据 / svn 路径
    var onOpenSettings: () -> Void = {}
    /// 检出完成后把本地目录加入左侧目标列表
    var onOpenLocal: (String) -> Void = { _ in }

    @State private var onlyChanged = false
    @State private var filter = ""
    /// 过滤框实际绑定的输入：防抖后才写入 filter，避免每个按键都全树重过滤
    @State private var filterInput = ""
    @State private var filterDebounce: Task<Void, Never>?
    @State private var showConsole = true
    @State private var commitRequest: CommitRequest?
    @State private var showSwitchSheet = false
    @State private var pending: PendingAction?

    @State private var checkoutRequest: CheckoutRequest?
    @State private var exportRequest: ExportRequest?
    @State private var newFolderRequest: NewFolderRequest?
    @State private var renameRequest: RenameRequest?
    @State private var remoteDeleteRequest: RemoteDeleteRequest?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if onlyChanged {
                changedList
            } else {
                tree
            }
            if showConsole {
                Divider()
                ConsolePanel(model: model, store: model.consoleStore)
                    .frame(height: 170)
            }
        }
        .onChange(of: filterInput) { newValue in
            filterDebounce?.cancel()
            guard newValue != filter else { return }
            filterDebounce = Task {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if !Task.isCancelled { filter = newValue }
            }
        }
        .sheet(item: $commitRequest) { request in
            CommitSheet(model: model, paths: request.paths) { paths, message in
                Task { await model.commit(paths: paths, message: message) }
            }
        }
        .sheet(isPresented: $showSwitchSheet) {
            SwitchSheet(current: model.info?.url ?? model.target.location) { url in
                Task { await model.switchTo(url) }
            }
        }
        .sheet(item: $checkoutRequest) { request in
            CheckoutSheet(url: request.url) { dest, revision, depth, openAfter in
                Task {
                    let ok = await model.checkout(url: request.url, to: dest,
                                                  revision: revision, depth: depth)
                    if ok && openAfter { onOpenLocal(dest) }
                }
            }
        }
        .sheet(item: $exportRequest) { request in
            ExportSheet(url: request.url) { dest, revision in
                Task { await model.export(url: request.url, to: dest, revision: revision) }
            }
        }
        .sheet(item: $newFolderRequest) { request in
            NewFolderSheet(parent: request.parent) { name in
                Task { await model.mkdirRemote(parent: request.parent, name: name) }
            }
        }
        .sheet(item: $renameRequest) { request in
            RenameSheet(url: request.url) { name in
                let parent = RepoModel.parent(of: request.url)
                Task { await model.moveRemote(from: request.url, to: RepoModel.joinRemote(parent, name)) }
            }
        }
        .sheet(item: $remoteDeleteRequest) { request in
            RemoteDeleteSheet(paths: request.paths) { message in
                Task {
                    await model.deleteRemote(paths: request.paths, message: message)
                    model.treeSelection = nil
                }
            }
        }
        .confirmationDialog(pending?.title ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { action in
            switch action {
            case .revert(let paths):
                Button("还原", role: .destructive) { Task { await model.revert(paths: paths) } }
            case .delete(let paths):
                Button("删除", role: .destructive) { Task { await model.delete(paths: paths) } }
            case .cleanup(let path):
                Button("清理") { Task { await model.cleanup(path: path) } }
            }
            Button("取消", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: 顶部工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle("仅显示变更", isOn: $onlyChanged)
                .toggleStyle(.switch)
                .controlSize(.small)
            TextField("过滤名称或路径", text: $filterInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, maxWidth: 240)

            Spacer()

            if !model.changedFiles.isEmpty {
                Text("\(model.changedFiles.count) 项变更")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.target.isRemote {
                Label("拖入上传 · 拖出保存", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("把文件拖进目录行即可上传；把文件行拖到访达即可保存副本")
            }

            Button {
                Task { await model.update() }
            } label: {
                Label("更新", systemImage: "arrow.down.to.line")
            }
            .disabled(model.target.isRemote)
            .help("svn update（拉取最新版本）")

            Button {
                commitRequest = CommitRequest(paths: commitCandidate)
            } label: {
                Label("提交…", systemImage: "arrow.up.to.line")
            }
            .disabled(commitCandidate.isEmpty)
            .help("提交选中的变更")

            Button {
                Task { await model.manualRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新读取状态与目录（svn status）")

            // 根目录级别的操作：树里每一行都能右键，但根目录本身没渲染成行
            Menu {
                if model.target.isRemote {
                    Button("检出到…") { checkoutRequest = CheckoutRequest(url: model.rootNode.url) }
                    Button("导出到…") { exportRequest = ExportRequest(url: model.rootNode.url) }
                    Divider()
                    Button("上传文件到这里…") { actions.upload(model.rootNode.url) }
                    Button("新建文件夹…") { newFolderRequest = NewFolderRequest(parent: model.rootNode.url) }
                } else {
                    Button("更新到最新 (update)") { Task { await model.update() } }
                    Button("清理 (cleanup)") { pending = .cleanup(model.rootForCommands) }
                    Button("切换 (switch)…") { showSwitchSheet = true }
                    Divider()
                    Button("上传文件到这里…") { actions.upload(model.rootForCommands) }
                    Button("浏览远程版本库…") { actions.openRemoteRoot() }
                }
                Divider()
                Button("显示 svn info") { Task { await model.infoFor(path: model.rootForCommands) } }
                Button("查看此目录的提交日志") { onShowLog(model.rootForCommands) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("针对整个工作副本的操作")

            Toggle(isOn: $showConsole) {
                Image(systemName: "terminal")
            }
            .toggleStyle(.button)
            .help("显示 / 隐藏命令输出")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 拖进来的文件落到某个目录：远程走 svn import，本地工作副本走复制 + svn add
    private func receiveFiles(_ paths: [String], into directory: String) async {
        if model.target.isRemote {
            await model.upload(localPaths: paths, to: directory)
        } else {
            await model.copyIntoWorkingCopy(files: paths, directory: directory)
        }
    }

    private var commitCandidate: [String] {
        if !model.selectedPaths.isEmpty { return model.selectedPaths.sorted() }
        return model.changedFiles
            .filter { $0.item != .ignored && $0.item != .none }
            .map { $0.path }
            .sorted()
    }

    // MARK: 加载失败

    @ViewBuilder
    private func loadFailureView(_ error: String) -> some View {
        let lines = error.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("无法读取这个位置")
                    .font(.callout.bold())
            }
            Text(lines.prefix(4).joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if model.target.isRemote {
                Text("远程仓库需要登录时：点「配置凭据」在该主机名下填写用户名与密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("重试") {
                    Task {
                        model.lastError = nil
                        await model.reloadChildren(model.rootNode)
                    }
                }
                Button(model.target.isRemote ? "配置凭据…" : "检查 svn 路径…") { onOpenSettings() }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: 树

    @State private var rootDropTargeted = false

    private var tree: some View {
        VStack(spacing: 0) {
            columnHeader
            if model.isBusy {
                // 刷新期间给一条进度条，说明还在读，而不是界面卡住了
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(height: 2)
            } else {
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rootChildren.isEmpty {
                        if let err = model.lastError, !model.isBusy {
                            loadFailureView(err)
                        } else if model.isBusy || model.loadingDirs.contains(model.rootNode.url) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取列表…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                        } else {
                            Text("（空目录）")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    } else {
                        ForEach(flatRows) { row in
                            FileTreeNodeRow(node: row.node, model: model, actions: actions,
                                            filter: filter, depth: row.depth)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 拖到空白处 = 放到当前打开的这个根目录下
            .overlay {
                if rootDropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.06).cornerRadius(6))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $rootDropTargeted) { providers in
                collectDroppedPaths(providers) { paths in
                    guard !paths.isEmpty else { return }
                    Task { await receiveFiles(paths, into: model.rootNode.url) }
                }
                return true
            }
        }
        .onAppear {
            // 调试用：SVNVIS_SHEET=checkout / export / newfolder 自动打开对应弹窗，便于截图验收
            switch ProcessInfo.processInfo.environment["SVNVIS_SHEET"] {
            case "checkout": checkoutRequest = CheckoutRequest(url: model.rootNode.url)
            case "export": exportRequest = ExportRequest(url: model.rootNode.url)
            case "newfolder": newFolderRequest = NewFolderRequest(parent: model.rootNode.url)
            case "open":
                // 等价于「双击第一个文件」：验证 UI 层到打开动作的整条链路
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let file = await firstFileUnderRoot() else { return }
                    model.treeSelection = file.url
                    actions.open(file.url)
                }
            default: break
            }
        }
        .task(id: model.target.id) {
            if model.children[model.rootNode.url] == nil {
                await model.loadChildren(model.rootNode)
            }
            // 兜底：首屏若没读到内容（偶发的空目录），延迟后强制再读一次。
            // 正在读取中就不插手，避免同一次打开跑两遍。
            try? await Task.sleep(nanoseconds: 700_000_000)
            let rootURL = model.rootNode.url
            if (model.children[rootURL] ?? []).isEmpty,
               !model.isBusy,
               !model.loadingDirs.contains(rootURL) {
                await model.reloadChildren(model.rootNode)
            }
        }
    }

    /// 调试用：往下最多找两层，返回第一个文件节点
    private func firstFileUnderRoot() async -> FileNode? {
        var level = model.displayChildren(of: model.rootNode.url)
        for _ in 0..<2 {
            if let f = level.first(where: { !$0.isDir }) { return f }
            var next: [FileNode] = []
            for dir in level.filter({ $0.isDir }).prefix(3) {
                await model.loadChildren(dir)
                next += model.displayChildren(of: dir.url)
            }
            if next.isEmpty { break }
            level = next
        }
        return nil
    }

    private var rootChildren: [FileNode] {
        let kids = model.displayChildren(of: model.rootNode.url)
        guard !filter.isEmpty else { return kids }
        return kids.filter { node in
            node.name.localizedCaseInsensitiveContains(filter) || subtreeMatches(node)
        }
    }

    private func subtreeMatches(_ node: FileNode) -> Bool {
        guard node.isDir else { return false }
        let prefix = node.url + "/"
        if model.statusMap.keys.contains(where: { $0.hasPrefix(prefix) && $0.localizedCaseInsensitiveContains(filter) }) {
            return true
        }
        return (model.children[node.url] ?? []).contains { $0.name.localizedCaseInsensitiveContains(filter) || subtreeMatches($0) }
    }

    /// 某个目录当前应显示的子项（含过滤）
    private func visibleChildren(of node: FileNode) -> [FileNode] {
        let kids = model.displayChildren(of: node.url)
        guard !filter.isEmpty else { return kids }
        return kids.filter { child in
            child.name.localizedCaseInsensitiveContains(filter) || subtreeMatches(child)
        }
    }

    // MARK: 扁平化可见行

    struct FlatNode: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.url }
    }

    /// 把树拍平成一维行列表再交给 LazyVStack。
    /// 旧的「行内递归嵌套子行」写法让 LazyVStack 失效：展开一个大目录时，
    /// 整棵子树是同一行 body 的一部分，会被一次性全部渲染。
    /// 拍平后每行都是 LazyVStack 的直接子项，滚动 / 展开都只渲染可见部分。
    private var flatRows: [FlatNode] {
        var rows: [FlatNode] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(FlatNode(node: node, depth: depth))
                if node.isDir, isExpanded(node) {
                    walk(visibleChildren(of: node), depth: depth + 1)
                }
            }
        }
        walk(rootChildren, depth: 0)
        return rows
    }

    /// 过滤时强制展开所有层级，便于直接看到命中的子项
    private func isExpanded(_ node: FileNode) -> Bool {
        !filter.isEmpty || model.expandedDirs.contains(node.url)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("名称")
                .padding(.leading, 26)
            Spacer(minLength: 16)
            Text("状态")
                .frame(width: 92, alignment: .leading)
            Text("版本")
                .frame(width: 66, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: 仅显示变更

    private var filteredChanged: [SVNStatusEntry] {
        guard !filter.isEmpty else { return model.changedFiles }
        return model.changedFiles.filter {
            $0.path.localizedCaseInsensitiveContains(filter)
        }
    }

    private var changedList: some View {
        Group {
            if filteredChanged.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("没有本地改动")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedPaths) {
                    ForEach(filteredChanged) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.item.symbolName)
                                .foregroundStyle(entry.item.tint)
                            Text(model.relativePath(entry.path))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(entry.item.displayName)
                                .font(.caption)
                                .foregroundStyle(entry.item.tint)
                                .frame(width: 92, alignment: .leading)
                            Text(entry.commitRevision.map { "r\($0)" } ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 66, alignment: .trailing)
                        }
                        .tag(entry.path)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            // 变更列表里只有本地路径，直接交给系统默认应用
                            actions.open(entry.path)
                        })
                        .contextMenu {
                            FileContextMenu(model: model, actions: actions,
                                            paths: menuPaths(for: entry.path),
                                            isDir: false, url: entry.path)
                        }
                    }
                }
            }
        }
    }

    private func menuPaths(for url: String) -> [String] {
        if model.selectedPaths.contains(url), model.selectedPaths.count > 1 {
            return model.selectedPaths.sorted()
        }
        return [url]
    }

    // MARK: 动作注入

    private var actions: FileActions {
        FileActions(
            update: { paths in Task { await model.update(paths: paths) } },
            commit: { paths in commitRequest = CommitRequest(paths: paths) },
            diff: { paths in Task { await model.diff(paths: paths) } },
            add: { paths in Task { await model.add(paths: paths) } },
            revert: { paths in pending = .revert(paths) },
            delete: { paths in pending = .delete(paths) },
            cleanup: { path in pending = .cleanup(path) },
            blame: { path in Task { await model.blame(path: path) } },
            info: { path in Task { await model.infoFor(path: path) } },
            showLog: { path in onShowLog(path) },
            switchRoot: { showSwitchSheet = true },
            reveal: { path in model.revealInFinder(path) },
            copy: { path in NSPasteboard.general.setString(path, forType: .string) },
            checkout: { url in checkoutRequest = CheckoutRequest(url: url) },
            export: { url in exportRequest = ExportRequest(url: url) },
            upload: { url in
                let files = Panel.chooseFiles()
                guard !files.isEmpty else { return }
                Task {
                    if model.target.isRemote {
                        await model.upload(localPaths: files, to: url)
                    } else {
                        await model.copyIntoWorkingCopy(files: files, directory: url)
                    }
                }
            },
            mkdir: { url in newFolderRequest = NewFolderRequest(parent: url) },
            rename: { url in renameRequest = RenameRequest(url: url) },
            open: { url in Task { await model.openFile(url) } },
            openWith: { url in
                guard let app = Panel.chooseApplication() else { return }
                Task { await model.openFile(url, withApplication: app) }
            },
            revealCopy: { url in Task { await model.revealTempCopy(of: url) } },
            deleteRemote: { paths in remoteDeleteRequest = RemoteDeleteRequest(paths: paths) },
            openRemoteRoot: {
                let root = model.info?.repositoryRoot ?? model.info?.url ?? model.target.location
                onOpenRemote(root)
            }
        )
    }

    /// 在工作副本里直接打开远程版本库（TortoiseSVN 的 Repo-browser 入口）
    private func onOpenRemote(_ url: String) {
        NotificationCenter.default.post(name: .openRemoteURL, object: url)
    }
}

extension Notification.Name {
    static let openRemoteURL = Notification.Name("cn.fuhao.Torti.openRemoteURL")
}

// MARK: - 右键菜单

struct FileContextMenu: View {
    @ObservedObject var model: RepoModel
    let actions: FileActions
    let paths: [String]
    let isDir: Bool
    let url: String

    private var primary: String { paths.first ?? url }
    private var local: Bool { !model.target.isRemote }
    private var allVersioned: Bool { paths.allSatisfy { model.isVersioned($0) } }
    private var hasUnversioned: Bool { paths.contains { !model.isVersioned($0) } }
    private var hasChanges: Bool {
        paths.contains { p in
            guard let e = model.statusMap[p] else { return false }
            return e.item.isChanged
        }
    }

    var body: some View {
        // 文件：双击即可打开，这里给「打开方式…」之类的补充入口
        if !isDir {
            let onDisk = FileManager.default.fileExists(atPath: url)
            Button(local ? "打开" : "打开（版本库副本）") { actions.open(url) }
                .disabled(local && !onDisk)
            Button("打开方式…") { actions.openWith(url) }
                .disabled(local && !onDisk)
            if !local {
                Button("在访达中显示副本") { actions.revealCopy(url) }
            }
            Divider()
        }
        if local {
            Button("更新") { actions.update(paths) }
            Button("提交…") { actions.commit(paths) }
                .disabled(!allVersioned || !hasChanges)
            Divider()
            Button("查看差异") { actions.diff(paths) }
                .disabled(!allVersioned)
            Button("添加至版本控制") { actions.add(paths) }
                .disabled(!hasUnversioned)
            Button("还原…") { actions.revert(paths) }
                .disabled(!hasChanges)
            Button("删除…") { actions.delete(paths) }
                .disabled(!allVersioned)
            Divider()
            // 本地工作副本：拿它在版本库里的 URL 再检出一份干净的
            Button("再检出一份到…") { actions.checkout(model.info?.url ?? url) }
        } else {
            Button("检出到…") { actions.checkout(url) }
            Button("导出到…") { actions.export(url) }
            Divider()
            if isDir {
                Button("上传文件到这里…") { actions.upload(url) }
                Button("新建文件夹…") { actions.mkdir(url) }
            }
            Button("重命名…") { actions.rename(url) }
            Button("删除…") { actions.deleteRemote(paths) }
        }

        Divider()
        if !isDir {
            Button("追溯 (blame)") { actions.blame(primary) }
        }
        Button("查看提交日志") { actions.showLog(primary) }
        Button("显示 svn info") { actions.info(primary) }

        Divider()
        if local {
            if isDir {
                Button("上传文件到这里…") { actions.upload(url) }
                Button("切换 (switch)…") { actions.switchRoot() }
            }
            Button("清理 (cleanup)") {
                actions.cleanup(isDir ? url : (url as NSString).deletingLastPathComponent)
            }
            Button("浏览远程版本库…") { actions.openRemoteRoot() }
                .disabled(model.info?.repositoryRoot == nil && model.info?.url == nil)
            Divider()
            Button("在访达中显示") { actions.reveal(url) }
        } else {
            Button("复制 URL") { actions.copy(url) }
        }
    }
}

// MARK: - 目录树行（扁平化：由 FileBrowserView 决定渲染哪些行，这里不再递归）

struct FileTreeNodeRow: View {
    let node: FileNode
    @ObservedObject var model: RepoModel
    let actions: FileActions
    let filter: String
    let depth: Int

    @State private var isDropTargeted = false
    @State private var isHovered = false

    /// 过滤时强制展开，便于直接看到命中的子项
    private var expanded: Bool { !filter.isEmpty || model.expandedDirs.contains(node.url) }

    var body: some View {
        interactiveRow
            .onAppear {
                // 展开的目录滚进可视区时才补读子目录（远程 list / 本地枚举都发生在这一刻）
                if node.isDir, expanded, model.children[node.url] == nil {
                    Task { await model.loadChildren(node) }
                }
            }
    }

    /// 目录：接收从访达拖进来的文件；文件：可以被拖出去
    @ViewBuilder
    private var interactiveRow: some View {
        if node.isDir {
            row
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.10).cornerRadius(5))
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    collectDroppedPaths(providers) { paths in
                        guard !paths.isEmpty else { return }
                        Task {
                            if model.target.isRemote {
                                await model.upload(localPaths: paths, to: node.url)
                            } else {
                                await model.copyIntoWorkingCopy(files: paths, directory: node.url)
                            }
                        }
                    }
                    return true
                }
        } else {
            row
                .itemProvider { model.dragItem(for: node.url) }
        }
    }

    private var effectivePaths: [String] {
        if model.selectedPaths.contains(node.url), model.selectedPaths.count > 1 {
            return model.selectedPaths.sorted()
        }
        return [node.url]
    }

    private var row: some View {
        let st = model.status(for: node)
        let entry = model.statusMap[node.url]
        let selected = model.treeSelection == node.url

        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                chevron
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(node.isDir ? Color.accentColor : Color.secondary)
                    .frame(width: 15)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(st == .deleted || st == .missing, color: .red)
                if st != .normal {
                    StatusBadge(status: st)
                }
            }
            Spacer(minLength: 16)
            if inSync(st) {
                // 本地工作副本里没有改动、且已纳入版本控制 = 和版本库一致
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.green.opacity(0.9))
                    Text("一致")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .frame(width: 92, alignment: .leading)
                .help("本地与版本库基准版本一致，没有待提交的改动")
            } else {
                Text(statusText(st))
                    .font(.caption)
                    .foregroundStyle(st == .normal ? Color.secondary.opacity(0.55) : st.tint)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
            Text((entry?.commitRevision ?? node.revision).map { "r\($0)" } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        // Finder 风格的圆角选中 + 轻悬停反馈；悬停态行本地持有，不进模型
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.18)
                      : isHovered ? Color.primary.opacity(0.045)
                      : Color.clear)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // 单击选中 / 双击打开：单击放在 simultaneous 里保证即时响应，
        // 双击是主手势，这样不会被单击抢走（双击时会先选中，无副作用）。
        .simultaneousGesture(TapGesture(count: 1).onEnded { model.treeSelection = node.url })
        .gesture(TapGesture(count: 2).onEnded { handleDoubleClick() })
        .help(doubleClickHint)
        .contextMenu {
            FileContextMenu(model: model, actions: actions, paths: effectivePaths,
                            isDir: node.isDir, url: node.url)
        }
    }

    private func handleDoubleClick() {
        if node.isDir {
            // 过滤模式下树是强制展开的，双击不参与展开/折叠
            guard filter.isEmpty else { return }
            toggleExpanded()
        } else {
            actions.open(node.url)
        }
    }

    private func toggleExpanded() {
        let willExpand = !model.expandedDirs.contains(node.url)
        withAnimation(.easeOut(duration: 0.16)) {
            model.toggleExpanded(node.url)
        }
        if willExpand { Task { await model.loadChildren(node) } }
    }

    private var doubleClickHint: String {
        if node.isDir { return "双击展开 / 折叠" }
        return model.target.isRemote ? "双击打开只读副本" : "双击打开"
    }

    /// 本地工作副本里「已纳入版本控制 + 没有任何待提交改动」的项：状态列显示 ✅。
    /// 远程模式不显示（版本库里的东西本来就没有本地副本可比）。
    private func inSync(_ st: SVNItemStatus) -> Bool {
        guard !model.target.isRemote, st == .normal else { return false }
        guard let entry = model.statusMap[node.url] else { return false }
        return entry.item == .normal
    }

    private func statusText(_ st: SVNItemStatus) -> String {
        if st == .normal { return "" }
        guard node.isDir else { return st.displayName }
        // 目录自身有状态（未纳管 / 已添加 / 已删除…）时直说，纯聚合才写「含改动」
        if let own = model.statusMap[node.url], own.item.isChanged {
            return own.item.displayName
        }
        return "含改动"
    }

    @ViewBuilder private var chevron: some View {
        if node.isDir {
            if model.loadingDirs.contains(node.url) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard filter.isEmpty else { return }
                        toggleExpanded()
                    }
            }
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private var iconName: String {
        if node.isDir { return expanded ? "folder.fill" : "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "swift", "m", "mm", "h", "c", "cpp", "hpp", "java", "kt": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        case "sh", "zsh", "bash", "py", "rb", "plist", "conf": return "terminal"
        case "md", "txt", "log": return "doc.plaintext"
        case "json", "xml", "yml", "yaml": return "curlybraces"
        default: return "doc"
        }
    }
}

struct StatusBadge: View {
    let status: SVNItemStatus

    var body: some View {
        if status != .normal {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tint)
                .font(.system(size: 11))
                .help(status.displayName)
        }
    }
}
