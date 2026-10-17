// 生成 NovPool 的「不规则湖面 + 中心漩涡」图标（原创、纯色、无渐变、无黄色）。
//
// 运行：
//   swift scripts/render-blackhole-icon.swift
//
// 产物（写入 NovPoolApp/Assets/）：
//   - blackhole.png          256x256，透明背景不规则湖面（桌面悬浮图标）
//   - blackhole-template.png 36x36（18pt@2x），单色剪影，供菜单栏状态图标使用
//   - blackhole-app-1024.png 1024x1024，浅色底 + 不规则湖面（app 图标主图）
import CoreGraphics
import Foundation
import ImageIO

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "NovPoolApp/Assets", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 调色板（湖蓝/青系，无黄色）
let lakeColor = CGColor(red: 0.145, green: 0.58, blue: 0.675, alpha: 1)     // 湖面青蓝
let vortexColor = CGColor(red: 0.055, green: 0.30, blue: 0.36, alpha: 1)     // 漩涡（更深一档的青）
let appBackground = CGColor(red: 0.93, green: 0.965, blue: 0.98, alpha: 1)   // app 图标浅底

/// 不规则湖岸：半径是角度的平滑函数（固定谐波，可复现，无随机）。
func lakeRadius(_ theta: CGFloat) -> CGFloat {
    let base: CGFloat = 0.44
    let wobble = 1
        + 0.055 * sin(3 * theta + 0.6)
        + 0.040 * sin(5 * theta + 1.9)
        + 0.025 * sin(8 * theta + 0.3)
    return max(base * CGFloat(wobble), 0.04)
}

func lakePath(center: CGPoint) -> CGPath {
    let path = CGMutablePath()
    let steps = 300
    for index in 0...steps {
        let theta = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let radius = lakeRadius(theta)
        let point = CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// 中心漩涡：阿基米德螺线，由内向外两圈多一点。
func vortexPath(center: CGPoint) -> CGPath {
    let path = CGMutablePath()
    let turns: CGFloat = 2.25
    let thetaMax = turns * 2 * .pi
    let inner: CGFloat = 0.025
    let outer: CGFloat = 0.205
    let steps = 420
    for index in 0...steps {
        let progress = CGFloat(index) / CGFloat(steps)
        let theta = progress * thetaMax
        let radius = inner + (outer - inner) * progress
        let point = CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

/// 画不规则湖面 + 中心漩涡。
func drawWhirlpool(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.scaleBy(x: size, y: size)
    let center = CGPoint(x: 0.5, y: 0.5)

    context.setFillColor(lakeColor)
    context.addPath(lakePath(center: center))
    context.fillPath()

    context.setStrokeColor(vortexColor)
    context.setLineWidth(0.018)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(vortexPath(center: center))
    context.strokePath()

    context.restoreGState()
}

/// 菜单栏模板：单色剪影（湖面实心，漩涡镂空透明）。
func drawWhirlpoolTemplate(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.scaleBy(x: size, y: size)
    let center = CGPoint(x: 0.5, y: 0.5)

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.addPath(lakePath(center: center))
    context.fillPath()

    context.setBlendMode(.clear)
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.setLineWidth(0.022)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(vortexPath(center: center))
    context.strokePath()
    context.setBlendMode(.normal)

    context.restoreGState()
}

func makeContext(pixels: Int) -> CGContext {
    CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("无法创建 PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("PNG 写入失败")
    }
}

// 悬浮图标：透明背景不规则湖面
let floatingPixels = 256
let floatingContext = makeContext(pixels: floatingPixels)
floatingContext.translateBy(
    x: CGFloat(floatingPixels) * (1 - 0.94) / 2,
    y: CGFloat(floatingPixels) * (1 - 0.94) / 2
)
drawWhirlpool(in: floatingContext, size: CGFloat(floatingPixels) * 0.94)
writePNG(floatingContext.makeImage()!, to: outputDirectory.appending(path: "blackhole.png"))

// 菜单栏模板：按状态栏图标的实际显示尺寸出图（18pt@2x）并留光学边距。
// 若沿用大尺寸位图又不显式设置 NSImage.size，系统会按像素尺寸当点尺寸渲染，
// 图标在菜单栏里会明显比其他应用大一圈。
let templatePixels = 36
let templateContext = makeContext(pixels: templatePixels)
let menubarGlyph = CGFloat(templatePixels) * 0.84
templateContext.translateBy(
    x: (CGFloat(templatePixels) - menubarGlyph) / 2,
    y: (CGFloat(templatePixels) - menubarGlyph) / 2
)
drawWhirlpoolTemplate(in: templateContext, size: menubarGlyph)
writePNG(templateContext.makeImage()!, to: outputDirectory.appending(path: "blackhole-template.png"))

// app 图标：浅底 + 不规则湖面
let appPixels = 1024
let appContext = makeContext(pixels: appPixels)
appContext.setFillColor(appBackground)
appContext.fill(CGRect(x: 0, y: 0, width: CGFloat(appPixels), height: CGFloat(appPixels)))
appContext.translateBy(
    x: CGFloat(appPixels) * (1 - 0.88) / 2,
    y: CGFloat(appPixels) * (1 - 0.88) / 2
)
drawWhirlpool(in: appContext, size: CGFloat(appPixels) * 0.88)
writePNG(appContext.makeImage()!, to: outputDirectory.appending(path: "blackhole-app-1024.png"))

print("已生成：")
print("  \(outputDirectory.appending(path: "blackhole.png").path(percentEncoded: false))")
print("  \(outputDirectory.appending(path: "blackhole-template.png").path(percentEncoded: false))")
print("  \(outputDirectory.appending(path: "blackhole-app-1024.png").path(percentEncoded: false))")
