import SwiftUI
import AppKit

// MARK: - 原生富文本正文编辑器（NSTextView，所见即所得）
//
// 渲染：markdown → NSAttributedString（MarkdownLite），排版即最终呈现。
// 回写：每次编辑按字体 traits 序列化回 markdown，落到 prose.md。
// 增强：AI 味命中（禁用词/堆叠副词/鉴定词等）与伏笔关键词以临时属性实时高亮，
//       临时属性不参与序列化，正文文件保持干净。

extension Notification.Name {
    /// 保存/退出/切项目前，让所有正文编辑器立即把防抖中的文本交回 store
    static let zbFlushProseEditors = Notification.Name("ZhiBi.flushProseEditors")
}

enum ProseEditorFlush {
    /// 同步触发（NotificationCenter 在主线程同步派发）
    static func now() {
        NotificationCenter.default.post(name: .zbFlushProseEditors, object: nil)
    }
}

struct RichProseEditor: NSViewRepresentable {
    @Binding var markdown: String
    let baseFont: NSFont
    let textColor: NSColor
    /// 高亮词表（如活跃伏笔的标题/种下原文关键词）
    var clueNeedles: [String] = []
    /// 资料库命中跳转：定位 needle 首次出现的位置并选中/滚动。
    var focusNeedle: String?
    var focusToken: UUID?
    /// 编辑暂停后回传一次完整 AI 味扫描结果（与高亮共用同一次后台扫描）
    var onLint: ((LintSummary) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 显式栈：NSTextTable（真表格）只在 TextKit 1 下排版，
        // TextKit 2 会静默忽略表格块、并把临时高亮属性一并吞掉
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
        context.coordinator.layoutManager = layoutManager

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
        context.coordinator.installFlushHooks()
        context.coordinator.applyFocusIfNeeded()
        // 点击别处（失焦）也 flush：防抖窗口不再依赖用户停笔
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
                coordinator?.flushSerialize()
            }
        return scroll
    }

    /// 视图被移除（切章/切板块）时把最后 250ms 的输入同步回 store。
    /// SwiftUI 换章用 .id(n) 重建整个编辑器，没有这一步会静默丢字。
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.textView == nil { coordinator.textView = scroll.documentView as? NSTextView }
        MainActor.assumeIsolated { coordinator.flushSerialize() }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // 排版设置变化（宋体/字号）→ 重新渲染已有正文
        if coordinator.lastFont != baseFont {
            coordinator.cancelPendingSerialize()
            coordinator.lastFont = baseFont
            coordinator.reload(markdown: coordinator.lastSerialized, baseFont: baseFont, textColor: textColor)
            coordinator.scheduleHighlights()
            coordinator.applyFocusIfNeeded()
            return
        }

        // 外部值变化（切章/加载/快照回滚/采纳草稿/去AI味）→ 重新渲染
        if coordinator.lastSerialized != markdown {
            // 丢弃防抖中的旧文本：否则它会在渲染后回写 store，把刚完成的回滚/采纳覆盖掉
            coordinator.cancelPendingSerialize()
            let selected = tv.selectedRange()
            coordinator.reload(markdown: markdown, baseFont: baseFont, textColor: textColor)
            coordinator.lastSerialized = markdown
            let maxLoc = max(0, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: min(selected.location, maxLoc), length: 0))
            coordinator.scheduleHighlights()
            coordinator.applyFocusIfNeeded()
            return
        }

        // 文本与词表都未变时不重排高亮——断开自馈循环
        coordinator.scheduleHighlightsIfChanged()
        coordinator.applyFocusIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichProseEditor
        weak var textView: NSTextView?
        var textStorage: NSTextStorage?
        var layoutManager: NSLayoutManager?
        var lastSerialized: String = ""
        var lastFont: NSFont?
        private var lastNeedles: [String] = []
        private var lastHighlightText: String = ""
        private var lastLintSignature: String = ""
        private var lastFocusToken: UUID?
        /// 资料库命中后保持高亮的范围；作者一改选区/打字就撤掉。
        private var focusHighlightRange: NSRange?
        private var highlightWork: DispatchWorkItem?
        /// 大章节流的序列化（每键击全量 serialize 在 10 万字章上 ~25ms）
        private var serializeWork: DispatchWorkItem?
        /// 串长度变化超过该值（粘贴/删除大段）立即序列化，不进防抖
        private let serializeImmediateThreshold = 400

        init(_ parent: RichProseEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            // 作者开始改稿：命中定位高亮让位，避免和编辑选区抢视觉焦点
            focusHighlightRange = nil
            // 新段落回归正文样式，避免标题/引用样式黏连；
            // 表格单元格内保留单元格属性，否则打字会脱出表格
            tv.typingAttributes = Self.typingAttributes(in: tv, baseFont: parent.baseFont, textColor: parent.textColor)

            scheduleSerialize()
            scheduleHighlights()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, let focused = focusHighlightRange else { return }
            // 程序定位时选区正好等于高亮范围；作者点到别处才撤掉持续高亮。
            if tv.selectedRange() != focused {
                focusHighlightRange = nil
                scheduleHighlights()
            }
        }

        /// 序列化回 markdown：小改（逐字输入）防抖 250ms；结构性变化（大段增删/
        /// 换行数变化）与关键时机（失焦/关窗/退出）立即 flush，不丢字。
        private func scheduleSerialize() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let currentLength = storage.length
            let prevLength = lastSerialized.utf16.count
            let structural = abs(currentLength - prevLength) > serializeImmediateThreshold
            if structural {
                serializeNow()
                return
            }
            serializeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.serializeNow() }
            serializeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func cancelPendingSerialize() {
            serializeWork?.cancel()
            serializeWork = nil
        }

        /// 立即序列化并回传（保存/退出的唯一 flush 点）
        func flushSerialize() {
            serializeWork?.cancel()
            serializeWork = nil
            serializeNow()
        }

        private func serializeNow() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let md = MarkdownLite.serialize(storage)
            if md == lastSerialized { return }
            lastSerialized = md
            parent.markdown = md
        }

        /// 编辑器被移除/窗口关闭/失焦：把最后 250ms 的输入立刻落进 store
        func installFlushHooks() {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.flushSerialize()
                }
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.flushSerialize()
                }
            // 宿主保存前主动 flush（⌘S / 关闭项目 / 退出）：willTerminate 排在保存之后，
            // 只靠它会让最后一次保存漏掉防抖窗口里的字。
            NotificationCenter.default.addObserver(
                forName: .zbFlushProseEditors, object: nil, queue: .main) { [weak self] _ in
                    self?.flushSerialize()
                }
        }

        static func typingAttributes(in tv: NSTextView, baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
            let loc = tv.selectedRange().location - 1
            if loc >= 0, let storage = tv.textStorage, storage.length > loc,
               storage.attributes(at: loc, effectiveRange: nil)[MarkdownLite.tableRowIndexKey] != nil {
                return storage.attributes(at: loc, effectiveRange: nil)
            }
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 4.5
            ps.paragraphSpacing = 11
            return [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: ps]
        }

        /// 资料库命中跳转：只消费一次 token，避免每次 updateNSView 都抢选区。
        func applyFocusIfNeeded() {
            guard let token = parent.focusToken, token != lastFocusToken else { return }
            lastFocusToken = token
            guard let tv = textView, let needle = parent.focusNeedle,
                  let range = KnowledgeFocus.range(of: needle, in: tv.string) else { return }
            focusHighlightRange = range
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
            tv.showFindIndicator(for: range)
            scheduleHighlights()
        }

        // MARK: 高亮（临时属性，不落盘）

        func scheduleHighlights() {
            scheduleHighlightsIfChanged(force: true)
        }

        /// 文本与词表都未变化时不排程——断开 onLint→重渲染→重扫描的自馈循环
        func scheduleHighlightsIfChanged(force: Bool = false) {
            let text = textView?.string ?? ""
            let needles = parent.clueNeedles
            if !force, text == lastHighlightText, needles == lastNeedles { return }
            lastHighlightText = text
            lastNeedles = needles
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlights() }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        private func applyHighlights() {
            // TextKit 1 下 layoutManager 恒有；缺失说明视图未就绪，直接跳过
            guard let tv = textView, tv.layoutManager != nil else { return }
            let text = tv.string
            let needles = parent.clueNeedles
            // 扫描放后台：完整扫描与高亮词范围一次算完，主线程只落临时属性
            DispatchQueue.global(qos: .utility).async {
                let summary = AILint.scan(text)
                let marks = Self.highlightRanges(text: text, clueNeedles: needles)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tv = self.textView, let lm = tv.layoutManager,
                          tv.string == text else { return }
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
                    // 资料库命中定位：持续蓝色高亮，直到作者移动选区或开始打字
                    if let focused = self.focusHighlightRange, NSMaxRange(focused) <= ns.length {
                        lm.addTemporaryAttribute(.backgroundColor,
                                                 value: NSColor.systemBlue.withAlphaComponent(0.18),
                                                 forCharacterRange: focused)
                        lm.addTemporaryAttribute(.underlineStyle, value: markUnderline,
                                                 forCharacterRange: focused)
                        lm.addTemporaryAttribute(.underlineColor,
                                                 value: NSColor.systemBlue.withAlphaComponent(0.75),
                                                 forCharacterRange: focused)
                    }
                    // 签名去重：结果无变化不回写，避免 onLint→重渲染→重扫描的自馈循环
                    let signature = "\(summary.grade)|\(summary.topIssues.map { "\($0.kind):\($0.count)" }.joined(separator: ","))|\(summary.wordCount)"
                    if signature != self.lastLintSignature {
                        self.lastLintSignature = signature
                        self.parent.onLint?(summary)
                    }
                }
            }
        }

        /// 单趟产出全部高亮范围：AI 味词表（true）+ 伏笔关键词（false）
        static func highlightRanges(text: String, clueNeedles: [String]) -> [(NSRange, Bool)] {
            let ns = text as NSString
            var out: [(NSRange, Bool)] = []
            // 词表去重（ banned/adverbs/tells/teasers 有交叉）+ clue needles 合并成一张表一趟扫
            var seen = Set<String>()
            var needles: [(String, Bool)] = []
            for w in AILint.bannedLevel1 + AILint.stackingAdverbs + AILint.threeCharTells + AILint.foreshadowTeasers
            where !seen.contains(w) {
                seen.insert(w)
                needles.append((w, true))
            }
            for n in clueNeedles where n.count >= 2 && !seen.contains(n) {
                seen.insert(n)
                needles.append((n, false))
            }
            // 长 needle 优先：短词命中不吞掉长词（「不由得」vs「由」）
            needles.sort { $0.0.count > $1.0.count }
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
            lastFont = baseFont
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 4.5
            ps.paragraphSpacing = 11
            tv.typingAttributes = [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: ps]
        }
    }
}
