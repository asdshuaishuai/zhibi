import Foundation

// MARK: - 确定性 AI 味检测（零 LLM 成本）
// 来源：Humanizer v4.1 禁用词表 + InkOS ai-tells 结构化检测 + oh-story check-ai-patterns

struct LintHit: Codable, Identifiable {
    var id: UUID = UUID()
    var kind: String        // 类别
    var detail: String      // 命中说明
    var sample: String      // 示例上下文
    var count: Int
}

struct LintSummary: Codable {
    var hits: [LintHit] = []
    /// 轻度 / 中度 / 重度
    var grade: String = "轻度"
    var bannedPerKilo: Double = 0       // 禁用词密度（/千字）
    var psychologyRatio: Double = 0     // 心理词占比
    var paragraphUniformity: Double = 0 // 段落长度变异系数（越低越"等长"越像 AI）
    var wordCount: Int = 0
    /// 全章句长标准差（sepia/中文校准：人类 ≈15.2 字 vs AI ≈12.8 字，单语料方向参考）
    var sentenceLengthSD: Double? = nil

    var topIssues: [LintHit] { hits.filter { $0.count > 0 }.sorted { $0.count > $1.count } }
}

enum AILint {
    /// 一级禁用词（出现即标记）
    static let bannedLevel1: [String] = [
        "仿佛", "犹如", "宛若", "如同", "一丝", "一抹", "些许", "几分", "隐约",
        "深吸一口气", "缓缓", "不禁", "微微", "轻轻", "淡淡",
        "眼中闪过", "嘴角勾起", "眉头微皱", "眉眼低垂", "瞳孔微缩",
        "心中一动", "心头一震", "心下了然", "心中暗道", "心底泛起", "不由得",
        "不容置疑", "不容置喙", "不易察觉", "显而易见", "毫无疑问", "不可否认",
        "不由自主", "情不自禁", "自然而然",
    ]

    /// 高频堆叠副词（一段内重复即标记）
    static let stackingAdverbs: [String] = [
        "极其", "极度", "极易", "极为", "猛地", "死死", "狠狠", "稳稳", "偏偏",
        "生生", "硬生生", "活生生", "瞬间", "下一秒", "那一秒", "立刻", "此刻",
        "此时", "紧接着", "骤然", "当场",
    ]

    /// 三字鉴定词（评论区众测公认"一眼AI"）
    static let threeCharTells: [String] = [
        "声音很平", "目光一凛", "眼神一凛", "指节泛白", "眼神复杂", "意味深长",
    ]

    /// 套话 / 填充语（直接删）
    static let fillerPhrases: [String] = [
        "值得注意的是", "需要指出的是", "不难发现", "基于以上分析", "综上所述",
        "总而言之", "不可否认的是", "毋庸置疑", "不得不说", "坦率地说",
        "客观来讲", "众所周知", "从某种意义上说", "说白了", "意味着什么",
        "换句话说", "在当今", "随着.*的(发展|推进)", "让我们来看", "先说答案",
        "掰开了揉碎了", "你品一下", "看明白了吗", "看到没有",
    ]

    /// 公式化转折词（密度高即"等距转折"）
    static let formulaicTransitions: [String] = ["然而", "与此同时", "此外", "因此", "于是", "只见", "旋即"]

    /// 心理告知词
    static let psychologyWords: [String] = ["感到", "觉得", "意识到", "心中", "心里", "内心", "情绪"]

    /// 章末预告（空泛预告钩子）
    static let foreshadowTeasers: [String] = ["他不知道的是", "她不知道的是", "殊不知", "谁也没有想到", "谁都不知道"]

    /// 双音节冗余（中文校准：单音节动词 idiomatic 处用了双音节垫话；正则兼容"进行了/作出了"）
    static let doubleSyllablePaddingPattern =
        "(进行|加以|予以|作出|做出)了?(讨论|说明|调查|研究|分析|采访|回应|处理|反驳|决定|解释|利用)"

    /// 三连排比 / 否定列举（结构模板）
    static let ruleOfThreePatterns: [String] = [
        "有的[^。\n]{1,14}有的[^。\n]{1,14}有的",
        "一边[^。\n]{1,14}一边[^。\n]{1,14}一边",
        "没有[^。，\n]{1,12}，没有[^。，\n]{1,12}，只有",
        "不是[^。\n]{1,14}，不是[^。\n]{1,14}，",
    ]

    /// 段首套话（中文编辑反馈）
    static let paragraphOpeners: [String] = ["其实", "事实上", "换句话说", "可以说", "显然"]

