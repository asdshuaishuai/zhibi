import AppKit

// MARK: - 封面 SVG 服务层：代码提取 / 渲染 / 书架加载（CLI 与 app 共用）

enum CoverSVG {
    /// 从 AI 输出中提取 ```svg / ``` 代码块；没有围栏时尝试截取 <svg…</svg>
    static func extractSVG(_ text: String) -> String? {
        if let start = text.range(of: "```svg"), let fence = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            let code = String(text[start.upperBound..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if code.contains("<svg") { return code }
        }
        if let start = text.range(of: "<svg"), let end = text.range(of: "</svg>") {
            return String(text[start.lowerBound...end.upperBound])
        }
        return nil
    }

    /// SVG 字符串 → 指定尺寸的 NSImage（macOS 11+ NSImage 原生解 SVG；失败返回 nil）
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

/// 书架封面位图：异步解码 cover.svg → NSImage，带进程内缓存
enum ShelfCoverLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(url: URL) async -> NSImage? {
        let file = url.appendingPathComponent("cover.svg")
        let key = file.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let svg = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let renderTask = Task.detached(priority: .userInitiated) {
            CoverSVG.render(svg, width: 264, height: 364)  // @2x of 132x182
        }
        guard let img = await renderTask.value else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
