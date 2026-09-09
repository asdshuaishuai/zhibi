import Foundation
import AppKit

// MARK: - MarkdownLite：小说正文专用的轻量 Markdown 往返
//
// 存储权威永远是 prose.md（纯 markdown，可带走）；编辑器渲染成原生富文本（所见即所得）。
// 支持子集：标题(# ##)、粗体(**…**)、斜体(*…*)、引用(> )、分隔线(---)、段落。
// 块类型用自定义 key 存在内存属性串上，不落盘。

enum MarkdownLite {
    enum BlockKind: Int {
        case paragraph = 0
        case heading = 1
        case quote = 2
        case rule = 3
    }

    static let kindKey = NSAttributedString.Key("zb.md.kind")
    static let levelKey = NSAttributedString.Key("zb.md.level")

    // MARK: markdown → 富文本

    static func render(_ markdown: String, bodyFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraphBuffer: [String] = []

        func appendBlock(_ attr: NSAttributedString) {
            out.append(attr)
            out.append(NSAttributedString(string: "\n"))
        }

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            appendBlock(inline(paragraphBuffer.joined(separator: ""), kind: .paragraph, level: 0,
                               baseFont: bodyFont, textColor: textColor))
            paragraphBuffer = []
        }

        for line in lines {
            // 只剥半角空白判空；全角空格缩进属于正文内容
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
            if headingLevel >= 3, trimmed.dropFirst(headingLevel).hasPrefix(" ") {
                flushParagraph()
                appendBlock(inline(String(trimmed.dropFirst(headingLevel + 1)), kind: .heading, level: min(headingLevel, 6),
                                   baseFont: themedFont(base: bodyFont, bold: true, size: bodyFont.pointSize * 1.15),
                                   textColor: textColor))
            } else if headingLevel == 2, trimmed.hasPrefix("## ") {
                flushParagraph()
                appendBlock(inline(String(trimmed.dropFirst(3)), kind: .heading, level: 2,
                                   baseFont: themedFont(base: bodyFont, bold: true, size: bodyFont.pointSize * 1.22),
                                   textColor: textColor))
            } else if headingLevel == 1, trimmed.hasPrefix("# ") {
                flushParagraph()
                appendBlock(inline(String(trimmed.dropFirst(2)), kind: .heading, level: 1,
                                   baseFont: themedFont(base: bodyFont, bold: true, size: bodyFont.pointSize * 1.42),
                                   textColor: textColor))
            } else if trimmed == "---" || trimmed == "———" {
                flushParagraph()
                let rule = inline("────────", kind: .rule, level: 0,
                                  baseFont: bodyFont, textColor: textColor.withAlphaComponent(0.5))
                appendBlock(rule)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                appendBlock(inline(String(trimmed.dropFirst(2)), kind: .quote, level: 0,
                                   baseFont: bodyFont, textColor: textColor.withAlphaComponent(0.78)))
            } else {
                paragraphBuffer.append(trimmed)
            }
        }
        flushParagraph()
        return out
    }

    private static func themedFont(base: NSFont, bold: Bool, size: CGFloat) -> NSFont {
        let descriptor = bold ? base.fontDescriptor.withSymbolicTraits([.bold]) : base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    // MARK: 行内解析（token 扫描；定界符不进入输出文本 → 真正所见即所得）

    static func inline(_ text: String, kind: BlockKind, level: Int, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var bold = false
        var italic2 = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var font = baseFont
            var traits: NSFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.bold) }
            if italic2 { traits.insert(.italic) }
            if !traits.isEmpty, let f = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(traits), size: baseFont.pointSize) { font = f }
            let ps = NSMutableParagraphStyle()
            applyParagraphStyle(ps, kind: kind)
            let attr = NSAttributedString(string: buffer, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: ps,
                kindKey: kind.rawValue,
                levelKey: level,
            ])
            out.append(attr)
            buffer = ""
        }

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let ch = text[currentIndex]
            if ch == "*" {
                let next = text.index(after: currentIndex)
                let next2 = next < text.endIndex ? text.index(after: next) : nil
                if next < text.endIndex, text[next] == "*", let n2 = next2, text[n2] == "*" {
                    flush()
                    bold.toggle(); italic2.toggle()
                    currentIndex = text.index(currentIndex, offsetBy: 3)
                    continue
                }
                if next < text.endIndex, text[next] == "*" {
                    flush()
                    bold.toggle()
                    currentIndex = text.index(currentIndex, offsetBy: 2)
                    continue
                }
                flush()
                italic2.toggle()
                currentIndex = next
                continue
            }
            buffer.append(ch)
            currentIndex = text.index(after: currentIndex)
        }

        flush()
        // 段落样式兜底（空段也有 style/key）
        if out.length == 0 {
            let ps = NSMutableParagraphStyle()
            applyParagraphStyle(ps, kind: kind)
            out.setAttributes([.font: baseFont, .foregroundColor: textColor,
                               .paragraphStyle: ps, kindKey: kind.rawValue, levelKey: level],
                              range: NSRange(location: 0, length: 0))
        }
        return out
    }

    private static func applyParagraphStyle(_ ps: NSMutableParagraphStyle, kind: BlockKind) {
        switch kind {
        case .paragraph:
            ps.lineSpacing = 4.5
            ps.paragraphSpacing = 11
        case .heading:
            ps.paragraphSpacingBefore = 13
            ps.paragraphSpacing = 8
        case .quote:
            ps.headIndent = 22
            ps.firstLineHeadIndent = 22
            ps.lineSpacing = 3
            ps.paragraphSpacing = 11
        case .rule:
            ps.alignment = .center
            ps.paragraphSpacingBefore = 11
            ps.paragraphSpacing = 11
        }
    }

    // MARK: 富文本 → markdown（按 font traits 重建定界符）

    static func serialize(_ attributed: NSAttributedString) -> String {
        let ns = attributed.string as NSString
        var lines: [String] = []
        let length = ns.length
        var location = 0

        while location < length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = paraRange.upperBound
            let trimmed = trimmedRange(paraRange, in: ns)
            let raw = ns.substring(with: trimmed)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lines.last?.isEmpty != true { lines.append("") }
                continue
            }
            let kindRaw = attributed.attribute(kindKey, at: trimmed.location, effectiveRange: nil) as? Int
                ?? BlockKind.paragraph.rawValue
            let kind = BlockKind(rawValue: kindRaw) ?? .paragraph

            switch kind {
            case .rule:
                lines.append("---")
            case .heading:
                // 标题的加粗是结构性样式，不回写成行内 **；level 保留 ### 层级
                let level = attributed.attribute(levelKey, at: trimmed.location, effectiveRange: nil) as? Int ?? 1
                lines.append(String(repeating: "#", count: max(1, level)) + " " + raw)
            case .quote:
                lines.append("> " + runsMarkdown(attributed, range: trimmed))
            case .paragraph:
                lines.append(runsMarkdown(attributed, range: trimmed))
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n\n") + (lines.isEmpty ? "" : "\n")
    }

    private static func runsMarkdown(_ attributed: NSAttributedString, range: NSRange) -> String {
        var out = ""
        attributed.enumerateAttribute(.font, in: range) { value, subRange, stop in
            let text = (attributed.string as NSString).substring(with: subRange)
            guard let font = value as? NSFont, !text.isEmpty else {
                out += text
                return
            }
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            if bold && italic {
                out += "***" + text + "***"
            } else if bold {
                out += "**" + text + "**"
            } else if italic {
                out += "*" + text + "*"
            } else {
                out += text
            }
        }
        while out.contains("****") { out = out.replacingOccurrences(of: "****", with: "") }
        while out.contains("** *") { out = out.replacingOccurrences(of: "** *", with: "***") }
        return out
    }

    private static func trimmedRange(_ range: NSRange, in ns: NSString) -> NSRange {
        let raw = ns.substring(with: range)
        // 剥常规空白（含换行），但豁免全角空格 U+3000——那是中文段首缩进，必须保留
        func isTrimmed(_ ch: Character) -> Bool {
            ch.isWhitespace && ch != "\u{3000}"
        }
        let leading = raw.count - raw.drop(while: isTrimmed).count
        let trailing = raw.reversed().prefix(while: isTrimmed).count
        return NSRange(location: range.location + leading,
                       length: max(0, range.length - leading - trailing))
    }
}
