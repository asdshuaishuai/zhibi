import Foundation

// MARK: - 确定性验证（零 LLM 成本的部分）
// 审校只查客观错误，只报告不改正文（NarraCat continuity-editor 纪律）。

enum Validator {
    @MainActor
    static func deterministicReport(store: ProjectStore, chapter n: Int) -> ValidationReport {
        var report = ValidationReport(chapter: n)
        guard let ch = store.chapter(n) else { return report }

        // 1. 骨架覆盖
        if let sk = ch.skeleton, !sk.beats.isEmpty {
            let unfinished = sk.beats.filter { !$0.done && !$0.summary.isEmpty }
            if !unfinished.isEmpty {
                report.deterministicIssues.append(ValidationIssue(
                    severity: .note, category: "骨架覆盖",
                    message: "还有 \(unfinished.count) 个节拍未勾选完成",
                    evidence: unfinished.prefix(3).map(\.summary).joined(separator: "；"),
                    suggestion: "确认这些节点已写完可勾选；或改骨架。"))
            }
            // 2. 伏笔合同对账（计划账本 vs 正文）
            for touch in sk.clueTouches {
                guard let clue = store.clues.first(where: { $0.id == touch.clueID }) else {
                    report.deterministicIssues.append(ValidationIssue(
                        severity: .warning, category: "伏笔合同",
                        message: "骨架引用了不存在的伏笔 \(touch.clueID)",
                        evidence: touch.requirement, suggestion: "修正骨架中的伏笔编号，或在台账中补建。"))
                    continue
                }
                let needles = [clue.title] + quoteKeywords(clue.plantedQuote)
                let found = needles.contains { !$0.isEmpty && ch.prose.occurrences(of: $0) > 0 }
                if !found {
                    report.deterministicIssues.append(ValidationIssue(
                        severity: touch.action == .reveal ? .blocker : .warning,
                        category: "伏笔合同",
                        message: "[\(clue.id)] \(clue.title) 要求本章「\(touch.action.rawValue)」，但正文未见相关内容",
                        evidence: clue.plantedQuote.isEmpty ? clue.detail : clue.plantedQuote,
                        suggestion: "补写可定位的兑现段（InkOS 硬对应：必须有具体场景动作，不能只内心提及），或在本章伏笔触点里删掉这条。"))
                }
            }
        } else if ch.status != .empty && ch.prose.wordCountText > 200 {
            report.deterministicIssues.append(ValidationIssue(
                severity: .note, category: "骨架覆盖",
                message: "本章没有骨架（写前契约）",
                evidence: "", suggestion: "可让 AI 搭骨架提案后由你修改批准；纯自由写作也可忽略。"))
        }

        // 3. 过期伏笔提醒
        let overdue = store.activeClues(currentChapter: n).filter { $0.isOverdue(currentChapter: n) }
        for c in overdue.prefix(4) {
            report.deterministicIssues.append(ValidationIssue(
                severity: .warning, category: "伏笔合同",
                message: "[\(c.id)] \(c.title) 已 \(n - c.lastActionChapter) 章未推进（节奏 \(c.timing.rawValue)）",
                evidence: c.detail, suggestion: "本章推进、显式搁置、或放弃。"))
        }

        // 4. AI 味确定性扫描
        let lint = AILint.scan(ch.prose)
        report.lintSummary = lint
        for h in lint.topIssues {
            let sev: Severity = (h.kind == "禁用词" && lint.bannedPerKilo > 15) ? .warning : .note
            report.deterministicIssues.append(ValidationIssue(
                severity: sev, category: "AI味",
                message: "【\(h.kind)】\(h.detail)",
                evidence: h.sample, suggestion: "去AI味面板可逐处处理。"))
        }

        // 5. 字数
        let target = store.project.chapterWordTarget
        let wc = ch.wordCount
        if wc > 0 {
            if wc < Int(Double(target) * 0.7) {
                report.deterministicIssues.append(ValidationIssue(
                    severity: .note, category: "字数",
                    message: "本章 \(wc) 字，低于目标 \(target) 的 70%",
                    evidence: "", suggestion: "欠长不自动补写（oh-story 纪律）——扩写由你决定。"))
            } else if wc > Int(Double(target) * 1.6) {
                report.deterministicIssues.append(ValidationIssue(
                    severity: .note, category: "字数",
                    message: "本章 \(wc) 字，超出目标 \(target) 的 60%",
                    evidence: "", suggestion: "超长只净删一次，删不改剧情走向。"))
            }
        }

        // 6. 时间线：本章排期的事件若已揭示，检查正文是否覆盖揭示意图（标题级模糊核对跳过，仅提示未排期）
        let events = store.timelineEvents.filter { $0.chapter == n }
        if events.isEmpty && ch.status != .empty {
            report.deterministicIssues.append(ValidationIssue(
                severity: .note, category: "时间线",
                message: "第\(n)章没有登记任何时间线事件",
                evidence: "", suggestion: "写完后用「让 AI 记一笔」补登记，或在时间线手动添加。"))
        }

        // 7. 跨章重复（InkOS：跨章重复检测——重复句最容易造成 AI 味/水字观感）
        for rep in crossChapterRepeats(store: store, chapter: n, prose: ch.prose) {
            report.deterministicIssues.append(ValidationIssue(
                severity: .warning, category: "跨章重复",
                message: rep.message, evidence: rep.evidence,
                suggestion: "换一种写法或删一处。"))
        }

        report.checkedAt = Date()
        return report
    }

