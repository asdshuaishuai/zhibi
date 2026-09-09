// 生成 执笔 macOS App Icon（1024×1024，Big Sur 圆角规格）
// 设计概念：宣纸底 · 虚线骨架+关键节点（AI 搭骨架）· 实心墨迹（人写正文）· 朱砂「执」印
// 运行：swift Scripts/make_icon.swift <输出目录>

import Foundation
import CoreGraphics
import ImageIO
import CoreText

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let W = CGFloat(size)
let inset: CGFloat = 100
let contentRect = CGRect(x: inset, y: inset, width: W - 2 * inset, height: W - 2 * inset)
let radius = contentRect.width * 0.225
let roundedPath = CGPath(roundedRect: contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// MARK: 底板 + 投影

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: rgb(0x2A2318, 0.20))
ctx.addPath(roundedPath)
ctx.setFillColor(rgb(0xF7F2E7))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(roundedPath)
ctx.clip()

// 宣纸渐变
let paper = CGGradient(colorsSpace: cs, colors: [rgb(0xFBF8F0), rgb(0xF1E9D9)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: W/2, y: contentRect.maxY), end: CGPoint(x: W/2, y: contentRect.minY), options: [])

// 纸纹：极淡的横向纤维
ctx.setFillColor(rgb(0xC9BFA8, 0.10))
for i in 0..<9 {
    let y = contentRect.minY + 60 + CGFloat(i) * 86 + CGFloat((i * 37) % 23)
    ctx.fill(CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: 1.6))
}

// MARK: 毛笔笔画形状（锥形横画，中段最厚，右端顿笔）

func brushPath(centerY: CGFloat, arch: CGFloat, x0: CGFloat, x1: CGFloat,
               tipW: CGFloat, maxW: CGFloat, endW: CGFloat, droop: CGFloat) -> CGPath {
    let n = 56
    var top: [CGPoint] = []
    var bottom: [CGPoint] = []
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let x = x0 + (x1 - x0) * t
        let yc = centerY + arch * sin(.pi * t) - droop * pow(t, 2.4)
        var hw = tipW + (maxW - tipW) * pow(t, 1.35)
        if t > 0.9 { hw -= (endW) * (t - 0.9) / 0.1 }          // 右端收锋
        if t < 0.06 { hw *= 0.55 + 0.45 * (t / 0.06) }          // 起笔尖入
        top.append(CGPoint(x: x, y: yc + hw))
        bottom.append(CGPoint(x: x, y: yc - hw * 0.94))
    }
    let p = CGMutablePath()
    p.move(to: top[0])
    for pt in top.dropFirst() { p.addLine(to: pt) }
    for pt in bottom.reversed() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}

// MARK: 骨架层（AI）：圆点笔路导轨 + 三个关键节点

ctx.saveGState()
let guidePath = CGMutablePath()
guidePath.move(to: CGPoint(x: 246, y: 690))
guidePath.addQuadCurve(to: CGPoint(x: 792, y: 706),
                       control: CGPoint(x: 516, y: 728))
ctx.addPath(guidePath)
ctx.setStrokeColor(rgb(0x9A9284, 0.95))
ctx.setLineWidth(13)
ctx.setLineDash(phase: 0, lengths: [2, 34])
ctx.setLineCap(.round)
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// 关键节点：骨架上更大的实心点（落在导轨的贝塞尔曲线上）
for nx in [336.0, 516.0, 698.0] {
    let t = (nx - 246) / (792 - 246)
    let y = (1 - t) * (1 - t) * 690 + 2 * (1 - t) * t * 728 + t * t * 706
    ctx.setFillColor(rgb(0x8F8778, 1))
    ctx.fillEllipse(in: CGRect(x: nx - 12, y: y - 12, width: 24, height: 24))
}
ctx.restoreGState()

// MARK: 正文层（人）：实心墨迹

let ink = brushPath(centerY: 442, arch: 9, x0: 200, x1: 838, tipW: 4, maxW: 56, endW: 16, droop: 8)
ctx.saveGState()
ctx.addPath(ink)
ctx.clip()
let inkGrad = CGGradient(colorsSpace: cs, colors: [rgb(0x3A362E), rgb(0x14120D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(inkGrad, start: CGPoint(x: 512, y: 500), end: CGPoint(x: 512, y: 400), options: [])

// 飞白：笔画内几道纸色细痕
ctx.setStrokeColor(rgb(0xF5EFE2, 0.22))
ctx.setLineWidth(3.2)
ctx.setLineCap(.round)
for (dy, off) in [(16.0, 60.0), (6.0, 180.0), (24.0, 320.0)] {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 230 + off, y: 452 + dy))
    path.addQuadCurve(to: CGPoint(x: 700 + off * 0.5, y: 458 + dy),
                      control: CGPoint(x: 460 + off * 0.6, y: 470 + dy + 6))
    ctx.addPath(path)
    ctx.strokePath()
}
ctx.restoreGState()

// 墨迹投影（轻微，垫起层次）
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x14120D, 0.18))
ctx.addPath(ink)
ctx.setStrokeColor(rgb(0x14120D, 0.01))
ctx.setLineWidth(1)
ctx.strokePath()
ctx.restoreGState()

// MARK: 朱砂印（执）

ctx.saveGState()
ctx.translateBy(x: 706, y: 218)
ctx.rotate(by: -0.055)
let sealW: CGFloat = 148, sealH: CGFloat = 148
let sealRect = CGRect(x: -sealW/2, y: -sealH/2, width: sealW, height: sealH)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x5A1F14, 0.30))
let sealGrad = CGGradient(colorsSpace: cs, colors: [rgb(0xC64B33), rgb(0xA93226)] as CFArray, locations: [0, 1])!
ctx.addPath(CGPath(roundedRect: sealRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.clip()
ctx.drawLinearGradient(sealGrad, start: CGPoint(x: 0, y: sealH/2), end: CGPoint(x: 0, y: -sealH/2), options: [])
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// 「执」
let font = CTFontCreateWithName("PingFang SC Semibold" as CFString, 92, nil)
let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: rgb(0xFBF6EC, 0.96)] as CFDictionary
if let astr = CFAttributedStringCreate(nil, "执" as CFString, attrs) {
    let line = CTLineCreateWithAttributedString(astr)
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: -b.midX, y: -b.midY)
    CTLineDraw(line, ctx)
}
// 印章内边框
ctx.setStrokeColor(rgb(0xFBF6EC, 0.5))
ctx.setLineWidth(3.5)
let inner = sealRect.insetBy(dx: 9, dy: 9)
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.strokePath()
ctx.restoreGState()

// MARK: 内高光与外缘

ctx.saveGState()
ctx.addPath(roundedPath)
ctx.clip()
ctx.addPath(roundedPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()
ctx.addPath(roundedPath)
ctx.setStrokeColor(rgb(0x4A3D26, 0.16))
ctx.setLineWidth(2)
ctx.strokePath()

// MARK: 输出

guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let fm = FileManager.default
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outURL = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("written: \(outURL.path)")
