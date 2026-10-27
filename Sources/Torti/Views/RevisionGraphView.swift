import SwiftUI

/// 修订版本图：按分支分列、按修订号排行，Canvas 精确绘制。
struct RevisionGraphView: View {
    @ObservedObject var model: RepoModel
    @State private var selectedRevision: Int?
    @State private var zoom: CGFloat = 1.0

    private let rowHeight: CGFloat = 34
    private let columnWidth: CGFloat = 150
    private let topPad: CGFloat = 34
    private let leftPad: CGFloat = 28

    private var rows: [Int] { model.graph.rows }
    private var graph: RevisionGraph { model.graph }

    private var canvasSize: CGSize {
        let columns = max(graph.branches.count, 1)
        return CGSize(width: leftPad + CGFloat(columns) * columnWidth + 150,
                      height: topPad + CGFloat(max(rows.count, 1)) * rowHeight + 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if graph.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        canvas
                            .frame(width: max(canvasSize.width * zoom, geo.size.width),
                                   height: max(canvasSize.height * zoom, geo.size.height),
                                   alignment: .topLeading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                Divider()
                footer
            }
        }
        .task {
            if model.graph.isEmpty && !model.isBusy {
                await model.refreshGraph()
            }
        }
    }

    // MARK: 顶部工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("数据源：\(model.graphSource)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Stepper("深度 \(model.graphLimit)", value: $model.graphLimit, in: 100...3000, step: 100)
                .frame(width: 170)
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 0.6...1.8).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("重新生成") { Task { await model.refreshGraph() } }
                .disabled(model.isBusy)
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("暂无版本树数据")
                .font(.headline)
            Text("从版本库根目录读取 svn log，生成 主干 / 分支 / 标签 的修订图。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("生成版本树") { Task { await model.refreshGraph() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Canvas

    private var canvas: some View {
        Canvas { context, _ in
            let s = zoom
            let points = positions(scale: s)

            // 列标题
            for (index, branch) in graph.branches.enumerated() {
                let x = (leftPad + CGFloat(index) * columnWidth) * s
                let color = branchColor(column: index, branch: branch)
                let label = Text(branch)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                context.draw(label, at: CGPoint(x: x, y: 10 * s), anchor: .leading)
            }

            // 连线
            for edge in graph.edges {
                guard let from = points[key(row: edge.fromRow, column: edge.fromColumn)],
                      let to = points[key(row: edge.toRow, column: edge.toColumn)] else { continue }
                var path = Path()
                path.move(to: from)
                if edge.fromColumn == edge.toColumn {
                    path.addLine(to: to)
                } else {
                    let midY = (from.y + to.y) / 2
                    path.addCurve(to: to,
                                  control1: CGPoint(x: from.x, y: midY),
                                  control2: CGPoint(x: to.x, y: midY))
                }
                context.stroke(path,
                               with: .color(edge.isCopy ? Color.purple.opacity(0.8) : Color.gray.opacity(0.4)),
                               lineWidth: (edge.isCopy ? 2 : 1.4) * s)
            }

            // 节点
            for node in graph.nodes {
                guard let p = points[key(row: node.row, column: node.column)] else { continue }
                let color = branchColor(column: node.column, branch: node.branch)
                if selectedRevision == node.revision {
                    let ring = CGRect(x: p.x - 9 * s, y: p.y - 9 * s, width: 18 * s, height: 18 * s)
                    context.fill(Path(ellipseIn: ring), with: .color(color.opacity(0.28)))
                }
                let dot = CGRect(x: p.x - 5.5 * s, y: p.y - 5.5 * s, width: 11 * s, height: 11 * s)
                context.fill(Path(ellipseIn: dot), with: .color(color))
                context.stroke(Path(ellipseIn: dot), with: .color(Color(nsColor: .textBackgroundColor)),
                               lineWidth: 1.5 * s)

                let rev = Text("r\(node.revision)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: .labelColor))
                context.draw(rev, at: CGPoint(x: p.x + 10 * s, y: p.y - 5 * s), anchor: .leading)

                let author = Text(node.author ?? "-")
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                context.draw(author, at: CGPoint(x: p.x + 10 * s, y: p.y + 7 * s), anchor: .leading)

                if node.isCopy {
                    let mark = Text("⑂")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)
                    context.draw(mark, at: CGPoint(x: p.x + 50 * s, y: p.y - 6 * s), anchor: .leading)
                }
            }
        }
        .background(Color.clear)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let node = nearestNode(to: value.location, scale: zoom) {
                        selectedRevision = node.revision
                    }
                }
        )
    }

    // MARK: 布局计算

    private func key(row: Int, column: Int) -> String { "\(row)-\(column)" }

    private func positions(scale: CGFloat) -> [String: CGPoint] {
        var map: [String: CGPoint] = [:]
        let count = rows.count
        for node in graph.nodes {
            let x = (leftPad + CGFloat(node.column) * columnWidth) * scale
            let y = (topPad + CGFloat(count - 1 - node.row) * rowHeight) * scale
            map[key(row: node.row, column: node.column)] = CGPoint(x: x, y: y)
        }
        return map
    }

    private func nearestNode(to point: CGPoint, scale: CGFloat) -> GraphNode? {
        let points = positions(scale: scale)
        var best: (node: GraphNode, distance: CGFloat)?
        for node in graph.nodes {
            guard let p = points[key(row: node.row, column: node.column)] else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < 26 * scale, best == nil || d < best!.distance {
                best = (node, d)
            }
        }
        return best?.node
    }

    private func branchColor(column: Int, branch: String) -> Color {
        if branch == "trunk" { return .blue }
        if branch.hasPrefix("tags/") { return .orange }
        if branch.hasPrefix("branches/") {
            let palette: [Color] = [.green, .purple, .pink, .teal, .indigo, .mint, .cyan]
            return palette[column % palette.count]
        }
        return .gray
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(graph.branches.enumerated()), id: \.offset) { index, branch in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(branchColor(column: index, branch: branch))
                                .frame(width: 8, height: 8)
                            Text(branch).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    HStack(spacing: 4) {
                        Text("⑂").font(.caption).foregroundStyle(.purple)
                        Text("分支 / 标签复制").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                }
            }
            if let rev = selectedRevision, let entry = model.logs.first(where: { $0.revision == rev }) {
                HStack(alignment: .top, spacing: 8) {
                    Text("r\(rev)").font(.system(.callout, design: .monospaced)).bold()
                    Text(entry.author ?? "(未知)").font(.callout).foregroundStyle(.secondary)
                    Text(entry.firstLine).font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(entry.paths.count) 个路径").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("点击节点查看该版本详情")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(height: 74, alignment: .top)
    }
}