    struct RepeatFinding {
        var message: String
        var evidence: String
    }

    /// 与前 2 章的逐字重复句（≥10 字）与开头雷同检测
    @MainActor
    static func crossChapterRepeats(store: ProjectStore, chapter n: Int, prose: String) -> [RepeatFinding] {
        var findings: [RepeatFinding] = []
        let prevChapters = store.chapters.filter { $0.number < n && !$0.prose.isEmpty }.suffix(2)
        guard !prevChapters.isEmpty, !prose.isEmpty else { return findings }

        // 逐字重复句
        let sentences = prose.splitSentence().filter { $0.count >= 10 }
        for prev in prevChapters {
            let prevSet = Set(prev.prose.splitSentence())
            var hits = 0
            var sample = ""
            for s in sentences where prevSet.contains(s) {
                hits += 1
                if sample.isEmpty { sample = s }
            }
            if hits > 0 {
                findings.append(RepeatFinding(
                    message: "与第\(prev.number)章有 \(hits) 个逐字重复句（≥10字）",
                    evidence: "如：「\(String(sample.prefix(30)))…」"))
            }
        }

        // 开头雷同（与上一章开头前 12 字一致 → 容易读出 AI 的套版感）
        if let prev = prevChapters.last {
            let a = String(prose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            let b = String(prev.prose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            if a.count >= 8 && a == b {
                findings.append(RepeatFinding(
                    message: "本章开头与第\(prev.number)章开头雷同（前 12 字一致）",
                    evidence: a))
            }
        }
        return findings
    }

    /// 从种下原文提取检索关键词（取 2-6 字的词首）
    private static func quoteKeywords(_ quote: String) -> [String] {
        let clean = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 4 else { return clean.isEmpty ? [] : [clean] }
        let mid = String(clean.dropFirst(min(2, clean.count - 1)))
        let keyword = String(mid.prefix(6))
        return keyword.isEmpty ? [] : [keyword]
    }
}

extension String {
    var wordCountText: Int { WordStats.chineseCount(self) }

    /// 按中文句读切句
    func splitSentence() -> [String] {
        self.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n，,；;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
extension ProjectStore {
    /// AI 审校提案会合并到这份确定性报告之上
    func draftValidationReport(for chapter: Int) -> ValidationReport {
        Validator.deterministicReport(store: self, chapter: chapter)
    }
}
