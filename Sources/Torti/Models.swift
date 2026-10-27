import Foundation
import SwiftUI

// MARK: - 文件 / 目录节点（本地路径 或 仓库 URL 通用）

struct FileNode: Identifiable, Hashable {
    let url: String
    let name: String
    let isDir: Bool
    /// 远程目录用 svn list 拿到的最后提交版本（本地工作副本走 status 的 commitRevision）
    var revision: Int? = nil

    var id: String { url }
}

// MARK: - 工作副本 / 仓库目标

struct RepoTarget: Identifiable, Hashable, Codable {
    let id: UUID
    var location: String
    var isRemote: Bool

    init(id: UUID = UUID(), location: String, isRemote: Bool) {
        self.id = id
        self.location = location
        self.isRemote = isRemote
    }

    var name: String {
        let trimmed = location.hasSuffix("/") ? String(location.dropLast()) : location
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? location : last
    }
}

// MARK: - 状态

enum SVNItemStatus: String {
    case unversioned
    case normal
    case added
    case missing
    case deleted
    case replaced
    case modified
    case merged
    case conflicted
    case ignored
    case obstructed
    case external
    case incomplete
    case none

    init(raw: String?) {
        self = SVNItemStatus(rawValue: raw ?? "") ?? .none
    }

    var displayName: String {
        switch self {
        case .unversioned: return "未纳入版本控制"
        case .normal: return "正常"
        case .added: return "已添加"
        case .missing: return "缺失"
        case .deleted: return "已删除"
        case .replaced: return "已替换"
        case .modified: return "已修改"
        case .merged: return "已合并"
        case .conflicted: return "冲突"
        case .ignored: return "已忽略"
        case .obstructed: return "被阻挡"
        case .external: return "外部引用"
        case .incomplete: return "未完成"
        case .none: return "未知"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .modified, .merged: return "exclamationmark.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted, .missing: return "minus.circle.fill"
        case .replaced: return "arrow.2.circlepath.circle.fill"
        case .conflicted: return "exclamationmark.triangle.fill"
        case .unversioned: return "questionmark.circle.fill"
        case .ignored: return "circle.slash.fill"
        case .external: return "arrow.triangle.branch"
        case .obstructed: return "xmark.octagon.fill"
        case .incomplete: return "ellipsis.circle.fill"
        case .none: return "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .normal: return .green
        case .modified, .merged: return .red
        case .added, .replaced: return .purple
        case .deleted, .missing, .conflicted, .obstructed: return .red
        case .unversioned: return .blue
        case .ignored, .incomplete, .none: return .gray
        case .external: return .teal
        }
    }

    var priority: Int {
        switch self {
        case .conflicted, .obstructed: return 100
        case .missing, .deleted: return 80
        case .modified, .merged, .replaced: return 60
        case .added: return 50
        case .unversioned: return 40
        case .incomplete: return 30
        case .external: return 20
        case .normal: return 10
        case .ignored, .none: return 0
        }
    }

    var isChanged: Bool {
        switch self {
        case .normal, .none, .ignored, .external: return false
        default: return true
        }
    }
}

struct SVNStatusEntry: Identifiable, Hashable {
    let path: String
    let item: SVNItemStatus
    let props: String?
    let commitRevision: Int?
    let commitAuthor: String?
    let commitDate: Date?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var relativePath: String { path }
}

// MARK: - 日志

struct ChangedPath: Identifiable, Hashable {
    let action: String
    let path: String
    let copyFromPath: String?
    let copyFromRev: Int?

    var id: String { "\(action)-\(path)" }

    var actionName: String {
        switch action {
        case "A": return "新增"
        case "M": return "修改"
        case "D": return "删除"
        case "R": return "替换"
        default: return action
        }
    }

    var actionTint: Color {
        switch action {
        case "A": return .purple
        case "M": return .orange
        case "D": return .red
        case "R": return .blue
        default: return .gray
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let revision: Int
    let author: String?
    let date: Date?
    let message: String
    let paths: [ChangedPath]

    var id: Int { revision }

    var firstLine: String {
        message.split(separator: "\n").first.map(String.init) ?? ""
    }
}

struct SVNInfo: Hashable {
    let url: String?
    let repositoryRoot: String?
    let repositoryUUID: String?
    let workingCopyRoot: String?
    let revision: Int?
    let lastChangedRevision: Int?
    let lastChangedAuthor: String?
    let lastChangedDate: Date?
    let kind: String?
}

// MARK: - 版本树

struct GraphNode: Identifiable, Hashable {
    let revision: Int
    let branch: String
    let column: Int
    let row: Int
    let author: String?
    let summary: String
    let changeCount: Int
    let isCopy: Bool
    let isTag: Bool
    let isTrunk: Bool

    var id: String { "\(revision)-\(branch)" }
}

struct GraphEdge: Identifiable, Hashable {
    let fromRow: Int
    let fromColumn: Int
    let toRow: Int
    let toColumn: Int
    let isCopy: Bool

    var id: String { "\(fromRow)-\(fromColumn)-\(toRow)-\(toColumn)-\(isCopy)" }
}

struct RevisionGraph: Hashable {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var branches: [String] = []
    var rows: [Int] = []

    var isEmpty: Bool { nodes.isEmpty }
}

// MARK: - 视图标签

enum MainTab: String, CaseIterable, Identifiable {
    case files = "仓库浏览"
    case log = "提交日志"
    case graph = "版本树"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .log: return "list.bullet.rectangle"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}
