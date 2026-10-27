import Foundation

// MARK: - 执行结果

struct SVNCommandResult {
    let output: String
    let errorOutput: String
    let status: Int32
    let commandLine: String
}

enum SVNServiceError: LocalizedError {
    case executableMissing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let p): return "找不到 svn 可执行文件：\(p)\n请在「设置」中指定正确路径（例如 /opt/homebrew/bin/svn）。"
        case .commandFailed(let m): return m
        }
    }
}

// MARK: - 命令执行器

final class SVNExecutor: @unchecked Sendable {
    let executablePath: String
    let username: String?
    let password: String?

    private let queue = DispatchQueue(label: "svn.executor", qos: .userInitiated)
    private var currentProcess: Process?

    init(executablePath: String, username: String?, password: String?) {
        self.executablePath = executablePath
        self.username = username
        self.password = password
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    func cancel() {
        queue.async { self.currentProcess?.terminate() }
    }

    func fullArguments(_ args: [String]) -> [String] {
        var base = ["--non-interactive"]
        if let u = username, !u.isEmpty {
            base += ["--username", u]
        }
        if let p = password, !p.isEmpty {
            base += ["--password", p, "--no-auth-cache"]
        }
        return base + args
    }

    var displayName: String { (executablePath as NSString).lastPathComponent }

    /// 输出解码：优先 UTF-8，失败时退回 GB18030（部分老仓库/本地化环境），最后做容错解码
    static func decode(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// 用于展示的命令行（密码打码）
    func displayCommand(_ args: [String]) -> String {        var parts = [executablePath]
        var i = 0
        let full = fullArguments(args)
        while i < full.count {
            if full[i] == "--password", i + 1 < full.count {
                parts.append("--password ******")
                i += 2
                continue
            }
            parts.append(full[i])
            i += 1
        }
        return parts.joined(separator: " ")
    }

    func run(_ args: [String], cwd: String? = nil) async throws -> SVNCommandResult {
        guard isAvailable else { throw SVNServiceError.executableMissing(executablePath) }
        let exec = executablePath
        let full = fullArguments(args)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SVNCommandResult, Error>) in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exec)
                process.arguments = full
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

                // 必须给 UTF-8 locale，否则 svn 的中文提示会被转义成 {U+6B63} 这种形式
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "en_US.UTF-8"
                env["LANG"] = "en_US.UTF-8"
                env["LC_CTYPE"] = "en_US.UTF-8"
                process.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                self.currentProcess = process

                let lock = NSLock()
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = d; lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = d; lock.unlock()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()
                self.currentProcess = nil

                let code = process.terminationStatus
                let out = SVNExecutor.decode(outData)
                let err = SVNExecutor.decode(errData)
                let line = self.displayCommand(args)      // 密码打码
                let result = SVNCommandResult(output: out, errorOutput: err, status: code, commandLine: line)

                if code != 0 {
                    var msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    if msg.isEmpty { msg = out.trimmingCharacters(in: .whitespacesAndNewlines) }
                    let detail = "命令：\(line)\n退出码 \(code)\n\(msg)"
                    let lower = msg.lowercased()
                    let has = { (k: [String]) in k.contains(where: { lower.contains($0) }) }

                    // 先判定「地址 / 仓库不存在」——这类错误里通常也带 E170013，不能笼统算认证失败
                    let missingRepo = ["e210005", "no repository found", "e180001", "e670002", "url doesn't exist"]
                    let authOnly = ["e215004", "e170001", "e175013",
                                    "authentication failed", "authorization failed",
                                    "no more credentials", "could not authenticate",
                                    "认证失败", "无法认证"]
                    let connectOnly = ["e170013", "e730054", "unable to connect to a repository",
                                       "could not connect", "connection refused", "connection timed out"]

                    if has(missingRepo) {
                        continuation.resume(throwing: SVNServiceError.commandFailed(
                            "地址不对：服务器上没有这个版本库。\n请检查 URL 路径（例如 svn://host/repo 是否漏了 /repo 或写错大小写）。\n\n\(detail)"))
                    } else if has(authOnly) {
                        continuation.resume(throwing: SVNServiceError.commandFailed(
                            "认证失败：svn 没能拿到有效凭据。\n请到「设置 › 服务器凭据」为该主机填写用户名与密码。\n\n\(detail)"))
                    } else if has(connectOnly) {
                        continuation.resume(throwing: SVNServiceError.commandFailed(
                            "连接失败：没能连上服务器。\n请检查地址、网络，以及 svnserve / httpd 是否在运行。\n\n\(detail)"))
                    } else {
                        continuation.resume(throwing: SVNServiceError.commandFailed(detail))
                    }
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

// MARK: - XML 解析

enum SVNXMLParser {
    static func document(data: Data) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SVNServiceError.commandFailed("XML 解析失败：\(error.localizedDescription)\n\(text.prefix(500))")
        }
    }

    static func attribute(_ name: String, of element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    static func childText(_ name: String, of element: XMLElement) -> String? {
        element.elements(forName: name).first?.stringValue
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    // MARK: status

    static func parseStatus(xml: Data) throws -> [SVNStatusEntry] {
        let doc = try document(data: xml)
        guard let root = doc.rootElement() else { return [] }
        var result: [SVNStatusEntry] = []
        for entry in root.elements(forName: "entry") + root.elements(forName: "target").flatMap({ $0.elements(forName: "entry") }) {
            guard let path = attribute("path", of: entry) else { continue }
            guard let wc = entry.elements(forName: "wc-status").first else { continue }
            let item = SVNItemStatus(raw: attribute("item", of: wc))
            let props = attribute("props", of: wc)
            var rev: Int? = nil, author: String? = nil, date: Date? = nil
            if let commit = wc.elements(forName: "commit").first {
                if let r = attribute("revision", of: commit) { rev = Int(r) }
                author = childText("author", of: commit)
                date = parseDate(childText("date", of: commit))
            }
            result.append(SVNStatusEntry(path: path, item: item, props: props,
                                         commitRevision: rev, commitAuthor: author, commitDate: date))
        }
        return result
    }

    // MARK: info

    static func parseInfo(xml: Data) throws -> SVNInfo? {
        let doc = try document(data: xml)
        guard let root = doc.rootElement(),
              let entry = root.elements(forName: "entry").first else { return nil }
        let rev = Int(attribute("revision", of: entry) ?? "")
        let url = childText("url", of: entry)
        let repoRoot = entry.elements(forName: "repository").first.flatMap { childText("root", of: $0) }
        let uuid = entry.elements(forName: "repository").first.flatMap { childText("uuid", of: $0) }
        let wcRoot = entry.elements(forName: "wc-info").first.flatMap { childText("wcroot-abspath", of: $0) }
        let commit = entry.elements(forName: "commit").first
        let lastRev = commit.flatMap { Int(attribute("revision", of: $0) ?? "") }
        let lastAuthor = commit.flatMap { childText("author", of: $0) }
        let lastDate = commit.flatMap { parseDate(childText("date", of: $0)) }
        return SVNInfo(url: url, repositoryRoot: repoRoot, repositoryUUID: uuid,
                       workingCopyRoot: wcRoot, revision: rev,
                       lastChangedRevision: lastRev, lastChangedAuthor: lastAuthor,
                       lastChangedDate: lastDate, kind: attribute("kind", of: entry))
    }

    // MARK: log

    static func parseLog(xml: Data) throws -> [LogEntry] {
        let doc = try document(data: xml)
        guard let root = doc.rootElement() else { return [] }
        var entries: [LogEntry] = []
        for e in root.elements(forName: "logentry") {
            guard let revText = attribute("revision", of: e), let revision = Int(revText) else { continue }
            let author = childText("author", of: e)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let date = parseDate(childText("date", of: e))
            let msg = childText("msg", of: e) ?? ""
            var paths: [ChangedPath] = []
            if let pathsEl = e.elements(forName: "paths").first {
                for p in pathsEl.elements(forName: "path") {
                    guard let path = p.stringValue, !path.isEmpty else { continue }
                    let cp = attribute("copyfrom-path", of: p)
                    let cr = attribute("copyfrom-rev", of: p).flatMap { Int($0) }
                    paths.append(ChangedPath(action: attribute("action", of: p) ?? "M",
                                             path: path, copyFromPath: cp, copyFromRev: cr))
                }
            }
            entries.append(LogEntry(revision: revision, author: author?.isEmpty == true ? nil : author,
                                    date: date, message: msg, paths: paths))
        }
        return entries.sorted { $0.revision > $1.revision }
    }

    // MARK: list

    static func parseList(xml: Data, parentURL: String) throws -> [FileNode] {
        let doc = try document(data: xml)
        guard let root = doc.rootElement() else { return [] }
        var nodes: [FileNode] = []
        for list in root.elements(forName: "list") {
            for e in list.elements(forName: "entry") {
                guard let name = childText("name", of: e) else { continue }
                let kind = attribute("kind", of: e) ?? "file"
                let base = parentURL.hasSuffix("/") ? parentURL : parentURL + "/"
                let childURL = base + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                let rev = e.elements(forName: "commit").first
                    .flatMap { attribute("revision", of: $0) }
                    .flatMap { Int($0) }
                nodes.append(FileNode(url: childURL, name: name, isDir: kind == "dir", revision: rev))
            }
        }
        return nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - 版本树构建

enum RevisionGraphBuilder {
    static func branchKey(for path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p = String(p.dropFirst()) }
        let comps = p.split(separator: "/").map(String.init)
        guard let first = comps.first, !first.isEmpty else { return "/" }
        if first == "trunk" { return "trunk" }
        if (first == "branches" || first == "tags"), comps.count > 1 {
            return "\(first)/\(comps[1])"
        }
        return first
    }

    /// 容器目录本身不算一个分支线（只在 import 时出现）
    private static func isStructuralContainer(_ path: String) -> Bool {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return trimmed == "branches" || trimmed == "tags" || trimmed.isEmpty
    }

    static func build(entries: [LogEntry]) -> RevisionGraph {
        let ascending = entries.sorted { $0.revision < $1.revision }
        guard !ascending.isEmpty else { return RevisionGraph() }

        struct Draft {
            let revision: Int
            let branch: String
            let items: [ChangedPath]
            let author: String?
            let summary: String
        }

        var drafts: [Draft] = []
        var copies: [(fromRev: Int, fromBranch: String, toRev: Int, toBranch: String)] = []

        for entry in ascending {
            var grouped: [String: [ChangedPath]] = [:]
            for p in entry.paths {
                if isStructuralContainer(p.path) { continue }
                let b = branchKey(for: p.path)
                grouped[b, default: []].append(p)
                if let from = p.copyFromPath, let fromRev = p.copyFromRev {
                    let fb = branchKey(for: from)
                    if fb != b { copies.append((fromRev, fb, entry.revision, b)) }
                }
            }
            for (branch, items) in grouped {
                drafts.append(Draft(revision: entry.revision, branch: branch, items: items,
                                    author: entry.author, summary: entry.firstLine))
            }
        }

        guard !drafts.isEmpty else { return RevisionGraph() }

        // 行号 = 出现过节点的修订号，按升序排列
        let revisions = Array(Set(drafts.map { $0.revision })).sorted()
        var rowOf: [Int: Int] = [:]
        for (i, r) in revisions.enumerated() { rowOf[r] = i }

        // 列号 = 分支首次出现的顺序
        var branchOrder: [String] = []
        for d in drafts.sorted(by: { $0.revision < $1.revision }) where !branchOrder.contains(d.branch) {
            branchOrder.append(d.branch)
        }

        var nodes: [GraphNode] = []
        struct Key: Hashable { let rev: Int; let branch: String }
        var nodeIndex: [Key: GraphNode] = [:]

        for d in drafts {
            let column = branchOrder.firstIndex(of: d.branch) ?? 0
            let node = GraphNode(
                revision: d.revision,
                branch: d.branch,
                column: column,
                row: rowOf[d.revision] ?? 0,
                author: d.author,
                summary: d.summary,
                changeCount: d.items.count,
                isCopy: d.items.contains { $0.copyFromPath != nil },
                isTag: d.branch.hasPrefix("tags/"),
                isTrunk: d.branch == "trunk"
            )
            nodes.append(node)
            nodeIndex[Key(rev: d.revision, branch: d.branch)] = node
        }

        var byBranch: [String: [GraphNode]] = [:]
        for n in nodes { byBranch[n.branch, default: []].append(n) }

        var edges: [GraphEdge] = []
        for (_, list) in byBranch {
            let sorted = list.sorted { $0.row < $1.row }
            for i in 1..<max(sorted.count, 1) {
                edges.append(GraphEdge(fromRow: sorted[i - 1].row, fromColumn: sorted[i - 1].column,
                                       toRow: sorted[i].row, toColumn: sorted[i].column, isCopy: false))
            }
        }

        for c in copies {
            guard let target = nodeIndex[Key(rev: c.toRev, branch: c.toBranch)] else { continue }
            let candidates = (byBranch[c.fromBranch] ?? [])
                .filter { $0.row < target.row }
                .sorted { $0.row > $1.row }
            guard let source = candidates.first else { continue }
            edges.append(GraphEdge(fromRow: source.row, fromColumn: source.column,
                                   toRow: target.row, toColumn: target.column, isCopy: true))
        }

        return RevisionGraph(nodes: nodes, edges: edges, branches: branchOrder, rows: revisions)
    }
}
