import Foundation

// MARK: - 导入已有大纲 / 设定 / 正文
// 一等支持 oh-story 目录规范（大纲/ 设定/ 正文/ 追踪/_tracking-state.json），
// 其余按通用 markdown/txt 启发式分类，全部结果由作者在导入预览里确认。

struct ImportItem: Identifiable {
    enum Kind: String {
        case chapter = "章节"
        case canon = "设定/资料"
        case outline = "大纲"
        case skip = "忽略"
    }

    var id = UUID()
    var kind: Kind
    var chapterNumber: Int?
    var title: String
    var content: String
    var sourceName: String
}

struct ImportSummary {
    var detectedLayout: String
    var items: [ImportItem] = []
    /// 从 oh-story 追踪 JSON 结构化提取
    var stages: [Stage] = []
    var clues: [Clue] = []
    var chapters: Int { items.filter { $0.kind == .chapter }.count }
    var canon: Int { items.filter { $0.kind == .canon }.count }
    var outlines: Int { items.filter { $0.kind == .outline }.count }
}

enum ImportService {
    enum Layout {
        case ohStory
        case generic
    }

    static func detectLayout(_ url: URL) -> Layout {
        let tracking = url.appendingPathComponent("追踪/_tracking-state.json")
        return FileManager.default.fileExists(atPath: tracking.path) ? .ohStory : .generic
    }

    /// 扫描目录，产出导入清单（不落库，等作者确认）
    static func scan(_ url: URL) -> ImportSummary {
        var summary = ImportSummary(detectedLayout: detectLayout(url) == .ohStory ? "oh-story 规范（追踪/_tracking-state.json 已识别）" : "通用目录")
        let fm = FileManager.default

        // oh-story：四个标准目录
        for (dirName, kind) in [("设定", ImportItem.Kind.canon), ("大纲", ImportItem.Kind.outline)] {
            let dir = url.appendingPathComponent(dirName, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["md", "txt"].contains(f.pathExtension.lowercased()) {
                    guard f.lastPathComponent.hasPrefix("_") == false else { continue }
                    if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                    summary.items.append(ImportItem(kind: kind, title: f.deletingPathExtension().lastPathComponent,
                                                    content: Disk.readText(f), sourceName: "\(dirName)/\(f.lastPathComponent)"))
                }
            }
        }
        // 递归子目录（如 大纲/第一阶段/）
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in enumerator {
                if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                let rel = f.path.replacingOccurrences(of: url.path, with: "")
                if rel.contains("/大纲/") && f.pathExtension.lowercased() == "md" {
                    let relPath = String(rel.dropFirst())
                    if !summary.items.contains(where: { $0.sourceName == relPath }) {
                        summary.items.append(ImportItem(kind: .outline, title: relPath.replacingOccurrences(of: ".md", with: ""),
                                                        content: Disk.readText(f), sourceName: relPath))
                    }
                }
            }
        }
        // 正文
        let proseDir = url.appendingPathComponent("正文", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: proseDir, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["md", "txt"].contains(f.pathExtension.lowercased()) {
                if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                if let (num, title) = parseChapterName(f.deletingPathExtension().lastPathComponent) {
                    summary.items.append(ImportItem(kind: .chapter, chapterNumber: num, title: title,
                                                    content: Disk.readText(f), sourceName: "正文/\(f.lastPathComponent)"))
                }
            }
        }
        // 追踪 JSON：结构化提取书名 / 阶段 / 活跃伏笔 / 下一章承诺
        let tracking = url.appendingPathComponent("追踪/_tracking-state.json")
        if let data = try? Data(contentsOf: tracking),
           let obj = parseTolerantJSON(data) as? [String: Any] {
            if let project = obj["project"] as? [String: Any], let title = project["title"] as? String {
                summary.items.append(ImportItem(kind: .canon, title: "追踪状态（导入摘要）",
                                                content: "原书名：\(title)。结构化伏笔/阶段已单独提取，无需手动处理。",
                                                sourceName: "追踪/_tracking-state.json"))
            }
            // 阶段
            if let stages = obj["stages_overview"] as? [[String: Any]] {
                summary.stages = stages.enumerated().compactMap { i, s in
                    guard let name = s["name"] as? String else { return nil }
                    var st = Stage(id: (s["id"] as? Int) ?? i + 1)
                    st.name = name
                    st.theme = (s["theme"] as? String) ?? (s["主题"] as? String) ?? ""
                    if let start = s["chapter_start"] as? Int { st.chapterStart = start }
                    if let end = s["chapter_end"] as? Int { st.chapterEnd = end }
                    return st
                }
            }
            // 活跃伏笔（多种可能键名，容错）
            let clueArrays = [obj["active_foreshadowing"], obj["foreshadows"], obj["伏笔"]].compactMap { $0 }
            var imported: [Clue] = []
            for entry in clueArrays {
                guard let arr = entry as? [[String: Any]] else { continue }
                for c in arr {
                    let id = (c["id"] as? String) ?? (c["编号"] as? String) ?? ""
                    let name = (c["name"] as? String) ?? (c["title"] as? String) ?? (c["内容"] as? String) ?? ""
                    guard !name.isEmpty else { continue }
                    var clue = Clue(id: id.isEmpty ? "F\(imported.count + 1)" : id, title: name)
                    clue.detail = (c["detail"] as? String) ?? (c["desc"] as? String) ?? ""
                    clue.plantedChapter = (c["planted_chapter"] as? Int) ?? (c["埋设章"] as? Int) ?? 0
                    clue.lastActionChapter = clue.plantedChapter
                    clue.status = .planted
                    clue.importance = (c["importance"] as? String) ?? "中"
                    if let q = c["planted_quote"] as? String { clue.plantedQuote = q }
                    imported.append(clue)
                }
            }
            summary.clues = imported
            // 下一章承诺 → 设定节（安全落点；作者可在骨架里引用）
            if let commit = obj["next_chapter_commitments"] as? [String: Any] {
                var lines: [String] = []
                if let n = commit["next_chapter"] as? Int {
                    lines.append("下一章：第\(n)章" + ((commit["title_suggestion"] as? String).map { "《\($0)》" } ?? ""))
                }
                if let must = commit["must_fulfill"] as? [String] {
                    lines.append("")
                    lines.append("硬交付：")
                    lines.append(contentsOf: must.map { "- \($0)" })
                }
                if !lines.isEmpty {
                    summary.items.append(ImportItem(kind: .canon, title: "下一章承诺（导入）",
                                                    content: lines.joined(separator: "\n"),
                                                    sourceName: "追踪/_tracking-state.json#next_chapter_commitments"))
                }
            }
        }

