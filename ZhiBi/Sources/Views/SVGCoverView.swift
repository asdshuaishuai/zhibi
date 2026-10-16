import SwiftUI
import AppKit

// MARK: - SVG 封面渲染（AI 产出 SVG 代码 → NSImage 原生绘制）
//
// macOS 11+ 的 NSImage 原生支持 SVG 解码（CoreSVG），中文 <text> 用系统字体渲染无障碍。
// ShelfCoverSVG 负责异步解码 + 位图缓存；BookCoverTile 拿到位图就优先用真封面。

enum SVGCoverRenderer {
    /// SVG 字符串 → 指定尺寸的 NSImage（失败返回 nil，调用方回退渐变封面）
    static func render(_ svg: String, width: CGFloat, height: CGFloat) -> NSImage? {
        guard let source = NSImage(data: Data(svg.utf8)) else { return nil }
        let target = NSSize(width: width, height: height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), // @2x
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: target)
        img.addRepresentation(rep)
        return img
    }
}

/// 书架封面位图：异步解码 cover.svg → NSImage，主线程回调

/// 已有 NSImage 的封面层（叠加在渐变底之上，保持圆角书形）
struct SVGCoverLayer: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
    }
}
