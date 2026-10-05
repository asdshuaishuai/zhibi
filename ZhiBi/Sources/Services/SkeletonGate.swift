import Foundation

// MARK: - 骨架质量闸门（SkeletonGate）
//
// 骨架是「写前契约」。契约写得含糊，后面每一步（草稿、审查、伏笔对账）都要靠猜。
// 这里用确定性代码在作者批准骨架之前先过一遍闸门：该章到期该收的伏笔有没有进合同、
// 钩子是否具体、揭 1 埋 1 是否成立、场景层是否可执行、视角有没有漂移、字数预算是否合理。
//
// 只报告不代改——打分与问题清单挂在骨架提案上，作者可以照单改，也可以直接无视。
// 零 LLM 成本。

enum SkeletonGate {
    struct GateIssue: Identifiable {
        var id: String { code }
        var code: String
        var severity: Severity
        var message: String
        var suggestion: String
    }

    struct Report {
        var chapter: Int = 0
        var issues: [GateIssue] = []
        /// 0-100，供 UI 显示；不是通过率，是「这份骨架作为写前契约的可执行度」
        var score: Int = 0
        var plantCount: Int = 0
        var developCount: Int = 0
        var revealCount: Int = 0
        /// 本章到期/过期却在合同里的伏笔
        var dueCovered: [String] = []
        /// 本章到期/过期但合同里没提的伏笔
        var dueMissed: [String] = []
        var hookKind: String = ""
        var hookConcrete: Bool = false
        var wordsPlanned: Int = 0
        /// 近几章用过的钩子形态（判断是否连续同型 → 套版感）
        var recentHookKinds: [String] = []

        var blockers: [GateIssue] { issues.filter { $0.severity == .blocker } }
        var warnings: [GateIssue] { issues.filter { $0.severity == .warning } }

        /// 人话总结（一行）
        var summary: String {
            let b = blockers.count, w = warnings.count
            if b == 0 && w == 0 { return "骨架可执行度 \(score)/100，没查出问题。" }
            return "骨架可执行度 \(score)/100：\(b) 项必须先处理，\(w) 项建议处理。"
        }
    }

    /// 字数预算容差：合计建议字数与目标字数偏差超过这个比例就提醒
    static let wordBudgetTolerance = 0.4
    /// 场景层完整度低于这个值就提醒（骨架可以只有节拍，但那样审查环节取证会变弱）
    static let sceneCompletenessFloor = 0.5
    /// 连续多少章用同一种钩子形态算套版
    static let hookRepeatLimit = 3