    static func scan(_ text: String) -> LintSummary {
        var hits: [LintHit] = []
        let charCount = max(1, WordStats.chineseCount(text))
        let kilo = Double(charCount) / 1000.0

        func countAll(_ words: [String]) -> Int {
            words.reduce(0) { $0 + text.occurrences(of: $1) }
        }

        func hit(_ kind: String, _ detail: String, _ sample: String, _ count: Int) {
            if count > 0 { hits.append(LintHit(kind: kind, detail: detail, sample: sample, count: count)) }
        }

        // 1. 一级禁用词
        var bannedTotal = 0
        var bannedSamples: [String] = []
        for w in bannedLevel1 {
            let c = text.occurrences(of: w)
            if c > 0 {
                bannedTotal += c
                if bannedSamples.count < 4 { bannedSamples.append("「\(w)」×\(c)") }
            }
        }
        hit("禁用词", "一级禁用词命中 \(bannedSamples.joined(separator: "、"))", bannedSamples.first ?? "", bannedTotal)

        // 2. "不是A而是B" 三毒 + NNY
        let notBut = text.regexMatches(of: "不是[^，。！？\\n]{1,24}[，,]?\\s*而是")
        hit("不是A而是B", "『不是…而是…』句式，需逐处判定：假靶子/同义替换/无关硬凑", notBut.first?.sample(in: text) ?? "", notBut.count)
        let nny = text.regexMatches(of: "不是[^。\\n]{1,20}。不是[^。\\n]{1,20}。只是")
        hit("NNY变体", "『不是X。不是Y。只是Z。』三连否定", nny.first?.sample(in: text) ?? "", nny.count)

        // 3. 堆叠副词（同一段内重复）
        var stackCount = 0
        var stackSample = ""
        for para in text.paragraphs {
            for w in stackingAdverbs {
                let c = para.occurrences(of: w)
                if c >= 2 {
                    stackCount += 1
                    if stackSample.isEmpty { stackSample = "「\(w)」一段内出现 \(c) 次" }
                }
            }
        }
        hit("堆叠副词", "同段内副词重复（\(stackSample)）", stackSample, stackCount)

        // 4. 三字鉴定词
        let tells = threeCharTells.reduce(0) { $0 + text.occurrences(of: $1) }
        hit("三字鉴定词", threeCharTells.first { text.occurrences(of: $0) > 0 }.map { "「\($0)」等鉴定词" } ?? "", "", tells)

        // 5. 套话
        var fillerCount = 0
        var fillerSample = ""
        for pattern in fillerPhrases {
            let c = pattern.contains(".*") ? text.regexCount(pattern) : text.occurrences(of: pattern)
            if c > 0 {
                fillerCount += c
                if fillerSample.isEmpty { fillerSample = pattern.replacingOccurrences(of: ".*", with: "…") }
            }
        }
        hit("套话填充", "科普腔/套话命中（\(fillerSample)…）", fillerSample, fillerCount)

        // 6. 转折词密度
        let transCount = formulaicTransitions.reduce(0) { $0 + text.occurrences(of: $1) }
        let transPerKilo = Double(transCount) / kilo
        if transPerKilo > 3 {
            hit("公式化转折", "转折词密度 \(String(format: "%.1f", transPerKilo))/千字（>3 判等距转折）", "", transCount)
        }

        // 7. 心理词占比
        let psyCount = psychologyWords.reduce(0) { $0 + text.occurrences(of: $1) }
        let psyRatio = Double(psyCount) / Double(max(1, charCount))
        if psyRatio > 0.01 {
            hit("心理告知", "『感到/觉得/心中』类词占比 \(String(format: "%.1f", psyRatio * 100))%——情绪要用动作外化", "", psyCount)
        }

        // 8. 章末空泛预告
        let tail = String(text.suffix(600))
        let teaser = firstTeaser(in: tail)
        hit("章末预告", teaser.isEmpty ? "" : "章末空泛预告「\(teaser)」——用具体钩子物件/事件收束", teaser, teaser.isEmpty ? 0 : 1)

        // 9. 段落等长（变异系数 < 0.15）
        let lengths = text.paragraphs.map { WordStats.chineseCount($0) }.filter { $0 > 20 }
        var cv = 1.0
        if lengths.count >= 5 {
            let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
            let variance = lengths.map { (Double($0) - mean) * (Double($0) - mean) }.reduce(0, +) / Double(lengths.count)
            cv = mean > 0 ? (variance.squareRoot()) / mean : 1.0
            if cv < 0.15 {
                hit("段落等长", "段落长度变异系数 \(String(format: "%.2f", cv))（<0.15 判段落等长）", "", lengths.count)
            }
        }

        // 10. 对话标签密度（"说道/问道"类标签占对话段比例）
        let dialogueParas = text.paragraphs.filter { $0.contains("“") || $0.contains("「") }
        let tagged = dialogueParas.filter { p in ["说道", "问道", "答道", "喊道", "说道：", "说：", "道："].contains { p.occurrences(of: $0) > 0 } }
        let tagRatio = dialogueParas.isEmpty ? 0 : Double(tagged.count) / Double(dialogueParas.count)
        if tagRatio > 0.5 {
            hit("对话标签", "对话标签密度 \(Int(tagRatio * 100))%（>50% 判机械）——用动作/上下文替代", "", tagged.count)
        }

        // 11. 句长平坦（sepia §5：连续 3+ 近等长句为候选信号；SD 仅作展示，不设武断阈值）
        var flatRuns = 0
        var sentenceSD: Double? = nil
        let sentences = text.splitChineseSentences()
        if sentences.count >= 6 {
            let lens = sentences.map { WordStats.chineseCount($0) }.filter { $0 > 0 }
            if lens.count >= 6 {
                let total = Double(lens.reduce(0, +))
                let count = Double(lens.count)
                let mean = total / count
                var variance: Double = 0
                for l in lens {
                    let d = Double(l) - mean
                    variance += d * d
                }
                variance /= count
                let sd = variance.squareRoot()
                sentenceSD = sd
                var runLen = 1
                for i in 1..<lens.count {
                    if abs(lens[i] - lens[i - 1]) <= 3 { runLen += 1 } else {
                        if runLen >= 3 { flatRuns += 1 }
                        runLen = 1
                    }
                }
                if runLen >= 3 { flatRuns += 1 }
                let sdText = String(format: "%.1f", sd)
                hit("句长平坦", "连续近等长句（±3字）\(flatRuns) 组；全章句长标准差 \(sdText)——人类参考 ≈15.2 / AI ≈12.8（单语料方向）——拆一句长的或并两句短的", "", flatRuns)
            }
        }

        // 12. 双音节冗余
        let paddingTotal = doubleSyllablePaddingPattern.regexCount(on: text)
        hit("双音节冗余", paddingTotal > 0 ? "『进行讨论/予以处理』类垫话——动词单独即可" : "", "", paddingTotal)

        // 13. 三连排比 / 否定列举
        let ro3Count = ruleOfThreePatterns.reduce(0) { $0 + $1.regexCount(on: text) }
        hit("三连排比", ro3Count > 0 ? "三连同构或否定列举——保留最强一条" : "", "", ro3Count)

        // 14. 段首套话
        let openerCount = text.paragraphs.filter { p in
            paragraphOpeners.contains { p.hasPrefix($0) }
        }.count
        hit("段首套话", openerCount > 0 ? "\(openerCount) 个段落以『其实/事实上』类开头——删掉直接说" : "", "", openerCount)

        // 分级（Humanizer 五维表 + sepia 结构信号，取最高档；注意 sepia 校准：不要把每条规则用满）
        let bannedPerKilo = Double(bannedTotal) / kilo
        var grade = "轻度"
        if bannedPerKilo > 15 || psyRatio > 0.025 || tagRatio > 0.5 { grade = "重度" }
        else if bannedPerKilo > 5 || psyRatio > 0.01 || transPerKilo > 3 || cv < 0.15
                    || flatRuns >= 2 || paddingTotal >= 3 { grade = "中度" }

        return LintSummary(hits: hits, grade: grade,
                           bannedPerKilo: bannedPerKilo,
                           psychologyRatio: psyRatio,
                           paragraphUniformity: cv,
                           wordCount: charCount,
                           sentenceLengthSD: sentenceSD)
    }

