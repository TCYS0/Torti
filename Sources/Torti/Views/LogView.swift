import SwiftUI
import AppKit

struct LogView: View {
    @ObservedObject var model: RepoModel
    @State private var authorFilter = ""
    @State private var messageFilter = ""
    @State private var onlyBranchEvents = false
    @State private var selectedRevision: Int?

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("作者", text: $authorFilter).frame(width: 110)
                TextField("提交说明包含", text: $messageFilter).frame(width: 200)
                Toggle("仅分支/标签事件", isOn: $onlyBranchEvents)
                    .toggleStyle(.checkbox)
                Stepper("最近 \(model.logLimit) 条", value: $model.logLimit, in: 50...2000, step: 50)
                    .frame(width: 180)
                if let scope = model.logScope {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        Text(model.relativePath(scope))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            Task { await model.clearLogScope() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("查看全部历史")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 260)
                }
                Spacer()
                Button("重新加载") {
                    Task {
                        if let scope = model.logScope {
                            await model.loadLog(for: scope)
                        } else {
                            await model.refreshLog()
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)

            Divider()

            HSplitView {
                List(selection: $selectedRevision) {
                    ForEach(filteredLogs) { entry in
                        LogRow(entry: entry)
                            .tag(entry.revision)
                    }
                }
                .frame(minWidth: 420)

                LogDetail(entry: selectedEntry, model: model)
                    .frame(minWidth: 320)
            }
        }
    }

    private var filteredLogs: [LogEntry] {
        model.logs.filter { entry in
            if !authorFilter.isEmpty, !(entry.author ?? "").localizedCaseInsensitiveContains(authorFilter) { return false }
            if !messageFilter.isEmpty, !entry.message.localizedCaseInsensitiveContains(messageFilter) { return false }
            if onlyBranchEvents, !entry.paths.contains(where: { $0.copyFromPath != nil }) { return false }
            return true
        }
    }

    private var selectedEntry: LogEntry? {
        model.logs.first { $0.revision == selectedRevision } ?? filteredLogs.first
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("r\(entry.revision)")
                    .font(.system(.body, design: .monospaced))
                    .bold()
                Text(entry.author ?? "(未知)")
                    .foregroundStyle(.secondary)
                Spacer()
                if let d = entry.date {
                    Text(LogView.dateFormatter.string(from: d))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.paths.contains(where: { $0.copyFromPath != nil }) {
                    Label("分支/标签", systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text("\(entry.paths.count) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(entry.firstLine)
                .lineLimit(2)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

struct LogDetail: View {
    let entry: LogEntry?
    let model: RepoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("r\(entry.revision) · \(entry.author ?? "(未知)")")
                            .font(.headline)
                        Text(entry.message.isEmpty ? "(无提交说明)" : entry.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        Text("变更路径 (\(entry.paths.count))")
                            .font(.subheadline.bold())
                        ForEach(entry.paths) { p in
                            HStack(alignment: .top, spacing: 6) {
                                Text(p.actionName)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(p.actionTint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(p.actionTint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.path)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    if let from = p.copyFromPath {
                                        Text("复制自 \(from) @ r\(p.copyFromRev ?? 0)")
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(12)
                }
                HStack {
                    Button("追溯选中文件") {
                        if let p = entry.paths.first {
                            let base = model.target.isRemote
                                ? (model.info?.repositoryRoot ?? model.graphSource)
                                : model.rootForCommands
                            Task { await model.blame(path: base + p.path) }
                        }
                    }
                    .disabled(entry.paths.isEmpty)
                    Button("复制版本号") {
                        NSPasteboard.general.setString("\(entry.revision)", forType: .string)
                    }
                    Spacer()
                }
                .padding(12)
            } else {
                VStack {
                    Spacer()
                    Text("选择一条提交查看详情")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
