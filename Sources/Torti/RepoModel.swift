import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 独立的控制台输出缓冲：与 RepoModel 解耦后，追加日志不会触发
/// 文件树 / 日志页等大范围重渲染；超出上限丢弃最旧内容，防止长会话撑爆 Text。
@MainActor
final class ConsoleStore: ObservableObject {
    @Published private(set) var text = ""
    private static let capacity = 120_000

    func append(_ line: String) {
        text += line
        if text.count > Self.capacity {
            text = String(text.suffix(Self.capacity * 3 / 4))
        }
    }

    func clear() { text = "" }
}

/// 极简异步信号量：限制并发目录读取数（展开很快时不给每个目录都起进程）。
actor LoadGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

@MainActor
final class RepoModel: ObservableObject {
    let target: RepoTarget
    private let executorFactory: (String) -> SVNExecutor

    @Published var rootNode: FileNode
    @Published var children: [String: [FileNode]] = [:] {
        didSet { invalidateDisplayCache() }
    }
    @Published var statusMap: [String: SVNStatusEntry] = [:] {
        didSet { rebuildDirStatusCache() }
    }
    @Published var changedFiles: [SVNStatusEntry] = []
    @Published var info: SVNInfo?
    @Published var logs: [LogEntry] = []
    @Published var graph = RevisionGraph()
    @Published var isBusy = false
    /// 正在读取子项的目录（行上显示小转圈；同时防止重复点击触发同一目录的并发读取）
    @Published var loadingDirs: Set<String> = []
    /// 命令输出独立成 ObservableObject：追加日志只刷新底部控制台，
    /// 不再让整棵文件树 / 日志页跟着重渲染（原来每打一行日志全界面重算一遍）。
    let consoleStore = ConsoleStore()
    @Published var lastError: String?
    /// 目录 → 子树内最严重状态的缓存：statusMap 变化时一次算好，
    /// 文件树渲染每行 O(1) 查表，不再对整张 statusMap 做前缀扫描。
    @Published private(set) var dirStatusCache: [String: SVNItemStatus] = [:]
    /// 文件树里已展开的目录（存模型里：刷新 / 切页签后展开状态不丢）
    @Published var expandedDirs: Set<String> = []
    @Published var logLimit: Int = 200
    @Published var graphLimit: Int = 400
    @Published var selectedPaths: Set<String> = []
    @Published var treeSelection: String?
    @Published var logScope: String?
    @Published var statusMessage: String = ""

    init(target: RepoTarget, executorFactory: @escaping (String) -> SVNExecutor) {
        self.target = target
        self.executorFactory = executorFactory
        self.rootNode = FileNode(url: target.location, name: target.name, isDir: true)
    }

    private var activeExecutor: SVNExecutor?

    /// 认证要按「版本库地址」匹配主机名。
    /// 本地工作副本的 target.location 是磁盘路径，取不到 host，就会被当成没有凭据
    /// （表现就是 update/commit 直接 E170001，即使设置里明明配了该服务器）。
    private var credentialLocation: String {
        if target.isRemote { return target.location }
        if let root = info?.repositoryRoot, !root.isEmpty { return root }
        if let url = info?.url, !url.isEmpty { return url }
        return target.location
    }

    private var executor: SVNExecutor {
        let e = executorFactory(credentialLocation)
        activeExecutor = e
        return e
    }

    /// 本地工作副本在跑需认证的命令前，先补一次 info 拿到版本库地址
    /// （`svn info` 读的是 .svn/wc.db，不需要认证，所以这一步是安全的）。
    private func ensureCredentialContext() async {
        guard !target.isRemote, info == nil else { return }
        try? await loadInfo()
    }

    func stop() {
        activeExecutor?.cancel()
        logToConsole("⏹ 已请求停止当前命令")
    }

    /// 命令的工作目录 / 路径基准：始终是「当前打开的这个目录」，
    /// 这样 svn status 返回的相对路径与文件树的节点路径才对得上。
    var rootForCommands: String {
        target.location
    }