    private static func firstTeaser(in tail: String) -> String {
        foreshadowTeasers.first { tail.occurrences(of: $0) > 0 } ?? ""
    }
}

// MARK: - String helpers

private let regexCacheLock = NSLock()
private var regexCache: [String: NSRegularExpression] = [:]

func cachedRegex(_ pattern: String) -> NSRegularExpression? {
    regexCacheLock.lock()
    defer { regexCacheLock.unlock() }
    if let re = regexCache[pattern] { return re }
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    regexCache[pattern] = re
    return re
}

extension String {
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while let range = range(of: needle, options: [], range: searchStart..<endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    func regexCount(_ pattern: String) -> Int {
        guard let re = cachedRegex(pattern) else { return 0 }
        let ns = self as NSString
        return re.numberOfMatches(in: self, range: NSRange(location: 0, length: ns.length))
    }

    func regexCount(on target: String) -> Int {
        target.regexCount(self)
    }

    /// 中文切句（。！？；与对应全角）
    func splitChineseSentences() -> [String] {
        components(separatedBy: CharacterSet(charactersIn: "。！？；!?;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    struct RegexMatch { let range: Range<String.Index> }
    func regexMatches(of pattern: String) -> [Range<String.Index>] {
        guard let re = cachedRegex(pattern) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Range(m.range, in: self)
        }
    }

    /// 段落（按空行/换行切分）
    var paragraphs: [String] {
        components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension Range where Bound == String.Index {
    func sample(in text: String, context: Int = 12) -> String {
        let lower = text.index(lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
    }
}