    @MainActor
    static func evaluate(_ sk: ChapterSkeleton, store: ProjectStore, chapter n: Int,
                         targetWords: Int? = nil) -> Report {
        let target = targetWords ?? store.project.chapterWordTarget
        var r = Report(chapter: n)
        var penalty = 0

        func issue(_ code: String, _ sev: Severity, _ msg: String, _ fix: String) {
            r.issues.append(GateIssue(code: code, severity: sev, message: msg, suggestion: fix))
        }

        // 1. 节拍数量：太少撑不起一章，太多写不完（3-6 是 InkOS 的经验区间）
        if sk.beats.count < 3 {
            issue("beats.tooFew", .warning, "只有 \(sk.beats.count) 个节拍，\(target) 字的章节撑不满", "补到 3-6 拍，或把这一拍拆成「当下目标→阻力→转折」三步")
            penalty += 8
        } else if sk.beats.count > 6 {
            issue("beats.tooMany", .warning, "\(sk.beats.count) 个节拍偏多，容易写成流水账", "合并到 6 拍以内，把过渡拍并进相邻的推进拍")
            penalty += 6
        }

        // 2. 节拍可辨识度：一句话太短的节拍无法执行
        let thinBeats = sk.beats.filter { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 }
        if !thinBeats.isEmpty {
            issue("beats.tooThin", .warning, "\(thinBeats.count) 个节拍写得太笼统（不足 8 字），照着写会跑偏",
                  "每拍写清「谁、在哪、要什么、被什么挡住、结果变成什么」")
            penalty += 4 * thinBeats.count
        }

        // 3. 功能定位分布：全章都是"过渡"就是注水
        let purposes = sk.beats.map { $0.purpose.trimmingCharacters(in: .whitespacesAndNewlines) }
        let emptyPurpose = purposes.filter { $0.isEmpty }.count
        if emptyPurpose > 0 {
            issue("beats.noPurpose", .note, "\(emptyPurpose) 个节拍没有功能定位", "标上：推进/爽点/埋伏笔/收钩子/情绪/过渡")
            penalty += 2 * emptyPurpose
        }
        let transitionOnly = purposes.filter { $0.contains("过渡") }.count
        if sk.beats.count >= 3, transitionOnly * 2 > sk.beats.count {
            issue("beats.allTransition", .warning, "\(transitionOnly)/\(sk.beats.count) 个节拍都是过渡——本章没有实质推进",
                  "至少让一拍承担「推进」或「爽点」，把读者等了最久的那件事往前挪一步")
            penalty += 12
        }

        // 4. 转折：没有转折的拍是过场
        let noTurn = sk.beats.filter { $0.turn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if noTurn == sk.beats.count, sk.beats.count > 0 {
            issue("beats.noTurn", .note, "所有节拍都没写「转折」——读者看不出这一章改变了什么",
                  "每拍补一句从什么变成什么（起承转合的「转」）")
            penalty += 6
        }

        // 5. 章尾钩子：必须存在、必须具体、不能连续同型
        let hookText = sk.endHook.trimmingCharacters(in: .whitespacesAndNewlines)
        if hookText.isEmpty {
            issue("hook.missing", .blocker, "没有章尾钩子——网文断章是留住读者的命门",
                  "写清收在什么画面、指向哪里；从七种形态里选一种：" + HookKind.allCases.map(\.rawValue).joined(separator: "/"))
            penalty += 20
            r.hookConcrete = false
        } else {
            let eval = CraftCodex.hookConcreteness(hookText)
            r.hookConcrete = eval.concrete
            if !eval.concrete {
                let why = eval.vague.isEmpty ? "找不到具体锚点（物件/动作/人）" : "命中空泛词「\(eval.vague.prefix(2).joined(separator: "、"))」"
                issue("hook.vague", .warning, "章尾钩子\(why)",
                      "把钩子挂在一个能拍成镜头的东西上；参考钩子类型学与各自的翻车方式")
                penalty += 10
            }
            // 分类钩子形态（作者没填就用确定性分类兜底）
            r.hookKind = sk.hookKind.isEmpty ? (CraftCodex.classifyHook(hookText)?.rawValue ?? "") : sk.hookKind
            // 钩子形态轮换：连续同型会形成可预测的套版感
            let recent = previousHookKinds(store: store, before: n, limit: hookRepeatLimit)
            r.recentHookKinds = recent
            if !r.hookKind.isEmpty, recent.count >= hookRepeatLimit,
               recent.suffix(hookRepeatLimit - 1).allSatisfy({ $0 == r.hookKind }) {
                issue("hook.repeated", .warning,
                      "连续 \(hookRepeatLimit) 章都用「\(r.hookKind)」型钩子，读者已经能预测章末了",
                      "换一种形态：" + HookKind.allCases.filter { $0.rawValue != r.hookKind }.map(\.rawValue).joined(separator: "/"))
                penalty += 8
            }
        }

        // 6. 伏笔触点合同：揭 1 埋 1 + 到期账必须进合同
        r.plantCount = sk.clueTouches.filter { $0.action == .plant }.count
        r.developCount = sk.clueTouches.filter { $0.action == .develop }.count
        r.revealCount = sk.clueTouches.filter { $0.action == .reveal || $0.action == .resolve }.count
        if r.revealCount > 0 && r.plantCount == 0 {
            issue("clue.noPlant", .warning, "本章收了 \(r.revealCount) 个伏笔但没埋新的——账越收越空，后劲会断",
                  "揭 1 埋 1：至少挂一个新钩子（新伏笔用 propose_clues 登记，或写进 clue_touches 的 plant）")
            penalty += 10
        }
        let due = store.activeClues(currentChapter: n).filter { $0.isOverdue(currentChapter: n) }
        let touched = Set(sk.clueTouches.map(\.clueID))
        r.dueCovered = due.filter { touched.contains($0.id) }.map(\.id)
        r.dueMissed = due.filter { !touched.contains($0.id) }.map(\.id)
        if !r.dueMissed.isEmpty {
            let names = due.filter { r.dueMissed.contains($0.id) }.prefix(3)
                .map { "[\($0.id)] \($0.title)（已 \(n - $0.lastActionChapter) 章未动）" }.joined(separator: "；")
            issue("clue.dueMissed", .warning, "有 \(r.dueMissed.count) 条到期伏笔本章合同里没提：\(names)",
                  "本章推进它、或在触点里显式标 defer（搁置）让告警停下——烂在账上最伤读者信任")
            penalty += 6 * r.dueMissed.count
        }

        // 7. 触点引用的伏笔必须存在，且动作不能与台账状态矛盾
        for t in sk.clueTouches {
            guard let clue = store.clues.first(where: { $0.id == t.clueID }) else {
                issue("clue.orphan.\(t.clueID)", .warning, "触点引用了台账里不存在的伏笔 \(t.clueID)",
                      "改编号，或先用 propose_clues 把它登记进台账")
                penalty += 6
                continue
            }
            if t.action == .plant && clue.plantedChapter > 0 && clue.plantedChapter < n {
                issue("clue.replant.\(t.clueID)", .note, "[\(clue.id)] 第\(clue.plantedChapter)章已经埋过，本章再标 plant 会重复埋设",
                     "改成 develop/reveal，或这确实是二次强调就写清 requirement")
                penalty += 3
            }
            if (t.action == .reveal || t.action == .resolve) && clue.status == .resolved {
                issue("clue.reresolve.\(t.clueID)", .warning, "[\(clue.id)] 台账里已是「已回收」，本章又要揭示一次",
                     "确认是不是同一条伏笔；台账记错了就先修台账")
                penalty += 6
            }
            if t.requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issue("clue.noRequirement.\(t.clueID)", .note, "[\(clue.id)] 的触点没写硬要求，审查时无从判定是否兑现",
                      "写清本章对这条伏笔具体要做到什么（可定位的场景动作，不是内心提及）")
                penalty += 3
            }
        }

        // 8. 硬交付与禁止项
        if sk.mustDeliver.isEmpty {
            issue("deliver.missing", .warning, "没有硬交付项——这章「必须兑现的那件事」没写下来，草稿会自由发挥",
                  "写 1-3 条读者等了最久、本章必须兑现或明确推进的事")
            penalty += 8
        }
        if sk.mustAvoid.isEmpty {
            issue("avoid.missing", .note, "没有禁止项",
                  "至少加一条反指纹约束，例如「结尾不要『决定+接纳+成长』三连」「章末不写主题总结」")
            penalty += 3
        } else if !sk.mustAvoid.joined().contains("三连") && !sk.mustAvoid.joined().contains("总结") {
            issue("avoid.noAntiFingerprint", .note, "禁止项里没有反 AI 指纹的约束",
                  "加一条「结尾不要决定+接纳+成长三连」或「章末不写主题总结」——这是模型最强的结局指纹")
            penalty += 2
        }

        // 9. 字数预算
        r.wordsPlanned = sk.beats.reduce(0) { $0 + $1.suggestedWords }
        if r.wordsPlanned > 0 {
            let dev = abs(Double(r.wordsPlanned - target)) / Double(max(1, target))
            if dev > wordBudgetTolerance {
                issue("words.budget", .warning,
                      "各拍建议字数合计 \(r.wordsPlanned)，与目标 \(target) 偏差 \(Int(dev * 100))%",
                      r.wordsPlanned > target ? "砍掉次要拍或压缩过渡拍" : "补拍，或把关键戏写足（欠长不自动补写，但骨架要先算对）")
                penalty += 6
            }
        } else {
            issue("words.none", .note, "没有任何节拍标了建议字数，无法核对篇幅分配", "给主要拍标上字数，过渡拍可以少")
            penalty += 2
        }

        // 10. 场景层：视角一致性、在场冲突、完整度
        if sk.beats.contains(where: { !$0.pov.isEmpty }) {
            let povs = Set(sk.beats.map { $0.pov.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if povs.count > 1 {
                issue("scene.povDrift", .warning,
                      "本章出现 \(povs.count) 个视角人物（\(povs.sorted().joined(separator: "、"))）——一章内视角漂移是最常见的连贯性事故",
                      "统一到一个视角，或明确分节换视角并在 mustDeliver 里写清切点")
                penalty += 10
            }
        }
        // 同一时间标记下同一人物出现在两个地点 = 物理不可能
        var seen: [String: Set<String>] = [:]
        var castConflicts: [String] = []
        for b in sk.beats {
            let key = b.timeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !b.location.isEmpty else { continue }
            for person in b.cast {
                // 必须按「人 + 时间标记」建键：只按人建键会把不同时间的正常换场景误判成分身两地
                let pk = person + "|" + key
                let loc = seen[pk] ?? []
                if !loc.isEmpty && !loc.contains(b.location) {
                    castConflicts.append("\(person)（\(loc.sorted().joined(separator: "/")) 与 \(b.location)，同在「\(key)」）")
                }
                seen[pk, default: []].insert(b.location)
            }
        }
        if !castConflicts.isEmpty {
            issue("scene.castConflict", .blocker, "同一时间有人分身两地：\(castConflicts.prefix(2).joined(separator: "；"))",
                  "错开时间标记，或改地点/出场人物")
            penalty += 15
        }
        let avgScene = sk.beats.isEmpty ? 0 : sk.beats.map(\.sceneCompleteness).reduce(0, +) / Double(sk.beats.count)
        if avgScene < sceneCompletenessFloor && avgScene > 0 {
            issue("scene.thin", .note,
                  "场景层只填了 \(Int(avgScene * 100))%（视角/地点/时间/出场/转折）",
                  "填满场景层之后，连贯性审查能查到分身两地与视角漂移，草稿也不会靠猜空间关系")
            penalty += 4
        } else if avgScene == 0 {
            issue("scene.none", .note, "骨架没有场景层信息（视角/地点/时间/出场人物/转折）",
                  "老骨架可以没有；新骨架建议填上，这是连贯性审查的取证基础")
            penalty += 3
        }

        // 11. 期待感：本章挂上的新期待要可验证
        if !sk.newExpectation.isEmpty {
            let e = sk.newExpectation
            if e.count < 6 || CraftCodex.vagueEndings.contains(where: { e.contains($0) }) {
                issue("expect.vague", .note, "本章挂的新期待太笼统（「\(e)」）——不可验证的期待等于没挂",
                      "写成读者能核对的具体事件，例如「他会在宗门大比上赢下第三场」")
                penalty += 4
            }
        }

        r.score = max(0, 100 - penalty)
        return r
    }

    /// 取本章之前若干章已批准/已有骨架的钩子形态（用于套版检测）
    @MainActor
    private static func previousHookKinds(store: ProjectStore, before n: Int, limit: Int) -> [String] {
        store.chapters
            .filter { $0.number < n && $0.skeleton != nil }
            .sorted { $0.number > $1.number }
            .prefix(limit)
            .compactMap { ch -> String? in
                guard let sk = ch.skeleton else { return nil }
                if !sk.hookKind.isEmpty { return sk.hookKind }
                guard !sk.endHook.isEmpty else { return nil }
                return CraftCodex.classifyHook(sk.endHook)?.rawValue
            }
            .reversed()
    }
}