    var graphSource: String {
        info?.repositoryRoot ?? target.location
    }

    /// 把绝对路径缩写为相对当前根的路径
    func relativePath(_ path: String) -> String {
        let root = rootForCommands
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    // MARK: - 控制台

    func logToConsole(_ text: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        consoleStore.append("[\(ts)] \(text)\n")
    }

    func clearConsole() { consoleStore.clear() }

    /// 展开 / 折叠目录（视图层带动画调用）
    func toggleExpanded(_ url: String) {
        if expandedDirs.contains(url) {
            expandedDirs.remove(url)
        } else {
            expandedDirs.insert(url)
        }
    }

    // MARK: - 加载

    /// 并发去重：addTarget、切目标、首屏 task 可能同时调 refreshAll，
    /// 已在跑时直接复用当前任务，不把 info/status/log/list 全套命令跑两遍。
    private var refreshTask: Task<Void, Never>?

    func refreshAll() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { await performRefreshAll() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// 刷新代次：新的刷新一开始，旧的刷新在每一步之间就会自觉退出，
    /// 快速连点目标列表时不会堆一串过期的 svn 命令 + 解析。
    private var refreshGen = 0

    private func performRefreshAll() async {
        refreshGen &+= 1
        let gen = refreshGen
        isBusy = true
        lastError = nil
        defer { if gen == refreshGen { isBusy = false } }
        do {
            try await loadInfo()
        } catch {
            lastError = error.localizedDescription
            logToConsole("✗ \(error.localizedDescription)")
        }
        guard gen == refreshGen else { return }
        await refreshStatus()
        guard gen == refreshGen else { return }
        await loadChildren(rootNode)
        guard gen == refreshGen else { return }
        await refreshLog()
    }

    func loadInfo() async throws {
        let result = try await executor.run(["info", "--xml", target.location])
        let xml = Data(result.output.utf8)
        info = try await Self.parseOffMain { try SVNXMLParser.parseInfo(xml: xml) }
        if let i = info {
            statusMessage = "版本库 \(i.revision.map(String.init) ?? "-")"
        }
    }

    /// 顶部刷新按钮：重读 info / 状态 / 目录 / 日志。
    /// 目录不能只靠缓存，否则外部（访达、命令行、别的客户端）新建的文件在树里看不到。
    func manualRefresh() async {
        refreshGen &+= 1
        let gen = refreshGen
        await ensureCredentialContext()
        guard gen == refreshGen else { return }
        try? await loadInfo()
        guard gen == refreshGen else { return }
        await refreshStatus()
        guard gen == refreshGen else { return }
        await reloadCachedDirectories()
        guard gen == refreshGen else { return }
        if !target.isRemote { await refreshLog() }
    }

    /// 重新读取当前已展开的目录列表
    func reloadCachedDirectories() async {
        if target.isRemote {
            // 先在临时字典里全部更新完，再一次赋值 —— 逐目录写 children 会
            // 触发 N 次 objectWillChange，让整棵树连着重渲染 N 遍。
            var updated = children
            for dir in Array(children.keys) {
                do {
                    let result = try await executor.run(["list", "--xml", dir])
                    let xml = Data(result.output.utf8)
                    updated[dir] = try await Self.parseOffMain {
                        try SVNXMLParser.parseList(xml: xml, parentURL: dir)
                    }
                } catch {
                    logToConsole("✗ list \(dir): \(error.localizedDescription)")
                }
            }
            children = updated
        } else {
            await syncChildrenWithDisk()
        }
    }

    func refreshStatus() async {
        guard !target.isRemote else { return }
        await ensureCredentialContext()
        let root = rootForCommands
        do {
            let result = try await executor.run(["status", "--xml", "-v", "."], cwd: root)
            let xml = Data(result.output.utf8)
            // 几千条状态建 DOM 树很吃 CPU，放后台解析
            let entries = try await Self.parseOffMain { try SVNXMLParser.parseStatus(xml: xml) }
            var map: [String: SVNStatusEntry] = [:]
            map.reserveCapacity(entries.count)
            var changed: [SVNStatusEntry] = []
            changed.reserveCapacity(entries.count / 4)
            for e in entries {
                let full = Self.absolutePath(relative: e.path, root: root)
                let entry = SVNStatusEntry(path: full, item: e.item, props: e.props,
                                           commitRevision: e.commitRevision,
                                           commitAuthor: e.commitAuthor, commitDate: e.commitDate)
                map[full] = entry
                if e.item.isChanged { changed.append(entry) }
            }
            statusMap = map
            changedFiles = changed.sorted { $0.path < $1.path }
            selectedPaths = Set(changed.filter { $0.item != .ignored && $0.item != .none }.map { $0.path })
            statusMessage = "\(changedFiles.count) 处本地改动"
            // 磁盘上可能有外部新建/删除的文件，顺手同步已展开的目录（后台枚举）
            await syncChildrenWithDisk()
        } catch {
            lastError = error.localizedDescription
            logToConsole("✗ status: \(error.localizedDescription)")
        }
    }

    static func absolutePath(relative: String, root: String) -> String {
        if relative.hasPrefix("/") { return relative }
        return (root as NSString).appendingPathComponent(relative)
    }

    /// 丢掉缓存重新读取某个目录（首次渲染落空时的兜底）
    func reloadChildren(_ node: FileNode) async {
        children[node.url] = nil
        await loadChildren(node)
    }

    func loadChildren(_ node: FileNode) async {
        let url = node.url
        // 已加载过、或正在读取中（快速连点同一个目录）直接返回，不重复起进程
        if children[url] != nil || loadingDirs.contains(url) { return }
        loadingDirs.insert(url)

        await loadGate.acquire()
        let outcome: Result<[FileNode], Error>
        if target.isRemote {
            do {
                let result = try await executor.run(["list", "--xml", url])
                let xml = Data(result.output.utf8)
                let nodes = try await Self.parseOffMain { try SVNXMLParser.parseList(xml: xml, parentURL: url) }
                outcome = .success(nodes)
            } catch {
                outcome = .failure(error)
            }
        } else {
            // 目录枚举走后台：大目录（几千个条目）在主线程做会把界面卡成海滩球
            outcome = .success(await Self.localListingAsync(url))
        }
        await loadGate.release()

        switch outcome {
        case .success(let nodes):
            children[url] = nodes
        case .failure(let error):
            lastError = error.localizedDescription
            logToConsole("✗ list: \(error.localizedDescription)")
        }
        loadingDirs.remove(url)
    }

    /// XML 解析（XMLDocument 建树 + 上千条节点）统一放到后台，避免主线程卡顿
    nonisolated private static func parseOffMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    /// 读一个本地目录的内容（跳过 .svn 与访达噪音文件）
    nonisolated static func localListing(_ directory: String) -> [FileNode] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        var nodes: [FileNode] = []
        nodes.reserveCapacity(items.count)
        for item in items {
            if item == ".svn" || item == ".git" || item == ".DS_Store" { continue }
            let full = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            nodes.append(FileNode(url: full, name: item, isDir: isDir.boolValue))
        }
        return sortedNodes(nodes)
    }

    /// 后台线程枚举目录
    nonisolated static func localListingAsync(_ directory: String) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) { localListing(directory) }.value
    }

    /// 已缓存的目录按磁盘实际内容重读一遍（后台并发枚举，主线程只做最后一次赋值）。
    /// 不清空缓存，这样树里已展开的层级不会塌回去；外部（访达/命令行）新建或删除的文件也能立刻看到。
    func syncChildrenWithDisk() async {
        guard !target.isRemote, !children.isEmpty else { return }
        let dirs = Array(children.keys)
        var updated = children
        await withTaskGroup(of: (String, [FileNode]).self) { group in
            for dir in dirs {
                group.addTask { (dir, await RepoModel.localListingAsync(dir)) }
            }
            for await (dir, nodes) in group {
                updated[dir] = nodes
            }
        }
        children = updated
    }

    nonisolated static func sortedNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 某个目录下应当显示的子项：目录实际内容 + 已删除/缺失的条目。
    /// 直接读目录内容会漏掉 `svn rm` 过的文件（磁盘上已经没有了），
    /// 但 TortoiseSVN 这类客户端会把它标成红色删除线显示出来。
    ///
    /// 结果按「数据版本号」缓存：children / statusMap 变了才重算，
    /// 否则每次视图求值都会对每个目录重跑一次排序（上千项的 ICU 排序足以卡住主线程）。
    func displayChildren(of directory: String) -> [FileNode] {
        if let hit = displayCache[directory], hit.gen == displayGen { return hit.nodes }

        var nodes = children[directory] ?? []
        if !target.isRemote {
            let existing = Set(nodes.map { $0.name })
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            for entry in statusByDir[directory] ?? [] where entry.item == .deleted || entry.item == .missing {
                guard !existing.contains(entry.name) else { continue }
                nodes.append(FileNode(url: prefix + entry.name, name: entry.name, isDir: false))
            }
            nodes = Self.sortedNodes(nodes)
        }
        displayCache[directory] = (displayGen, nodes)
        return nodes
    }

    /// 目录 → 子树内最严重状态。statusMap 每次变化只算一遍
    /// （每条改动沿祖先目录向上冒泡），替代原来每行渲染时的全表前缀扫描。
    private func rebuildDirStatusCache() {
        var cache: [String: SVNItemStatus] = [:]
        var byDir: [String: [(name: String, item: SVNItemStatus)]] = [:]
        for (path, entry) in statusMap {
            let parent = (path as NSString).deletingLastPathComponent
            byDir[parent, default: []].append(((path as NSString).lastPathComponent, entry.item))
            var dir = parent
            while !dir.isEmpty && dir != "/" {
                if let current = cache[dir], current.priority >= entry.item.priority {
                    // 已有更严重的，跳过
                } else {
                    cache[dir] = entry.item
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        dirStatusCache = cache
        statusByDir = byDir
        invalidateDisplayCache()
    }

    /// 目录内容视图缓存：视图求值时只查表，重算只发生在 children / statusMap 变化后
    private var displayGen = 0
    private var displayCache: [String: (gen: Int, nodes: [FileNode])] = [:]
    /// statusMap 按父目录分组，displayChildren 不必再全表扫描
    private var statusByDir: [String: [(name: String, item: SVNItemStatus)]] = [:]

    private func invalidateDisplayCache() {
        displayGen &+= 1
        if displayCache.count > 2_000 { displayCache.removeAll(keepingCapacity: true) }
    }

    /// 目录读取闸门：同时最多 4 个目录在读取。
    /// 树展开得很快时，没有闸门会给每个目录都起一个 svn 进程 / 磁盘枚举，CPU 瞬间打满。
    private let loadGate = LoadGate(limit: 4)

    /// 文件取自身状态；目录取「自身 + 所有子项」里最严重的一个（查缓存，O(1)）。
    /// 注意不能因为目录本身有 normal 记录就提前返回，否则父目录永远不显示子项改动。
    func status(for node: FileNode) -> SVNItemStatus {
        if target.isRemote { return .normal }
        var worst: SVNItemStatus = statusMap[node.url]?.item ?? .normal
        guard node.isDir else { return worst }
        if let sub = dirStatusCache[node.url], sub.priority > worst.priority { worst = sub }
        return worst
    }

    /// 是否已纳入版本控制（未纳管 / 已忽略的不能 delete、blame、diff）
    func isVersioned(_ url: String) -> Bool {
        guard let e = statusMap[url] else { return false }
        switch e.item {
        case .unversioned, .ignored, .none: return false
        default: return true
        }
    }


    func hasChanges(under node: FileNode) -> Bool {
        if !node.isDir { return statusMap[node.url]?.item.isChanged ?? false }
        let prefix = node.url + "/"
        if let own = statusMap[node.url], own.item.isChanged { return true }
        return statusMap.keys.contains { $0.hasPrefix(prefix) && statusMap[$0]!.item.isChanged }
    }

    // MARK: - 日志 & 版本树

    func refreshLog() async {
        await ensureCredentialContext()
        do {
            let result = try await executor.run(["log", "--xml", "-v", "-l", String(logLimit), rootForCommands])
            let xml = Data(result.output.utf8)
            logs = try await Self.parseOffMain { try SVNXMLParser.parseLog(xml: xml) }
        } catch {
            lastError = error.localizedDescription
            logToConsole("✗ log: \(error.localizedDescription)")
        }
    }

    func refreshGraph() async {
        isBusy = true
        defer { isBusy = false }
        if info == nil {
            try? await loadInfo()
        }
        do {
            let result = try await executor.run(["log", "--xml", "-v", "-l", String(graphLimit), graphSource])
            let xml = Data(result.output.utf8)
            let (entries, built) = try await Self.parseOffMain { () -> ([LogEntry], RevisionGraph) in
                let parsed = try SVNXMLParser.parseLog(xml: xml)
                return (parsed, RevisionGraphBuilder.build(entries: parsed))
            }
            logs = entries
            graph = built
            logToConsole("✓ 版本树：\(graph.nodes.count) 个节点 / \(graph.branches.count) 条分支线")
        } catch {
            lastError = error.localizedDescription
            logToConsole("✗ graph: \(error.localizedDescription)")
        }
    }

    // MARK: - 操作

    @discardableResult
    func runOperation(_ args: [String], cwd: String? = nil) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        await ensureCredentialContext()
        let display = "svn " + args.joined(separator: " ")
        logToConsole("▶ \(display)")
        do {
            let result = try await executor.run(args, cwd: cwd ?? (target.isRemote ? nil : rootForCommands))
            let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { logToConsole(out) }
            logToConsole("✓ 完成")
            return true
        } catch {
            logToConsole("✗ \(error.localizedDescription)")
            lastError = error.localizedDescription
            return false
        }
    }

    func update(paths: [String] = []) async {
        let args = ["update"] + (paths.isEmpty ? [] : paths)
        if await runOperation(args) {
            try? await loadInfo()        // 头部「版本 rN」跟着变
            await refreshStatus()
            await refreshLog()
        }
    }

    func cleanup(path: String? = nil) async {
        let args = ["cleanup"] + (path.map { [$0] } ?? [])
        if await runOperation(args) { await refreshStatus() }
    }

    func revert(paths: [String]) async {
        guard !paths.isEmpty else { return }
        if await runOperation(["revert", "-R"] + paths) {
            treeSelection = nil
            await refreshStatus()
        }
    }

    func add(paths: [String]) async {
        guard !paths.isEmpty else { return }
        // --parents：父目录还没纳入版本控制时一并补上（往未纳管目录里放文件很常见）
        if await runOperation(["add", "--parents"] + paths) { await refreshStatus() }
    }

    func delete(paths: [String]) async {
        guard !paths.isEmpty else { return }
        if await runOperation(["delete"] + paths) {
            treeSelection = nil
            await refreshStatus()
        }
    }

    func diff(paths: [String]) async {
        guard !paths.isEmpty else { return }
        await runOperation(["diff"] + paths)
    }

    func commit(paths: [String], message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty, !trimmed.isEmpty else { return }
        // 未纳管的文件先自动 add，再和其余改动一起提交（对应 TortoiseSVN 提交框里「check to add」）
        let toAdd = paths.filter { statusMap[$0]?.item == .unversioned }
        if !toAdd.isEmpty {
            logToConsole("▶ 先加入版本控制：\(toAdd.count) 个未纳管项")
            _ = await runOperation(["add", "--parents"] + toAdd)
        }
        if await runOperation(["commit", "-m", trimmed] + paths) {
            selectedPaths = []
            treeSelection = nil
            try? await loadInfo()
            await refreshStatus()
            await refreshLog()
        }
    }

    func switchTo(_ url: String) async {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if await runOperation(["switch", url.trimmingCharacters(in: .whitespacesAndNewlines)]) {
            await refreshAll()
        }
    }

    func blame(path: String) async {
        await runOperation(["blame", path])
    }

    func infoFor(path: String) async {
        await runOperation(["info", path])
    }

    // MARK: - 单路径日志

    /// 只看某个文件/目录的提交历史（文件树右键「查看提交日志」）
    func loadLog(for path: String, limit: Int = 200) async {
        logScope = path
        do {
            let result = try await executor.run(["log", "--xml", "-v", "-l", String(limit), path])
            let xml = Data(result.output.utf8)
            logs = try await Self.parseOffMain { try SVNXMLParser.parseLog(xml: xml) }
            logToConsole("✓ 日志：\(relativePath(path)) 共 \(logs.count) 条")
        } catch {
            lastError = error.localizedDescription
            logToConsole("✗ log: \(error.localizedDescription)")
        }
    }

    func clearLogScope() async {
        logScope = nil
        await refreshLog()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 打开文件

    /// 远程文件没有本地实体，导出一份只读副本后再交给系统打开。
    /// 同一个 URL 只导出一次，重复打开直接复用（避免每双击一次都跑一遍 svn export）。
    private var openedTempFiles: [String: String] = [:]

    /// 双击 / 右键「打开」的统一入口：本地直接用系统默认应用打开，远程先取临时副本
    func openFile(_ url: String, withApplication appURL: URL? = nil) async {
        var path = url
        if target.isRemote {
            guard let copy = await temporaryCopy(of: url) else { return }
            path = copy
        }
        await open(localPath: path, withApplication: appURL)
    }

    /// 已加载目录里该路径的最后提交版本（缓存 key 里带上它：版本变了就重新导出）
    private func knownRevision(for url: String) -> Int? {
        for (_, kids) in children {
            if let n = kids.first(where: { $0.url == url }), let r = n.revision { return r }
        }
        return nil
    }

    /// 远程文件 → 本地临时副本（同一版本只导出一次，文件还在就复用）
    func temporaryCopy(of url: String) async -> String? {
        let cacheKey = url + (knownRevision(for: url).map { "#r\($0)" } ?? "")
        if let cached = openedTempFiles[cacheKey], FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let name = URL(string: url)?.lastPathComponent
            ?? (url as NSString).lastPathComponent
        // 用整条 URL 做子目录名，避免不同仓库里的同名文件互相覆盖
        let key = url
            .replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("TortiOpen")
        let dir = (base as NSString).appendingPathComponent(String(key.suffix(160)))
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            logToConsole("✗ 无法创建临时目录：\(error.localizedDescription)")
            return nil
        }
        let target = (dir as NSString).appendingPathComponent(name)
        try? FileManager.default.removeItem(atPath: target)
        statusMessage = "正在取版本库副本…"
        let ok = await export(url: url, to: target)
        guard ok else { return nil }
        openedTempFiles[cacheKey] = target
        return target
    }

    /// 用系统默认应用（或指定应用）打开一个本地路径
    @discardableResult
    func open(localPath path: String, withApplication appURL: URL? = nil) async -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            let name = (path as NSString).lastPathComponent
            logToConsole("✗ 打不开「\(name)」：本地磁盘上没有这个文件")
            statusMessage = "文件不在本地"
            return false
        }
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            if let appURL {
                _ = try await NSWorkspace.shared.open([url],
                                                      withApplicationAt: appURL,
                                                      configuration: config)
            } else {
                _ = try await NSWorkspace.shared.open(url, configuration: config)
            }
            logToConsole("✓ 已打开 \((path as NSString).lastPathComponent)")
        } catch {
            logToConsole("✗ 打不开「\((path as NSString).lastPathComponent)」：\(error.localizedDescription)")
            statusMessage = "打开失败"
            return false
        }
        if target.isRemote {
            logToConsole("ℹ 这是版本库里的只读副本（\(path)），改动不会自动提交；要修改请先「检出到…」")
        }
        return true
    }

    /// 远程文件：导出副本后在访达里选中它（方便直接拖去别的地方用）
    func revealTempCopy(of url: String) async {
        guard let path = await temporaryCopy(of: url) else { return }
        revealInFinder(path)
        logToConsole("✓ 副本：\(path)")
    }

    // MARK: - 检出 / 导出

    /// 检出远程 URL 到本地目录（直接提交到版本库之外的标准操作，不需要工作副本）
    @discardableResult
    func checkout(url: String, to destination: String, revision: Int? = nil, depth: String = "infinity") async -> Bool {
        var args = ["checkout"]
        if let revision { args += ["--revision", String(revision)] }
        if depth != "infinity" { args += ["--depth", depth] }
        args += [url, destination]
        let ok = await runOperation(args)
        if ok { logToConsole("✓ 已检出到 \(destination)") }
        return ok
    }

    /// 导出（不带 .svn）：远程 URL 或本地工作副本路径都可以作为来源
    @discardableResult
    func export(url: String, to destination: String, revision: Int? = nil) async -> Bool {
        var args = ["export", "--force"]
        if let revision { args += ["--revision", String(revision)] }
        args += [url, destination]
        let ok = await runOperation(args)
        if ok { logToConsole("✓ 已导出到 \(destination)") }
        return ok
    }

    /// 把仓库里的文件导出到临时目录，返回本地路径（拖拽出文件 / 预览用）
    func exportToTemp(url: String) async -> String? {
        let name = URL(string: url)?.lastPathComponent ?? (url as NSString).lastPathComponent
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("TortiDrag")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sub = (dir as NSString).appendingPathComponent(UUID().uuidString)
        let target = (sub as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        } catch {
            logToConsole("✗ 无法创建临时目录：\(error.localizedDescription)")
            return nil
        }
        let ok = await export(url: url, to: target)
        return ok ? target : nil
    }

    // MARK: - 远程写操作（无需工作副本，直接在版本库上提交）

    /// 供「拖出文件」使用的 NSItemProvider：本地直接给出路径，远程先导出到临时目录再给出
    func dragItem(for url: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = URL(string: url)?.lastPathComponent ?? (url as NSString).lastPathComponent
        provider.suggestedName = name
        let typeID = UTType.fileURL.identifier

        if target.isRemote {
            provider.registerFileRepresentation(forTypeIdentifier: typeID,
                                                fileOptions: [],
                                                visibility: .all) { completion in
                Task { @MainActor in
                    let path = await self.exportToTemp(url: url)
                    completion(path.map { URL(fileURLWithPath: $0) }, false, nil)
                }
                return nil
            }
        } else {
            provider.registerFileRepresentation(forTypeIdentifier: typeID,
                                                fileOptions: [],
                                                visibility: .all) { completion in
                completion(URL(fileURLWithPath: url), false, nil)
                return nil
            }
        }
        return provider
    }

    static func joinRemote(_ dir: String, _ name: String) -> String {
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        return base + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
    }

    /// 取父级路径 / URL。不能直接用 NSString.deletingLastPathComponent ——
    /// 它会把 `svn://host/...` 里的双斜杠压缩掉，导致刷新到错误的地址。
    static func parent(of url: String) -> String {
        var s = url
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        guard let idx = s.lastIndex(of: "/") else { return url }
        let parent = String(s[s.startIndex...s.index(before: idx)])
        return parent.isEmpty ? url : parent
    }

    /// 上传本地文件 / 目录到远程目录（svn import）
    func upload(localPaths: [String], to remoteDir: String) async {
        guard !localPaths.isEmpty else { return }
        // 先看一眼目标目录里已有什么，避免覆盖已存在的项目
        if children[remoteDir] == nil {
            await loadChildren(FileNode(url: remoteDir, name: (remoteDir as NSString).lastPathComponent, isDir: true))
        }
        let existing = Set((children[remoteDir] ?? []).map { $0.name })
        var done = 0
        for path in localPaths {
            let name = (path as NSString).lastPathComponent
            if existing.contains(name) {
                logToConsole("⏭ 跳过「\(name)」：远程目录里已存在同名项（要改内容请先检出后提交）")
                continue
            }
            let dest = Self.joinRemote(remoteDir, name)
            logToConsole("↑ 上传 \(name) → \(dest)")
            if await runOperation(["import", "-m", "上传 \(name)", path, dest]) { done += 1 }
        }
        logToConsole(done == 0 ? "✗ 没有文件被上传" : "✓ 上传完成 \(done)/\(localPaths.count)")
        await reloadDirectory(url: remoteDir)
    }

    /// 远程新建目录（svn mkdir 会直接产生一次提交）
    @discardableResult
    func mkdirRemote(parent: String, name: String) async -> Bool {
        let url = Self.joinRemote(parent, name)
        let ok = await runOperation(["mkdir", "-m", "新建目录 \(name)", url])
        if ok { await reloadDirectory(url: parent) }
        return ok
    }

    /// 远程删除（直接提交到版本库，需要写权限）
    @discardableResult
    func deleteRemote(paths: [String], message: String) async -> Bool {
        guard !paths.isEmpty else { return false }
        var args = ["delete", "-m", message]
        args += paths
        let ok = await runOperation(args)
        if let first = paths.first {
            await reloadDirectory(url: Self.parent(of: first))
        }
        return ok
    }

    /// 远程重命名 / 移动（svn move 直接提交）
    @discardableResult
    func moveRemote(from: String, to: String) async -> Bool {
        let ok = await runOperation(["move", "-m", "重命名 / 移动 \((from as NSString).lastPathComponent) → \((to as NSString).lastPathComponent)", from, to])
        if ok {
            let fromParent = Self.parent(of: from)
            let toParent = Self.parent(of: to)
            await reloadDirectory(url: fromParent)
            if toParent != fromParent { await reloadDirectory(url: toParent) }
        }
        return ok
    }

    /// 把本地文件放进工作副本目录并 svn add（拖入本地模式）
    func copyIntoWorkingCopy(files: [String], directory: String) async {
        let fm = FileManager.default
        var added: [String] = []
        for file in files {
            let name = (file as NSString).lastPathComponent
            let dest = (directory as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: dest) {
                logToConsole("⏭ 跳过「\(name)」：目标目录里已存在同名文件")
                continue
            }
            do {
                try fm.copyItem(atPath: file, toPath: dest)
                added.append(dest)
            } catch {
                logToConsole("✗ 复制失败 \(name)：\(error.localizedDescription)")
            }
        }
        if !added.isEmpty {
            await add(paths: added)
            logToConsole("✓ 已放入 \(added.count) 个文件，还需「提交」才会进入版本库")
        }
        await reloadDirectory(url: directory)
    }

    /// 重新读取某个目录（URL 形态与本地路径都用这一套）
    func reloadDirectory(url: String) async {
        let node = FileNode(url: url, name: (url as NSString).lastPathComponent, isDir: true)
        children[url] = nil
        await loadChildren(node)
    }

    /// 测试连通性与认证（设置页使用）
    func testConnection() async -> String {
        do {
            try await loadInfo()
            if let info {
                var text = "连接成功：\(info.url ?? target.location)"
                if let rev = info.revision { text += "\n最新版本：r\(rev)" }
                if let root = info.repositoryRoot { text += "\n版本库根：\(root)" }
                logToConsole("✓ \(text.replacingOccurrences(of: "\n", with: " | "))")
                return text
            }
            return "连接成功，但未解析到版本库信息。"
        } catch {
            logToConsole("✗ \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
