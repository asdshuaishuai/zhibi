import SwiftUI
import AppKit

// MARK: - 原生富文本正文编辑器（NSTextView，所见即所得）
//
// 渲染：markdown → NSAttributedString（MarkdownLite），排版即最终呈现。
// 回写：每次编辑按字体 traits 序列化回 markdown，落到 prose.md。
// 增强：AI 味命中（禁用词/堆叠副词/鉴定词等）与伏笔关键词以临时属性实时高亮，
//       临时属性不参与序列化，正文文件保持干净。

struct RichProseEditor: NSViewRepresentable {
    @Binding var markdown: String
    let baseFont: NSFont
    let textColor: NSColor
    /// 高亮词表（如活跃伏笔的标题/种下原文关键词）
    var clueNeedles: [String] = []
    /// 编辑暂停后回传一次完整 AI 味扫描结果（与高亮共用同一次后台扫描）
    var onLint: ((LintSummary) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 12)
        tv.font = baseFont
        tv.typingAttributes = [.font: baseFont, .foregroundColor: textColor]

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.textView = tv
        context.coordinator.lastSerialized = markdown
        context.coordinator.reload(markdown: markdown, baseFont: baseFont, textColor: textColor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // 外部值变化（切章/加载/快照回滚）→ 重新渲染
        if coordinator.lastSerialized != markdown {
            let selected = tv.selectedRange()
            coordinator.reload(markdown: markdown, baseFont: baseFont, textColor: textColor)
            coordinator.lastSerialized = markdown
            let maxLoc = max(0, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: min(selected.location, maxLoc), length: 0))
            coordinator.scheduleHighlights()
        }

        // 编辑后重算高亮（防抖）
        coordinator.scheduleHighlights()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichProseEditor
        weak var textView: NSTextView?
        var lastSerialized: String = ""
        private var highlightWork: DispatchWorkItem?

        init(_ parent: RichProseEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            // 新段落回归正文样式，避免标题/引用样式黏连
            let bodyFont = parent.baseFont
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 4.5
            ps.paragraphSpacing = 11
            tv.typingAttributes = [.font: bodyFont, .foregroundColor: parent.textColor, .paragraphStyle: ps]

            let md = MarkdownLite.serialize(storage)
            lastSerialized = md
            parent.markdown = md
            scheduleHighlights()
        }

        // MARK: 高亮（临时属性，不落盘）

        func scheduleHighlights() {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlights() }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        private func applyHighlights() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let text = tv.string
            // 扫描放后台：完整 LLMint 扫描与高亮词范围一次算完，主线程只落临时属性
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let summary = AILint.scan(text)
                let marks = Self.highlightRanges(text: text, clueNeedles: self?.parent.clueNeedles ?? [])
                DispatchQueue.main.async {
                    guard let self, let tv = self.textView, let lm = tv.layoutManager,
                          (tv.string as NSString).length == (text as NSString).length else { return }
                    let ns = tv.string as NSString
                    let full = NSRange(location: 0, length: ns.length)
                    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
                    lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
                    let markBackground = NSColor(ZB.vermillion).withAlphaComponent(0.16)
                    let markUnderline = NSUnderlineStyle.single.rawValue
                    let markUnderlineColor = NSColor(ZB.vermillion).withAlphaComponent(0.7)
                    let clueBackground = NSColor.systemTeal.withAlphaComponent(0.14)
                    for (range, isAITell) in marks {
                        lm.addTemporaryAttribute(.backgroundColor, value: isAITell ? markBackground : clueBackground, forCharacterRange: range)
                        if isAITell {
                            lm.addTemporaryAttribute(.underlineStyle, value: markUnderline, forCharacterRange: range)
                            lm.addTemporaryAttribute(.underlineColor, value: markUnderlineColor, forCharacterRange: range)
                        }
                    }
                    self.parent.onLint?(summary)
                }
            }
        }

        /// 单趟产出全部高亮范围：AI 味词表（true）+ 伏笔关键词（false）
        static func highlightRanges(text: String, clueNeedles: [String]) -> [(NSRange, Bool)] {
            let ns = text as NSString
            var out: [(NSRange, Bool)] = []
            var needles: [(String, Bool)] = []
            for w in AILint.bannedLevel1 + AILint.stackingAdverbs + AILint.threeCharTells + AILint.foreshadowTeasers {
                needles.append((w, true))
            }
            for n in clueNeedles where n.count >= 2 {
                needles.append((n, false))
            }
            for (needle, isAITell) in needles {
                var searchStart = 0
                while searchStart < ns.length {
                    let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                    let found = ns.range(of: needle, options: [], range: searchRange)
                    if found.location == NSNotFound { break }
                    out.append((found, isAITell))
                    searchStart = found.location + found.length
                }
            }
            return out
        }

        func reload(markdown: String, baseFont: NSFont, textColor: NSColor) {
            guard let tv = textView else { return }
            let rendered = MarkdownLite.render(markdown, bodyFont: baseFont, textColor: textColor)
            tv.textStorage?.setAttributedString(rendered)
            tv.font = baseFont
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 4.5
            ps.paragraphSpacing = 11
            tv.typingAttributes = [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: ps]
        }
    }
}