        // generic 兜底：根目录下的散文件
        if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["md", "txt"].contains(f.pathExtension.lowercased()) {
                if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                let name = f.deletingPathExtension().lastPathComponent
                if let (num, title) = parseChapterName(name) {
                    summary.items.append(ImportItem(kind: .chapter, chapterNumber: num, title: title,
                                                    content: Disk.readText(f), sourceName: f.lastPathComponent))
                } else if !summary.items.contains(where: { $0.sourceName == f.lastPathComponent }) {
                    summary.items.append(ImportItem(kind: .canon, title: name, content: Disk.readText(f), sourceName: f.lastPathComponent))
                }
            }
        }
        return summary
    }

    /// 单文件导入（拖入/选择一个 md 或 txt）
    static func scanSingleFile(_ url: URL) -> ImportSummary {
        var summary = ImportSummary(detectedLayout: "单文件")
        let name = url.deletingPathExtension().lastPathComponent
        let content = Disk.readText(url)
        if let (num, title) = parseChapterName(name) {
            summary.items.append(ImportItem(kind: .chapter, chapterNumber: num, title: title, content: content, sourceName: url.lastPathComponent))
        } else {
            summary.items.append(ImportItem(kind: .canon, title: name, content: content, sourceName: url.lastPathComponent))
        }
        return summary
    }

    /// 把确认后的清单写入库
    @MainActor
    static func apply(_ summary: ImportSummary, into store: ProjectStore) {
        for item in summary.items where item.kind != .skip {
            switch item.kind {
            case .chapter:
                let num = item.chapterNumber ?? (store.chapters.map(\.number).max() ?? 0) + 1
                if let existing = store.chapter(num), !existing.prose.isEmpty {
                    _ = store.snapshotProse(chapter: num, tag: "导入覆盖前")
                }
                _ = store.ensureChapter(num)
                store.updateChapter(num, countWords: false) {
                    $0.title = item.title
                    $0.prose = item.content
                    $0.status = .written
                }
            case .canon, .outline:
                let section = CanonSection(title: item.kind == .outline ? "大纲·\(item.title)" : item.title,
                                           content: item.content, certainty: .tentative)
                if !store.canonSections.contains(where: { $0.title == section.title }) {
                    store.canonSections.append(section)
                }
            case .skip:
                break
            }
        }
        // 结构化：阶段 + 伏笔（不覆盖已有）
        for s in summary.stages where !store.stages.contains(where: { $0.id == s.id }) {
            store.stages.append(s)
        }
        store.stages.sort { $0.id < $1.id }
        for c in summary.clues where !store.clues.contains(where: { $0.id == c.id }) {
            var clue = c
            if clue.actions.isEmpty {
                clue.actions = [ClueActionLog(chapter: max(1, clue.plantedChapter), kind: .plant, note: "导入自 oh-story 追踪")]
            }
            store.clues.append(clue)
        }
        store.clues.sort { $0.id < $1.id }
        store.project.title = store.project.title == "未命名作品" ? titleGuess(from: summary) : store.project.title
        try? store.saveNow()
    }

    /// 容错解析：oh-story 追踪 JSON 常含字符串内裸换行等非法控制字符，
    /// 先把字符串内的控制字符转义再交给严格解析器。
    static func parseTolerantJSON(_ data: Data) -> Any? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        var out = String()
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        for ch in text {
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                out.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                out.append(ch)
                continue
            }
            if inString, let scalar = ch.unicodeScalars.first, scalar.value < 0x20 {
                switch scalar.value {
                case 0x0A:
                    // 未闭合的字符串在换行处终结：先转义换行再补引号
                    out.append(contentsOf: "\\n\"")
                    inString = false
                case 0x0D:
                    out.append(contentsOf: "\\r")
                case 0x09:
                    out.append(contentsOf: "\\t")
                default:
                    out.append(" ")
                }
            } else {
                out.append(ch)
            }
        }
        text = out
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    static func titleGuess(from summary: ImportSummary) -> String {
        if let track = summary.items.first(where: { $0.sourceName.contains("_tracking-state") }),
           let range = track.content.range(of: "原书名：") {
            let rest = track.content[range.upperBound...]
            let title = String(rest.prefix(while: { $0 != "。" && $0 != "（" && $0 != "(" && !$0.isNewline }))
            if !title.isEmpty { return title }
        }
        return "导入作品"
    }

    /// 中文数字 → 阿拉伯数字（第十二章 → 12；一百二十三 → 123）
    static func chineseNumeral(_ input: String) -> Int {
        let digits: [Character: Int] = ["零": 0, "两": 2, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        // 病态文件名保护：超长汉字数字串（第壹零壹…×19）会让算术 trap（SIGTRAP 崩进程），
        // 先限长，其余一律溢出安全运算（&* / &+ 不回滚、不崩）
        guard input.count <= 12 else { return 0 }
        var total = 0
        var section = 0      // 当前"十/百"段
        var current = 0
        for ch in input {
            if let d = digits[ch] {
                current = current &* 10 &+ d
            } else if ch == "十" {
                section = section &+ (current == 0 ? 1 : current) &* 10
                current = 0
            } else if ch == "百" {
                section = section &+ (current == 0 ? 1 : current) &* 100
                current = 0
                total = total &+ section
                section = 0
            }
        }
        return total &+ section &+ current
    }

    /// 解析「第001章_血夜」「第 12 章 风起」类文件名
    static func parseChapterName(_ name: String) -> (Int, String)? {
        guard let re = try? NSRegularExpression(pattern: "第\\s*([0-9０-９一二三四五六七八九十百零两]+)\\s*章[_\\-\\s]*(.*)") else { return nil }
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        var numStr = ns.substring(with: m.range(at: 1))
        // 全角数字转半角
        let map = "０１２３４５６７８９"
        for (i, ch) in map.enumerated() {
            numStr = numStr.replacingOccurrences(of: String(ch), with: String(i))
        }
        let num: Int
        if let parsed = Int(numStr) {
            num = parsed
        } else {
            num = chineseNumeral(numStr)
        }
        guard num >= 1 else { return nil }
        var title = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "第\(num)章" }
        return (num, title)
    }
}
