
import SwiftUI
import AppKit

/// 只读 Markdown 渲染视图（设定/大纲/提案 memo 用）
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastMarkdown: String?
        var lastFontSize: CGFloat = 0
        var textStorage: NSTextStorage?
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 显式栈：表格（NSTextTable）只在 TextKit 1 下排版
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        context.coordinator.textStorage = storage

        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 10)
        tv.font = .systemFont(ofSize: fontSize)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let c = context.coordinator
        let font = NSFont.systemFont(ofSize: fontSize)
        let color = NSColor.labelColor
        if c.lastMarkdown != markdown || c.lastFontSize != fontSize {
            c.lastMarkdown = markdown
            c.lastFontSize = fontSize
            tv.textStorage?.setAttributedString(
                MarkdownLite.render(markdown, bodyFont: font, textColor: color))
        }
    }
}
