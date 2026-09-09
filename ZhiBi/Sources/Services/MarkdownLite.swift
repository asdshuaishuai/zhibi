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
        case listItem = 4
    }

    static let kindKey = NSAttributedString.Key("zb.md.kind")
    static let levelKey = NSAttributedString.Key("zb.md.level")
    static let markerKey = NSAttributedString.Key("zb.md.marker")
    static let codeKey = NSAttributedString.Key("zb.md.code")

    // MARK: markdown → 富文本

    static func render(_ markdown: String, bodyFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func appendBlock(_ attr: NSAttributedString) {
            out.append(attr)
            out.append(NSAttributedString(string: "\n"))
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            // 只剥半角空白判空；全角空格缩进属于正文内容。
            // 单换行不熔段：每个非空行独立成段（中文 txt 常见单换行分段形态）
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if trimmed.isEmpty {
                continue
            }
            let indentLevel = min(3, leadingSpaces / 2)
            let headingPrefix = trimmed.prefix(while: { $0 == "#" })
            let headingLevel = headingPrefix.count
            let headingRest = trimmed.dropFirst(headingLevel).drop(while: { $0 == " " })
            if (1...6).contains(headingLevel), !headingRest.isEmpty {
                appendBlock(inline(String(headingRest), kind: .heading, level: headingLevel,
                                   baseFont: themedFont(base: bodyFont, bold: true,
                                                        size: bodyFont.pointSize * (headingLevel == 1 ? 1.42 : 1.2)),
                                   textColor: textColor))
            } else if trimmed == "---" || trimmed == "———" {
                let rule = inline("────────", kind: .rule, level: 0,
                                  baseFont: bodyFont, textColor: textColor.withAlphaComponent(0.5))
                appendBlock(rule)
            } else if var list = listMarker(trimmed) {
                list.level = max(list.level, indentLevel)
                appendBlock(listAttr(list, baseFont: bodyFont, textColor: textColor))
            } else if trimmed.hasPrefix("> ") {
                appendBlock(inline(String(trimmed.dropFirst(2)), kind: .quote, level: 0,
                                   baseFont: bodyFont, textColor: textColor.withAlphaComponent(0.78)))
            } else {
                appendBlock(inline(trimmed, kind: .paragraph, level: 0,
                                   baseFont: bodyFont, textColor: textColor))
            }
        }
        return out
    }

    struct ListMarker {
        var text: String       // 去掉标记后的内容
        var marker: String     // "- " 或 "1. "
        var level: Int         // 嵌套层级（缩进/2）
    }

    /// 识别列表行：无序（- / *）、有序（1. / 1、），缩进两个空格一层
    static func listMarker(_ trimmed: String) -> ListMarker? {
        let leading = trimmed.prefix(while: { $0 == " " })
        let level = min(3, leading.count / 2)
        let body = trimmed.dropFirst(leading.count)

        if body.hasPrefix("- ") || body.hasPrefix("* ") {
            let content = String(body.dropFirst(2))
            guard !content.isEmpty else { return nil }
            return ListMarker(text: content, marker: "- ", level: level)
        }
        // 有序：数字+.（含全角顿号）
        if let re = cachedRegex("^(\\d{1,3})[.、)]\\s+(.+)$"),
           let m = re.firstMatch(in: String(body), range: NSRange(location: 0, length: (body as NSString).length)),
           m.range(at: 1).location != NSNotFound {
            let num = (body as NSString).substring(with: m.range(at: 1))
            let content = (body as NSString).substring(with: m.range(at: 2))
            return ListMarker(text: content, marker: num + ". ", level: level)
        }
        return nil
    }

    private static func listAttr(_ list: ListMarker, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let rendered = inline(list.text, kind: .listItem, level: list.level,
                              baseFont: baseFont, textColor: textColor)
        let out = NSMutableAttributedString(attributedString: rendered)
        let ps = NSMutableParagraphStyle()
        ps.headIndent = CGFloat(16 * (list.level + 1))
        ps.firstLineHeadIndent = CGFloat(16 * list.level)
        ps.lineSpacing = 3
        ps.paragraphSpacing = 5
        out.addAttribute(.paragraphStyle, value: ps,
                         range: NSRange(location: 0, length: out.length))
        out.addAttribute(markerKey, value: list.marker,
                         range: NSRange(location: 0, length: out.length))
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
            if ch == "\\" {
                // \* → 字面星号，不作为定界符
                let next = text.index(after: currentIndex)
                if next < text.endIndex, text[next] == "*" {
                    buffer.append("*")
                    currentIndex = text.index(currentIndex, offsetBy: 2)
                    continue
                }
            }
            if ch == "`" {
                // 行内代码：`code` → 等宽字体 + 浅底
                flush()
                let rest = text[currentIndex...]
                if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                    let codeText = String(rest[rest.index(after: rest.startIndex)..<close])
                    var f = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .regular)
                    let ps = NSMutableParagraphStyle()
                    applyParagraphStyle(ps, kind: kind)
                    let attr = NSAttributedString(string: codeText, attributes: [
                        .font: f,
                        .foregroundColor: textColor,
                        .backgroundColor: textColor.withAlphaComponent(0.07),
                        .paragraphStyle: ps,
                        kindKey: kind.rawValue,
                        levelKey: level,
                        codeKey: true,
                    ])
                    out.append(attr)
                    currentIndex = text.index(currentIndex, offsetBy: codeText.count + 2)
                    continue
                }
            }
            if ch == "~" {
                // 删除线 ~~text~~
                let rest = text[currentIndex...]
                if rest.hasPrefix("~~"), let close = rest.dropFirst(2).range(of: "~~") {
                    flush()
                    let strikeText = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound])
                    var font = baseFont
                    let ps = NSMutableParagraphStyle()
                    applyParagraphStyle(ps, kind: kind)
                    let attr = NSMutableAttributedString(string: strikeText, attributes: [
                        .font: font,
                        .foregroundColor: textColor,
                        .paragraphStyle: ps,
                        kindKey: kind.rawValue,
                        levelKey: level,
                    ])
                    attr.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                      range: NSRange(location: 0, length: (strikeText as NSString).length))
                    out.append(attr)
                    currentIndex = close.upperBound
                    continue
                }
            }
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
        case .paragraph, .listItem:
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
            case .listItem:
                let marker = attributed.attribute(markerKey, at: trimmed.location, effectiveRange: nil) as? String ?? "- "
                let indent = String(repeating: "  ", count: max(0, (attributed.attribute(levelKey, at: trimmed.location, effectiveRange: nil) as? Int ?? 0)))
                lines.append(indent + marker + runsMarkdown(attributed, range: trimmed))
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
        func escape(_ t: String) -> String {
            t.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "*", with: "\\*")
        }
        var out = ""
        attributed.enumerateAttributes(in: range) { (attrs: [NSAttributedString.Key: Any], subRange: NSRange, _: UnsafeMutablePointer<ObjCBool>) in
            let text = (attributed.string as NSString).substring(with: subRange)
            if (attrs[codeKey] as? Bool) == true {
                out += "`" + escape(text) + "`"
                return
            }
            if attrs[.strikethroughStyle] != nil {
                out += "~~" + escape(text) + "~~"
                return
            }
            guard let font = attrs[.font] as? NSFont, !text.isEmpty else {
                out += escape(text)
                return
            }
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            if bold && italic {
                out += "***" + escape(text) + "***"
            } else if bold {
                out += "**" + escape(text) + "**"
            } else if italic {
                out += "*" + escape(text) + "*"
            } else {
                out += escape(text)
            }
        }
        while out.contains("****") { out = out.replacingOccurrences(of: "****", with: "") }
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
