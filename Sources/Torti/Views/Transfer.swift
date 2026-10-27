import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 系统面板小工具

enum Panel {
    /// 选择一个已存在的目录
    static func chooseDirectory(prompt: String = "选择", initial: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let initial { panel.directoryURL = URL(fileURLWithPath: initial) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// 选择要上传的文件 / 文件夹（可多选）
    static func chooseFiles() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        return panel.runModal() == .OK ? panel.urls.map { $0.path } : []
    }

    /// 选择用来打开文件的应用程序（「打开方式…」）
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 另存为（导出单个文件时使用）
    static func saveFile(name: String, initial: String? = nil) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.prompt = "导出"
        if let initial { panel.directoryURL = URL(fileURLWithPath: initial) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - 检出

struct CheckoutRequest: Identifiable {
    let id = UUID()
    let url: String
}

struct CheckoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: String

    /// (目标路径, 版本号, 深度, 检出后是否加入目标列表)
    let onCheckout: (String, Int?, String, Bool) -> Void

    @State private var destination = ""
    @State private var createSubfolder = true
    @State private var useRevision = false
    @State private var revisionText = ""
    @State private var depth = "infinity"
    @State private var openAfter = true

    private let depths: [(String, String)] = [
        ("infinity", "全部（递归所有子目录）"),
        ("immediates", "仅一层子目录"),
        ("files", "仅当前目录里的文件"),
        ("empty", "仅目录本身")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("检出到…")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("来源 URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("检出到哪个目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("父目录", text: $destination)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        if let picked = Panel.chooseDirectory(prompt: "检出到", initial: destination.isEmpty ? nil : destination) {
                            destination = picked
                        }
                    }
                }
                Toggle("在里面建一个「\(folderName)」子目录", isOn: $createSubfolder)
                    .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("检出指定版本而不是最新版", isOn: $useRevision)
                    .font(.caption)
                if useRevision {
                    HStack {
                        Text("r").foregroundStyle(.secondary)
                        TextField("版本号", text: $revisionText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                HStack {
                    Text("深度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $depth) {
                        ForEach(depths, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            Toggle("检出完成后加入左侧目标列表", isOn: $openAfter)
                .font(.caption)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("检出") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(finalDestination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var folderName: String {
        URL(string: url)?.lastPathComponent ?? (url as NSString).lastPathComponent
    }

    private var finalDestination: String {
        let base = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return createSubfolder ? (base as NSString).appendingPathComponent(folderName) : base
    }

    private func submit() {
        let rev = useRevision ? Int(revisionText.trimmingCharacters(in: .whitespaces)) : nil
        onCheckout(finalDestination, rev, depth, openAfter)
        dismiss()
    }
}

// MARK: - 导出

struct ExportRequest: Identifiable {
    let id = UUID()
    let url: String
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: String
    let onExport: (String, Int?) -> Void

    @State private var destination = ""
    @State private var useRevision = false
    @State private var revisionText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出到…")
                .font(.headline)
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 6) {
                Text("导出到哪个目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("父目录", text: $destination)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        if let picked = Panel.chooseDirectory(prompt: "导出到", initial: destination.isEmpty ? nil : destination) {
                            destination = picked
                        }
                    }
                }
                Text("会在该目录里生成「\(folderName)」（导出结果不含 .svn，不能再提交）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("导出指定版本", isOn: $useRevision)
                .font(.caption)
            if useRevision {
                HStack {
                    Text("r").foregroundStyle(.secondary)
                    TextField("版本号", text: $revisionText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("导出") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(finalDestination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var folderName: String {
        URL(string: url)?.lastPathComponent ?? (url as NSString).lastPathComponent
    }

    private var finalDestination: String {
        let base = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return (base as NSString).appendingPathComponent(folderName)
    }

    private func submit() {
        let rev = useRevision ? Int(revisionText.trimmingCharacters(in: .whitespaces)) : nil
        onExport(finalDestination, rev)
        dismiss()
    }
}

// MARK: - 远程新建目录

struct NewFolderRequest: Identifiable {
    let id = UUID()
    let parent: String
}

struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let parent: String
    let onCreate: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建目录")
                .font(.headline)
            Text(parent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            TextField("目录名", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Text("会用 svn mkdir 直接在版本库里创建，并产生一次提交。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

// MARK: - 远程重命名

struct RenameRequest: Identifiable {
    let id = UUID()
    let url: String
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: String
    let onRename: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名 / 移动")
                .font(.headline)
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            TextField("新名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Text("用 svn move 在同目录内改名，直接产生一次提交。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确定") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { name = URL(string: url)?.lastPathComponent ?? "" }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}

// MARK: - 远程删除确认

struct RemoteDeleteRequest: Identifiable {
    let id = UUID()
    let paths: [String]
}

struct RemoteDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let paths: [String]
    let onDelete: (String) -> Void

    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从版本库删除")
                .font(.headline)
            Text("这些项目会被 svn delete 直接提交删除（可再用 svn log 找回历史）：")
                .font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { p in
                        Text(URL(string: p)?.lastPathComponent ?? p)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            TextField("提交说明", text: $message)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("删除", role: .destructive) {
                    onDelete(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "删除 \(paths.count) 项" : message)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 拖放辅助

/// 把 NSItemProvider 里拖进来的多个文件路径收集起来（回调可能在任意线程）
final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func add(_ path: String) {
        lock.lock(); paths.append(path); lock.unlock()
    }

    func result() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
}

/// 处理「从访达拖文件进来」：兼容 fileURL / 纯文本路径两种载荷
func collectDroppedPaths(_ providers: [NSItemProvider],
                         completion: @escaping ([String]) -> Void) {
    let box = DropCollector()
    let group = DispatchGroup()
    let urlsType = UTType.fileURL.identifier

    for provider in providers {
        let types = [urlsType, UTType.plainText.identifier, "public.url"]
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                var path: String?
                if let url = item as? URL { path = url.path }
                else if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { path = u.path }
                else if let str = item as? String, !str.isEmpty {
                    path = str.hasPrefix("file://") ? URL(string: str)?.path : str
                }
                if let path { box.add(path) }
            }
            break
        }
    }

    group.notify(queue: .main) { completion(box.result()) }
}
