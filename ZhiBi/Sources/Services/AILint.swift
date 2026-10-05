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
    /// 对白字数占比（网文健康区约 25-45%；过低＝说明文腔，过高＝对白灌水）
    var dialogueRatio: Double? = nil
    /// 张力密度（动作/冲突词千字频次，CraftCodex.tensionDensity）——跨章横向比可看出注水
    var tensionDensity: Double? = nil
    /// 章末钩子是否具体（挂在物件/动作/人身上，而非抽象概念）
    var hookConcrete: Bool? = nil
    /// 抽象名词千字密度
    var abstractPerKilo: Double? = nil
    /// 情绪曲线是否平坦（四分法张力落差过小）
    var emotionCurveFlat: Bool? = nil
    /// 是否过度修正（去AI味去成了新的指纹：通篇破碎短句）
    var overCorrected: Bool? = nil

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

    /// 万能过渡句（AI 与新手共用的时间/场景填充，密度高即"转场靠套话"）
    static let universalTransitions: [String] = [
        "就在这时", "就在此时", "正当此时", "不知过了多久", "时间一分一秒", "时间仿佛静止",
        "片刻之后", "片刻后", "转眼之间", "转眼间", "翌日清晨", "第二天一早", "与此同时",
        "另一边", "话说", "且说", "却说", "不多时", "半晌", "过了许久",
    ]

    /// 认知动词堆叠（"他知道/他明白/他意识到"——把戏写成心理播报）
    static let cognitionVerbs: [String] = [
        "他知道", "她知道", "他知道", "他明白", "她明白", "他意识到", "她意识到",
        "他想起", "她想起", "他觉得", "她觉得", "他清楚", "她清楚", "他懂得",
        "心中清楚", "心里明白", "暗自思量", "心中暗想", "脑子里闪过",
    ]

    /// 抽象名词（抽象密度高＝概念先行，缺少可拍摄的东西）
    static let abstractNouns: [String] = [
        "命运", "真相", "意义", "价值", "情感", "心灵", "灵魂", "本质", "存在", "信念",
        "希望", "绝望", "孤独", "自由", "责任", "宿命", "记忆", "尊严", "勇气", "恐惧",
        "正义", "邪恶", "光明", "黑暗", "永恒", "轮回", "因果", "执念", "温暖", "冰冷",
    ]

    /// 代词段首（"他/她/我/你"开头段落占比过高＝叙述贴着一个人打转，缺少场景调度）
    static let pronounOpeners: [String] = ["他", "她", "我", "你", "它", "他们", "她们"]

    /// 时间跳跃提示（有跳跃但没有分节符＝转场缺失，读者会糊）
    static let timeJumpMarkers: [String] = [
        "三天后", "三日后", "两天后", "第二天", "翌日", "数日后", "半月后", "一个月后",
        "一年后", "多年以后", "许多年后", "当天夜里", "入夜", "天亮时",
    ]

    /// 分节符（Markdown 或空行以外的显式转场标记）
    static let sceneSeparators: [String] = ["***", "---", "◆", "◇", "※", "……"]

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
        let paragraphs = text.paragraphs   // 一次切分，第 10 项复用（原先各切一遍全文）
        let lengths = paragraphs.map { WordStats.chineseCount($0) }.filter { $0 > 20 }
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
        let dialogueParas = paragraphs.filter { $0.contains("“") || $0.contains("「") }
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

        // 15. 段首同构（连续段落以同一代词/同一个词开头 —— 叙述贴着一个人打转，是模型的强指纹）
        var pronounOpenerCount = 0
        var headCounter: [String: Int] = [:]
        for p in paragraphs {
            let head = String(p.prefix(1))
            if pronounOpeners.contains(head) { pronounOpenerCount += 1 }
            headCounter[String(p.prefix(2)), default: 0] += 1
        }
        let pronounOpenerRatio = paragraphs.isEmpty ? 0 : Double(pronounOpenerCount) / Double(paragraphs.count)
        if paragraphs.count >= 8, pronounOpenerRatio > 0.55 {
            hit("段首同构", "\(Int(pronounOpenerRatio * 100))% 的段落以人称代词开头（>55% 判同构）——换主语、换镜头、用动作或物件起段", "", pronounOpenerCount)
        }
        if let (head, cnt) = headCounter.max(by: { $0.value < $1.value }), paragraphs.count >= 10,
           cnt >= 6, Double(cnt) / Double(paragraphs.count) > 0.4 {
            hit("段首复读", "\(cnt) 个段落都以「\(head)」开头（占 \(Int(Double(cnt) / Double(paragraphs.count) * 100))%）——起段方式雷同", head, cnt)
        }

        // 16. 对白占比（网文健康区约 25-45%；过低＝说明文腔，过高＝对白灌水）
        var dialogueChars = 0
        for p in paragraphs {
            dialogueChars += dialogueCharsIn(p)
        }
        let dialogueRatio = Double(dialogueChars) / Double(max(1, charCount))
        if charCount >= 600 {
            if dialogueRatio < 0.12 {
                // count 不能传 dialogueChars：零对白时它恰好是 0，会被 hit() 的 count>0 门槛吞掉
                hit("对白过少", "对白占比 \(String(format: "%.0f", dialogueRatio * 100))%（<12%）——通篇叙述容易读成说明文，把冲突交给对白去吵", "", max(1, Int((0.12 - dialogueRatio) * 1000)))
            } else if dialogueRatio > 0.68 {
                hit("对白灌水", "对白占比 \(String(format: "%.0f", dialogueRatio * 100))%（>68%）——缺少动作与环境支点，读者会失去空间感", "", dialogueChars)
            }
        }

        // 17. 信息倾倒（连续多段无对白的纯叙述过长）
        var longestSilentRun = 0
        var currentRun = 0
        for p in paragraphs {
            if dialogueCharsIn(p) > 0 {
                longestSilentRun = max(longestSilentRun, currentRun)
                currentRun = 0
            } else {
                currentRun += WordStats.chineseCount(p)
            }
        }
        longestSilentRun = max(longestSilentRun, currentRun)
        if longestSilentRun > 900 {
            hit("信息倾倒", "最长连续无对白叙述 \(longestSilentRun) 字（>900）——插一句对白、一个动作或一次转场把它切开", "", longestSilentRun / 100)
        }

        // 18. 万能过渡句
        let transitionFiller = universalTransitions.reduce(0) { $0 + text.occurrences(of: $1) }
        let transitionFillerPerKilo = Double(transitionFiller) / kilo
        if transitionFillerPerKilo > 2.5 {
            hit("万能过渡", "『就在这时/不知过了多久』类过渡 \(transitionFiller) 处（\(String(format: "%.1f", transitionFillerPerKilo))/千字）——转场要给具体的时间地点锚点", "", transitionFiller)
        }

        // 19. 认知动词堆叠
        let cognitionCount = cognitionVerbs.reduce(0) { $0 + text.occurrences(of: $1) }
        let cognitionPerKilo = Double(cognitionCount) / kilo
        if cognitionPerKilo > 3 {
            hit("心理播报", "『他知道/他明白/他意识到』\(cognitionCount) 处（\(String(format: "%.1f", cognitionPerKilo))/千字）——把认知换成让读者自己看出来的行为", "", cognitionCount)
        }

        // 20. 抽象名词密度
        let abstractCount = abstractNouns.reduce(0) { $0 + text.occurrences(of: $1) }
        let abstractPerKilo = Double(abstractCount) / kilo
        if abstractPerKilo > 4 {
            hit("抽象先行", "抽象名词 \(abstractCount) 处（\(String(format: "%.1f", abstractPerKilo))/千字）——概念要落到具体物件与动作上（白描）", "", abstractCount)
        }

        // 21. 章末钩子强度（网文命门：钩子必须挂在具体的物件/动作/人身上）
        let tail400 = String(text.suffix(400))
        let hookEval = CraftCodex.hookConcreteness(tail400)
        if charCount >= 800, !tail400.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !hookEval.concrete {
                let why = hookEval.vague.isEmpty ? "找不到具体锚点" : "命中空泛词「\(hookEval.vague.prefix(2).joined(separator: "、"))」"
                hit("章末钩子空泛", "收尾\(why)——钩子要挂在一个可拍摄的物件、动作或人身上（CraftCodex 钩子类型学：悬念/危机/反转/信息差/承诺/情绪/登场）",
                    String(tail400.suffix(40)), 1)
            }
        }

        // 22. 情绪曲线平坦（四分法张力落差过小说明全章一个速度）
        let tension = CraftCodex.tensionDensity(text)
        var curveFlat = false
        if charCount >= 1600 {
            let quarters = quarterTensions(text)
            if quarters.count == 4 {
                let spread = (quarters.max() ?? 0) - (quarters.min() ?? 0)
                let peak = quarters.max() ?? 0
                // 落差既看绝对值也看相对峰值：全程低张力或全程同一张力都算平
                if spread < 1.5 || (peak > 0 && spread / peak < 0.35) {
                    curveFlat = true
                    hit("情绪曲线平坦", "四段张力 \(quarters.map { String(format: "%.1f", $0) }.joined(separator: " → "))——全章一个速度等于没有速度，至少安排一次节奏换挡",
                        "", Int(spread * 10))
                }
            }
        }

        // 23. 过度修正（去AI味的失败模式：把句子全打碎，形成新的"人味指纹"）
        let allLens = sentences.map { WordStats.chineseCount($0) }.filter { $0 > 0 }
        var overCorrected = false
        if allLens.count >= 10 {
            let meanLen = Double(allLens.reduce(0, +)) / Double(allLens.count)
            var v: Double = 0
            for l in allLens { let d = Double(l) - meanLen; v += d * d }
            let sdAll = (v / Double(allLens.count)).squareRoot()
            let shortRatio = Double(allLens.filter { $0 <= 6 }.count) / Double(allLens.count)
            if meanLen < 9 && sdAll < 5 && shortRatio > 0.5 {
                overCorrected = true
                hit("过度修正", "平均句长 \(String(format: "%.1f", meanLen)) 字、\(Int(shortRatio * 100))% 是 6 字以内短句——通篇破碎短句本身就是一种指纹，需要长句回来承重",
                    "", Int(meanLen))
            }
        }

        // 24. 转场缺失（有时间跳跃但没有分节符）
        let jumpCount = timeJumpMarkers.reduce(0) { $0 + text.occurrences(of: $1) }
        let hasSeparator = sceneSeparators.contains { text.contains($0) }
        if jumpCount >= 2, !hasSeparator {
            hit("转场缺失", "\(jumpCount) 处时间跳跃但没有分节符——读者会糊掉，用 *** 或空行明确切场", "", jumpCount)
        }

        // 25. 高频重复短语（同一 4 字短语反复出现＝口头禅/AI 签名句）
        if let (phrase, times) = topRepeatedQuadgram(text, minTimes: 4) {
            hit("短语复读", "「\(phrase)」一章内出现 \(times) 次——同一个修辞反复用会变成签名句", phrase, times)
        }

        // 分级（Humanizer 五维表 + sepia 结构信号 + 网文结构信号，取最高档；注意 sepia 校准：不要把每条规则用满）
        let bannedPerKilo = Double(bannedTotal) / kilo
        var grade = "轻度"
        if bannedPerKilo > 15 || psyRatio > 0.025 || tagRatio > 0.5 || cognitionPerKilo > 6 { grade = "重度" }
        else if bannedPerKilo > 5 || psyRatio > 0.01 || transPerKilo > 3 || cv < 0.15
                    || flatRuns >= 2 || paddingTotal >= 3
                    || cognitionPerKilo > 3 || abstractPerKilo > 4
                    || (charCount >= 600 && dialogueRatio < 0.12) || curveFlat
                    || longestSilentRun > 900 { grade = "中度" }

        return LintSummary(hits: hits, grade: grade,
                           bannedPerKilo: bannedPerKilo,
                           psychologyRatio: psyRatio,
                           paragraphUniformity: cv,
                           wordCount: charCount,
                           sentenceLengthSD: sentenceSD,
                           dialogueRatio: dialogueRatio,
                           tensionDensity: tension,
                           hookConcrete: charCount >= 800 ? hookEval.concrete : nil,
                           abstractPerKilo: abstractPerKilo,
                           emotionCurveFlat: curveFlat,
                           overCorrected: overCorrected)
    }

    // MARK: - 度量辅助（纯函数，可单测）

    /// 统计一行里对白引号内的字数（支持中文弯引号与直角引号）
    static func dialogueCharsIn(_ line: String) -> Int {
        var total = 0
        var stack: [Character] = []
        let pairs: [Character: Character] = ["“": "”", "「": "」", "『": "』"]
        let closers: Set<Character> = ["”", "」", "』"]
        for c in line {
            if let closer = stack.last {
                if c == closer { stack.removeLast() }   // 右引号本身不算对白内容
                else { total += 1 }
            } else if pairs[c] != nil {
                stack.append(pairs[c]!)
            } else if closers.contains(c) {
                continue    // 孤立的右引号不计
            }
        }
        return total
    }

    /// 四分法张力：把全文按字符位置切四段，各算 CraftCodex.tensionDensity
    static func quarterTensions(_ text: String) -> [Double] {
        let chars = Array(text)
        guard chars.count >= 400 else { return [] }
        let size = chars.count / 4
        return (0..<4).map { i in
            let start = i * size
            let end = (i == 3) ? chars.count : start + size
            return CraftCodex.tensionDensity(String(chars[start..<end]))
        }
    }

    /// 出现次数最多的 4 字短语（跳过含标点/空白的窗口，避免把结构性分隔算成修辞）
    static func topRepeatedQuadgram(_ text: String, minTimes: Int) -> (phrase: String, times: Int)? {
        let chars = Array(text)
        guard chars.count >= 40 else { return nil }
        var counts: [String: Int] = [:]
        let skip: Set<Character> = [" ", "\n", "\t", "，", "。", "！", "？", "、", "；", "：", "“", "”", "「", "」", "（", "）", "…"]
        for i in 0...(chars.count - 4) {
            let window = chars[i..<(i + 4)]
            if window.contains(where: { skip.contains($0) }) { continue }
            counts[String(window), default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= minTimes else { return nil }
        return (best.key, best.value)
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
