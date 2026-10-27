import Foundation
import CoreGraphics
import ImageIO

// 生成应用图标：现代 macOS 风格 —— 浅色卡片底板 + 一张紫蓝→青的渐变「版本树」。
// 每个尺寸都按矢量重新绘制（不是缩放），所以 16px 上依然清晰；小尺寸自动简化。
//
//   swiftc -O -parse-as-library tools/gen-icon.swift -o /tmp/gen-icon
//   /tmp/gen-icon /tmp/AppIcon.iconset
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns

// 渐变主色：紫蓝 → 蓝 → 青
private let cTop = (CGFloat(0.40), CGFloat(0.35), CGFloat(0.92))   // 6659EB
private let cMid = (CGFloat(0.16), CGFloat(0.60), CGFloat(0.95)) // 2A99F2
private let cEnd = (CGFloat(0.06), CGFloat(0.78), CGFloat(0.80))  // 10C7CC

private func mix(_ a: (CGFloat, CGFloat, CGFloat),
                 _ b: (CGFloat, CGFloat, CGFloat),
                 _ t: CGFloat) -> CGColor {
    let u = min(max(t, 0), 1)
    return CGColor(red: a.0 + (b.0 - a.0) * u,
                   green: a.1 + (b.1 - a.1) * u,
                   blue: a.2 + (b.2 - a.2) * u,
                   alpha: 1)
}

/// 按纵向位置取渐变色（t: 0 = 顶, 1 = 底）
private func rampColor(_ t: CGFloat) -> CGColor {
    t < 0.55 ? mix(cTop, cMid, t / 0.55) : mix(cMid, cEnd, (t - 0.55) / 0.45)
}

func renderIcon(size: Int) -> CGImage? {
    let S = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    let radius = S * 0.2237
    let bounds = CGRect(x: 0, y: 0, width: S, height: S)
    let card = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(card)
    ctx.clip()

    // --- 卡片底板：近白 → 浅蓝灰，底部压一点阴影，做出「一张纸」的层次 ---
    let paperTop = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    let paperBottom = CGColor(red: 0.905, green: 0.925, blue: 0.960, alpha: 1)
    let paper = CGGradient(colorsSpace: colorSpace,
                           colors: [paperTop, paperBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S), options: [])

    if size >= 64 {
        // 底部内阴影
        let shade = [CGColor(red: 0.35, green: 0.42, blue: 0.55, alpha: 0.001),
                     CGColor(red: 0.35, green: 0.42, blue: 0.55, alpha: 0.16)] as CFArray
        let sg = CGGradient(colorsSpace: colorSpace, colors: shade, locations: [0, 1])!
        ctx.drawLinearGradient(sg, start: CGPoint(x: 0, y: S * 0.74), end: CGPoint(x: 0, y: S), options: [])
        // 顶部内高光
        let gloss = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
                     CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        let gg = CGGradient(colorsSpace: colorSpace, colors: gloss, locations: [0, 1])!
        ctx.drawLinearGradient(gg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S * 0.18), options: [])
    }

    // --- 版本图 ---
    let simple = size <= 64
    let top = S * 0.20
    let bottom = S * 0.82
    let trunkX = S * (simple ? 0.44 : 0.37)
    let branchX = S * (simple ? 0.66 : 0.64)
    let splitY = S * 0.44
    let joinY = S * 0.60

    // 线条路径
    let lines = CGMutablePath()
    lines.move(to: CGPoint(x: trunkX, y: top))
    lines.addLine(to: CGPoint(x: trunkX, y: bottom))
    if simple {
        lines.move(to: CGPoint(x: trunkX, y: S * 0.46))
        lines.addLine(to: CGPoint(x: branchX, y: S * 0.52))
        lines.addLine(to: CGPoint(x: branchX, y: bottom))
    } else {
        lines.move(to: CGPoint(x: branchX, y: joinY))
        lines.addLine(to: CGPoint(x: branchX, y: bottom))
        // 主干 → 分支的平滑分叉
        lines.move(to: CGPoint(x: trunkX, y: splitY))
        lines.addCurve(to: CGPoint(x: branchX, y: joinY),
                       control1: CGPoint(x: trunkX + (branchX - trunkX) * 0.55, y: splitY),
                       control2: CGPoint(x: trunkX, y: joinY - (joinY - splitY) * 0.30))
    }

    // 节点（现代 git 图：实心色点 + 白色内圈）
    let nodes: [CGPoint] = simple
        ? [CGPoint(x: trunkX, y: top),
           CGPoint(x: trunkX, y: S * 0.46),
           CGPoint(x: branchX, y: bottom)]
        : [CGPoint(x: trunkX, y: top),
           CGPoint(x: trunkX, y: splitY),
           CGPoint(x: trunkX, y: bottom),
           CGPoint(x: branchX, y: joinY),
           CGPoint(x: branchX, y: bottom)]

    let lineWidth = S * (simple ? 0.085 : 0.062)
    let nodeR = S * (simple ? 0.075 : 0.060)
    let holeR = nodeR * 0.42

    // 阴影（只打在图形上，卡片本身是干净的）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: S * 0.014),
                  blur: S * 0.028,
                  color: CGColor(red: 0.15, green: 0.20, blue: 0.35, alpha: 0.30))

    // 线条：描边路径转成填充区，再灌渐变色
    ctx.saveGState()
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(lines)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let graphColors = [rampColor(0), rampColor(0.55), rampColor(1)] as CFArray
    let graphGrad = CGGradient(colorsSpace: colorSpace, colors: graphColors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(graphGrad,
                           start: CGPoint(x: 0, y: top - lineWidth),
                           end: CGPoint(x: 0, y: bottom + lineWidth), options: [])
    ctx.restoreGState()

    // 节点：按纵向位置取渐变色 + 白色内圈
    for n in nodes {
        let t = (n.y - top) / max(bottom - top, 1)
        ctx.setFillColor(rampColor(t))
        ctx.addArc(center: n, radius: nodeR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        if !simple {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
            ctx.addArc(center: n, radius: holeR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // --- 卡片细边框：让浅色图标在浅色 Dock 上也能立住 ---
    if size >= 64 {
        let inset = S * 0.006
        let frame = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
        ctx.setStrokeColor(CGColor(red: 0.72, green: 0.76, blue: 0.84, alpha: 0.9))
        ctx.setLineWidth(S * 0.012)
        ctx.addPath(frame)
        ctx.strokePath()
    }
    return ctx.makeImage()
}

func savePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

@main
struct GenIcon {
    static func main() {
        let outDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let files: [(Int, String)] = [
            (16,   "icon_16x16.png"),
            (32,   "icon_16x16@2x.png"),
            (32,   "icon_32x32.png"),
            (64,   "icon_32x32@2x.png"),
            (128,  "icon_128x128.png"),
            (256,  "icon_128x128@2x.png"),
            (256,  "icon_256x256.png"),
            (512,  "icon_256x256@2x.png"),
            (512,  "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")
        ]

        var rendered: [Int: CGImage] = [:]
        for (size, name) in files {
            let image: CGImage? = {
                if let cached = rendered[size] { return cached }
                guard let img = renderIcon(size: size) else { return nil }
                rendered[size] = img
                return img
            }()
            guard let image else {
                print("✗ 渲染失败 \(size)")
                continue
            }
            savePNG(image, to: (outDir as NSString).appendingPathComponent(name))
        }
        print("✓ 已生成 \(outDir)")
    }
}
