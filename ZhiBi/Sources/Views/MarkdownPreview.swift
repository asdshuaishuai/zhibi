
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
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
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
