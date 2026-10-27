import SwiftUI
import AppKit

// MARK: - 命令输出（贴在文件树底部，操作结果直接可见）

struct ConsolePanel: View {
    /// model 只驱动 isBusy / 停止 / 清空；日志文本走独立的 store，
    /// 这样追加日志不会连带文件树重渲染（RepoModel 的 objectWillChange 不再因日志触发）。
    @ObservedObject var model: RepoModel
    @ObservedObject var store: ConsoleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("命令输出")
                    .font(.caption.bold())
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                    Button("停止") { model.stop() }
                        .controlSize(.mini)
                }
                Spacer()
                Button("清空") { model.clearConsole() }
                    .controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.text.isEmpty
                         ? "（在文件树里右键执行操作后，这里显示 svn 命令与输出）"
                         : store.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(store.text.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("console-bottom")
                }
                .onChange(of: store.text) { _ in
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
        }
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: - 提交窗口

struct CommitSheet: View {
    @ObservedObject var model: RepoModel
    let paths: [String]
    var onCommit: ([String], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("提交到版本库")
                    .font(.headline)
                Spacer()
                Text("已选 \(selected.count) / \(paths.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(paths, id: \.self) { path in
                        Toggle(isOn: binding(for: path)) {
                            HStack(spacing: 6) {
                                if let entry = model.statusMap[path] {
                                    Image(systemName: entry.item.symbolName)
                                        .foregroundStyle(entry.item.tint)
                                }
                                Text(model.relativePath(path))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if model.statusMap[path]?.item == .unversioned {
                                    Text("未纳管 · 提交时自动 add")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 170)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            Text("提交说明")
                .font(.subheadline.bold())
            TextEditor(text: $message)
                .font(.system(.body))
                .frame(height: 84)
                .border(Color.secondary.opacity(0.25))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("填写本次提交的说明…")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("svn commit -m …")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("提交") {
                    onCommit(selected.sorted(), message)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 580)
        .onAppear {
            if selected.isEmpty { selected = Set(paths) }
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) },
                set: { on in
                    if on { selected.insert(path) } else { selected.remove(path) }
                })
    }
}

// MARK: - 切换分支 / 标签

struct SwitchSheet: View {
    let current: String
    var onSwitch: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(current: String, onSwitch: @escaping (String) -> Void) {
        self.current = current
        self.onSwitch = onSwitch
        _text = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切换到其他分支 / 标签")
                .font(.headline)
            Text("当前：\(current)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("https://…/branches/xxx", text: $text)
                .textFieldStyle(.roundedBorder)
            Text("switch 会改动工作副本的基准 URL，未提交的本地修改可能引发冲突。")
                .font(.caption)
                .foregroundStyle(.orange)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("切换") {
                    onSwitch(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 540)
    }
}
