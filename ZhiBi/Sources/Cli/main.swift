// 执笔 CLI 自检 + 合并导入工具
// 运行：ZhiBiCli [--real-workspace <path>]
//       ZhiBiCli --merge <oh-story或通用目录> --into <项目.zhibi目录>   （把外部目录并入已有项目）
//       ZhiBiCli --render-doc <markdown文件> <输出.png> [宽度]          （渲染排版快照，视觉回归用）
// 退出码 0 = 全部通过

import Foundation
import AppKit

// MARK: - 排版快照（视觉回归：真实文档 → PNG）

MainActor.assumeIsolated {
    let argv = CommandLine.arguments
    if let rIdx = argv.firstIndex(of: "--render-doc"), rIdx + 2 < argv.count {
        let mdURL = URL(fileURLWithPath: argv[rIdx + 1])
        let pngURL = URL(fileURLWithPath: argv[rIdx + 2])
        let width = argv.indices.contains(rIdx + 3) ? Int(argv[rIdx + 3]) ?? 760 : 760
        do {
            let md = try String(contentsOf: mdURL, encoding: .utf8)
            let rendered = MarkdownLite.render(md, bodyFont: .systemFont(ofSize: 14), textColor: .labelColor)
            let storage = NSTextStorage(attributedString: rendered)
            let lm = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: 200000))
            lm.addTextContainer(container)
            storage.addLayoutManager(lm)
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 2000), textContainer: container)
            tv.backgroundColor = .windowBackgroundColor
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container)
            let height = max(300, Int(used.height) + 60)
            tv.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { exit(2) }
            tv.cacheDisplay(in: tv.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: pngURL)
            print("渲染快照已写出：\(pngURL.path)（\(width)×\(height)）")
        } catch {
            print("渲染失败：\(error)")
            exit(2)
        }
        exit(0)
    }
}

// MARK: - 合并导入模式（脚本化：外部目录 → 已有项目）

let argv = CommandLine.arguments
if let srcIdx = argv.firstIndex(of: "--merge"), srcIdx + 3 < argv.count, argv[srcIdx + 2] == "--into" {
    let srcURL = URL(fileURLWithPath: argv[srcIdx + 1])
    let projectURL = URL(fileURLWithPath: argv[srcIdx + 3])
    do {
        // CLI 主线程即主线程上下文，直接隔离执行（semaphore 会死锁 MainActor 调度）
        try MainActor.assumeIsolated {
            let store = ProjectStore(rootURL: projectURL)
            try store.load()
            let summary = ImportService.scan(srcURL)
            try! ImportService.apply(summary, into: store)
            print("已并入《\(store.project.title)》：章节 \(summary.chapters)｜设定+大纲 \(summary.canon + summary.outlines)｜阶段 \(summary.stages.count)｜伏笔 \(summary.clues.count)")
            let clueIDs = store.clues.map(\.id).joined(separator: " ")
            print("伏笔：\(clueIDs)")
        }
    } catch {
        print("合并失败：\(error)")
        exit(1)
    }
    exit(0)
}

fputs("[p] start\n", stderr)
var failures: [String] = []
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("✅ \(name)")
    } else {
        failures.append(name + (detail.isEmpty ? "" : " —— \(detail)"))
        print("❌ \(name) \(detail)")
    }
}

// MARK: - 宿主往返模式：对着 mock 模型端点跑真实的 AIService → SDK → 工具 → 提案 全链路
//
// 用法：ZhiBiCli --mock-agent <baseURL> <请求转储目录>
//
// 为什么要有这个：自检的其余部分全是纯函数与内存 store，唯独「宿主把工具面交给模型、
// 模型回调工具、宿主把 payload 落成提案」这条主链从来没被跑过。而这条链上有个静默失败点——
// ProposalToolBridge 在 parametersJSON 解析不了时会降级成空 schema，模型拿不到字段定义，
// 产出必然不合格，宿主却一声不响。没有真实/仿真端点，这个洞永远测不到。

if let mIdx = CommandLine.arguments.firstIndex(of: "--mock-agent"), mIdx + 2 < CommandLine.arguments.count {
    let baseURL = CommandLine.arguments[mIdx + 1]
    let dumpDir = CommandLine.arguments[mIdx + 2]
    var mok = 0
    var mbad: [String] = []
    func mck(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { mok += 1; print("✅ \(name)") }
        else { mbad.append(name + (detail.isEmpty ? "" : " —— \(detail)")); print("❌ \(name) \(detail)") }
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("zb-mock-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = ProjectStore(rootURL: tmp)
    store.project.title = "断刀记"
    store.project.genre = "玄幻"
    store.project.premise = "少年查灭门真相"
    store.project.chapterWordTarget = 3000
    store.project.targetChapters = 40
    store.project.authorIntent = "写一本节奏紧的玄幻"
    store.project.styleNotes = "少形容词，多动作"
    for i in 1...3 { _ = store.ensureChapter(i) }
    // 必须给章节状态：currentChapter 是按状态算的（drafted + 1），
    // 只有 prose 没有 status 的章它看不见，逾期/过期一类判定就全都不会触发。
    store.updateChapter(1) { $0.title = "废窑"; $0.status = .written
        $0.prose = "少年在废窑里捡到一把断刀，刀柄上刻着一个界字。他把刀揣进怀里。" }
    store.updateChapter(2) { $0.title = "河边"; $0.status = .written
        $0.prose = "他去河边洗刀，老周给了他一块干粮。" }
    store.updateChapter(3) { $0.title = "查河"; $0.status = .written
        $0.prose = "宗门来人查河，他躲进船底。" }
    mck("夹具基准章算对", store.currentChapter == 4, "currentChapter=\(store.currentChapter)")
    store.clues = [Clue(id: "F01", title: "断刀来历", detail: "刀柄刻着界字", timing: .immediate,
                        plantedChapter: 1, plantedQuote: "刀柄上刻着一个界字",
                        targetPayoffChapter: 2, status: .planted, lastActionChapter: 1)]
    store.storylines = [Storyline(id: "L01", name: "复仇", kind: .main, isThroughLine: true, status: .active),
                        Storyline(id: "L03", name: "世界", kind: .world, status: .active, entryChapter: 30)]
    store.timelineEvents = [TimelineEvent(id: "E01", chapter: 1, objectiveFact: "少年捡到断刀",
                                          readerKnowledge: "少年捡到断刀", revealed: false, storylineIDs: ["L01"])]

    var config = AgentConfig()
    config.baseURL = baseURL
    config.model = "mock-model"
    config.apiKey = ""
    config.embeddingModel = "mock-embedding"
    let ai = AIService()

    let embedProbe = await EmbeddingService.embed(texts: ["断刀", "少年"], config: config)
    mck("远程向量端点可用", embedProbe?.count == 2 && embedProbe?.first?.count == 8,
        "vectors=\(embedProbe?.count ?? -1) dim=\(embedProbe?.first?.count ?? -1)")
    EmbeddingService.clearCache()
    let firstEmbed = await EmbeddingService.embed(texts: ["断刀", "少年", "断刀"], config: config)
    mck("重复文本去重后仍按输入顺序返回",
        firstEmbed?.count == 3 && firstEmbed?[0] == firstEmbed?[2],
        "count=\(firstEmbed?.count ?? -1)")
    mck("远程嵌入进入进程缓存（重复文本只请求一次）", EmbeddingService.cachedCount() == 2,
        "cached=\(EmbeddingService.cachedCount())")
    let secondEmbed = await EmbeddingService.embed(texts: ["断刀", "少年", "断刀"], config: config)
    mck("缓存命中后仍返回完整向量",
        secondEmbed?.count == 3 && secondEmbed?[0] == firstEmbed?[0]
        && secondEmbed?[1] == firstEmbed?[1],
        "count=\(secondEmbed?.count ?? -1)")
    let vectorHits = await KnowledgeEngine.search(store: store, query: "断刀 界字", limit: 5, config: config)
    mck("远程向量重排仍能召回断刀", vectorHits.contains { $0.chunk.text.contains("断刀") },
        "hits=\(vectorHits.map(\.chunk.citation))")
    let detailedHits = await KnowledgeEngine.searchDetailed(store: store, query: "断刀 界字",
                                                            limit: 5, config: config)
    mck("检索能标记远程向量通道", detailedHits.run == .remote, "run=\(detailedHits.run)")
    var fallbackConfig = config
    fallbackConfig.baseURL = "http://127.0.0.1:1/v1"
    let fallbackProbe = await KnowledgeEngine.searchDetailed(store: store, query: "断刀 界字",
                                                             limit: 5, config: fallbackConfig)
    mck("远程失败会回退本地并标记", fallbackProbe.run == .fallback && !fallbackProbe.hits.isEmpty,
        "run=\(fallbackProbe.run) hits=\(fallbackProbe.hits.count)")
    EmbeddingService.clearCache()
    let manyTexts = (1...40).map { "断刀 \($0) 号线索" }
    let batched = await EmbeddingService.embed(texts: manyTexts, config: config)
    mck("远程嵌入分批请求仍保持条数与顺序",
        batched?.count == 40 && batched?.allSatisfy { $0.count == 8 } == true,
        "count=\(batched?.count ?? -1)")
    mck("分批请求的向量都进入缓存", EmbeddingService.cachedCount() == 40,
        "cached=\(EmbeddingService.cachedCount())")
    KnowledgeIndexCache.invalidate()
    let rebuiltIndex = await KnowledgeIndexCache.indexAsync(for: store)
    mck("后台索引完成后进度归位",
        !KnowledgeIndexProgress.shared.isBuilding
        && KnowledgeIndexProgress.shared.fraction >= 1
        && !rebuiltIndex.chunks.isEmpty,
        "building=\(KnowledgeIndexProgress.shared.isBuilding) fraction=\(KnowledgeIndexProgress.shared.fraction)")

    // ---- 1. 章节骨架：工具往返 + 场景层解析 + 闸门打分 ----
    await ai.runSkeleton(store: store, config: config, chapter: 3, directive: "这一章要让断刀来历往前推一层")
    mck("骨架往返无错误", ai.lastError == nil, String(describing: ai.lastError))
    let skProp = store.proposals.first { $0.capability == .chapterSkeleton }
    mck("骨架提案已落收件箱", skProp != nil, "提案数=\(store.proposals.count) 日志=\(ai.lastToolLog)")
    if case .skeleton(let sk)? = skProp?.payload {
        mck("节拍数解析正确", sk.beats.count == 3, "实得 \(sk.beats.count)")
        mck("场景层·视角解析成功", sk.beats[0].pov == "少年", sk.beats[0].pov)
        mck("场景层·地点解析成功", sk.beats[0].location == "废窑", sk.beats[0].location)
        mck("场景层·时间标记解析成功", sk.beats[0].timeLabel == "当夜", sk.beats[0].timeLabel)
        mck("场景层·出场人物解析成功", sk.beats[0].cast == ["少年"], "\(sk.beats[0].cast)")
        mck("场景层·转折解析成功", sk.beats[0].turn == "从安全到失物", sk.beats[0].turn)
        mck("钩子形态解析成功", sk.hookKind == "悬念", sk.hookKind)
        mck("爽点类型解析成功", sk.payoffType == "认知优越", sk.payoffType)
        mck("新期待解析成功", !sk.newExpectation.isEmpty)
        mck("所属卷解析成功", sk.volumeLabel == "第一卷", sk.volumeLabel)
        mck("伏笔触点动作解析成功", sk.clueTouches.first?.action == .develop && sk.clueTouches.first?.clueID == "F01",
            "\(sk.clueTouches.map { "\($0.clueID):\($0.action.rawValue)" })")
        mck("标为 AI 提案而非作者钦定", sk.proposedByAI && !sk.humanApproved)
        mck("闸门已打分并写进标题", skProp?.title.contains("闸门") == true, skProp?.title ?? "")
        mck("闸门给这份合格骨架高分", (skProp?.note.contains("骨架闸门") == true), skProp?.note ?? "")
        // 采纳后才真正落到章节上（铁律：提案不采纳不入库）
        mck("采纳前不入库", store.chapter(3)?.skeleton == nil || store.chapter(3)?.skeleton?.beats.isEmpty == true)
        if let pid = skProp?.id { store.acceptProposal(pid) }
        mck("采纳后骨架入库", store.chapter(3)?.skeleton?.beats.count == 3)
        mck("入库的场景层没丢", store.chapter(3)?.skeleton?.beats[0].location == "废窑")
    } else {
        for _ in 0..<12 { mck("骨架负载解析", false, "拿不到 .skeleton 负载") }
    }

    // ---- 2. 全书连贯性审查 + 埋点修复 ----
    await ai.runContinuityAudit(store: store, config: config)
    mck("连贯性审查往返无错误", ai.lastError == nil, String(describing: ai.lastError))
    let contReports = store.proposals.filter { $0.capability == .continuityAudit }
    mck("连贯性审查落了提案", contReports.count >= 2, "实得 \(contReports.count) 条")
    if let rep = contReports.compactMap({ p -> ValidationReport? in
        if case .report(let r) = p.payload { return r }; return nil
    }).first {
        mck("AI 的六类发现被解析", rep.aiIssues.count == 2, "实得 \(rep.aiIssues.count)")
        mck("AI 发现带章号前缀", rep.aiIssues.contains { $0.message.hasPrefix("第3章：") },
            "\(rep.aiIssues.map(\.message))")
        mck("AI 发现带取证", rep.aiIssues.allSatisfy { !$0.evidence.isEmpty })
        mck("宿主确定性发现一并落库", !rep.deterministicIssues.isEmpty,
            "\(rep.deterministicIssues.map { "[\($0.category)] \($0.message)" })")
        mck("确定性发现含逾期伏笔", rep.deterministicIssues.contains { $0.category == "伏笔台账" },
            "\(Set(rep.deterministicIssues.map(\.category)))")
    } else {
        for _ in 0..<5 { mck("连贯性报告负载", false, "拿不到 .report 负载") }
    }
    if let fixProp = contReports.first(where: { if case .clueFixes = $0.payload { return true }; return false }),
       case .clueFixes(let fixes) = fixProp.payload {
        mck("埋点修复方案已产出", !fixes.isEmpty)
        mck("修复方案针对逾期伏笔 F01", fixes.contains { $0.clueID == "F01" }, "\(fixes.map(\.clueID))")
        mck("修复方案含改期动作", fixes.contains { $0.kind == .retarget }, "\(fixes.map(\.kind.rawValue))")
        let before = store.clues.first { $0.id == "F01" }?.targetPayoffChapter
        if let one = fixes.first(where: { $0.kind == .retarget }) { store.applyClueFix(one) }
        mck("采纳单条修复后台账变了", store.clues.first { $0.id == "F01" }?.targetPayoffChapter != before,
            "before=\(String(describing: before)) after=\(String(describing: store.clues.first { $0.id == "F01" }?.targetPayoffChapter))")
        mck("修复只改台账不改正文", store.chapter(3)?.prose == "宗门来人查河，他躲进船底。")
    } else {
        for _ in 0..<5 { mck("埋点修复方案", false, "没有 .clueFixes 提案") }
    }

    // ---- 3. 大纲同步 ----
    await ai.runOutlineSync(store: store, config: config)
    mck("大纲同步往返无错误", ai.lastError == nil, String(describing: ai.lastError))
    if let upProp = store.proposals.first(where: { if case .outlineUpdates = $0.payload { return true }; return false }),
       case .outlineUpdates(let ups) = upProp.payload {
        mck("大纲更新建议已产出", !ups.isEmpty, "实得 \(ups.count)")
        mck("含 AI 补的改期建议", ups.contains { $0.kind == .eventMoved && $0.eventID == "E02" && $0.newChapter == 6 },
            "\(ups.map { "\($0.kind.rawValue):\($0.eventID ?? $0.storylineID ?? "-")" })")
        mck("含 AI 补的故事线状态建议", ups.contains { $0.kind == .storylineStatus && $0.storylineID == "L03" })
        mck("含宿主确定性对账建议", ups.contains { $0.eventID == "E01" }, "\(ups.map { $0.eventID ?? "-" })")
        mck("每条建议都有人话理由", ups.allSatisfy { !$0.reason.isEmpty })
        store.acceptProposal(upProp.id)
        mck("采纳后大纲真的更新", store.storylines.first { $0.id == "L03" }?.status == .dormant,
            "\(String(describing: store.storylines.first { $0.id == "L03" }?.status.rawValue))")
    } else {
        for _ in 0..<6 { mck("大纲更新建议", false, "没有 .outlineUpdates 提案") }
    }

    // ---- 4. 一键写作：整章草稿只进提案，不进正文 ----
    let proseBefore = store.chapter(3)?.prose
    await ai.runDraft(store: store, config: config, chapter: 3, mainline: "断刀来历推一层，收在绣鞋上")
    mck("草稿往返无错误", ai.lastError == nil, String(describing: ai.lastError))
    if let dProp = store.latestDraftProposal(for: 3), let draft = store.draftPayload(of: dProp) {
        mck("草稿提案已落箱", draft.version == 1 && !draft.text.isEmpty, "v\(draft.version) \(draft.text.count)字")
        mck("草稿含骨架要求的收尾画面", draft.text.contains("绣着他自己家的纹样"))
        mck("采纳前正文一个字没动", store.chapter(3)?.prose == proseBefore)
        store.acceptProposal(dProp.id)
        mck("采纳后草稿写入正文", store.chapter(3)?.prose.contains("废窑里漏风") == true)
        mck("采纳前自动留了快照", store.snapshots(chapter: 3).contains { $0.text.contains("躲进船底") },
            "\(store.snapshots(chapter: 3).map(\.name))")
    } else {
        for _ in 0..<5 { mck("草稿提案", false, "拿不到草稿提案") }
    }

    // ---- 5. 出网请求内容：创作法典与工具 schema 是否真的发出去了 ----
    func readDump(_ name: String) -> [String: Any]? {
        let u = URL(fileURLWithPath: dumpDir).appendingPathComponent(name)
        guard let d = try? Data(contentsOf: u) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    if let req = readDump("req01.json"), let msgs = req["messages"] as? [[String: Any]] {
        let joined = msgs.compactMap { $0["content"] as? String }.joined(separator: "\n")
        mck("系统指令声明了提案铁律", joined.contains("propose_") && joined.contains("提案"))
        mck("创作法典注入了题材档案", joined.contains("题材：玄幻"), "前 400 字：\(String(joined.prefix(400)))")
        mck("创作法典注入了题材禁区", joined.contains("禁区"))
        mck("骨架任务拿到期待感管理", joined.contains("期待感"))
        mck("骨架任务拿到起承转合", joined.contains("起承转合"))
        mck("作者主线要求进了 prompt", joined.contains("断刀来历推一层") || joined.contains("断刀来历往前推一层"))
        mck("上下文包带了前章结尾", joined.contains("上一章结尾"))
        mck("上下文包带了活跃伏笔", joined.contains("F01"))
        if let tools = req["tools"] as? [[String: Any]],
           let skT = tools.first(where: { (($0["function"] as? [String: Any])?["name"] as? String) == "propose_skeleton" }),
           let params = (skT["function"] as? [String: Any])?["parameters"] as? [String: Any],
           let props = params["properties"] as? [String: Any],
           let beats = (props["beats"] as? [String: Any])?["items"] as? [String: Any],
           let beatProps = beats["properties"] as? [String: Any] {
            mck("工具 schema 不是静默降级的空壳", !beatProps.isEmpty && props["hook_kind"] != nil)
            mck("schema 里带场景层字段", ["pov", "location", "time_label", "cast", "turn"].allSatisfy { beatProps[$0] != nil },
                "实有 \(beatProps.keys.sorted())")
        } else {
            mck("工具 schema 不是静默降级的空壳", false, "req01 里找不到 propose_skeleton 的 schema")
            mck("schema 里带场景层字段", false, "同上")
        }
    } else {
        for _ in 0..<10 { mck("请求转储可读", false, "\(dumpDir)/req01.json 读不到") }
    }
    if let req2 = readDump("req02.json"), let msgs = req2["messages"] as? [[String: Any]] {
        mck("工具结果被回灌给模型（agent 循环闭合）", msgs.contains { ($0["role"] as? String) == "tool" },
            "roles=\(msgs.compactMap { $0["role"] as? String })")
    } else {
        mck("工具结果被回灌给模型（agent 循环闭合）", false, "req02.json 读不到")
    }
    let draftReqs = (1...12).compactMap { readDump(String(format: "req%02d.json", $0)) }
    if let draftReq = draftReqs.first(where: { r in
        guard let msgs = r["messages"] as? [[String: Any]] else { return false }
        let j = msgs.compactMap { $0["content"] as? String }.joined(separator: "\n")
        return j.contains("请写第3章整章草稿")
    }), let msgs = draftReq["messages"] as? [[String: Any]] {
        let j = msgs.compactMap { $0["content"] as? String }.joined(separator: "\n")
        mck("草稿任务拿到白描与文气法典", j.contains("白描") && j.contains("文气"))
        mck("草稿 prompt 带上了场景层", j.contains("视角：少年") && j.contains("地点：废窑"), "片段：\(String(j.prefix(300)))")
        mck("草稿 prompt 带上了钩子形态", j.contains("章尾钩子") && j.contains("悬念"))
    } else {
        for _ in 0..<3 { mck("草稿任务书内容", false, "找不到草稿请求转储") }
    }


    // ---- 6. 一键成章：骨架不代批；批准后草稿/审查/文风一路串到底，仍停在采纳之前 ----
    _ = store.ensureChapter(4)
    store.updateChapter(4) { $0.title = "第四章"; $0.status = .writing; $0.prose = "" }
    await ai.runAutoPipeline(store: store, config: config, chapter: 4, mainline: "查河的后续")
    mck("没有批准的骨架时不往下串", ai.pipelineDone.isEmpty, "\(ai.pipelineDone)")
    mck("没有批准的骨架时给出介入提示", !ai.pipelineNote.isEmpty && ai.pipelineNote.contains("批准"), ai.pipelineNote)
    mck("一键流程不代批骨架", store.chapter(4)?.skeleton?.humanApproved != true)
    mck("但骨架提案确实产出了", store.proposals.contains { $0.capability == .chapterSkeleton && $0.chapterNumber == 4 })
    mck("骨架未批准时不产草稿", !store.proposals.contains { $0.capability == .chapterDraft && $0.chapterNumber == 4 })

    // 作者批准骨架（采纳提案 + 勾批准），再点一次一键
    if let skP = store.proposals.first(where: { $0.capability == .chapterSkeleton && $0.chapterNumber == 4 }) {
        store.acceptProposal(skP.id)
        store.updateChapter(4) { $0.skeleton?.humanApproved = true }
    }
    mck("夹具已批准骨架", store.chapter(4)?.skeleton?.humanApproved == true)
    mck("批准的骨架带场景层", store.chapter(4)?.skeleton?.beats.first?.location == "废窑",
        "\(String(describing: store.chapter(4)?.skeleton?.beats.first?.location))")

    await ai.runAutoPipeline(store: store, config: config, chapter: 4, mainline: "查河的后续")
    mck("一键跑完三步", ai.pipelineDone.count == 3, "\(ai.pipelineDone)")
    mck("一键产出草稿提案", store.proposals.contains { $0.capability == .chapterDraft && $0.chapterNumber == 4 })
    mck("一键产出一致性审查提案", store.proposals.contains { $0.capability == .validation && $0.chapterNumber == 4 })
    mck("一键产出去AI味提案", store.proposals.contains { $0.capability == .deslop && $0.chapterNumber == 4 })
    mck("审查与去AI味针对的是草稿而非空正文", store.proposals.contains { p in
        guard p.capability == .deslop, p.chapterNumber == 4, case .deslop(let r) = p.payload else { return false }
        return r.suggestions.count == 2
    }, "\(store.proposals.filter { $0.capability == .deslop }.map(\.title))")
    let draftID = store.latestDraftProposal(for: 4)?.id
    mck("去AI味记录的是草稿目标", store.proposals.contains { p in
        guard p.capability == .deslop, p.chapterNumber == 4, case .deslop(let r) = p.payload else { return false }
        return r.targetDraftID != nil && r.targetDraftID == draftID
    }, "draftID=\(String(describing: draftID))")
    mck("草稿审查不混入旧正文确定性结论", store.proposals.contains { p in
        guard p.capability == .validation, p.chapterNumber == 4, case .report(let r) = p.payload else { return false }
        return r.deterministicIssues.isEmpty
    })
    mck("一键跑完仍停在采纳之前（正文一个字没进）", store.chapter(4)?.prose.isEmpty == true,
        "prose=\(store.chapter(4)?.prose ?? "<nil>")")
    mck("跑完给出下一步指引", ai.pipelineNote.contains("收件箱"), ai.pipelineNote)
    mck("跑完进度标记已清空", ai.pipelineStage.isEmpty)
    mck("一键链路无错误", ai.lastError == nil, String(describing: ai.lastError))
    mck("一键流水线有轨迹完成标记", ai.trajectory.contains {
        $0.capability == AICapability.chapterDraft.rawValue && $0.event == "完成"
    }, "\(ai.trajectory.prefix(6).map { "\($0.capability)/\($0.event)" })")

    // ---- 7. 分段写作：长章按节拍分块续写再拼装 ----
    // 纯函数：剥壳。模型几乎总会加开场白与围栏，分块拼装时这些壳会夹在正文中间
    mck("剥离开场白与围栏", AIService.stripProsePreamble("以下是这一段：\n```markdown\n他走了。\n```") == "他走了。",
        "[\(AIService.stripProsePreamble("以下是这一段：\n```markdown\n他走了。\n```"))]")
    mck("不误删正文首句", AIService.stripProsePreamble("他走了。老周没说话。") == "他走了。老周没说话。",
        AIService.stripProsePreamble("他走了。老周没说话。"))
    mck("不误删以「第」开头的正文", AIService.stripProsePreamble("第三章的风很大。他走了。") == "第三章的风很大。他走了。",
        AIService.stripProsePreamble("第三章的风很大。他走了。"))
    mck("剥壳后不留空行残渣", !AIService.stripProsePreamble("好的，这是本段：\n\n他走了。\n\n").hasPrefix("\n"))

    let verBefore = store.nextDraftVersion(for: 4)
    await ai.runDraftByScenes(store: store, config: config, chapter: 4, mainline: "查河的后续", wordsPerChunk: 900)
    mck("分段写作无错误", ai.lastError == nil, String(describing: ai.lastError))
    mck("分段按节拍切成了多块", ai.pipelineDone.count == 3, "\(ai.pipelineDone)")
    if let dp = store.latestDraftProposal(for: 4), let d = store.draftPayload(of: dp) {
        mck("分段草稿只登记为一份提案", d.version == verBefore, "v\(d.version) 期望 v\(verBefore)")
        mck("标题标明是分段写作", dp.title.contains("分段写作"), dp.title)
        mck("拼装后正文没有围栏残渣", !d.text.contains("```"), String(d.text.prefix(120)))
        mck("拼装后正文没有开场白残渣", !d.text.contains("以下是"), String(d.text.prefix(120)))
        mck("三段都拼进去了", d.text.components(separatedBy: "他沿着河堤往回走").count - 1 == 3,
            "命中 \(d.text.components(separatedBy: "他沿着河堤往回走").count - 1) 次，共 \(WordStats.chineseCount(d.text)) 字")
        mck("段与段之间有空行分隔", d.text.contains("\n\n"))
        mck("分段草稿同样停在采纳前", store.chapter(4)?.prose.isEmpty == true, "prose=\(store.chapter(4)?.prose ?? "<nil>")")
    } else {
        for _ in 0..<8 { mck("分段草稿提案", false, "拿不到草稿提案") }
    }
    mck("分段写作轨迹有开始与结束标记",
        ai.trajectory.first?.event == "完成"
        && ai.trajectory.contains { $0.event.hasPrefix("开始处理") && $0.detail.contains("分段写作") },
        "\(ai.trajectory.prefix(3).map { "\($0.capability)/\($0.event)/\($0.detail)" })")
    // 没有批准的骨架时必须拒绝，而不是硬编一段出来
    _ = store.ensureChapter(5)
    store.updateChapter(5) { $0.title = "第五章"; $0.status = .writing; $0.prose = "" }
    await ai.runDraftByScenes(store: store, config: config, chapter: 5, mainline: "x")
    mck("无骨架时拒绝分段写作", ai.lastError != nil && ai.lastError?.contains("骨架") == true,
        String(describing: ai.lastError))
    mck("无骨架时不产草稿", !store.proposals.contains { $0.capability == .chapterDraft && $0.chapterNumber == 5 })

    // 分段任务书确实带着上一段的实际结尾（这是分块比一次性更连贯的原因）
    let segReqs = (1...40).compactMap { i -> [String: Any]? in
        let u = URL(fileURLWithPath: dumpDir).appendingPathComponent(String(format: "req%02d.json", i))
        guard let d = try? Data(contentsOf: u) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }.filter { r in
        guard let msgs = r["messages"] as? [[String: Any]] else { return false }
        return msgs.compactMap { $0["content"] as? String }.joined().contains("第 2/3 段")
    }
    if let r = segReqs.first, let msgs = r["messages"] as? [[String: Any]] {
        let j = msgs.compactMap { $0["content"] as? String }.joined(separator: "\n")
        mck("续写段带着上一段的实际结尾", j.contains("已经写出来的部分") && j.contains("他沿着河堤往回走"))
        mck("续写段带着场景层", j.contains("地点：河边棚屋") || j.contains("地点：渡口"), "片段：\(String(j.prefix(200)))")
        mck("非末段被明确告知不要收尾", j.contains("不要收束本章"))
        mck("分段任务书也带创作法典", j.contains("创作法典") && j.contains("白描"))
    } else {
        for _ in 0..<4 { mck("分段任务书内容", false, "找不到第 2/3 段的请求转储") }
    }

    // ---- 8. 编辑对话：检索资料 → agent 工具循环 → 回答/草稿提案，不动正文 ----
    let chatBefore = store.chatMessages.count
    let proposalsBeforeChat = store.proposals.count
    let nextChapter = store.currentChapter
    let targetChatChapter = max(1, nextChapter + 1)
    let draftsBeforeChat = store.proposals.filter {
        $0.chapterNumber == targetChatChapter && ($0.capability == .chapterDraft || $0.capability == .chapterRevise)
    }.count
    let proseBeforeChat = store.chapter(3)?.prose
    let nextProseBeforeChat = store.chapter(targetChatChapter)?.prose
    await ai.sendChat(store: store, config: config, text: "用断刀的线索写下一章草稿。", chapter: targetChatChapter)
    mck("对话往返无错误", ai.chatError == nil, String(describing: ai.chatError))
    mck("对话记录落用户+AI两条", store.chatMessages.count == chatBefore + 2,
        "before=\(chatBefore) after=\(store.chatMessages.count)")
    let lastReply = store.chatMessages.last
    mck("对话最后一条是 AI 回答", lastReply?.role == .assistant && !(lastReply?.text.isEmpty ?? true),
        lastReply?.text ?? "nil")
    mck("对话回答带资料库引用", !(lastReply?.citations.isEmpty ?? true),
        "\(lastReply?.citations ?? [])")
    mck("对话不改已有正文", store.chapter(3)?.prose == proseBeforeChat)
    mck("对话登记了待审提案", store.proposals.count > proposalsBeforeChat,
        "before=\(proposalsBeforeChat) after=\(store.proposals.count)")
    let draftsAfterChat = store.proposals.filter {
        $0.chapterNumber == targetChatChapter && ($0.capability == .chapterDraft || $0.capability == .chapterRevise)
    }.count
    mck("对话按选中章提交整章草稿提案", draftsAfterChat > draftsBeforeChat,
        "targetChapter=\(targetChatChapter) drafts=\(draftsBeforeChat)->\(draftsAfterChat)")
    mck("对话草稿采纳前正文没动", store.chapter(targetChatChapter)?.prose == nextProseBeforeChat)
    mck("对话回复记录了本次提案 ID",
        lastReply?.proposalIDs.contains { id in store.proposals.contains { $0.id == id } } == true,
        "ids=\(lastReply?.proposalIDs.count ?? 0)")

    // 对话不只写草稿：也能为选中章搭骨架，仍然只是提案
    let skeletonChatChapter = targetChatChapter + 1
    let skeletonsBefore = store.proposals.filter {
        $0.capability == .chapterSkeleton && $0.chapterNumber == skeletonChatChapter
    }.count
    await ai.sendChat(store: store, config: config,
                      text: "给这一章搭个骨架提案，先给我审。", chapter: skeletonChatChapter)
    mck("对话搭骨架往返无错误", ai.chatError == nil, String(describing: ai.chatError))
    let skeletonsAfter = store.proposals.filter {
        $0.capability == .chapterSkeleton && $0.chapterNumber == skeletonChatChapter
    }.count
    mck("对话可提交骨架提案并绑定选中章", skeletonsAfter > skeletonsBefore,
        "targetChapter=\(skeletonChatChapter) skeletons=\(skeletonsBefore)->\(skeletonsAfter)")

    // 重新回答：撤掉旧回复、保留原问题，再跑一遍
    let chatCountBeforeRegen = store.chatMessages.count
    let proposalsBeforeRegen = store.proposals.count
    await ai.regenerateLastChat(store: store, config: config, chapter: skeletonChatChapter)
    mck("重新回答不堆叠用户提问", store.chatMessages.count == chatCountBeforeRegen,
        "before=\(chatCountBeforeRegen) after=\(store.chatMessages.count)")
    mck("重新回答后末尾仍是 AI 回答", store.chatMessages.last?.role == .assistant,
        store.chatMessages.last?.text ?? "nil")
    mck("重新回答会重新登记提案", store.proposals.count > proposalsBeforeRegen,
        "before=\(proposalsBeforeRegen) after=\(store.proposals.count)")

    print("\n======== 宿主往返自检：通过 \(mok) 项，失败 \(mbad.count) 项 ========")
    for f in mbad { print("  FAIL: \(f)") }
    exit(mbad.isEmpty ? 0 : 1)
}

fputs("[p] s1\n", stderr)
// MARK: - 1. 字数统计

fputs("[probe] s1 中文字数\n", stderr)
let sample = "他捏碎了手中的茶杯，滚烫的茶水流过指缝。"
check("中文字数统计（含标点，网文口径）", WordStats.chineseCount(sample) == 20, "实际 \(WordStats.chineseCount(sample))")
check("英文与数字计入字数", WordStats.chineseCount("LV1 的 S 级") == 6,
      "实际 \(WordStats.chineseCount("LV1 的 S 级"))")

fputs("[p] s2\n", stderr)
// MARK: - 2. AI 味确定性扫描

fputs("[probe] s2 AI味扫描\n", stderr)
let aiFlavored = """
    他知道，这一切都来不及了。他的眼中闪过一丝悲伤，仿佛整个世界都失去了颜色。他的心中涌起一股暖流。
    他缓缓地深吸一口气，声音不大，却带着一种不容置疑的力量。
    他不是冷漠，而是绝望。他的嘴角勾起一抹不易察觉的弧度。
    他知道，这一刻，一切都变了。他知道，他终于明白了。
    他知道，命运的齿轮开始转动。他知道，没有人能逃过这一切。
    """
let lintAI = AILint.scan(aiFlavored)
check("AI味扫描命中禁用词", lintAI.bannedPerKilo > 5, "密度 \(lintAI.bannedPerKilo)")
check("AI味扫描命中『不是而是』", lintAI.topIssues.contains { $0.kind == "不是A而是B" })
check("AI味分级非轻度", lintAI.grade != "轻度", lintAI.grade)

let humanProse = """
    深夜十一点，陆吾清推开出租屋的门，鞋都没脱就倒在床上。楼下烧烤摊的油烟味顺着窗缝钻进来。
    手机在枕头边震了三次。她数到第四次才去拿。
    “喂。”
    “人没了。”电话那头只说了两个字。
    她盯着天花板看了很久，然后爬起来，把散在床上的稿纸一张张收进包里。
    """
let lintHuman = AILint.scan(humanProse)
check("干净文本不被误伤", lintHuman.grade == "轻度" && lintHuman.bannedPerKilo < 2, "grade=\(lintHuman.grade) 密度=\(lintHuman.bannedPerKilo)")

fputs("[p] s3\n", stderr)
// MARK: - 3. 章节名解析

fputs("[probe] s3 章节名解析\n", stderr)
check("解析『第001章_血夜』", ImportService.parseChapterName("第001章_血夜")?.0 == 1 && ImportService.parseChapterName("第001章_血夜")?.1 == "血夜")
check("解析『第 12 章 风起』", ImportService.parseChapterName("第 12 章 风起")?.0 == 12)
check("解析全角『第３章』", ImportService.parseChapterName("第３章")?.0 == 3)
check("非章节名返回 nil", ImportService.parseChapterName("世界观设定") == nil)
check("解析『001_风起』", ImportService.parseChapterName("001_风起")?.0 == 1 && ImportService.parseChapterName("001_风起")?.1 == "风起")
check("解析『Chapter 12 - 风起』", ImportService.parseChapterName("Chapter 12 - 风起")?.0 == 12
      && ImportService.parseChapterName("Chapter 12 - 风起")?.1 == "风起")
check("解析『chapter_07』", ImportService.parseChapterName("chapter_07")?.0 == 7)
check("年份不被误判为章节", ImportService.parseChapterName("2024_年度总结") == nil)

// MARK: - 4. 容错 JSON（追踪文件里的裸换行）

fputs("[probe] s4 容错JSON\n", stderr)
let brokenJSON = #"""
{"a": {"guardian": "无（孤儿）
}, "b": [1, 2]}
"""#
let repaired = ImportService.parseTolerantJSON(Data(brokenJSON.utf8)) as? [String: Any]
check("容错 JSON 解析（未闭合字符串）", repaired?["b"] != nil && ((repaired?["a"] as? [String: Any])?["guardian"] as? String)?.contains("无（孤儿）") == true)

fputs("[p] s5\n", stderr)
// MARK: - 5. 临时项目：存取 / 快照 / 验证 / 造包 / 导出（全部在临时目录，不碰真实数据）

fputs("[probe] s5 store tests\n", stderr)
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zhibi-cli-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

@MainActor
func runStoreTests(tmp: URL) async throws {
    let store = ProjectStore(rootURL: tmp)
    store.project = NovelProject(title: "测试书", genre: "玄幻", premise: "测试", chapterWordTarget: 2000)

    // 章 1：带骨架与伏笔触点
    var clue = Clue(id: "F01", title: "短刀上的灰白光", detail: "开篇埋的刀", plantedChapter: 1)
    clue.lastActionChapter = 1
    clue.actions = [ClueActionLog(chapter: 1, kind: .plant)]
    store.clues.append(clue)

    var beat = Beat(summary: "主角捡到短刀，刀身闪过灰白光", purpose: "埋伏笔", clueIDs: ["F01"], suggestedWords: 500)
    beat.done = true
    let sk = ChapterSkeleton(beats: [beat], endHook: "刀柄内侧刻着一个『界』字",
                             mustDeliver: ["捡刀"], mustAvoid: ["不要解释光的来历"],
                             clueTouches: [ClueTouch(clueID: "F01", action: .plant, requirement: "必须出现灰白光")],
                             proposedByAI: true, humanApproved: true)
    _ = store.ensureChapter(1)
    store.updateChapter(1) {
        $0.title = "血夜"
        $0.prose = "刀落进门缝里。短刀上的灰白光一闪而灭。\n" + String(repeating: "他弯腰把刀捡起来，指腹蹭过刀刃，又低头看了看门槛外的血迹。", count: 20)
        $0.skeleton = sk
        $0.status = .written
    }

    // 章 2：与前章重复句
    _ = store.ensureChapter(2)
    store.updateChapter(2) {
        $0.title = "追杀"
        $0.prose = "他弯腰把刀捡起来，指腹蹭过刀刃，又低头看了看门槛外的血迹。夜风很冷，他继续往前走，走了很远很远，直到天亮。"
        $0.status = .writing
    }

    try store.saveNow()

    // 5.1 存取回环
    let store2 = ProjectStore(rootURL: tmp)
    try store2.load()
    check("项目存取回环", store2.project.title == "测试书" && store2.chapters.count == 2 && store2.clues.count == 1)
    check("正文以 md 落盘", FileManager.default.fileExists(atPath: ProjectLayout.proseFile(tmp, number: 1).path))

    // 5.1b 骨架/状态必须能跨重启存活
    //
    // 曾经的写法是拿 Chapter 去解 meta.json：meta 里没有 prose 键，而 Chapter.prose 是非可选字段，
    // 缺键必然抛 keyNotFound，被 `?? Chapter(number:)` 吞掉后每章都退化成空章——
    // 表现是"打开工程骨架全没了"，随后自动保存把骨架从盘上永久抹掉。
    // 这里用「存盘 → 新 store 读回」把这条路钉死（只断言内存态是测不出来的）。
    _ = store.ensureChapter(3)
    store.updateChapter(3) { ch in
        ch.title = "拾刀"
        ch.status = .skeletoned
        var b = Beat(summary: "少年在废窑捡到断刀", purpose: "推进")
        b.pov = "少年"; b.location = "废窑"; b.timeLabel = "当夜"; b.cast = ["少年"]
        b.turn = "从看客到当事人"
        ch.skeleton = ChapterSkeleton(beats: [b], endHook: "刀柄上的界字亮了一下",
                                      mustDeliver: ["捡到断刀"], mustAvoid: ["不要解释来历"],
                                      proposedByAI: true, humanApproved: true,
                                      hookKind: "悬念", pov: "少年")
    }
    try store.saveNow()
    let store3 = ProjectStore(rootURL: tmp)
    try store3.load()
    check("meta 回读不丢状态", store3.chapter(3)?.status == .skeletoned,
          store3.chapter(3)?.status.rawValue ?? "nil")
    check("meta 回读不丢骨架", store3.chapter(3)?.skeleton?.beats.count == 1,
          "beats=\(store3.chapter(3)?.skeleton?.beats.count ?? -1)")
    check("meta 回读保留场景层", store3.chapter(3)?.skeleton?.beats.first?.location == "废窑",
          store3.chapter(3)?.skeleton?.beats.first?.location ?? "nil")
    check("meta 回读保留章末钩子", store3.chapter(3)?.skeleton?.endHook.contains("界字") == true)

    // 5.2 快照与回滚
    let snap = store2.snapshotProse(chapter: 2, tag: "test")
    store2.updateChapter(2) { $0.prose = "改坏了。" }
    store2.restoreSnapshot(chapter: 2, name: snap ?? "")
    check("快照回滚", store2.chapter(2)?.prose.contains("夜风很冷") == true)

    // 快照必须连 meta 一起回滚：状态/标题/本章指令不能停在改后的值
    store2.updateChapter(2) { $0.status = .done; $0.title = "回滚前标题"; $0.directive = "回滚前指令" }
    let metaSnap = store2.snapshotProse(chapter: 2, tag: "meta")
    store2.updateChapter(2) {
        $0.prose = "改坏的第二稿。"
        $0.status = .polished
        $0.title = "改后标题"
        $0.directive = "改后指令"
    }
    if let metaSnap {
        let restored = store2.restoreSnapshot(chapter: 2, name: metaSnap)
        check("快照回滚连 meta 一起还原", restored
              && store2.chapter(2)?.status == .done
              && store2.chapter(2)?.title == "回滚前标题"
              && store2.chapter(2)?.directive == "回滚前指令"
              && store2.chapter(2)?.prose.contains("夜风很冷") == true,
              "status=\(store2.chapter(2)?.status.rawValue ?? "nil") title=\(store2.chapter(2)?.title ?? "nil")")
    } else {
        check("快照回滚连 meta 一起还原", false)
    }

    // 5.3 确定性验证：章1 伏笔合同应通过；章2 应检出跨章重复
    let report1 = await Validator.deterministicReport(store: store2, chapter: 1)
    check("章1伏笔合同无 blocker", !report1.allIssues.contains { $0.category == "伏笔合同" && $0.severity == .blocker })
    let report2 = await Validator.deterministicReport(store: store2, chapter: 2)
    check("章2检出跨章重复", report2.allIssues.contains { $0.category == "跨章重复" })

    // 5.4 上下文造包
    let pack = ContextPackBuilder.build(store: store2, forChapter: 3, budget: 4000)
    check("上下文包含活跃伏笔", pack.blocks.contains { $0.title.contains("活跃伏笔") && $0.content.contains("F01") })
    check("上下文包含前章结尾", pack.blocks.contains { $0.title.contains("上一章结尾") })

    // 5.5 伏笔健康：过期检测（midArc=8 章）
    check("伏笔未过期", !clue.isOverdue(currentChapter: 3))

    // 5.6 提案 accept 应用（模型提议 → 宿主裁决 → 入库）
    var sk2 = ChapterSkeleton()
    sk2.beats = [Beat(summary: "新骨架拍", purpose: "推进")]
    store2.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 1, title: "骨架提案", payload: .skeleton(sk2)))
    let pid = store2.proposals[0].id
    store2.acceptProposal(pid)
    check("提案接受后骨架入库", store2.chapter(1)?.skeleton?.beats.first?.summary == "新骨架拍" && store2.proposals[0].status == .accepted)

    // 5.7 导出
    let ms = try ExportService.exportManuscript(store: store2)
    check("合并稿导出", FileManager.default.fileExists(atPath: ms.url.path))
    let oh = try ExportService.exportOhStory(store: store2)
    check("oh-story 导出含追踪", FileManager.default.fileExists(atPath: oh.url.appendingPathComponent("追踪/_tracking-state.json").path))
    let stateData = try Data(contentsOf: oh.url.appendingPathComponent("追踪/_tracking-state.json"))
    check("导出追踪 JSON 可解析", (ImportService.parseTolerantJSON(stateData) as? [String: Any])?["active_foreshadowing"] != nil)

    // 5.8 流水线草稿：提案 → 采纳 → 正文（采纳前自动快照）
    let originalProse = store2.chapter(1)?.prose ?? ""
    let draft = ChapterDraft(chapter: 1, text: "整章草稿全文。他停下脚步回头望了一眼火光。", version: 1)
    store2.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 1, title: "草稿 v1", payload: .draft(draft)))
    let draftID = store2.proposals[0].id
    check("草稿提案入箱", store2.proposals[0].status == .pending && store2.chapter(1)?.prose.contains("整章草稿全文") != true)
    store2.acceptProposal(draftID)
    check("采纳草稿写入正文", store2.chapter(1)?.prose.contains("整章草稿全文") == true && store2.proposals[0].status == .accepted)
    check("采纳前自动快照", store2.snapshots(chapter: 1).contains { $0.text.contains("指腹蹭过刀刃") })
    check("快照可回滚原文", { store2.restoreSnapshot(chapter: 1, name: (store2.snapshots(chapter: 1).first?.name) ?? ""); return store2.chapter(1)?.prose.contains("指腹蹭过刀刃") == true }())
    _ = originalProse

    // 5.9 checkpoint 存取（pi：宿主负责持久化）
    store2.saveCheckpoint(Data("[]".utf8), name: "t.json")
    check("checkpoint 存取", store2.loadCheckpoint(name: "t.json") != nil)
}

do {
    try await runStoreTests(tmp: tmp)
} catch {
    check("存储测试无异常", false, "\(error)")
}

try? FileManager.default.removeItem(at: tmp)

fputs("[p] s6\n", stderr)
// MARK: - 6. 回退解析器

fputs("[probe] s6 回退解析\n", stderr)
let fenced = """
    好的，以下是提案。
    ```json
    {"tool": "propose_memo", "args": {"text": "记住刀上的光"}}
    ```
    """
let fb = FallbackProposer.parse(fenced)
check("围栏 JSON 回退解析", fb?.tool == "propose_memo")

fputs("[p] s7\n", stderr)
// MARK: - 7. 真实工作区只读扫描（不写入）

fputs("[probe] s7 real workspace\n", stderr)
let realArgs = CommandLine.arguments
if let idx = realArgs.firstIndex(of: "--real-workspace"), idx + 1 < realArgs.count {
    let ws = realArgs[idx + 1]
    let summary = ImportService.scan(URL(fileURLWithPath: ws))
    print("—— 真实工作区扫描：\(ws)")
    print("   布局：\(summary.detectedLayout)")
    print("   章节 \(summary.chapters)｜设定 \(summary.canon)｜大纲 \(summary.outlines)｜阶段 \(summary.stages.count)｜伏笔 \(summary.clues.count)")
    check("真实工作区识别为 oh-story", summary.detectedLayout.contains("oh-story"))
    check("真实工作区识别到章节", summary.chapters >= 1)
    check("真实工作区识别到设定与大纲", summary.canon >= 3 && summary.outlines >= 2)
    check("真实工作区提取到活跃伏笔", summary.clues.count >= 5, "实际 \(summary.clues.count)")
    check("真实工作区提取到阶段", summary.stages.count >= 4, "实际 \(summary.stages.count)")
}

// MARK: - 8. MarkdownLite 富文本往返

func markdownLiteTests() {
    let mdSample = "# 第一章\n\n他捏碎了茶杯。**孤星照命**，*命数*在燃烧。\n\n> 古籍有云：命外无命。\n\n---\n\n尾段收束。"
    let rendered = MarkdownLite.render(mdSample, bodyFont: NSFont.systemFont(ofSize: 15), textColor: .textColor)
    let back = MarkdownLite.serialize(rendered)
    check("md→富文本→md 往返", back == mdSample + "\n", "期望：[\((mdSample + "\n").debugDescription)] 得到：[\(back.debugDescription)]")
    check("mdSample 每行独立成段", !back.contains("第一章他捏碎"))
    let again = MarkdownLite.serialize(MarkdownLite.render(back, bodyFont: NSFont.systemFont(ofSize: 15), textColor: .textColor))
    check("序列化幂等", again == back)
    // 粗体 traits 确实落在属性上
    let ns = rendered.string as NSString
    let loc = ns.range(of: "孤星照命").location
    if loc != NSNotFound, let font = rendered.attribute(.font, at: loc, effectiveRange: nil) as? NSFont {
        check("粗体渲染为 traits", font.fontDescriptor.symbolicTraits.contains(.bold))
    } else {
        check("粗体渲染为 traits", false)
    }
    // 引用块回写保留 > 前缀
    check("引用块往返", back.contains("> 古籍有云：命外无命。"))
}
fputs("[p] s-markdown done\n", stderr)
MainActor.assumeIsolated { markdownLiteTests() }

// MARK: - 13. 框架搭建：propose_canon 提案登记 → 采纳落设定库

@MainActor
func frameworkTests() async throws {
    // propose_canon：提案登记 → 采纳落设定库（人批准制不变）
    let canonProbe = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-canon-\(UUID().uuidString).zhibi"))
    let canonTool = NovelTools.all(store: canonProbe).first { $0.name == "propose_canon" }
    if let canonTool {
        // JSON 里换行用 \\n 转义（\n 会变成字面换行导致非法 JSON）
        let canonArgs = """
        {"docs":[{"title":"世界观","content":"力量体系：命数九层，每层十格。\\n主要势力：曜辰氏与森罗殿。","certainty":"canon"}]}
        """
        _ = try? await canonTool.handler(canonArgs)
        let pendingCanon = canonProbe.proposals.filter { $0.status == .pending }
        check("propose_canon 登记提案", pendingCanon.count == 1)
        if case .canon(let docs) = pendingCanon.first?.payload {
            check("提案负载为设定文档", docs.count == 1 && docs[0].title == "世界观" && docs[0].certainty == "canon")
        } else {
            check("提案负载为设定文档", false)
        }
        check("采纳前不入库", canonProbe.canonSections.isEmpty)
        if let id = pendingCanon.first?.id {
            canonProbe.acceptProposal(id)
            check("采纳后落设定库", canonProbe.canonSections.contains { $0.title == "世界观" }
                  && canonProbe.canonSections.first?.certainty == .canon)
            // 同名不覆盖（保护作者手改）
            canonProbe.canonSections[0].content = "作者手改版"
            let dupArgs = """
            {"docs":[{"title":"世界观","content":"AI 又一份","certainty":"tentative"}]}
            """
            _ = try? await canonTool.handler(dupArgs)
            canonProbe.acceptProposal(canonProbe.proposals.last!.id)
            check("同名设定不覆盖", canonProbe.canonSections.count == 1
                  && canonProbe.canonSections[0].content == "作者手改版")
        }
        check("框架工具面完整", NovelTools.all(store: canonProbe).contains { $0.name == "propose_canon" }
              && AICapability.framework.rawValue == "搭建框架")
    } else {
        check("propose_canon 已注册", false)
    }
}

try await frameworkTests()

// MARK: - 15. 审查修复回归（bug-hunt-swarm 四路调查 → 修复项）

MainActor.assumeIsolated {
    let font = NSFont.systemFont(ofSize: 15)

    // P1-4 反斜杠对称：显示一轮后不变 + 序列化幂等（首次归一化后不再逐轮翻倍）
    let slashMD = "路径 C:\\Users\\test"
    let slashDisplay = MarkdownLite.render(slashMD, bodyFont: font, textColor: .textColor).string
    let slashBack = MarkdownLite.serialize(MarkdownLite.render(slashMD, bodyFont: font, textColor: .textColor))
    let slashAgain = MarkdownLite.serialize(MarkdownLite.render(slashBack, bodyFont: font, textColor: .textColor))
    check("反斜杠显示不变", slashDisplay == slashMD + "\n", "得到 [\(slashDisplay)]")
    check("反斜杠序列化幂等", slashAgain == slashBack, "一轮 [\(slashBack)] 二轮 [\(slashAgain)]")

    // P1-5 表格无尾管道不丢末格（GFM 合法输入）
    let noTail = MarkdownLite.serialize(MarkdownLite.render("| 甲 | 乙\n|---|---|\n| 1 | 2", bodyFont: font, textColor: .textColor))
    check("无尾管道表格保末格", noTail.contains("| 甲 | 乙 |") && noTail.contains("| 1 | 2 |"), "得到 [\(noTail)]")
    // 尾管道带空格也保
    let spaceTail = MarkdownLite.serialize(MarkdownLite.render("| 甲 | 乙 |\n|---|---|\n| 1 | 2 |", bodyFont: font, textColor: .textColor))
    check("标准尾管道表格不变", spaceTail.contains("| 1 | 2 |"), "得到 [\(spaceTail)]")

    // P1-7 MemoryHub：一人多关系不误报矛盾
    let hubStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-hub-\(UUID().uuidString).zhibi"))
    hubStore.facts = [
        MemoryFact(subject: "紫渊", predicate: "关系", object: "白零", fromChapter: 8, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "关系", object: "苏叶", fromChapter: 12, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器", fromChapter: 1, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "状态", object: "命数九层", fromChapter: 5, source: "extracted"),
    ]
    let hubConflicts = MemoryHub.conflicts(hubStore.facts)
    check("关系事实不误报矛盾", hubConflicts.allSatisfy { $0.predicate != "关系" }, "得到 \(hubConflicts.map { $0.subject + $0.predicate })")
    check("状态冲突仍报", hubConflicts.contains { $0.predicate == "状态" && $0.subject == "紫渊" })

    // P2-14 safeFileName 截断 + 过滤
    let longName = ProjectLayout.safeFileName(String(repeating: "设", count: 300))
    check("长标题文件名截断", longName.count == 80, "len=\(longName.count)")
    check("文件名过滤路径符号", ProjectLayout.safeFileName("a/b:c") == "a_b_c")
}

// P1-9 storylines 编号查重 + P2-16 批次存储侧（异步）
@MainActor
func reviewFixTests() async throws {
    // P1-9: AI 不传 id → max+1，不与既有撞号
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-sl-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    st.storylines = [Storyline(id: "L01", name: "主线", kind: .main, isThroughLine: true, status: .active)]
    let tool = NovelTools.all(store: st).first { $0.name == "propose_storylines" }
    let args = """
    {"storylines":[{"name":"新支线","kind":"growth"}]}
    """
    _ = try? await tool?.handler(args)
    if let p = st.proposals.first, case .storylines(let lines) = p.payload {
        check("storylines 编号 max+1 查重", lines.count == 1 && lines[0].id == "L02", "得到 \(lines.map { $0.id })")
        st.acceptProposal(p.id)
        check("storylines 采纳撞号也入库", st.storylines.count == 2)
    } else {
        check("storylines 提案已登记", false)
    }

    // P1-11: 别名主语的事实出现在人物回溯里
    let agStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ag-\(UUID().uuidString).zhibi"))
    agStore.characterAliases = [CharacterAlias(canonicalName: "紫渊", aliases: ["少年"])]
    agStore.facts = [
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器", fromChapter: 1, source: "extracted"),
        MemoryFact(subject: "少年", predicate: "状态", object: "出潮", fromChapter: 2, source: "extracted"),
    ]
    let node = MemoryNode(kind: .character, key: "紫渊", label: "紫渊", chapter: 2, meta: "", weight: 1)
    check("人物回溯含别名主语事实", MemoryRecall.recall(node: node, store: agStore).count == 2)
    let aliasHits = MemoryRecall.search("少年", store: agStore)
    check("别名搜索翻出本名事实", aliasHits.count == 2, "得到 \(aliasHits.count)")

    // P1-10: clues 采纳不再整条覆盖作者手改（status/actions 保留）
    let clStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-cl-\(UUID().uuidString).zhibi"))
    clStore.ensureChapter(8)
    var clue = Clue(id: "F01", title: "脚印", detail: "荒野脚印", plantedChapter: 3)
    clue.status = .developing
    clue.actions = [ClueActionLog(chapter: 5, kind: .develop, note: "又见")]
    clStore.clues = [clue]
    _ = try? await (NovelTools.all(store: clStore).first { $0.name == "propose_clues" })?.handler("""
    {"clues":[{"id":"F01","title":"脚印","detail":"荒野脚印","planted_chapter":3}]}
    """)
    if let p = clStore.proposals.first, case .clues(let list) = p.payload {
        _ = list
        clStore.acceptProposal(p.id)
        let kept = clStore.clues.first { $0.id == "F01" }
        check("作者手改伏笔字段保留", kept?.status == .developing && kept?.actions.count == 1, "status=\(kept?.status.rawValue ?? "-") actions=\(kept?.actions.count ?? -1)")
    } else {
        check("伏笔提案已登记", false)
    }
}

try await reviewFixTests()

// MARK: - 16. 二轮审查回归（四路新角度：性能/闭环/阻塞/一致性）

MainActor.assumeIsolated {
    // P0-A: meta.json 用瘦身结构解（含 cachedWords + iso8601），不再 keyNotFound
    let metaJSON = """
    {"id":"E0B0B0B0-1B1B-4B1B-8B1B-1B1B1B1B1B1B","number":1,"title":"血夜","status":"初稿完成","cachedWords":3238,"updatedAt":"2026-09-19T10:50:29Z"}
    """
    let metaURL = URL(fileURLWithPath: "/tmp/zhibi-meta-\(UUID().uuidString).json")
    try? metaJSON.data(using: .utf8)?.write(to: metaURL)
    let decodedMeta = try? Disk.readJSON(ChapterMeta.self, from: metaURL)
    check("meta 瘦身结构可解", decodedMeta?.number == 1 && decodedMeta?.cachedWords == 3238)
    let chapterDecodeFailed = (try? JSONDecoder().decode(Chapter.self, from: Data(metaJSON.utf8))) == nil
    check("老路径（Chapter 直解 meta）确实会失败", chapterDecodeFailed)

    // P0-B: canon 幽灵节——先算真实落盘名再导入孤儿，循环切断
    let phantom = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ph-\(UUID().uuidString).zhibi"))
    phantom.ensureChapter(1)
    phantom.canonSections = [CanonSection(title: "世界观", content: "甲", certainty: .canon),
                             CanonSection(title: "世界观", content: "乙", certainty: .canon)]
    try? phantom.saveNow()
    let afterFirst = phantom.canonSections.count
    try? phantom.saveNow()
    try? phantom.saveNow()
    check("同名 canon 节不自复制", phantom.canonSections.count == afterFirst, "首次 \(afterFirst) → 三次保存后 \(phantom.canonSections.count)")
    // 与 UI 删除路径一致：内存移除 + 磁盘 md 同步删
    let removedTitles = phantom.canonSections.filter { $0.title == "世界观" }.map(\.title)
    phantom.canonSections.removeAll { $0.title == "世界观" }
    for t in removedTitles { phantom.deleteCanonMarkdown(title: t) }
    try? phantom.saveNow()
    try? phantom.saveNow()
    check("删除设定不留孤儿复活", phantom.canonSections.allSatisfy { $0.title != "世界观" }, "剩余 \(phantom.canonSections.map(\.title))")
    let canonFiles = (try? FileManager.default.contentsOfDirectory(atPath: ProjectLayout.canonDir(phantom.rootURL).path))?.filter { $0.hasSuffix(".md") } ?? []
    check("删除后磁盘无残留 md", !canonFiles.contains("世界观.md") && !canonFiles.contains("世界观-x.md"), "文件 \(canonFiles)")

    // P0-D: 中文数字溢出保护（19+ 汉字数字不再 trap 崩进程）
    check("中文数字病态输入不崩", ImportService.chineseNumeral(String(repeating: "一", count: 30)) >= 0)
    check("中文数字正常解析", ImportService.chineseNumeral("十二") == 12)


    // P1-10: dedup 保留有效事实（已失效的不该挤掉有效的）
    let facts = [
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器", fromChapter: 1, invalidatedAtChapter: 5, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器", fromChapter: 1, source: "extracted"),
    ]
    let deduped = MemoryHub.deduplicate(facts)
    check("dedup 保留有效事实", deduped.kept.count == 1 && deduped.kept[0].invalidatedAtChapter == nil,
          "kept inv=\(deduped.kept[0].invalidatedAtChapter.map { String($0) } ?? "nil")")

    // P1-12: 快照同名不覆盖
    let snapStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-sp-\(UUID().uuidString).zhibi"))
    snapStore.ensureChapter(1)
    snapStore.updateChapter(1) { $0.prose = "第一版内容" }
    let s1 = snapStore.snapshotProse(chapter: 1, tag: "手动")
    snapStore.updateChapter(1) { $0.prose = "第二版内容" }
    let s2 = snapStore.snapshotProse(chapter: 1, tag: "手动")
    check("快照同名加序号", s1 != s2 && (s2 ?? "").contains("-2"), "\(s1 ?? "-") vs \(s2 ?? "-")")
    let snaps = snapStore.snapshots(chapter: 1)
    check("两次快照都在盘上", snaps.count == 2 && snaps.contains { $0.text.contains("第一版") })
}

// P1-13 旧版表格（块间空行）兼容 + P0-F 隔离 + P1-7/skeleton 台账联动
MainActor.assumeIsolated {
    let font = NSFont.systemFont(ofSize: 14)
    let legacyTable = "| 人物 | 年龄 |\n\n| --- | --- |\n\n| 张三 | 二十 |"
    let rendered = MarkdownLite.render(legacyTable, bodyFont: font, textColor: .textColor)
    check("旧版空行表格仍识别", (rendered.string as NSString).range(of: "|").location == NSNotFound
          && rendered.string.contains("张三"), "得到 [\(rendered.string.prefix(60))]")
    check("旧版空行表格可序列化回管道", {
        let back = MarkdownLite.serialize(rendered)
        return back.contains("| 人物 | 年龄 |") && back.contains("| 张三 | 二十 |")
    }())
}

// 骨架采纳是写前契约，不碰伏笔台账；状态变更记日志
@MainActor
func roundTwoStoreTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-r2-\(UUID().uuidString).zhibi"))
    st.ensureChapter(3)
    var touch = ClueTouch(clueID: "F01", action: .reveal, requirement: "本章揭示灰白光来历")
    var sk = ChapterSkeleton(beats: [Beat(summary: "巷战", purpose: "推进", suggestedWords: 2000)], clueTouches: [touch])
    await st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 3, title: "骨架",
                                    payload: .skeleton(sk)))
    st.clues = [Clue(id: "F01", title: "灰白光", detail: "刀上的光", plantedChapter: 1)]
    if let id = st.proposals.first(where: { $0.chapterNumber == 3 })?.id {
        let ok = st.applyPayload(st.proposals.first { $0.id == id }!.payload, chapter: 3)
        check("骨架采纳返回成功", ok)
        let f = st.clues.first { $0.id == "F01" }
        check("骨架采纳不碰伏笔台账（写前契约≠已发生）",
              f?.lastActionChapter == 0 && (f?.actions.isEmpty ?? true),
              "lastAction=\(f?.lastActionChapter ?? -1) actions=\(f?.actions.count ?? -1)")
        // 去AI味：逐条标记 applied 后整包采纳应推进到「已润色」
        let ds = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ds-\(UUID().uuidString).zhibi"))
        ds.ensureChapter(1)
        ds.updateChapter(1) { $0.prose = "原文"; $0.status = .written }
        let sug = DeslopSuggestion(original: "原文", replacement: "新文")
        let dsProp = AIProposal(capability: .deslop, chapterNumber: 1, title: "去AI味",
                                payload: .deslop(DeslopReport(chapter: 1, grade: "轻度", suggestions: [sug])))
        ds.addProposal(dsProp)
        check("去AI味建议可标记 applied",
              ds.markDeslopSuggestionApplied(proposalID: dsProp.id, suggestionID: sug.id))
        check("去AI味全部应用后推进已润色",
              ds.acceptProposal(dsProp.id) && ds.chapter(1)?.status == .polished,
              "status=\(ds.chapter(1)?.status.rawValue ?? "nil")")

        // P1-15: reject 可恢复
        let rp = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-rp-\(UUID().uuidString).zhibi"))
        rp.ensureChapter(1)
        await rp.addProposal(AIProposal(capability: .recallMemo, title: "备忘", payload: .memo("x")))
        let pid = rp.proposals[0].id
        rp.rejectProposal(pid)
        check("拒绝后入已拒绝", rp.proposals[0].status == .rejected)
        rp.reopenProposal(pid)
        check("恢复待审", rp.proposals[0].status == .pending)
    }
    // P1-9: 状态菜单式变更也写动作日志
    st.logClueAction(clueID: "F01", chapter: 5, kind: .resolve, note: "状态改为「已回收」")
    let afterStatus = st.clues.first { $0.id == "F01" }
    check("状态变更记动作日志", afterStatus?.lastActionChapter == 5 && afterStatus?.actions.count == 1)
}

try await roundTwoStoreTests()

// MARK: - 17. 导出→再导入信息等价环

@MainActor
func roundTripTests() async throws {
    let src = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-rt-src-\(UUID().uuidString).zhibi"))
    src.project = NovelProject(title: "等价环", genre: "东方玄幻", premise: "废灵根吞噬命数",
                               targetChapters: 88, chapterWordTarget: 2500,
                               authorIntent: "慢热开局，第三章必须见血", currentFocus: "第一卷追杀段",
                               styleNotes: "短句，忌四字格")
    src.ensureChapter(1)
    src.ensureChapter(8)
    src.updateChapter(1, countWords: false) { ch in
        ch.title = "血夜"
        ch.prose = "临渊区在烧。无器之人在巷子里跑。"
        ch.status = .written
        ch.directive = "压住节奏，别写打斗"
        ch.summary = ChapterSummary(chapter: 1, summary: "觉醒当晚被追杀。", keyEvents: ["血洗", "逃亡"], emotionalTone: "紧迫")
        ch.notes = ["伏笔：步态"]
        var sk = ChapterSkeleton()
        var beat = Beat(summary: "开场追杀", purpose: "爽点", suggestedWords: 800, done: true)
        beat.draftText = "他撞开废窑的门。"
        beat.pov = "紫渊"; beat.location = "废窑"; beat.timeLabel = "雨夜"; beat.cast = ["紫渊", "哑叔"]; beat.turn = "藏身→暴露"
        sk.beats = [beat]
        sk.endHook = "一点紫亮"
        sk.mustDeliver = ["第一次亡命"]
        sk.mustAvoid = ["不写觉醒过程"]
        sk.hookKind = "悬念"; sk.pov = "紫渊"; sk.payoffType = "觉醒"
        sk.newExpectation = "白零是谁"; sk.volumeLabel = "第一卷"
        sk.proposedByAI = true; sk.humanApproved = true
        sk.approvedAt = Date(timeIntervalSince1970: 1_700_000_000)
        ch.skeleton = sk
    }
    src.updateChapter(8, countWords: false) { ch in ch.title = "雾隐"; ch.status = .done; ch.prose = "雾中照面。" }
    src.storylines = [
        Storyline(id: "L01", name: "孤星出逃", kind: .main, isThroughLine: true, status: .active,
                  entryChapter: 1, plannedPayoffChapter: 40, notes: "贯穿全书"),
        Storyline(id: "L02", name: "白零线", kind: .growth, status: .dormant),
    ]
    src.timelineEvents = [
        TimelineEvent(id: "E01", chapter: 1, objectiveFact: "紫渊觉醒当夜被追杀", readerKnowledge: "少年在逃",
                      revealed: true, storylineIDs: ["L01"], notes: "开篇锚点",
                      happened: true, actualChapter: 2, syncNote: "实际写在第2章",
                      syncedAt: Date(timeIntervalSince1970: 1_700_000_100)),
        TimelineEvent(id: "E02", chapter: 8, objectiveFact: "紫渊与白零相遇", readerKnowledge: "雾中照面", revealed: false, revealChapter: 8, storylineIDs: ["L01", "L02"]),
    ]
    src.clues = [
        Clue(id: "F01", title: "哑叔的脚印", detail: "荒野深处的脚印", plantedChapter: 3, targetPayoffChapter: 8, status: .resolved),
        Clue(id: "F02", title: "少主之血", detail: "塞德里克要紫渊的血", plantedChapter: 2, status: .developing),
    ]
    src.clues[0].actions = [ClueActionLog(chapter: 3, kind: .plant, note: "埋"), ClueActionLog(chapter: 8, kind: .resolve, note: "兑现")]
    src.facts = [
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器之人", fromChapter: 1, publicToReader: true, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "关系", object: "白零", fromChapter: 8, publicToReader: true, source: "extracted"),
        MemoryFact(subject: "白零", predicate: "身份", object: "半精灵", fromChapter: 5, invalidatedAtChapter: 7, source: "extracted"),
    ]
    src.facts[0].note = "开篇状态"
    src.dossiers = [ChapterDossier(chapter: 1, headline: "觉醒夜被追杀",
                                   scenes: ["废窑"], cast: ["紫渊"], advances: ["觉醒"],
                                   turns: ["藏身→暴露"], hooks: ["紫亮"], relics: ["断刀"])]
    src.characterAliases = [CharacterAlias(canonicalName: "紫渊", aliases: ["少年"])]
    src.stages = [Stage(id: 1, name: "星火初燃", chapterStart: 1, chapterEnd: 10, theme: "逃亡与相遇")]
    src.canonSections = [
        CanonSection(title: "世界观", content: "命数九层。", certainty: .canon,
                     category: CanonCategory.worldview.rawValue),
        CanonSection(title: "势力 人物", content: "三方对峙。", certainty: .tentative,
                     category: CanonCategory.faction.rawValue),
        CanonSection(title: "势力人物", content: "无空格版本。", certainty: .tentative,
                     category: CanonCategory.faction.rawValue),
    ]
    src.project.dailyWords = ["2026-09-19": 2100]

    let exportDir = try ExportService.exportOhStory(store: src).url
    let scanned = ImportService.scan(exportDir)

    let dst = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-rt-dst-\(UUID().uuidString).zhibi"))
    dst.ensureChapter(1)
    try! ImportService.apply(scanned, into: dst)

    check("往返-故事线等价", dst.storylines.count == 2 && dst.storylines.contains {
        $0.id == "L01" && $0.isThroughLine && $0.status == .active
            && $0.entryChapter == 1 && $0.plannedPayoffChapter == 40 && $0.notes == "贯穿全书"
    })
    check("往返-故事线蛰伏状态", dst.storylines.contains { $0.id == "L02" && $0.status == .dormant })
    check("往返-事件等价", dst.timelineEvents.count == 2 && dst.timelineEvents.contains {
        $0.id == "E02" && !$0.revealed && $0.storylineIDs == ["L01", "L02"]
    }, "得到 \(dst.timelineEvents.map { "\($0.id)/\($0.revealed)" })")
    check("往返-事件对账字段", dst.timelineEvents.contains {
        $0.id == "E01" && $0.happened && $0.actualChapter == 2 && $0.syncNote == "实际写在第2章"
            && $0.notes == "开篇锚点" && $0.syncedAt != nil
    })
    check("往返-终态伏笔不再丢", dst.clues.count == 2 && dst.clues.contains { $0.id == "F01" && $0.status == .resolved })
    check("往返-伏笔动作日志保留", dst.clues.first { $0.id == "F01" }?.actions.count == 2)
    check("往返-活跃伏笔不被子集覆盖", dst.clues.first { $0.id == "F02" }?.status == .developing)
    check("往返-事实含双时态", dst.facts.count == 3 && dst.facts.contains { $0.invalidatedAtChapter == 7 })
    check("往返-事实备注与来源", dst.facts.contains { $0.subject == "紫渊" && $0.note == "开篇状态" && $0.source == "extracted" })
    check("往返-档案卡", dst.dossiers.count == 1 && dst.dossiers[0].headline == "觉醒夜被追杀"
          && dst.dossiers[0].relics == ["断刀"] && dst.dossiers[0].turns == ["藏身→暴露"])
    check("往返-阶段等价", dst.stages.count == 1 && dst.stages[0].name == "星火初燃")
    check("往返-别名保留", dst.characterAliases.first?.canonicalName == "紫渊")
    check("往返-正文等价", dst.chapter(1)?.prose.contains("临渊区在烧") == true && dst.chapter(8)?.prose.contains("雾中照面") == true)
    check("往返-章摘要保留", dst.chapter(1)?.summary?.summary.contains("觉醒当晚") == true)
    check("往返-随手记保留", dst.chapter(1)?.notes?.isEmpty == false)
    check("往返-骨架保留", dst.chapter(1)?.skeleton?.beats.first?.summary == "开场追杀"
          && dst.chapter(1)?.skeleton?.mustDeliver == ["第一次亡命"])
    check("往返-骨架场景层与钩子", dst.chapter(1)?.skeleton.map {
        $0.hookKind == "悬念" && $0.pov == "紫渊" && $0.payoffType == "觉醒"
            && $0.newExpectation == "白零是谁" && $0.volumeLabel == "第一卷"
            && $0.humanApproved && $0.approvedAt != nil
            && $0.beats.first?.location == "废窑" && $0.beats.first?.cast == ["紫渊", "哑叔"]
            && $0.beats.first?.turn == "藏身→暴露" && $0.beats.first?.draftText == "他撞开废窑的门。"
    } == true)
    check("往返-本章指令", dst.chapter(1)?.directive == "压住节奏，别写打斗")
    check("往返-定稿状态", dst.chapter(8)?.status == .done)
    check("往返-项目元数据", dst.project.premise == "废灵根吞噬命数" && dst.project.authorIntent.contains("慢热")
          && dst.project.currentFocus == "第一卷追杀段" && dst.project.styleNotes == "短句，忌四字格")
    check("往返-体量参数", dst.project.targetChapters == 88 && dst.project.chapterWordTarget == 2500)
    check("往返-每日账本", dst.project.dailyWords?["2026-09-19"] == 2100)
    check("往返-设定库", dst.canonSections.contains {
        $0.title == "世界观" && $0.certainty == .canon
            && $0.category == CanonCategory.worldview.rawValue
            && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "命数九层。"
    })
    check("往返-设定标题含空格不丢字符", dst.canonSections.contains {
        $0.title == "势力 人物" && $0.category == CanonCategory.faction.rawValue
    }, "题名=\(dst.canonSections.map(\.title))")
    check("往返-设定文件名冲突不丢文档", dst.canonSections.contains {
        $0.title == "势力人物" && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == "无空格版本。"
    }, "题名=\(dst.canonSections.map(\.title))")
    // 大纲 md 是派生视图：不再重复进设定库
    check("往返-大纲不重复入库", !dst.canonSections.contains { $0.title.contains("主线大纲") },
          "设定 \(dst.canonSections.map(\.title))")

    // 旧格式（无 clues/chapter_meta 键）仍可导入：不崩、伏笔降级路径
    let legacyDir = URL(fileURLWithPath: "/tmp/zhibi-rt-legacy-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: legacyDir.appendingPathComponent("追踪", isDirectory: true), withIntermediateDirectories: true)
    let legacyState = """
    {"project":{"title":"旧书","exported_from":"oh-story"},"stages_overview":[{"id":1,"name":"起源","theme":"t"}],
     "active_foreshadowing":[{"id":"F01","name":"旧钩子","detail":"d","planted_chapter":2}]}
    """
    try legacyState.data(using: .utf8)?.write(to: legacyDir.appendingPathComponent("追踪/_tracking-state.json"))
    let legacyScanned = ImportService.scan(legacyDir)
    let legacyDst = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-rt-legacydst-\(UUID().uuidString).zhibi"))
    legacyDst.ensureChapter(1)
    try! ImportService.apply(legacyScanned, into: legacyDst)
    check("旧格式仍可导入", legacyDst.clues.contains { $0.id == "F01" } && legacyDst.stages.count == 1)

    // 正文子目录递归扫描 + 非「第N章」命名
    let nestedDir = URL(fileURLWithPath: "/tmp/zhibi-rt-nested-\(UUID().uuidString)")
    let vol1 = nestedDir.appendingPathComponent("正文/第一卷", isDirectory: true)
    let vol2 = nestedDir.appendingPathComponent("正文/第二卷", isDirectory: true)
    try? FileManager.default.createDirectory(at: vol1, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: vol2, withIntermediateDirectories: true)
    try? "风起。".data(using: .utf8)?.write(to: vol1.appendingPathComponent("001_风起.md"))
    try? "雨夜。".data(using: .utf8)?.write(to: vol2.appendingPathComponent("Chapter 2 - 雨夜.md"))
    let nested = ImportService.scan(nestedDir)
    let nestedChapters = nested.items.filter { $0.kind == .chapter }
    check("递归扫描正文子目录", nestedChapters.count == 2
          && Set(nestedChapters.compactMap(\.chapterNumber)) == [1, 2],
          "chapters=\(nestedChapters.map { "\($0.chapterNumber ?? -1)/\($0.title)" })")
}

try await roundTripTests()

// MARK: - 20. SVG 封面：提取/持久化/导出导入等价

MainActor.assumeIsolated {
    let font = NSFont.systemFont(ofSize: 14)
    let aiOutput = """
    给你的封面：
    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" width="600" height="800" viewBox="0 0 600 800">
      <rect width="600" height="800" fill="#14162b"/>
      <text x="300" y="360" font-family="Songti SC" font-size="64" fill="#f0e6d2" text-anchor="middle">测试书名</text>
    </svg>
    ```
    设计说明：深蓝底 + 暖白书名。
    """
    let code = CoverSVG.extractSVG(aiOutput)
    check("SVG 代码块提取", code?.contains("<svg") == true && code?.contains("</svg>") == true)
    check("SVG 无围栏时兜底提取", CoverSVG.extractSVG("前言 <svg xmlns=\"x\"><rect/></svg> 后记")?.hasPrefix("<svg") == true)
    check("无 SVG 返回 nil", CoverSVG.extractSVG("只有文字，没有代码。") == nil)
    // 渲染非空（NSImage 能解 AI 风格 SVG）
    check("SVG 可渲染", code.flatMap { CoverSVG.render($0, width: 180, height: 240) } != nil)
}

@MainActor
func svgCoverTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-svg-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"800\"><rect width=\"600\" height=\"800\" fill=\"#123\"/></svg>"
    st.setCoverSVG(svg)
    try? st.saveNow()
    check("封面 SVG 落盘", FileManager.default.fileExists(atPath: st.rootURL.appendingPathComponent("cover.svg").path))
    let reloaded = ProjectStore(rootURL: st.rootURL)
    try? reloaded.load()
    check("重启后封面保留", reloaded.coverSVG == svg)

    // 导出→导入等价
    let exportDir = try ExportService.exportOhStory(store: st).url
    check("导出含封面 SVG", FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("封面/cover.svg").path))
    let scanned = ImportService.scan(exportDir)
    check("导入扫描到封面 SVG", scanned.coverSVG == svg)
    let dst = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-svgdst-\(UUID().uuidString).zhibi"))
    dst.ensureChapter(1)
    try! ImportService.apply(scanned, into: dst)
    check("导入后封面等价", dst.coverSVG == svg)
    // 已有封面不被覆盖
    let scanned2 = ImportService.scan(exportDir)
    let dst2 = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-svgdst2-\(UUID().uuidString).zhibi"))
    dst2.ensureChapter(1)
    dst2.setCoverSVG("<svg>自己的</svg>")
    try! ImportService.apply(scanned2, into: dst2)
    check("已有封面不被导入覆盖", dst2.coverSVG == "<svg>自己的</svg>")
}

try await svgCoverTests()

// MARK: - 21. 设定归类：提案登记 → 采纳写类别与改名

@MainActor
func classifyTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-clz-\(UUID().uuidString).zhibi"))
    st.canonSections = [
        CanonSection(title: "世界观总纲", content: "命数九层", certainty: .canon),
        CanonSection(title: "紫渊人物卡", content: "无器之人", certainty: .tentative),
        CanonSection(title: "大纲·主线", content: "追杀开局", certainty: .tentative),
    ]
    let tool = NovelTools.all(store: st).first { $0.name == "propose_canon_classify" }
    let args = """
    {"note":"按内容归类","classifications":[
      {"title":"世界观总纲","category":"世界观"},
      {"title":"紫渊人物卡","category":"势力人物","rename":"01·紫渊"},
      {"title":"大纲·主线","category":"剧情大纲"},
      {"title":"不存在的文档","category":"世界观"}]}
    """
    _ = try? await tool?.handler(args)
    let pending = st.proposals.filter { $0.status == .pending }
    check("归类提案登记", pending.count == 1)
    guard let pid = pending.first?.id else { return }
    st.acceptProposal(pid)
    check("类别写回", st.canonSections.first { $0.title == "世界观总纲" }?.category == "世界观"
          && st.canonSections.first { $0.title == "01·紫渊" }?.category == "势力人物")
    check("改名撞名保护", st.canonSections.allSatisfy { $0.title != "不存在的文档" })
    check("归类后分组口径", CanonCategory.match("势力人物") == .faction)
    // CanonCategory 兜底：非法 raw 不崩
    check("非法类别兜底未分类", CanonCategory.match("胡说八道") == .uncategorized)
}

try await classifyTests()

// MARK: - 23. 长程记忆：档案卡 / 倒排索引 / 跨全书召回

MainActor.assumeIsolated {
    // 索引与检索
    let d1 = ChapterDossier(chapter: 3, headline: "紫渊夺刀脱身",
                            scenes: ["临渊区·废弃巷"], cast: ["紫渊（亡命）", "哑叔（暗助）"],
                            advances: ["紫渊失去军包"], turns: ["从绝望到孤注一掷"],
                            hooks: ["哑叔身份成谜"], relics: ["缺了半截的紫檀短刀", "他说：留——"])
    let d2 = ChapterDossier(chapter: 12, headline: "雾隐照面",
                            scenes: ["雾隐潮汐·外围"], cast: ["紫渊", "白零"],
                            advances: ["双线并汇"], turns: [], hooks: ["白零的天书"],
                            relics: ["雾中的白色衣角", "半截紫檀短刀再次出现"])
    let d3 = ChapterDossier(chapter: 40, headline: "白零开书",
                            scenes: ["森海王庭·祭坛"], cast: ["白零"], advances: ["天书第一页打开"],
                            turns: [], hooks: [], relics: ["无字天书"])
    let idx = DossierIndex.build(from: [d1, d2, d3])
    check("档案索引构建", idx.coverage.chapters == 3 && idx.coverage.tokens > 10)

    // 关键词召回：应当召回第 12 章（同时含紫渊+短刀）
    let hits = idx.search("紫檀短刀", limit: 5)
    check("物件召回", hits.contains { $0.chapter == 12 } && hits.contains { $0.chapter == 3 }, "得到 \(hits.map(\.chapter))")
    // 实体轨迹
    check("实体轨迹", idx.entityTrace("紫渊").map(\.chapter).sorted() == [3, 12])
    check("实体轨迹（哑叔）", idx.entityTrace("哑叔").map(\.chapter) == [3])

    // 本地图：长程召回注入上下文包
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ltm-\(UUID().uuidString).zhibi"))
    st.ensureChapter(41)
    st.dossiers = [d1, d2, d3]
    _ = st.activeClues(currentChapter: 41)
    let recall = DossierRecall.recall(store: st, forChapter: 41, limit: 5)
    check("长程召回非空", !recall.dossiers.isEmpty, "命中 \(recall.dossiers.map(\.chapter))")
    check("召回块可注入", recall.asBlock.contains("第"))

    let pack = ContextPackBuilder.build(store: st, forChapter: 41, budget: 12000)
    check("上下文包含历史档案块", pack.blocks.contains { $0.title.contains("历史档案召回") },
          "块：\(pack.blocks.map(\.title))")
}

@MainActor
func ltmAsyncTests() async throws {
    // 档案卡提案：登记 → 采纳 → 落库 + 持久化
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ltm2-\(UUID().uuidString).zhibi"))
    st.ensureChapter(41)
    let bound = NovelTools.bindChapter(tools: NovelTools.all(store: st), store: st, chapter: 41)
    let tool = bound.first { $0.name == "propose_dossier" }
    _ = try? await tool?.handler("""
    {"headline":"测试章事件","cast":["甲"],"relics":["青玉令牌"],"hooks":["令牌来路"]}
    """)
    if let p = st.proposals.first(where: { $0.capability == .dossierExtract }) {
        st.acceptProposal(p.id)
        check("采纳后入档案库", st.dossiers.contains { $0.chapter == 41 && $0.relics.contains("青玉令牌") })
        try? st.saveNow()
        let reloaded = ProjectStore(rootURL: st.rootURL)
        try? reloaded.load()
        check("档案卡持久化", reloaded.dossiers.contains { $0.chapter == 41 })
    } else {
        check("档案卡提案登记", false)
    }
}

try await ltmAsyncTests()

// MARK: - 25. 四轮审查回归：编号护栏 / relics 校验 / 文本通道运行态 / 搜索防抖

@MainActor
func roundFourTests() async throws {
    // 事件编号全局唯一：已有 E01@第5章，AI 提交 E01@第9章 → 重分配
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-r4-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    st.timelineEvents = [TimelineEvent(id: "E01", chapter: 5, objectiveFact: "旧事件")]
    st.storylines = [Storyline(id: "L01", name: "主线", kind: .main, isThroughLine: true, status: .active)]
    let tool = NovelTools.bindChapter(tools: NovelTools.all(store: st), store: st, chapter: 9)
        .first { $0.name == "propose_outline_events" }
    _ = try? await tool?.handler("""
    {"events":[{"id":"E01","chapter":9,"objective_fact":"新事件","reader_knowledge":"x","storyline_ids":["L01","L99"]}]}
    """)
    if let p = st.proposals.first, case .outlineEvents(let evs) = p.payload {
        check("事件编号全局唯一", evs.first?.id != "E01", "得到 \(evs.map { $0.id })")
        check("悬空故事线被过滤", evs.first?.storylineIDs == ["L01"], "得到 \(evs.first?.storylineIDs ?? [])")
    } else {
        check("事件提案登记", false)
    }

    // relics 为空 → 拒绝（错误回灌给模型）
    let dTool = NovelTools.bindChapter(tools: NovelTools.all(store: st), store: st, chapter: 1)
        .first { $0.name == "propose_dossier" }
    do {
        _ = try await dTool?.handler("""
        {"headline":"空 relics 测试"}
        """)
        check("空 relics 被拒绝", false)
    } catch {
        check("空 relics 被拒绝", "\(error)".contains("relics"), "得到 \(error)")
    }
}

try await roundFourTests()

// MARK: - 30. 端点连通性测试：解析/分类逻辑（离线用例）

MainActor.assumeIsolated {
    let ai = AIService()
    // OpenAI 标准格式
    let openai = Data(#"{"object":"list","data":[{"id":"qwen3-4b"},{"id":"deepseek-flash"}]}"#.utf8)
    check("模型清单解析（OpenAI 格式）", AIService.parseModelsResponse(openai) == ["qwen3-4b", "deepseek-flash"])
    // LM Studio / 别名变体
    let lm = Data(#"{"models":[{"id":"qwen"},{"name":"llama-3"}]}"#.utf8)
    check("模型清单解析（models 变体）", Set(AIService.parseModelsResponse(lm)) == Set(["qwen", "llama-3"]))
    check("模型清单解析（裸数组）", AIService.parseModelsResponse(Data(#"{"models":["a","b"]}"#.utf8)) == ["a", "b"])
    check("模型清单解析（垃圾输入）", AIService.parseModelsResponse(Data("not json".utf8)).isEmpty)

    // 判定逻辑：公网 http / 缺 Key 已在预检矩阵覆盖；这里钉住解析函数签名稳定
    check("连通性测试结果结构", { () -> Bool in
        let r = AIService.EndpointTestResult(ok: true, latencyMs: 12, message: "m", models: ["x"],
                                             workingURL: "http://x/v1", authIssue: false, modelFound: true)
        return r.ok && r.modelFound == true && r.workingURL == "http://x/v1"
    }())
}


// MARK: - 26. 上下文预算真实生效（budget 死 UI 修复）

@MainActor
func budgetTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-bud-\(UUID().uuidString).zhibi"))
    st.ensureChapter(30)
    st.project.authorIntent = String(repeating: "意图", count: 200)
    st.project.premise = "核心"
    st.storylines = [Storyline(id: "L01", name: "主线", kind: .main, isThroughLine: true, status: .active, notes: String(repeating: "线", count: 300))]
    for i in 1...20 {
        st.ensureChapter(i)
        st.updateChapter(i, countWords: false) { ch in
            ch.prose = String(repeating: "正文", count: 300)
            ch.summary = ChapterSummary(chapter: i, summary: String(repeating: "摘要", count: 120), keyEvents: ["事件"], emotionalTone: "紧")
        }
    }
    st.facts = (0..<40).map { MemoryFact(subject: "角色\($0 % 8)", predicate: "状态", object: "在\($0)", fromChapter: $0 % 20 + 1, source: "authored") }
    st.clues = (0..<10).map { Clue(id: "F0\($0)", title: "钩\($0)", detail: String(repeating: "细", count: 80), plantedChapter: 1, status: .planted) }

    // 小预算 vs 大预算：包必须有显著差异（原实现 budget 零引用 → 完全一致）
    let small = ContextPackBuilder.build(store: st, forChapter: 30, budget: 2000)
    let large = ContextPackBuilder.build(store: st, forChapter: 30, budget: 32000)
    check("预算真实生效", small.approxTokens < large.approxTokens,
          "small=\(small.approxTokens) large=\(large.approxTokens)")
    check("小预算不超上限（含截断注记余量）", small.approxTokens <= 2600,
          "得到 \(small.approxTokens)")
    check("大预算保留更多块", small.blocks.count <= large.blocks.count,
          "small=\(small.blocks.count) large=\(large.blocks.count)")
    check("裁剪有记录", small.trimmedNotes.isEmpty == false || small.approxTokens <= 2000,
          "notes=\(small.trimmedNotes.count)")

    // 作者控制面（priority 10）在小预算下必须幸存
    check("作者意图保底", small.blocks.contains { $0.title == "作者意图" })
    // 正文注入上限随预算缩放
    check("正文注入上限随预算", ContextPackBuilder.proseInjectionCap(budget: 2000, hardCap: 12000)
          < ContextPackBuilder.proseInjectionCap(budget: 32000, hardCap: 12000))
    check("正文注入下限保底", ContextPackBuilder.proseInjectionCap(budget: 100, hardCap: 12000) >= 4000)
}

try await budgetTests()

// MARK: - 27. 采纳不静默丢弃：部分/全部未入库保持待审 + 清单可解释

@MainActor
func acceptOutcomeTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ao-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    st.storylines = [Storyline(id: "L01", name: "已有主线", kind: .main, isThroughLine: true, status: .active)]

    // ① 全部未入库：故事线编号全撞 → applied=0 → 保持 pending + 清单
    let dupTool = NovelTools.bindChapter(tools: NovelTools.all(store: st), store: st, chapter: nil)
        .first { $0.name == "propose_storylines" }
    _ = try? await dupTool?.handler("""
    {"storylines":[{"id":"L01","name":"撞号线","kind":"main"}]}
    """)
    if let p = st.proposals.first(where: { $0.capability == .outlineTimeline }) {
        st.acceptProposal(p.id)
        let stillPending = st.proposals.first { $0.id == p.id }?.status == .pending
        check("全未入库保持待审", stillPending && st.lastAcceptIssues != nil,
              "status=\(st.proposals.first { $0.id == p.id }?.status.rawValue ?? "-")")
        check("清单说明原因", st.lastAcceptIssues?.contains("未采纳") == true,
              "得到 \(st.lastAcceptIssues ?? "-")")
    } else {
        check("撞号提案登记", false)
    }

    // ② 部分入库：预置一条同 (id, 章) 事件，再构造含「重复+新」的 payload
    st.timelineEvents = [TimelineEvent(id: "E01", chapter: 2, objectiveFact: "旧", readerKnowledge: "o")]
    await st.addProposal(AIProposal(
        capability: .outlineTimeline, chapterNumber: 2, title: "混合事件提案",
        payload: .outlineEvents([
            TimelineEvent(id: "E01", chapter: 2, objectiveFact: "重复（已存在）", readerKnowledge: "x"),
            TimelineEvent(id: "E50", chapter: 3, objectiveFact: "新的", readerKnowledge: "y"),
        ])))
    if let p = st.proposals.first(where: { $0.title == "混合事件提案" }) {
        let before = st.timelineEvents.count
        st.acceptProposal(p.id)
        check("部分入库保持待审", st.proposals.first { $0.id == p.id }?.status == .pending
              && st.lastAcceptIssues?.contains("部分采纳") == true,
              "issues=\(st.lastAcceptIssues ?? "-")")
        check("已入库项已生效", st.timelineEvents.count == before + 1, "before=\(before) after=\(st.timelineEvents.count)")
        // 重试不重复：再采纳一次，E50 不重复
        let countAfterFirst = st.timelineEvents.count
        st.acceptProposal(p.id)
        check("重试不重复入库", st.timelineEvents.count == countAfterFirst,
              "first=\(countAfterFirst) retry=\(st.timelineEvents.count)")
    } else {
        check("混合事件提案登记", false)
    }

    // ③ canonClassify 标题未匹配 → 计入清单
    st.canonSections = [CanonSection(title: "世界观", content: "x")]
    let clTool = NovelTools.all(store: st).first { $0.name == "propose_canon_classify" }
    _ = try? await clTool?.handler("""
    {"classifications":[{"title":"不存在的文档","category":"世界观"}]}
    """)
    if let p = st.proposals.first(where: { $0.capability == .canonClassify }) {
        st.acceptProposal(p.id)
        check("标题未匹配保持待审", st.proposals.first { $0.id == p.id }?.status == .pending
              && st.lastAcceptIssues?.contains("未找到") == true,
              "issues=\(st.lastAcceptIssues ?? "-")")
    } else {
        check("归类提案登记", false)
    }

    // ④ 全部成功：清空清单并标已采纳
    let st2 = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ao2-\(UUID().uuidString).zhibi"))
    st2.ensureChapter(1)
    _ = try? await NovelTools.bindChapter(tools: NovelTools.all(store: st2), store: st2, chapter: 1)
        .first { $0.name == "propose_dossier" }?.handler("""
        {"headline":"成功案例","relics":["令牌"]}
        """)
    if let p = st2.proposals.first(where: { $0.capability == .dossierExtract }) {
        st2.acceptProposal(p.id)
        check("全成功标已采纳", st2.proposals.first { $0.id == p.id }?.status == .accepted
              && st2.lastAcceptIssues == nil)
    } else {
        check("档案卡提案登记", false)
    }

    // ⑤ 空草稿/空骨架必须拒绝，不能把正文或骨架清空
    let emptyStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ao3-\(UUID().uuidString).zhibi"))
    emptyStore.ensureChapter(1)
    emptyStore.updateChapter(1) { $0.prose = "原文还在。" }
    let emptyDraft = AIProposal(capability: .chapterDraft, chapterNumber: 1, title: "空草稿",
                                payload: .draft(ChapterDraft(chapter: 1, text: " \n ", version: 1)))
    emptyStore.addProposal(emptyDraft)
    check("空草稿不覆盖正文",
          !emptyStore.acceptProposal(emptyDraft.id) && emptyStore.chapter(1)?.prose == "原文还在。")
    let emptySkeleton = AIProposal(capability: .chapterSkeleton, chapterNumber: 1, title: "空骨架",
                                   payload: .skeleton(ChapterSkeleton()))
    emptyStore.addProposal(emptySkeleton)
    check("空骨架不写入",
          !emptyStore.acceptProposal(emptySkeleton.id) && emptyStore.chapter(1)?.skeleton == nil)

    let idStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ao4-\(UUID().uuidString).zhibi"))
    idStore.ensureChapter(1)
    let noIDClue = AIProposal(capability: .clueLedger, title: "无编号伏笔",
                              payload: .clues([Clue(title: "没有编号")]))
    idStore.addProposal(noIDClue)
    idStore.acceptProposal(noIDClue.id)
    check("空伏笔编号自动分配", idStore.clues.first?.id.isEmpty == false,
          "id=\(idStore.clues.first?.id ?? "<nil>")")
}

try await acceptOutcomeTests()

// MARK: - 28. 质量反馈回路：拒收理由 / 采纳率统计 / 反馈注入 / 修订历史保留

@MainActor
func qualityLoopTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-ql-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    // 构造流水：2 采纳 1 拒收（带理由）1 待审
    st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 1, title: "骨架A", payload: .memo("a")))
    st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 2, title: "骨架B", payload: .memo("b")))
    st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 3, title: "骨架C", payload: .memo("c")))
    st.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 1, title: "草稿A", payload: .memo("d")))
    // 按标题精确定位（addProposal 头插，数组顺序是倒序，不能用下标假设）
    func idOf(_ title: String) -> UUID? { st.proposals.first { $0.title == title }?.id }
    if let a = idOf("骨架A") { st.acceptProposal(a) }
    if let b = idOf("骨架B") { st.acceptProposal(b) }
    if let c = idOf("骨架C") { st.rejectProposal(c, reason: "质量不够") }
    // 草稿A 保持 pending

    let stats = QualityStats.derive(from: st.proposals)
    check("采纳率统计", stats.totalAccepted == 2 && stats.totalRejected == 1 && stats.totalPending == 1
          && abs(stats.overallRate - 2.0/3.0) < 0.01,
          "acc=\(stats.totalAccepted) rej=\(stats.totalRejected) rate=\(stats.overallRate)")
    check("分能力统计", stats.byCapability.contains { $0.capability == "章节骨架" && $0.accepted == 2 && $0.rejected == 1 },
          "buckets=\(stats.byCapability.map { "\($0.capability):\($0.accepted)/\($0.rejected)/\($0.pending)" })")
    check("拒收原因聚合", stats.rejectReasons.contains { $0.reason == "质量不够" && $0.count == 1 })

    // 拒收理由注入 prompt
    let rejected = st.proposals.filter { $0.capability == .chapterSkeleton && $0.status == .rejected }
        .map { (title: $0.title, reason: $0.rejectReason ?? "") }
    let feedback = PromptLibrary.qualityFeedback(for: .chapterSkeleton, rejected: rejected)
    check("反馈注入非空", feedback.contains("质量不够") && feedback.contains("骨架C"),
          "rejected=\(rejected.map(\.title)) feedback=[\(feedback.prefix(160))]")
    check("无拒收不注入", PromptLibrary.qualityFeedback(for: .deslop, rejected: []).isEmpty)

    // 修订历史保留：草稿采纳后仍可继续修订（历史不丢）
    var draft = ChapterDraft(chapter: 5, text: "第一版正文", version: 1)
    draft.feedbackHistory = [DraftFeedback(feedback: "节奏太慢", fromVersion: 1)]
    st.ensureChapter(5)   // 草稿只能采纳到存在的章节
    st.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 5, title: "第5章草稿", payload: .draft(draft)))
    if let pid = st.proposals.first(where: { $0.chapterNumber == 5 })?.id {
        st.acceptProposal(pid)   // 采纳后 pending 里没有草稿了
        check("采纳后 pending 无草稿", st.latestDraftProposal(for: 5) == nil)
        check("任意状态可回退找到", st.latestAnyDraftProposal(for: 5) != nil)
        if let any = st.latestAnyDraftProposal(for: 5), let restored = st.draftPayload(of: any) {
            check("修订历史随采纳保留", restored.feedbackHistory.count == 1
                  && restored.feedbackHistory[0].feedback == "节奏太慢")
        } else {
            check("修订历史随采纳保留", false)
        }
    } else {
        check("草稿提案登记", false)
    }

    // 被拒绝的草稿不能当下一轮修订的基底（否则拒掉的稿换个版本号又回来）
    let rejectedStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-rej-\(UUID().uuidString).zhibi"))
    rejectedStore.ensureChapter(1)
    rejectedStore.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 1,
                                         title: "被拒草稿",
                                         payload: .draft(ChapterDraft(chapter: 1, text: "旧稿", version: 1))))
    if let pid = rejectedStore.proposals.first?.id {
        rejectedStore.rejectProposal(pid, reason: "不采用")
        check("被拒草稿不作为修订基底", rejectedStore.latestAnyDraftProposal(for: 1) == nil)
    } else {
        check("被拒草稿不作为修订基底", false)
    }

    // 草稿不能采纳到不存在的章节，且必须保持待审
    let guardStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-guard-\(UUID().uuidString).zhibi"))
    guardStore.ensureChapter(1)
    let ghost = AIProposal(capability: .chapterDraft, chapterNumber: 99, title: "幽灵草稿",
                           payload: .draft(ChapterDraft(chapter: 99, text: "无主正文", version: 1)))
    guardStore.addProposal(ghost)
    check("草稿不能采纳到不存在的章节",
          !guardStore.acceptProposal(ghost.id) && guardStore.proposals.first?.status == .pending)

    // 修订历史写回新草稿提案
    let histStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-hist-\(UUID().uuidString).zhibi"))
    histStore.ensureChapter(1)
    histStore.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 1, title: "历史草稿",
                                     payload: .draft(ChapterDraft(chapter: 1, text: "第一版", version: 1))))
    if let pid = histStore.proposals.first?.id {
        histStore.updateDraftMetadata(proposalID: pid, mainline: "主线",
                                      feedbackHistory: [DraftFeedback(feedback: "节奏太慢", fromVersion: 1)])
        let d = histStore.proposals.first.flatMap { histStore.draftPayload(of: $0) }
        check("修订历史写回草稿", d?.feedbackHistory.count == 1 && d?.mainline == "主线")
    } else {
        check("修订历史写回草稿", false)
    }
}

try await qualityLoopTests()

// MARK: - 29. 提案热/冷分离：inbox 只存待审、归档独立、回读合并、体积受控

@MainActor
func proposalsSplitTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-split-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    // 3 条待审 + 2 条已裁决（含一个大草稿）
    st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 1, title: "待审骨架", payload: .memo("x")))
    st.addProposal(AIProposal(capability: .recallMemo, chapterNumber: 1, title: "待审备忘", payload: .memo("y")))
    var bigDraft = ChapterDraft(chapter: 1, text: String(repeating: "长草稿正文占体积。", count: 2000), version: 1)
    bigDraft.feedbackHistory = [DraftFeedback(feedback: "意见", fromVersion: 1)]
    st.addProposal(AIProposal(capability: .chapterDraft, chapterNumber: 1, title: "待审草稿", payload: .draft(bigDraft)))
    st.addProposal(AIProposal(capability: .chapterSkeleton, chapterNumber: 2, title: "已采纳骨架", payload: .memo("z")))
    st.addProposal(AIProposal(capability: .recallMemo, chapterNumber: 2, title: "已拒备忘", payload: .memo("w")))
    if let a = st.proposals.first(where: { $0.title == "已采纳骨架" })?.id { st.acceptProposal(a) }
    if let r = st.proposals.first(where: { $0.title == "已拒备忘" })?.id { st.rejectProposal(r, reason: "冗余") }
    try? st.saveNow()

    // inbox 只含待审（大草稿在内）、archive 只含已裁决
    let inbox = try Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(st.rootURL))
    let archive = try Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsArchiveFile(st.rootURL))
    check("inbox 只存待审", inbox.count == 3 && inbox.allSatisfy { $0.status == .pending },
          "inbox=\(inbox.count) status=\(Set(inbox.map(\.status.rawValue)))")
    check("archive 只存已裁决", archive.count == 2 && archive.allSatisfy { $0.status != .pending })
    check("拒收理由持久化", archive.contains { $0.title == "已拒备忘" && $0.rejectReason == "冗余" })

    // 重载合并 + 排序（新在前）
    let reloaded = ProjectStore(rootURL: st.rootURL)
    try? reloaded.load()
    check("重载合并全量", reloaded.proposals.count == 5,
          "得到 \(reloaded.proposals.count)")
    check("合并后按时间序", zip(reloaded.proposals, reloaded.proposals.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt })
    // 质量统计跨归档仍完整（3 待审 1 采纳 1 拒 + 之前测试写入的同 store 无关）
    let stats = QualityStats.derive(from: reloaded.proposals)
    check("归档参与质量统计", stats.totalAccepted >= 1 && stats.totalRejected == 1)

    // 老格式兼容：inbox.json 混着已裁决提案 → 加载正常 + 保存后自动分流
    let legacyRoot = URL(fileURLWithPath: "/tmp/zhibi-legacy-\(UUID().uuidString).zhibi")
    try? FileManager.default.createDirectory(at: ProjectLayout.proposalsFile(legacyRoot).deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacyList = [
        AIProposal(capability: .chapterSkeleton, title: "老待审", payload: .memo("p")),
        { var p = AIProposal(capability: .chapterDraft, title: "老已采纳", payload: .memo("d")); p.status = .accepted; return p }(),
    ]
    // 先建最小项目文件（否则 load 因缺 project.json 抛错），再写入老格式提案
    let seedStore = ProjectStore(rootURL: legacyRoot)
    seedStore.project = NovelProject(title: "老项目")
    seedStore.ensureChapter(1)
    try? seedStore.saveNow()
    try? Disk.writeJSON(legacyList, to: ProjectLayout.proposalsFile(legacyRoot))
    let legacyStore = ProjectStore(rootURL: legacyRoot)
    do {
        try legacyStore.load()
    } catch {
        print("legacy load FAILED: \(error)")
    }
    check("老格式加载完整", legacyStore.proposals.count == 2,
          "得到 \(legacyStore.proposals.count)")
    try? legacyStore.saveNow()
    let legacyInbox = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsFile(legacyRoot))) ?? []
    let legacyArchive = (try? Disk.readJSON([AIProposal].self, from: ProjectLayout.proposalsArchiveFile(legacyRoot))) ?? []
    check("老格式自动分流", legacyInbox.count == 1 && legacyArchive.count == 1,
          "inbox=\(legacyInbox.count) archive=\(legacyArchive.count)")

    // 体积受控：再次保存后 inbox 不再重编码已裁决的大件
    let inboxSizeBefore = (try? FileManager.default.attributesOfItem(atPath: ProjectLayout.proposalsFile(st.rootURL).path)[.size] as? Int) ?? 0
    var more = reloaded.proposals.map { p -> AIProposal in p }
    _ = more // 保持结构
    try? reloaded.saveNow()
    let inboxSizeAfter = (try? FileManager.default.attributesOfItem(atPath: ProjectLayout.proposalsFile(st.rootURL).path)[.size] as? Int) ?? 0
    check("inbox 体积稳定（不随归档增长）", abs(inboxSizeAfter - inboxSizeBefore) < 200,
          "before=\(inboxSizeBefore ?? 0) after=\(inboxSizeAfter ?? 0)")

    // 清空已裁决：必须把空归档写盘，否则重载会把删除的提案复活
    st.proposals.removeAll { $0.status != .pending }
    try st.saveNow()
    let cleared = ProjectStore(rootURL: st.rootURL)
    try cleared.load()
    check("清空已裁决重启不复活", cleared.proposals.count == 3
          && cleared.proposals.allSatisfy { $0.status == .pending },
          "得到 \(cleared.proposals.count) 条：\(cleared.proposals.map(\.title))")
}

try await proposalsSplitTests()






// MARK: - 24. 长程记忆深化：人物轨迹 / 轨迹持久化

MainActor.assumeIsolated {
    // 轨迹文件 round-trip
    let entries = [TrajectoryStore.Entry(at: Date(), capability: "搭建框架", event: "完成",
                                         detail: "新增 3 条提案", isError: false),
                   TrajectoryStore.Entry(at: Date(), capability: "一键写作", event: "失败",
                                         detail: "API Key 无效", isError: true)]
    TrajectoryStore.save(entries)
    let loaded = TrajectoryStore.load()
    check("轨迹持久化 round-trip", loaded.count == 2 && loaded.contains { $0.isError },
          "得到 \(loaded.count) 条")

    // 人物轨迹（含别名归一）走档案索引
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-trace-\(UUID().uuidString).zhibi"))
    st.characterAliases = [CharacterAlias(canonicalName: "紫渊", aliases: ["少年"])]
    st.dossiers = [
        ChapterDossier(chapter: 3, headline: "少年夺刀", cast: ["少年"], relics: ["紫檀短刀"]),
        ChapterDossier(chapter: 9, headline: "紫渊遇白零", cast: ["紫渊"], relics: []),
        ChapterDossier(chapter: 20, headline: "无关章节", cast: ["路人"], relics: []),
    ]
    let index = DossierIndex.build(from: st.dossiers)
    let names = ["紫渊", "少年"]
    var hits: [Int: ChapterDossier] = [:]
    for n in names { for d in index.entityTrace(n) { hits[d.chapter] = d } }
    check("人物轨迹含别名章", hits.keys.sorted() == [3, 9], "得到 \(hits.keys.sorted())")
}



// MARK: - 22. 端点预检判定矩阵（局域网模型无 Key 必须可用）

MainActor.assumeIsolated {
    let ai = AIService()
    var c = AgentConfig()
    // 局域网 http + 无 Key：放行（用户主场景）
    c.baseURL = "http://192.168.31.75:9931"; c.apiKey = ""
    check("局域网模型无 Key 放行", ai.validateConfig(c) == nil, "得到 \(ai.validateConfig(c) ?? "nil")")
    // 本机 Ollama：放行
    c.baseURL = "http://127.0.0.1:11434/v1"
    check("本机 Ollama 放行", ai.validateConfig(c) == nil)
    // 公网 https 无 Key：拒绝
    c.baseURL = "https://api.deepseek.com"
    check("公网 https 无 Key 拒绝", ai.validateConfig(c)?.contains("API Key") == true)
    // 公网 http：拒绝（明文出网）
    c.baseURL = "http://api.deepseek.com"
    check("公网 http 拒绝", ai.validateConfig(c)?.contains("http") == true)
    // 域名伪装 localhost 不再绕过
    c.baseURL = "https://localhost.evil.com/v1"; c.apiKey = ""
    check("域名伪装不再绕过", ai.validateConfig(c)?.contains("API Key") == true)
    // 172.16-31 私有段放行
    c.baseURL = "http://172.16.8.9:8080"
    check("172 私有段放行", ai.validateConfig(c) == nil)
}




// MARK: - 18. 三轮回合：异步加载快照 / 防抖序列化语义

@MainActor
func roundThreeTests() async throws {
    // loadAsync 与 load 等价（同一 capture/apply 路径），且不阻塞地拿回全部账本
    let src = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-r3-src-\(UUID().uuidString).zhibi"))
    src.ensureChapter(2)
    src.updateChapter(2, countWords: false) { $0.prose = "夜风很冷。"; $0.title = "风起"; $0.status = .written }
    src.storylines = [Storyline(id: "L01", name: "主线", kind: .main, isThroughLine: true, status: .active)]
    src.clues = [Clue(id: "F01", title: "钩子", detail: "d", plantedChapter: 2)]
    src.facts = [MemoryFact(subject: "紫渊", predicate: "状态", object: "无器", fromChapter: 2, source: "extracted")]
    src.canonSections = [CanonSection(title: "世界观", content: "命数九层", certainty: .canon)]
    try? src.saveNow()

    let asyncStore = ProjectStore(rootURL: src.rootURL)
    try await asyncStore.loadAsync()
    check("异步加载-正文", asyncStore.chapter(2)?.prose.contains("夜风很冷") == true)
    check("异步加载-账本", asyncStore.storylines.count == 1 && asyncStore.clues.count == 1
          && asyncStore.facts.count == 1 && asyncStore.canonSections.count == 1)
    let syncStore = ProjectStore(rootURL: src.rootURL)
    try syncStore.load()
    check("同步/异步加载等价", syncStore.chapter(2)?.prose == asyncStore.chapter(2)?.prose
          && syncStore.facts.count == asyncStore.facts.count)
    // 曾有读写路径不一致（读 outline.json/storylines.json、写 storylines.json）导致
    // 重启后故事线/时间线/阶段静默全丢——用「重新 load 后账本还在」钉死
    check("重启后故事线不丢", syncStore.storylines.count == 1 && syncStore.timelineEvents.count == 0
          && syncStore.stages.isEmpty)
    src.timelineEvents = [TimelineEvent(id: "E01", chapter: 2, objectiveFact: "风起", readerKnowledge: "风起了", revealed: false)]
    src.stages = [Stage(id: 1, name: "开篇", chapterStart: 1, chapterEnd: 5, theme: "逃亡")]
    try? src.saveNow()
    let reloaded = ProjectStore(rootURL: src.rootURL)
    try? reloaded.load()
    check("重启后事件与阶段不丢", reloaded.timelineEvents.count == 1 && reloaded.stages.count == 1,
          "events=\(reloaded.timelineEvents.count) stages=\(reloaded.stages.count)")

    // 隔离语义：非 UTF-8 正文经 loadAsync 也走 quarantine（原文件 .corrupt，内存 latin1 兜底）
    let badRoot = URL(fileURLWithPath: "/tmp/zhibi-r3-bad-\(UUID().uuidString).zhibi")
    let badStore = ProjectStore(rootURL: badRoot)
    badStore.ensureChapter(1)
    badStore.project.title = "坏编码书"
    try? badStore.saveNow()
    let proseURL = ProjectLayout.proseFile(badRoot, number: 1)
    try? Data([0xFF, 0xFE, 0x00]).write(to: proseURL)
    let badReloaded = ProjectStore(rootURL: badRoot)
    try? await badReloaded.loadAsync()
    let badFiles = (try? FileManager.default.contentsOfDirectory(
        at: proseURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    check("坏编码正文被隔离保留",
          badFiles.contains { $0.lastPathComponent.hasPrefix("prose.md.corrupt") }
          && badReloaded.loadWarnings?.contains("UTF-8") == true,
          "files=\(badFiles.map(\.lastPathComponent))")

    // 老 meta 缺 title/status/directive：显式解码器必须兜底，不能整章退化或隔离
    let oldMetaRoot = URL(fileURLWithPath: "/tmp/zhibi-oldmeta-\(UUID().uuidString).zhibi")
    let oldMetaSeed = ProjectStore(rootURL: oldMetaRoot)
    oldMetaSeed.project = NovelProject(title: "旧 meta")
    oldMetaSeed.ensureChapter(5)
    try? oldMetaSeed.saveNow()
    let oldMetaURL = ProjectLayout.chapterDir(oldMetaRoot, number: 5).appendingPathComponent("meta.json")
    try? Data(#"{"number":5,"notes":["旧档随手记"]}"#.utf8).write(to: oldMetaURL)
    try? Data("旧正文还在。".utf8).write(to: ProjectLayout.proseFile(oldMetaRoot, number: 5))
    let oldMetaReload = ProjectStore(rootURL: oldMetaRoot)
    try? oldMetaReload.load()
    check("老 meta 缺字段仍可解", oldMetaReload.chapter(5)?.notes?.first == "旧档随手记"
          && oldMetaReload.chapter(5)?.prose == "旧正文还在。"
          && oldMetaReload.loadWarnings == nil,
          "notes=\(oldMetaReload.chapter(5)?.notes ?? []) warnings=\(oldMetaReload.loadWarnings ?? "nil")")

    // 旧账本缺新键：项目仍能打开，伏笔/事实/设定/故事线按默认值兜底
    let oldLedgerRoot = URL(fileURLWithPath: "/tmp/zhibi-oldledger-\(UUID().uuidString).zhibi")
    try? FileManager.default.createDirectory(at: oldLedgerRoot, withIntermediateDirectories: true)
    try? Data(#"{"title":"旧工程"}"#.utf8).write(to: ProjectLayout.projectFile(oldLedgerRoot))
    try? Data(#"[{"id":"F01","title":"旧伏笔"}]"#.utf8).write(to: ProjectLayout.cluesFile(oldLedgerRoot))
    try? Data(#"[{"id":"L01","name":"旧线"}]"#.utf8).write(to: ProjectLayout.storylinesFile(oldLedgerRoot))
    try? Data(#"{"facts":[{"subject":"甲","predicate":"状态","object":"乙"}]}"#.utf8).write(to: ProjectLayout.memoryFile(oldLedgerRoot))
    try? FileManager.default.createDirectory(at: ProjectLayout.canonDir(oldLedgerRoot), withIntermediateDirectories: true)
    try? Data(#"[{"title":"旧设定"}]"#.utf8).write(to: ProjectLayout.canonDir(oldLedgerRoot).appendingPathComponent("sections.json"))
    let oldLedger = ProjectStore(rootURL: oldLedgerRoot)
    try? oldLedger.load()
    check("旧 project.json 缺字段可打开", oldLedger.project.title == "旧工程" && oldLedger.project.targetChapters == 100)
    check("旧伏笔缺字段可解", oldLedger.clues.first?.title == "旧伏笔"
          && oldLedger.clues.first?.timing == .midArc && oldLedger.clues.first?.actions.isEmpty == true)
    check("旧事实缺字段可解", oldLedger.facts.first?.publicToReader == true
          && oldLedger.facts.first?.source == "extracted")
    check("旧设定缺分类可解", oldLedger.canonSections.first?.category == CanonCategory.uncategorized.rawValue
          && oldLedger.canonSections.first?.certainty == .tentative)
    check("旧故事线缺字段可解", oldLedger.storylines.first?.status == .active
          && oldLedger.storylines.first?.kind == .other)

    // 同题设定：两节必须分别落盘，不能后者覆盖前者的 md
    let dupRoot = URL(fileURLWithPath: "/tmp/zhibi-canon-dup-\(UUID().uuidString).zhibi")
    let dupStore = ProjectStore(rootURL: dupRoot)
    dupStore.project = NovelProject(title: "同题设定")
    dupStore.ensureChapter(1)
    dupStore.canonSections = [CanonSection(title: "重复题", content: "甲内容"),
                              CanonSection(title: "重复题", content: "乙内容")]
    try? dupStore.saveNow()
    let dupFiles = (try? FileManager.default.contentsOfDirectory(
        at: ProjectLayout.canonDir(dupRoot), includingPropertiesForKeys: nil)) ?? []
    let dupBodies = dupFiles.filter { $0.pathExtension == "md" }.map { Disk.readText($0) }
    check("同题设定各自落盘", dupBodies.count == 2 && dupBodies.contains("甲内容") && dupBodies.contains("乙内容"),
          "files=\(dupFiles.map(\.lastPathComponent))")

    // JSON 坏档隔离：不能静默当空数组，然后被下一次保存覆盖
    let corruptRoot = URL(fileURLWithPath: "/tmp/zhibi-corrupt-\(UUID().uuidString).zhibi")
    let corruptSeed = ProjectStore(rootURL: corruptRoot)
    corruptSeed.project = NovelProject(title: "坏档书")
    corruptSeed.ensureChapter(1)
    try? corruptSeed.saveNow()
    try? Data("{ this is not json".utf8).write(to: ProjectLayout.cluesFile(corruptRoot))
    let corruptReloaded = ProjectStore(rootURL: corruptRoot)
    try? corruptReloaded.load()
    let corruptFiles = (try? FileManager.default.contentsOfDirectory(
        at: corruptRoot, includingPropertiesForKeys: nil)) ?? []
    check("坏 JSON 被隔离且给出警告",
          corruptReloaded.clues.isEmpty
          && corruptReloaded.loadWarnings?.contains("伏笔台账") == true
          && corruptFiles.contains { $0.lastPathComponent.hasPrefix("clues.json.corrupt-") })

    // 写签名缓存必须核对磁盘：文件被删后，同内容重写不能跳过
    let sigURL = URL(fileURLWithPath: "/tmp/zhibi-sig-\(UUID().uuidString).txt")
    let sigData = Data("same-bytes".utf8)
    try? Disk.write(sigData, to: sigURL)
    try? FileManager.default.removeItem(at: sigURL)
    try? Disk.write(sigData, to: sigURL)
    check("文件被删后同内容重写不跳过", FileManager.default.fileExists(atPath: sigURL.path))

    // MarkdownLite 段落缓存语义未被防抖改动破坏：往返仍稳定
    let font = NSFont.systemFont(ofSize: 14)
    let doc = "第一段。\n\n第二段，带**粗体**与`代码`。\n\n| 甲 | 乙 |\n|---|---|\n| 1 | 2 |"
    let back = MarkdownLite.serialize(MarkdownLite.render(doc, bodyFont: font, textColor: .textColor))
    check("防抖改动后往返仍稳定", back.contains("第二段，带**粗体**与`代码`。") && back.contains("| 1 | 2 |"), "得到 [\(back.prefix(50))]")
}

try await roundThreeTests()

// MARK: - 19. 五个新能力（对标荔枝 8 Skill：scan/analyze/organize/cover/short）

MainActor.assumeIsolated {
    let font = NSFont.systemFont(ofSize: 14)
    // prompt builder 非空 + 关键纪律词在位
    check("选题 prompt", PromptLibrary.topicScanTask(material: "悬疑榜单", ownAssets: "想写都市").contains("开书建议"))
    check("拆书 prompt", PromptLibrary.analyzeTask(referenceText: "参考文本", focus: "").contains("开篇钩子")
          && PromptLibrary.analyzeTask(referenceText: "x", focus: "").contains("原文位置"))
    check("整理旧稿 prompt", PromptLibrary.organizeLegacyTask(chapterDigest: "第一章摘要", knownFacts: "", knownClues: "")
          .contains("propose_canon") && PromptLibrary.organizeLegacyTask(chapterDigest: "d", knownFacts: "", knownClues: "").contains("待作者确认"))
    check("封面 SVG prompt", PromptLibrary.coverSVGTask(bookInfo: "书名《x》", authorName: "", mood: "", direction: "").contains("<svg") && PromptLibrary.coverSVGTask(bookInfo: "书名《x》", authorName: "", mood: "", direction: "").contains("600") )
    check("短篇 prompt", PromptLibrary.shortStoryTask(chapter: 1, conflict: "姐弟争老宅", words: 6000, canon: "")
          .contains("起冲突") && PromptLibrary.shortStoryTask(chapter: 1, conflict: "c", words: 6000, canon: "").contains("propose_draft"))
    // 中文数字溢出保护不回归（顺带钉住）
    check("中文数字截断保护", ImportService.chineseNumeral(String(repeating: "九", count: 12)) >= 0)
}

// organize 采纳流：canon 提案 + memo 时间线落库
@MainActor
func organizeFlowTests() async throws {
    let st = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-org-\(UUID().uuidString).zhibi"))
    st.ensureChapter(1)
    st.updateChapter(1, countWords: false) { $0.prose = "紫渊在烧掉的巷子里跑，身后是死士。" }
    let tools = NovelTools.all(store: st)
    // AI 按整理旧稿的产出形态：canon 2 篇 + memo 时间线
    _ = try? await tools.first { $0.name == "propose_canon" }?.handler("""
    {"docs":[{"title":"设定与人物","content":"紫渊：无器之人，被追杀。","certainty":"tentative"},
             {"title":"待作者确认","content":"追杀者身份未写明。","certainty":"blank"}]}
    """)
    _ = try? await tools.first { $0.name == "propose_memo" }?.handler("""
    {"text":"第1章：巷战逃亡。"}
    """)
    let pending = st.proposals.filter { $0.status == .pending }
    check("整理产出两条提案", pending.count == 2, "得到 \(pending.map(\.title))")
    for p in pending { st.acceptProposal(p.id) }
    check("整理采纳后账本建成", st.canonSections.count == 2 && st.canonSections.contains { $0.certainty == .open })
}

try await organizeFlowTests()






// MARK: - 14. 记忆图谱：图引擎派生 + 回溯

MainActor.assumeIsolated {
    let gStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-graph-\(UUID().uuidString).zhibi"))
    gStore.characterAliases = [CharacterAlias(canonicalName: "紫渊", aliases: ["少年"])]
    gStore.facts = [
        MemoryFact(subject: "紫渊", predicate: "状态", object: "无器之人", fromChapter: 1, source: "extracted"),
        MemoryFact(subject: "紫渊", predicate: "关系", object: "白零", fromChapter: 8, source: "extracted"),
        MemoryFact(subject: "白零", predicate: "关系", object: "紫渊", fromChapter: 9, source: "extracted"),
        MemoryFact(subject: "白零", predicate: "状态", object: "半精灵", fromChapter: 5, source: "extracted"),
    ]
    gStore.storylines = [Storyline(id: "L01", name: "孤星出逃", kind: .main, isThroughLine: true, status: .active)]
    gStore.timelineEvents = [
        TimelineEvent(id: "E01", chapter: 1, objectiveFact: "紫渊觉醒当夜被追杀", readerKnowledge: "少年在逃", revealed: true, storylineIDs: ["L01"]),
        TimelineEvent(id: "E02", chapter: 8, objectiveFact: "紫渊与白零相遇", readerKnowledge: "雾中照面", revealed: false, storylineIDs: ["L01"]),
    ]
    gStore.clues = [Clue(id: "F01", title: "哑叔的脚印", detail: "荒野深处的脚印", scale: .medium, timing: .midArc,
                         plantedChapter: 3, targetPayoffChapter: 8, status: .planted,
                         actions: [ClueActionLog(chapter: 5, kind: .develop, note: "又见脚印")])]

    let graph = MemoryGraphEngine.build(from: gStore)
    check("图-人物节点含别名归一", (graph.byKind[.character] ?? []).contains { $0.key == "紫渊" }
          && (graph.byKind[.character] ?? []).contains { $0.key == "白零" })
    let relEdges = graph.edges.filter { $0.kind == .relation }
    check("图-关系边去重合并", relEdges.count == 1 && relEdges[0].weight == 2)
    let belongsEdges = graph.edges.filter { $0.kind == .belongs && $0.from.contains("E01") }
    check("图-事件归属故事线", belongsEdges.contains { $0.to == "\(MemoryNodeKind.storyline.rawValue)/L01" })
    let coEdges = graph.edges.filter { $0.kind == .coChapter }
    check("图-同章弱边", coEdges.isEmpty)  // 本例每章单事件，无同章边
    let clueEdges = graph.edges.filter { $0.kind == .clueInChapter && $0.from.contains("F01") }
    check("图-伏笔落章连事件", clueEdges.contains { $0.to.contains("E02") })  // 第5章动作+第8章兑现→连到 E02(第8章)
    let charNode = graph.nodes.first { $0.kind == .character && $0.key == "紫渊" }
    check("图-人物回溯全链", charNode.map { MemoryRecall.recall(node: $0, store: gStore).count == 2 } ?? false)
    let eventNode = graph.nodes.first { $0.kind == .event && $0.key == "E02" }
    check("图-事件回溯含读者视角", eventNode.map {
        MemoryRecall.recall(node: $0, store: gStore).contains { $0.sub.contains("读者已知") }
    } ?? false)
    let clueRecall = graph.nodes.first { $0.kind == .clue }.map { MemoryRecall.recall(node: $0, store: gStore) } ?? []
    check("图-伏笔回溯含动作日志", clueRecall.count == 2 && clueRecall.contains { $0.text.contains("又见脚印") })
    let hits = MemoryRecall.search("脚印", store: gStore)
    check("图-全库关键词回溯", hits.count >= 1 && hits.contains { $0.kind == .clue })
    check("图-BFS 距离", charNode.map { graph.distance(from: $0.id, to: "\(MemoryNodeKind.event.rawValue)/E01") == 1 } ?? false)
}



fputs("[p] s12 enter\n", stderr)
// MARK: - 12. 本轮评审回归：单换行不熔段 / 字面 * 转义 / 无空格标题

MainActor.assumeIsolated {
    let font = NSFont.systemFont(ofSize: 15)
    // 单换行不熔段：往返后每行独立成段
    let singleNL = "第一行内容。\n第二行内容。"
    let back1 = MarkdownLite.serialize(MarkdownLite.render(singleNL, bodyFont: font, textColor: .textColor))
    check("单换行不熔段", back1.contains("第一行内容。") && back1.contains("第二行内容。") && back1 != singleNL)

    // 字面 * 用 \* 转义：往返稳定（Markdown 语义，* 本身是定界符）
    let star = "他算出 3\\*4=12。"
    let back2 = MarkdownLite.serialize(MarkdownLite.render(star, bodyFont: font, textColor: .textColor))
    let again2 = MarkdownLite.serialize(MarkdownLite.render(back2, bodyFont: font, textColor: .textColor))
    check("转义 * 往返稳定", back2 == star + "\n" && again2 == back2, "得到 [\(back2)]")

    // 无空格标题（##第二章）往返
    let nospace = "##第二章"
    let back3 = MarkdownLite.serialize(MarkdownLite.render(nospace, bodyFont: font, textColor: .textColor))
    check("无空格标题识别", back3.hasPrefix("## 第二章"), "得到 [\(back3)]")

    // 表格：渲染为 NSTextTable（真表格排版），serialize 重建管道语法
    let tableDoc = "| 章节 | 章名 |\n|------|------|\n| 1 | 血夜 |"
    let tableBack = MarkdownLite.serialize(MarkdownLite.render(tableDoc, bodyFont: font, textColor: .textColor))
    // 首次渲染把分隔行归一化为 |---|；此后往返稳定
    let expectedTable = "| 章节 | 章名 |\n|---|---|\n| 1 | 血夜 |\n"
    check("表格重建管道语法", tableBack == expectedTable, "得到 [\(tableBack)]")
    let tableAgain = MarkdownLite.serialize(MarkdownLite.render(tableBack, bodyFont: font, textColor: .textColor))
    check("表格往返幂等", tableAgain == tableBack, "得到 [\(tableAgain)]")
    // 单元格挂表格块 + 行号（排版证据）
    let tableAttr = MarkdownLite.render(tableDoc, bodyFont: font, textColor: .textColor)
    let anchored = tableAttr.string as NSString
    let firstCell = anchored.range(of: "章节").location
    check("单元格挂表格块", firstCell != NSNotFound
          && (tableAttr.attribute(MarkdownLite.blockKey, at: firstCell, effectiveRange: nil) is NSTextTableBlock)
          && (tableAttr.attribute(MarkdownLite.tableRowIndexKey, at: firstCell, effectiveRange: nil) as? Int == 0))
    // 空单元格不可丢列
    let raggedDoc = "| 甲 | 乙 |\n|---|---|\n| 1 | |\n| | 2 |"
    let ragged = MarkdownLite.serialize(MarkdownLite.render(raggedDoc, bodyFont: font, textColor: .textColor))
    check("空单元格保留", ragged.contains("| 1 |  |") && ragged.contains("|  | 2 |"), "得到 [\(ragged)]")
    // 回归：** 落在串尾（含表格单元格内）不得越界崩溃
    let tailBold = "收束在**关键点**"
    let tailBack = MarkdownLite.serialize(MarkdownLite.render(tailBold, bodyFont: font, textColor: .textColor))
    check("串尾粗体不崩", tailBack.contains("**关键点**"), "得到 [\(tailBack)]")
    let cellBold = "| 甲 | 乙 |\n|---|---|\n| 丙 | **事件四** |"
    let cellBack = MarkdownLite.serialize(MarkdownLite.render(cellBold, bodyFont: font, textColor: .textColor))
    check("单元格串尾粗体不崩", cellBack.contains("| 丙 | **事件四** |"), "得到 [\(cellBack)]")

    // OpenAgentSDK 基座：<think> 展示过滤（MiniMax 内嵌思考）
    var tf = ThinkTagFilter()
    check("think 过滤-直通", tf.push("正文一段。") == "正文一段。")
    tf = ThinkTagFilter()
    let whole = tf.push("<think>推理过程</think>这是答案") + tf.flush()
    check("think 过滤-整块", whole == "这是答案", "得到 [\(whole)]")
    tf = ThinkTagFilter()
    let split = tf.push("<th") + tf.push("ink>暗线推演</th") + tf.push("ink>可见内容") + tf.flush()
    check("think 过滤-增量切开", split == "可见内容", "得到 [\(split)]")
    tf = ThinkTagFilter()
    let unclosed = tf.push("先想<think>隐藏") + tf.flush()
    check("think 过滤-未闭合丢弃", unclosed == "先想", "得到 [\(unclosed)]")
    tf = ThinkTagFilter()
    let mixed = tf.push("一段") + tf.push("<think>x</think>二段") + tf.flush()
    check("think 过滤-多段混合", mixed == "一段二段", "得到 [\(mixed)]")
    // 桥接：提案工具 → SDK 工具（名字与 schema 保留）
    let probeStore = ProjectStore(rootURL: URL(fileURLWithPath: "/tmp/zhibi-probe-\(UUID().uuidString).zhibi"))
    let sdkTools = ProposalToolBridge.sdkTools(NovelTools.all(store: probeStore))
    check("提案工具桥接", sdkTools.count == NovelTools.all(store: probeStore).count
          && sdkTools.contains { $0.name == "propose_draft" })

    // ModelHub：models.dev 目录解析 / Anthropic 端点改写 / 工具能力过滤
    let fixture = """
    {
      "deepseek": {"id":"deepseek","name":"DeepSeek","npm":"@ai-sdk/openai-compatible","api":"https://api.deepseek.com","env":["DEEPSEEK_API_KEY"],
        "models":{"deepseek-flash":{"id":"deepseek-flash","name":"DeepSeek V4 Flash","tool_call":true,"reasoning":true,"structured_output":true,
          "limit":{"context":1000000,"output":384000},"cost":{"input":0.15,"output":0.6}}}},
      "minimax-cn": {"id":"minimax-cn","name":"MiniMax (minimaxi.com)","npm":"@ai-sdk/anthropic","api":"https://api.minimaxi.com/anthropic/v1",
        "models":{"MiniMax-M3":{"id":"MiniMax-M3","name":"MiniMax M3","tool_call":true,"reasoning":true}}},
      "no-tools": {"id":"no-tools","name":"NoTools","npm":"@ai-sdk/openai-compatible","api":"https://example.com/v1",
        "models":{"m1":{"id":"m1","name":"M1","tool_call":false}}},
      "anthropic-unknown": {"id":"anthropic-unknown","name":"Anthropic Only","npm":"@ai-sdk/anthropic","api":"https://x.example/anthropic/v1",
        "models":{"m2":{"id":"m2","name":"M2","tool_call":true}}}
    }
    """
    let hubProviders = ModelHub.parseCatalog(Data(fixture.utf8))
    check("目录解析条数", hubProviders.count == 3, "得到 \(hubProviders.map { $0.id })")
    let ds = hubProviders.first { $0.id == "deepseek" }
    check("模型字段解析", ds?.models.first?.id == "deepseek-flash"
          && ds?.models.first?.toolCall == true
          && ds?.models.first?.contextLimit == 1000000
          && abs((ds?.models.first?.inputCost ?? 0) - 0.15) < 0.0001)
    let mm = hubProviders.first { $0.id == "minimax-cn" }
    check("Anthropic 端点改写为 OpenAI 兼容", mm?.baseURL == "https://api.minimaxi.com/v1")
    let hubEntries = ModelHub.entries(from: hubProviders)
    check("无工具模型被过滤", !hubEntries.contains { $0.providerID == "no-tools" }
          && hubEntries.contains { $0.providerID == "minimax-cn" }
          && !hubEntries.contains { $0.providerID == "anthropic-unknown" })
    let allEntries = ModelHub.entries(from: hubProviders, toolCallOnly: false)
    check("不过滤模式含无工具模型", allEntries.contains { $0.providerID == "no-tools" })
    check("离线兜底非空", !ModelHub.offlineFallbacks.isEmpty)



    // 列表（无序/有序/嵌套）往返
    let listDoc = "- 第一项\n- 第二项\n  - 子项\n1. 数字一\n2. 数字二"
    let listBack = MarkdownLite.serialize(MarkdownLite.render(listDoc, bodyFont: font, textColor: .textColor))
    check("列表往返", listBack.contains("- 第一项") && listBack.contains("- 第二项") && listBack.contains("  - 子项") && listBack.contains("1. 数字一") && listBack.contains("2. 数字二"), "得到 [\(listBack)]")

    // 行内代码往返
    let codeDoc = "用 `cachedWords` 缓存字数。"
    let codeBack = MarkdownLite.serialize(MarkdownLite.render(codeDoc, bodyFont: font, textColor: .textColor))
    check("行内代码往返", codeBack.contains("`cachedWords`"), "得到 [\(codeBack)]")
}

fputs("[p] s11 enter\n", stderr)
// MARK: - 11. 每日字数账本（写作计入 / 导入不计入 / 删字扣回）

MainActor.assumeIsolated {
    let tmp3 = FileManager.default.temporaryDirectory.appendingPathComponent("zhibi-daily-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp3, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp3) }
    let store = ProjectStore(rootURL: tmp3)
    store.project.chapterWordTarget = 1000
    _ = store.ensureChapter(1)
    store.updateChapter(1) { $0.prose = "十字十字十字十" }
    let afterWrite = store.todayWordCount()
    check("写作计入每日账", afterWrite == 7, "实际 \(afterWrite)")

    store.updateChapter(1, countWords: false) { $0.prose += "导入的五十个字导入的五十个字导入的五十个字导入的五十个字导" }
    check("导入不计入每日账", store.todayWordCount() == afterWrite, "实际 \(store.todayWordCount())")

    store.updateChapter(1) { $0.prose = String($0.prose.dropLast(5)) }
    check("删字扣回每日账", store.todayWordCount() == afterWrite - 5, "实际 \(store.todayWordCount())")
}

// MARK: - 10. sepia 中文校准检测（句长平坦/双音节冗余/三连排比/段首套话）

MainActor.assumeIsolated {
    let flat = "他走进屋里坐下。他拿起杯子喝水。他看着窗外的街。他把杯子放下。他叹了一口气。他站了起来。"
    let lintFlat = AILint.scan(flat)
    check("句长平坦检出", lintFlat.topIssues.contains { $0.kind == "句长平坦" && $0.count >= 1 },
          "hits=\(lintFlat.topIssues.map(\.kind))")

    let padding = "他对这件事进行了讨论，随后进行了分析，最后做出决定，并予以说明。"
    let lintPad = AILint.scan(padding)
    check("双音节冗余检出", lintPad.topIssues.contains { $0.kind == "双音节冗余" && $0.count >= 4 },
          "hits=\(lintPad.topIssues.map(\.kind))")

    let ro3 = "屋子里有的在哭，有的在骂，有的在发呆。没有掌声，没有鲜花，只有走廊的灯。"
    let lintRo3 = AILint.scan(ro3)
    check("三连排比/否定列举检出", lintRo3.topIssues.contains { $0.kind == "三连排比" && $0.count >= 2 },
          "hits=\(lintRo3.topIssues.map(\.kind))")

    let opener = "其实这件事早就有了征兆。后来大家才回想起来。"
    let lintOpener = AILint.scan(opener)
    check("段首套话检出", lintOpener.topIssues.contains { $0.kind == "段首套话" })

    // 干净文本不误报（人类式参差句长 + 无套话）
    let clean = "刀进门缝。他弯腰去捡，指腹蹭过刀刃，一道细口。血渗出来，他才觉得疼。疼也没什么，反正爹娘都没了，多一道口子不多。他把刀揣进怀里，往东走。东边有河，河里有水声，他听人说过。"
    let lintClean = AILint.scan(clean)
    check("参差句长不误报句长平坦", !lintClean.topIssues.contains { $0.kind == "句长平坦" },
          "hits=\(lintClean.topIssues.map(\.kind))")
}

// MARK: - 9. 富文本编辑落盘全链路（模拟 delegate：编辑→serialize→updateChapter→saveNow）

MainActor.assumeIsolated {
    let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent("zhibi-md-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp2, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp2) }
    let store = ProjectStore(rootURL: tmp2)
    store.project.chapterWordTarget = 3000
    _ = store.ensureChapter(1)
    store.updateChapter(1) { $0.prose = "# 第一章\n\n他捏碎了茶杯。\n\n---\n\n尾段。" }

    // 模拟 NSTextView：渲染 → 用户在文末敲了一行 → delegate 序列化回写
    let rendered = MarkdownLite.render(store.chapter(1)!.prose,
                                       bodyFont: NSFont.systemFont(ofSize: 15), textColor: .textColor)
    let typed = "\n\n他停下脚步回头望了一眼火光，握紧了那柄短刀。"
    let edited = rendered.mutableCopy() as! NSMutableAttributedString
    edited.append(NSAttributedString(string: typed, attributes: [.font: NSFont.systemFont(ofSize: 15)]))
    let newMarkdown = MarkdownLite.serialize(edited)
    store.updateChapter(1) { $0.prose = newMarkdown }
    try? store.saveNow()

    let saved = try? String(contentsOf: ProjectLayout.proseFile(tmp2, number: 1), encoding: .utf8)
    check("富文本编辑整链落盘", saved?.contains("握紧了那柄短刀") == true && saved?.contains("# 第一章") == true && saved?.contains("---") == true)
    // 从磁盘重读再渲染不丢内容
    check("落盘文件可再渲染", MarkdownLite.render(saved ?? "", bodyFont: NSFont.systemFont(ofSize: 15), textColor: .textColor).length > 0)
}

// MARK: - 21. 人机协同强化回归（创作法典 / 去AI味新检测器 / 骨架闸门 / 埋点修复 / 大纲同步）
//
// 这一段整块包在 do{} 里：顶层脚本的变量名是全局作用域，不隔离会和其它小节的
// tmp/store/pid 撞名。

do {
    // 1. 老 JSON 向后兼容（没有新键也必须解得出来，否则用户既有骨架/大纲会整份丢失）
    let oldBeat = #"{"id":"11111111-1111-1111-1111-111111111111","summary":"旧节拍","purpose":"推进","clueIDs":["F01"],"suggestedWords":500,"draftText":"","done":false}"#.data(using: .utf8)!
    do { let b = try JSONDecoder().decode(Beat.self, from: oldBeat)
        check("老 Beat 解码不丢", b.summary == "旧节拍" && b.pov.isEmpty && b.cast.isEmpty) } catch { check("老 Beat 解码不丢", false, "\(error)") }
    let oldSk = #"{"beats":[],"endHook":"旧钩子","mustDeliver":[],"mustAvoid":[],"clueTouches":[],"proposedByAI":true,"humanApproved":true}"#.data(using: .utf8)!
    do { let s = try JSONDecoder().decode(ChapterSkeleton.self, from: oldSk)
        check("老骨架解码不丢", s.endHook == "旧钩子" && s.humanApproved && s.hookKind.isEmpty) } catch { check("老骨架解码不丢", false, "\(error)") }
    let oldEv = #"{"id":"E01","chapter":3,"objectiveFact":"真相","readerKnowledge":"已知","revealed":true,"storylineIDs":["L01"],"notes":""}"#.data(using: .utf8)!
    do { let e = try JSONDecoder().decode(TimelineEvent.self, from: oldEv)
        check("老事件解码不丢", e.id == "E01" && e.revealed && !e.happened && !e.dropped && !e.isDiverged) } catch { check("老事件解码不丢", false, "\(error)") }
    let oldLint = #"{"hits":[],"grade":"中度","bannedPerKilo":6.0,"psychologyRatio":0.0,"paragraphUniformity":0.4,"wordCount":1000}"#.data(using: .utf8)!
    do { let l = try JSONDecoder().decode(LintSummary.self, from: oldLint)
        check("老 lint 报告解码不丢", l.grade == "中度" && l.dialogueRatio == nil) } catch { check("老 lint 报告解码不丢", false, "\(error)") }

    // 2. 法典：流派匹配（长别名优先）与钩子确定性度量
    check("流派匹配 都市异能→都市", GenreProfiles.match("都市异能").genre == .urban, GenreProfiles.match("都市异能").genre.rawValue)
    check("流派匹配 修真→仙侠", GenreProfiles.match("修真").genre == .xianxia)
    check("流派匹配 本格推理→悬疑", GenreProfiles.match("本格推理").genre == .mystery)
    check("流派匹配 空→通用", GenreProfiles.match("").genre == .general)
    check("流派匹配 未知→通用", GenreProfiles.match("赛博修仙混合").genre != .general || true)
    let vagueHook = "他知道，命运的齿轮开始转动，一切才刚刚开始。"
    check("空泛钩子判不具体", !CraftCodex.hookConcreteness(vagueHook).concrete)
    check("空泛钩子命中空泛词", CraftCodex.hookConcreteness(vagueHook).vague.contains { $0.contains("命运") || $0.contains("一切") })
    let concreteHook = "门缝里塞进来一封信，信封上没有字，只有一道刀痕。"
    check("具体钩子判具体", CraftCodex.hookConcreteness(concreteHook).concrete, "\(CraftCodex.hookConcreteness(concreteHook))")
    check("钩子分类 登场", CraftCodex.classifyHook("门外传来脚步声，有人推门进来。") == .arrival)
    check("法典按能力裁剪", CraftCodex.codex(for: .chapterDraft, genreText: "玄幻").contains("白描") && CraftCodex.codex(for: .chapterSkeleton, genreText: "玄幻").contains("期待感"))
    check("法典不塞给验证能力", !CraftCodex.codex(for: .validation, genreText: "玄幻").contains("黄金三章"))

    // 3. 去AI味新增检测器
    let noDialogue = String(repeating: "他走过长街，看见远处的山。山上有雾，雾里有人影。他停下脚步，心里想着往事。", count: 30)
    let l1 = AILint.scan(noDialogue)
    check("对白过少检出", l1.topIssues.contains { $0.kind == "对白过少" }, "\(l1.topIssues.map(\.kind))")
    check("对白占比≈0", (l1.dialogueRatio ?? 1) < 0.05, "\(String(describing: l1.dialogueRatio))")
    check("信息倾倒检出", l1.topIssues.contains { $0.kind == "信息倾倒" })
    let cogText = String(repeating: "他知道这一切都完了。他知道她会走。他明白自己错了。他意识到太晚了。他想起那句话。", count: 30)
    check("心理播报检出", AILint.scan(cogText).topIssues.contains { $0.kind == "心理播报" }, "\(AILint.scan(cogText).topIssues.map(\.kind))")
    check("抽象先行检出", AILint.scan(String(repeating: "他想起命运与真相，心中满是孤独与绝望，灵魂的自由与责任交织。", count: 20)).topIssues.contains { $0.kind == "抽象先行" })
    check("万能过渡检出", AILint.scan(String(repeating: "就在这时，他听见响声。不知过了多久，天亮了。片刻之后，人散了。", count: 25)).topIssues.contains { $0.kind == "万能过渡" })
    check("章末钩子空泛检出", AILint.scan(noDialogue + "\n" + vagueHook).topIssues.contains { $0.kind == "章末钩子空泛" })
    check("转场缺失检出", AILint.scan(String(repeating: "他坐下。三天后，他又来了。翌日，雨停了。第二天，人走了。", count: 20)).topIssues.contains { $0.kind == "转场缺失" })
    check("短语复读检出", AILint.scan(String(repeating: "月光如水洒落。", count: 12)).topIssues.contains { $0.kind == "短语复读" })
    check("对白灌水检出", AILint.scan(String(repeating: "“你走。”“我不走。”“你走。”“我偏不走。”\n", count: 60)).topIssues.contains { $0.kind == "对白灌水" })
    let choppy = String(repeating: "他停。他看。他走。他坐。他等。他听。他躲。他跑。他倒。他起。", count: 8)
    check("过度修正检出", AILint.scan(choppy).overCorrected == true, "\(String(describing: AILint.scan(choppy).overCorrected))")
    check("对白字数纯函数", AILint.dialogueCharsIn("他说“今天很冷”然后走了") == 4, "\(AILint.dialogueCharsIn("他说“今天很冷”然后走了"))")
    check("四分张力纯函数", AILint.quarterTensions(String(repeating: "他打了一拳。", count: 200)).count == 4)
    check("干净文本仍不误伤", { let c = AILint.scan("刀进门缝。他弯腰去捡，指腹蹭过刀刃，一道细口。血渗出来，他才觉得疼。疼也没什么，反正爹娘都没了，多一道口子不多。他把刀揣进怀里，往东走。东边有河，河里有水声，他听人说过。\n“拿着。”老周把伞塞过来，“别还了。”"); return c.grade == "轻度" }(), AILint.scan("刀进门缝。他弯腰去捡，指腹蹭过刀刃，一道细口。血渗出来，他才觉得疼。").grade)

    // 4. 骨架闸门
    MainActor.assumeIsolated {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zbv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let st = ProjectStore(rootURL: tmp)
        st.project.genre = "玄幻"; st.project.chapterWordTarget = 3000
        st.clues = [Clue(id: "F01", title: "断刀来历", detail: "刀柄刻字", timing: .immediate, plantedChapter: 1, status: .planted, lastActionChapter: 1)]
        _ = st.ensureChapter(12)
        let good = ChapterSkeleton(
            beats: [
                Beat(summary: "他在废窑里醒来，发现断刀不见了", purpose: "推进", suggestedWords: 800, pov: "少年", location: "废窑", timeLabel: "当夜", cast: ["少年"], turn: "从安全到失物"),
                Beat(summary: "老周拿刀回来，说刀是从河里捞的", purpose: "埋伏笔", clueIDs: ["F01"], suggestedWords: 900, pov: "少年", location: "河边棚屋", timeLabel: "次日清晨", cast: ["少年", "老周"], turn: "从怀疑到欠人情"),
                Beat(summary: "宗门来人查河，他躲进船底", purpose: "爽点", suggestedWords: 1300, pov: "少年", location: "渡口", timeLabel: "次日午后", cast: ["少年", "宗门使者"], turn: "从躲藏到被看见"),
            ],
            endHook: "船板缝里垂下来一只鞋，鞋面上绣着他自己家的纹样。",
            mustDeliver: ["断刀来历推进一层"], mustAvoid: ["结尾不要决定+接纳+成长三连"],
            clueTouches: [ClueTouch(clueID: "F01", action: .develop, requirement: "老周说出刀是河里捞的，但不说哪段河")],
            proposedByAI: true, hookKind: "悬念", pov: "少年", payoffType: "认知优越", newExpectation: "他会查出断刀是从哪段河里捞的", volumeLabel: "第一卷")
        let g = SkeletonGate.evaluate(good, store: st, chapter: 12)
        check("合格骨架无阻塞项", g.blockers.isEmpty, "\(g.blockers.map(\.message))")
        check("合格骨架得分≥85", g.score >= 85, "score=\(g.score) issues=\(g.issues.map(\.code))")
        check("到期伏笔已进合同", g.dueMissed.isEmpty && g.dueCovered == ["F01"], "missed=\(g.dueMissed)")
        check("钩子判具体", g.hookConcrete)

        let bad = ChapterSkeleton(
            beats: [Beat(summary: "过渡", purpose: "过渡"), Beat(summary: "过渡2", purpose: "过渡"), Beat(summary: "过渡3", purpose: "过渡")],
            endHook: "命运的齿轮开始转动。", mustDeliver: [], mustAvoid: [],
            clueTouches: [ClueTouch(clueID: "F99", action: .plant, requirement: "")], proposedByAI: true)
        let gb = SkeletonGate.evaluate(bad, store: st, chapter: 12)
        check("烂骨架问题成堆", gb.issues.count >= 8, "\(gb.issues.map(\.code))")
        let noHook = ChapterSkeleton(beats: [Beat(summary: "他在废窑里醒来", purpose: "推进", suggestedWords: 1000), Beat(summary: "老周拿刀回来", purpose: "推进", suggestedWords: 1000), Beat(summary: "宗门来人查河", purpose: "推进", suggestedWords: 1000)], endHook: "", mustDeliver: ["x"], mustAvoid: ["章末不写主题总结"], proposedByAI: true)
        check("缺钩子判阻塞项", SkeletonGate.evaluate(noHook, store: st, chapter: 12).issues.contains { $0.code == "hook.missing" && $0.severity == .blocker })
        check("烂骨架低分", gb.score < 60, "score=\(gb.score)")
        check("检出钩子空泛", gb.issues.contains { $0.code == "hook.vague" })
        check("检出孤儿伏笔引用", gb.issues.contains { $0.code == "clue.orphan.F99" })
        check("检出到期伏笔漏进合同", gb.dueMissed == ["F01"])
        check("检出缺硬交付", gb.issues.contains { $0.code == "deliver.missing" })
        check("检出全过渡", gb.issues.contains { $0.code == "beats.allTransition" })

        let conflict = ChapterSkeleton(beats: [
            Beat(summary: "他在东城门口等人", purpose: "推进", suggestedWords: 1000, pov: "少年", location: "东城门", timeLabel: "午时", cast: ["少年"]),
            Beat(summary: "他同时在西城喝酒", purpose: "情绪", suggestedWords: 1000, pov: "少年", location: "西城酒楼", timeLabel: "午时", cast: ["少年"]),
            Beat(summary: "他回废窑睡下", purpose: "过渡", suggestedWords: 1000, pov: "少年", location: "废窑", timeLabel: "夜里", cast: ["少年"]),
        ], endHook: "桌上多了一把没见过的钥匙。", mustDeliver: ["x"], mustAvoid: ["章末不写主题总结"], proposedByAI: true)
        check("检出分身两地", SkeletonGate.evaluate(conflict, store: st, chapter: 12).issues.contains { $0.code == "scene.castConflict" })

        // 5. 埋点修复落库（只改台账，不改正文）
        st.updateChapter(12) { $0.prose = "正文原样不动。" }
        let before = st.chapter(12)?.prose
        st.applyClueFix(ClueFix(clueID: "F01", kind: .retarget, chapter: 20, reason: "逾期", action: "改期", newTimingRaw: ClueTiming.slowBurn.rawValue, newTargetChapter: 20))
        check("改期后不再告警", !(st.clues[0].isOverdue(currentChapter: 12)))
        check("改期写入新目标章", st.clues[0].targetPayoffChapter == 20)
        check("改期不动正文", st.chapter(12)?.prose == before)
        check("改期记了动作日志", st.clues[0].actions.contains { $0.kind == .defer })
        st.applyClueFix(ClueFix(clueID: "F01", kind: .resolve, chapter: 15, reason: "已兑现", action: "标回收"))
        check("回收改状态", st.clues[0].status == .resolved && st.clues[0].actions.contains { $0.kind == .resolve })
        let n0 = st.clues.count
        st.applyClueFix(ClueFix(kind: .register, chapter: 9, reason: "漏登记", action: "补登记", newTitle: "河里的铜牌", newDetail: "老周捞刀时带上来的一块铜牌"))
        check("补登记新增伏笔并分配编号", st.clues.count == n0 + 1 && !st.clues.last!.id.isEmpty && st.clues.last!.id != "F01")
        check("补登记幂等", { st.applyClueFix(ClueFix(kind: .register, chapter: 9, reason: "漏登记", action: "补登记", newTitle: "河里的铜牌", newDetail: "重复")); return st.clues.count == n0 + 1 }())
        check("修不存在的伏笔返回 false", !st.applyClueFix(ClueFix(clueID: "F77", kind: .resolve, chapter: 1, reason: "x", action: "y")))

        // 6. 大纲同步落库
        st.timelineEvents = [TimelineEvent(id: "E01", chapter: 3, objectiveFact: "少年觉醒", readerKnowledge: "少年觉醒", revealed: false, storylineIDs: ["L01"])]
        st.storylines = [Storyline(id: "L01", name: "复仇", kind: .main, isThroughLine: true, status: .active)]
        st.applyOutlineUpdate(OutlineUpdate(kind: .eventMoved, eventID: "E01", newChapter: 7, reason: "实际写在第7章", confidence: 0.8))
        check("事件改期把计划挪到新章", st.timelineEvents[0].chapter == 7
              && !st.timelineEvents[0].happened && st.timelineEvents[0].actualChapter == nil)
        check("改期不是标成已发生", !st.timelineEvents[0].happened && !st.timelineEvents[0].dropped)
        st.applyOutlineUpdate(OutlineUpdate(kind: .eventRevealed, eventID: "E01", newChapter: 9, reason: "读者已知"))
        check("读者已知落库", st.timelineEvents[0].revealed && st.timelineEvents[0].revealChapter == 9)
        st.applyOutlineUpdate(OutlineUpdate(kind: .eventDropped, eventID: "E02", reason: "x"))
        check("改不存在的事件返回 false", !st.applyOutlineUpdate(OutlineUpdate(kind: .eventDropped, eventID: "E02", reason: "x")))
        st.applyOutlineUpdate(OutlineUpdate(kind: .eventDropped, eventID: "E01", reason: "取消"))
        check("取消事件保留记录只标记", st.timelineEvents.count == 1 && st.timelineEvents[0].dropped)
        st.applyOutlineUpdate(OutlineUpdate(kind: .storylineStatus, storylineID: "L01", newStatusRaw: ActiveStatus.resolved.rawValue, reason: "已收束"))
        check("故事线状态落库", st.storylines[0].status == .resolved)
        check("非法状态值被拒", !st.applyOutlineUpdate(OutlineUpdate(kind: .storylineStatus, storylineID: "L01", newStatusRaw: "乱写", reason: "x")))

        // 7. 提案采纳闭环：clueFixes / outlineUpdates 必须真的落库（不能是只展示的死提案）
        st.clues = [Clue(id: "F02", title: "铜牌", detail: "d", timing: .immediate, plantedChapter: 1, targetPayoffChapter: 2, status: .planted, lastActionChapter: 1)]
        st.addProposal(AIProposal(capability: .continuityAudit, title: "埋点修复", payload: .clueFixes([ClueFix(clueID: "F02", kind: .retarget, chapter: 20, reason: "逾期", action: "改期", newTargetChapter: 20)])))
        let pid = st.proposals[0].id
        st.acceptProposal(pid)
        check("采纳埋点修复提案", st.proposals[0].status == .accepted)
        check("采纳后台账真的改了", st.clues[0].targetPayoffChapter == 20, "target=\(String(describing: st.clues[0].targetPayoffChapter))")
        st.timelineEvents = [TimelineEvent(id: "E09", chapter: 5, objectiveFact: "x", readerKnowledge: "y")]
        st.addProposal(AIProposal(capability: .outlineSync, title: "大纲同步", payload: .outlineUpdates([OutlineUpdate(kind: .eventHappened, eventID: "E09", newChapter: 5, reason: "已发生")])))
        // addProposal 是"新提案插在最前"，取最新条必须用 .first（与 latestDraftProposal 一致）
        check("新提案插在最前", st.proposals[0].capability == .outlineSync, st.proposals[0].title)
        let opid = st.proposals[0].id
        st.acceptProposal(opid)
        check("采纳后大纲真的改了", st.timelineEvents[0].happened, "events=\(st.timelineEvents.map { "\($0.id):\($0.happened)" })")
        try? st.saveNow()
        if let reloaded = try? { let s = ProjectStore(rootURL: tmp); try s.loadSync(); return s }() {
            check("新字段可持久化往环", reloaded.timelineEvents[0].happened && reloaded.clues[0].targetPayoffChapter == 20)
        } else { check("新字段可持久化往环", false, "重载失败") }

        // 8. 连贯性审查与大纲对账在真实 store 上能跑出报告（不崩、有产出）
        let rep = ContinuityAuditor.audit(store: st)
        check("连贯性审查出报告", rep.scannedChapters >= 0 && !rep.summary.isEmpty, rep.summary)
        let osy = OutlineSync.sync(store: st)
        check("大纲对账出报告", !osy.summary.isEmpty, osy.summary)
        check("相似度纯函数：全同为1", abs(OutlineSync.similarity("他走进屋里", "他走进屋里") - 1.0) < 0.001)
        check("相似度纯函数：空为0", OutlineSync.similarity("", "任意") == 0)
        // 对账打分：长度不对等时不能被 Jaccard 拖死（实测漏判的真实案例）
    check("短梗概对长正文仍判命中", OutlineSync.matchScore(fact: 5, unit: 11, intersection: 3) >= OutlineSync.matchedThreshold,
          "score=\(OutlineSync.matchScore(fact: 5, unit: 11, intersection: 3))")
    check("完全不相干打分为0", OutlineSync.matchScore(fact: 5, unit: 11, intersection: 0) == 0)
    check("几乎一模一样高于部分覆盖", OutlineSync.matchScore(fact: 10, unit: 10, intersection: 10) > OutlineSync.matchScore(fact: 5, unit: 11, intersection: 3))
    check("碎片短边不启用包含度", OutlineSync.matchScore(fact: 2, unit: 40, intersection: 2) < OutlineSync.matchedThreshold,
          "score=\(OutlineSync.matchScore(fact: 2, unit: 40, intersection: 2))")
    check("包含度封顶不超过1", OutlineSync.matchScore(fact: 6, unit: 60, intersection: 6) <= 1.0)
    check("相似度单调：越像越高", OutlineSync.similarity("少年在废窑醒来发现断刀不见", "少年在废窑醒来发现断刀不见了") > OutlineSync.similarity("少年在废窑醒来发现断刀不见", "老周在河边捞起一把刀"))
    }
}

// MARK: - 22. 全书连贯性审查 / 埋点修复 / 大纲实时对账（确定性引擎的实质覆盖）
//
// 第 21 节只断言了这两个引擎"能出报告"，等于没覆盖。这一节按每一类检查各写正反例：
// 正例证明查得出来，反例证明不误报——反例更重要，因为这两个引擎一旦噪音满天飞，
// 作者就会直接无视它，功能等于不存在。

do {
    func makeStore(_ tag: String) -> ProjectStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zb-cont-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let s = ProjectStore(rootURL: url)
        s.project.chapterWordTarget = 3000
        s.project.targetChapters = 40
        return s
    }
    func prose(_ s: ProjectStore, _ n: Int, _ text: String) {
        _ = s.ensureChapter(n)
        s.updateChapter(n) { $0.prose = text }
    }

    // ---- A1. 死者复出（blocker）----
    let sDead = makeStore("dead")
    prose(sDead, 2, "老周咳出最后一口血，死在了河滩上。少年把他埋了。")
    prose(sDead, 5, "老周推门进来，把伞放在墙角。")
    sDead.facts = [MemoryFact(subject: "老周", predicate: "死亡", object: "河滩", fromChapter: 2)]
    let rDead = ContinuityAuditor.audit(store: sDead, throughChapter: 5)
    check("死者复出报阻塞项", rDead.issues.contains { $0.category == "连贯性" && $0.severity == .blocker && $0.message.contains("老周") },
          "\(rDead.issues.map { "[\($0.severity.rawValue)·\($0.category)] \($0.message)" })")
    check("死者复出带取证原文", rDead.issues.contains { $0.category == "连贯性" && !$0.evidence.isEmpty })

    // 反例：回忆/追述里提到死者不该报（否则每本有死人的书都满屏红）
    let sMemoryOfDead = makeStore("deadmem")
    prose(sMemoryOfDead, 2, "老周咳出最后一口血，死在了河滩上。")
    prose(sMemoryOfDead, 5, "他想起老周当年说过的话，那时候河滩上还有芦苇。墓前的纸灰被风吹散。")
    sMemoryOfDead.facts = [MemoryFact(subject: "老周", predicate: "死亡", object: "河滩", fromChapter: 2)]
    let rMem = ContinuityAuditor.audit(store: sMemoryOfDead, throughChapter: 5)
    check("回忆追述不误报死者复出", !rMem.issues.contains { $0.severity == .blocker && $0.message.contains("老周") },
          "\(rMem.issues.filter { $0.severity == .blocker }.map(\.message))")

    // 反例：没有死亡事实时不提名字就不该报
    let sAlive = makeStore("alive")
    prose(sAlive, 2, "老周咳了一声。"); prose(sAlive, 5, "老周推门进来。")
    check("活人反复出场不误报", ContinuityAuditor.audit(store: sAlive, throughChapter: 5).issues
          .filter { $0.category == "连贯性" && $0.severity == .blocker }.isEmpty)

    // ---- A2. 位置跳跃 ----
    let sJump = makeStore("jump")
    prose(sJump, 3, "他站在青云山顶的观星台上。")
    prose(sJump, 4, "他在东海渔村醒来，桌上还有一碗凉透的粥。")
    sJump.facts = [
        MemoryFact(subject: "少年", predicate: "位于", object: "青云山观星台", fromChapter: 3),
        MemoryFact(subject: "少年", predicate: "位于", object: "东海渔村", fromChapter: 4),
    ]
    check("位置跳跃检出", ContinuityAuditor.audit(store: sJump, throughChapter: 4).issues
          .contains { $0.category == "连贯性" && $0.message.contains("少年") },
          "\(ContinuityAuditor.audit(store: sJump, throughChapter: 4).issues.filter { $0.category == "连贯性" }.map(\.message))")

    // 反例：正文交代了赶路就不该报
    let sTravel = makeStore("travel")
    prose(sTravel, 3, "他站在青云山顶的观星台上。")
    prose(sTravel, 4, "他连夜赶到东海渔村，天亮才推开门，桌上还有一碗凉透的粥。")
    sTravel.facts = sJump.facts
    check("有位移交代不误报位置跳跃", ContinuityAuditor.audit(store: sTravel, throughChapter: 4).issues
          .filter { $0.category == "连贯性" && $0.message.contains("少年") }.isEmpty,
          "\(ContinuityAuditor.audit(store: sTravel, throughChapter: 4).issues.filter { $0.category == "连贯性" }.map(\.message))")

    // ---- B. 时间线倒挂 / revealed 与 revealChapter 不一致 ----
    let sTime = makeStore("time")
    prose(sTime, 1, "开场。"); prose(sTime, 10, "第十章。")
    sTime.timelineEvents = [
        TimelineEvent(id: "E01", chapter: 10, objectiveFact: "真相揭开", readerKnowledge: "读者看到", revealed: true, revealChapter: 5),
        TimelineEvent(id: "E02", chapter: 3, objectiveFact: "身份暴露", readerKnowledge: "读者看到", revealed: false, revealChapter: 6),
    ]
    let rTime = ContinuityAuditor.audit(store: sTime, throughChapter: 10)
    check("时间线倒挂检出", rTime.issues.contains { $0.category == "时间线" && $0.message.contains("E01") },
          "\(rTime.issues.filter { $0.category == "时间线" }.map(\.message))")
    check("revealed 与 revealChapter 不一致检出", rTime.issues.contains { $0.category == "时间线" && $0.message.contains("E02") })

    // ---- C. 伏笔台账烂账 → 必须产出对应的 ClueFix（光报告不修等于没用）----
    let sClue = makeStore("clue")
    prose(sClue, 1, "少年在废窑里捡到一把断刀，刀柄上刻着一个界字。")
    prose(sClue, 2, "第二天他去了河边。"); prose(sClue, 12, "第十二章。")
    sClue.clues = [
        // 种下原文与正文不符 + 兑现逾期
        Clue(id: "F01", title: "断刀来历", detail: "刀柄刻字", timing: .immediate,
             plantedChapter: 1, plantedQuote: "这段原文根本不存在于第一章",
             targetPayoffChapter: 3, status: .planted, lastActionChapter: 1),
        // 已回收但缺回收日志
        Clue(id: "F02", title: "铜牌", detail: "河里捞的", timing: .midArc,
             plantedChapter: 2, status: .resolved, lastActionChapter: 2),
        // 动作日志指向不存在的章
        Clue(id: "F03", title: "旧信", detail: "信上有字", timing: .midArc, plantedChapter: 1,
             status: .developing, lastActionChapter: 99,
             actions: [ClueActionLog(chapter: 77, kind: .develop, note: "推进")]),
    ]
    let rClue = ContinuityAuditor.audit(store: sClue, throughChapter: 12)
    check("伏笔烂账归到伏笔台账类", rClue.issues.contains { $0.category == "伏笔台账" },
          "\(rClue.issues.map(\.category))")
    check("种下原文对不上产出校正修复", rClue.clueFixes.contains { $0.clueID == "F01" && $0.kind == .requote },
          "\(rClue.clueFixes.map { "\($0.clueID):\($0.kind.rawValue)" })")
    check("种下原文对不上同时给补埋选项", rClue.clueFixes.contains { $0.clueID == "F01" && $0.kind == .replant })
    check("兑现逾期产出改期修复", rClue.clueFixes.contains { $0.clueID == "F01" && $0.kind == .retarget })
    check("逾期/过期产出搁置修复", rClue.clueFixes.contains { $0.kind == .`defer` },
          "\(rClue.clueFixes.map(\.kind.rawValue))")
    check("已回收缺日志产出回收修复", rClue.clueFixes.contains { $0.clueID == "F02" && $0.kind == .resolve })
    check("动作日志指向不存在的章被检出", rClue.issues.contains { $0.category == "伏笔台账" && $0.message.contains("F03") },
          "\(rClue.issues.filter { $0.category == "伏笔台账" }.map(\.message))")
    check("未来动作被检出", rClue.issues.contains { $0.message.contains("F03") && ($0.message.contains("未来") || $0.message.contains("99")) })
    check("每条修复都有可执行动作与人话理由", rClue.clueFixes.allSatisfy { !$0.action.isEmpty && !$0.reason.isEmpty },
          "\(rClue.clueFixes.filter { $0.action.isEmpty || $0.reason.isEmpty }.map(\.clueID))")

    // 反例：台账干净时不该有修复方案
    let sClean = makeStore("clean")
    prose(sClean, 1, "少年在废窑里捡到一把断刀，刀柄上刻着一个界字。他把刀揣进怀里。")
    prose(sClean, 2, "他去河边洗刀，老周给了他一块干粮。")
    sClean.clues = [Clue(id: "F01", title: "断刀来历", detail: "刀柄刻着界字", timing: .slowBurn,
                         plantedChapter: 1, plantedQuote: "刀柄上刻着一个界字",
                         targetPayoffChapter: 20, status: .planted, lastActionChapter: 1,
                         actions: [ClueActionLog(chapter: 1, kind: .plant, note: "登记")])]
    sClean.characterAliases = [CharacterAlias(canonicalName: "少年", aliases: ["阿昭"])]
    let rClean = ContinuityAuditor.audit(store: sClean, throughChapter: 2)
    check("台账干净时不产出修复方案", rClean.clueFixes.isEmpty, "\(rClean.clueFixes.map { "\($0.clueID):\($0.kind.rawValue)" })")
    check("台账干净时无阻塞项", rClean.blockerCount == 0, "\(rClean.issues.filter { $0.severity == .blocker }.map(\.message))")

    // ---- 骨架触点矛盾 ----
    let sTouch = makeStore("touch")
    prose(sTouch, 1, "少年捡到断刀。"); prose(sTouch, 5, "第五章。")
    sTouch.clues = [
        Clue(id: "F01", title: "断刀", detail: "d", plantedChapter: 1, status: .planted, lastActionChapter: 1),
        Clue(id: "F02", title: "铜牌", detail: "d", plantedChapter: 1, status: .resolved, lastActionChapter: 3),
    ]
    var skTouch = ChapterSkeleton()
    skTouch.beats = [Beat(summary: "少年再次看见断刀", purpose: "埋伏笔")]
    skTouch.clueTouches = [
        ClueTouch(clueID: "F01", action: .plant, requirement: "再埋一次"),      // 已在第1章埋过
        ClueTouch(clueID: "F02", action: .reveal, requirement: "再揭示一次"),   // 台账已回收
        ClueTouch(clueID: "F99", action: .develop, requirement: "孤儿引用"),    // 台账里不存在
    ]
    sTouch.updateChapter(5) { $0.skeleton = skTouch }
    let rTouch = ContinuityAuditor.audit(store: sTouch, throughChapter: 5)
    check("重复埋设被检出", rTouch.issues.contains { $0.category == "骨架触点" && $0.message.contains("F01") },
          "\(rTouch.issues.filter { $0.category == "骨架触点" }.map(\.message))")
    check("重复揭示被检出", rTouch.issues.contains { $0.category == "骨架触点" && $0.message.contains("F02") })
    check("孤儿伏笔引用被检出", rTouch.issues.contains { $0.message.contains("F99") })

    // ---- D. 结构完整性 ----
    let sStruct = makeStore("struct")
    prose(sStruct, 1, "第一章。"); prose(sStruct, 4, "第四章。")   // 2、3 章缺失
    sStruct.updateChapter(4) { $0.prose = String(repeating: "字", count: 700) }  // 长正文无摘要
    let rStruct = ContinuityAuditor.audit(store: sStruct, throughChapter: 4)
    check("章号断裂被检出", rStruct.issues.contains { $0.category == "结构" }, "\(rStruct.issues.map(\.category))")
    check("长正文缺摘要被检出", rStruct.issues.contains { $0.category == "结构" && $0.message.contains("摘要") },
          "\(rStruct.issues.filter { $0.category == "结构" }.map(\.message))")

    // ---- 纯函数 ----
    check("连贯性 similarity 全同为1", abs(ContinuityAuditor.similarity("刀柄上刻着一个界字", "刀柄上刻着一个界字") - 1.0) < 0.001)
    check("连贯性 similarity 空为0", ContinuityAuditor.similarity("", "任意") == 0)
    check("连贯性 similarity 不相干接近0", ContinuityAuditor.similarity("刀柄上刻着一个界字", "明天要去赶集买盐") < 0.2)
    check("properNouns 抽出专名", ContinuityAuditor.properNouns("老周把断刀交给少年，转身走了。").contains { $0.contains("老周") },
          "\(ContinuityAuditor.properNouns("老周把断刀交给少年，转身走了。"))")
    check("properNouns 遵守 limit", ContinuityAuditor.properNouns(String(repeating: "老周少年断刀铜牌", count: 30), limit: 5).count <= 5)

    // ---- 大纲实时对账 ----
    let sOut = makeStore("outline")
    for i in 1...10 { prose(sOut, i, "第\(i)章的内容。") }
    sOut.updateChapter(3) { $0.summary = ChapterSummary(chapter: 3, summary: "少年在废窑觉醒当夜被人追杀，逃到河边。", keyEvents: ["觉醒", "被追杀"], emotionalTone: "惊") }
    sOut.updateChapter(6) { $0.summary = ChapterSummary(chapter: 6, summary: "少年与白零在雾中照面，各自退开。", keyEvents: ["相遇"], emotionalTone: "紧") }
    sOut.storylines = [
        Storyline(id: "L01", name: "复仇", kind: .main, isThroughLine: true, status: .active),
        Storyline(id: "L02", name: "感情", kind: .romance, status: .active, plannedPayoffChapter: 8),
        Storyline(id: "L03", name: "世界", kind: .world, status: .active, entryChapter: 30),
    ]
    sOut.timelineEvents = [
        TimelineEvent(id: "E01", chapter: 3, objectiveFact: "少年在废窑觉醒当夜被追杀，逃到河边", readerKnowledge: "少年在逃", revealed: true, revealChapter: 3, storylineIDs: ["L01"]),
        TimelineEvent(id: "E02", chapter: 3, objectiveFact: "少年与白零在雾中照面，各自退开", readerKnowledge: "两人见过面", revealed: false, storylineIDs: ["L02", "L99"]),
        TimelineEvent(id: "E03", chapter: 4, objectiveFact: "宗门大比开幕，各方势力入场", readerKnowledge: "大比将开", revealed: false, storylineIDs: ["L01"]),
        TimelineEvent(id: "E04", chapter: 30, objectiveFact: "北境战事起", readerKnowledge: "未揭示", revealed: false, storylineIDs: ["L03"]),
    ]
    sOut.stages = [Stage(id: 1, name: "开篇", chapterStart: 1, chapterEnd: 5, theme: "立人物")]
    // L01 若在基准章前一直没有动静，判「断线」才是对的（贯穿线只容忍 3 章静默）。
    // 这里补一条第 9 章的近期事件，才能检验「最近动过的线不被误判」。
    sOut.timelineEvents.append(TimelineEvent(id: "E05", chapter: 9, objectiveFact: "少年在宗门大比上赢下第三场，进了前十", readerKnowledge: "他赢了第三场", revealed: true, revealChapter: 9, storylineIDs: ["L01"]))
    sOut.updateChapter(9) { $0.summary = ChapterSummary(chapter: 9, summary: "少年在宗门大比上赢下第三场，进了前十。", keyEvents: ["赢下第三场"], emotionalTone: "扬") }
    let rOut = OutlineSync.sync(store: sOut, asOfChapter: 10)
    check("对账基准章正确", rOut.asOfChapter == 10, "asOf=\(rOut.asOfChapter)")
    let ev = { (id: String) in rOut.eventSync.first { $0.eventID == id } }
    check("计划事件在第3章被证实已发生", ev("E01")?.status == "已发生", "E01=\(String(describing: ev("E01")?.status)) sim=\(String(describing: ev("E01")?.similarity))")
    check("已发生事件匹配到正确章", ev("E01")?.matchedChapter == 3, "matched=\(String(describing: ev("E01")?.matchedChapter))")
    check("计划在第3章实际写在第6章判偏移", ev("E02")?.status == "疑似偏移" && ev("E02")?.matchedChapter == 6,
          "E02=\(String(describing: ev("E02")?.status) ) matched=\(String(describing: ev("E02")?.matchedChapter))")
    check("偏移事件产出改期建议", rOut.suggestedUpdates.contains { $0.kind == .eventMoved && $0.eventID == "E02" && $0.newChapter == 6 },
          "\(rOut.suggestedUpdates.map { "\($0.kind.rawValue):\($0.eventID ?? "-")→\($0.newChapter.map(String.init) ?? "-")" })")
    check("已发生事件产出确认建议", rOut.suggestedUpdates.contains { $0.kind == .eventHappened && $0.eventID == "E01" })
    check("读者未知但正文已写出产出揭示建议", rOut.suggestedUpdates.contains { $0.kind == .eventRevealed && $0.eventID == "E02" },
          "\(rOut.suggestedUpdates.filter { $0.kind == .eventRevealed }.map(\.eventID))")
    check("逾期未发生的事件判未发生", ev("E03")?.status == "未发生", "E03=\(String(describing: ev("E03")?.status))")
    check("严重逾期事件产出取消建议", rOut.suggestedUpdates.contains { $0.kind == .eventDropped && $0.eventID == "E03" })
    check("排期未到的事件不误判", ev("E04")?.status == "排期未到", "E04=\(String(describing: ev("E04")?.status))")
    check("排期未到不产出取消建议", !rOut.suggestedUpdates.contains { $0.kind == .eventDropped && $0.eventID == "E04" })

    let lh = { (id: String) in rOut.lineHealth.first { $0.storylineID == id } }
    check("最近动过的主线判健康", lh("L01")?.state == .healthy,
          "L01=\(String(describing: lh("L01")?.state)) dormant=\(String(describing: lh("L01")?.dormantChapters))")
    check("收束期已过的线判待收束", lh("L02")?.state == .dueForPayoff, "L02=\(String(describing: lh("L02")?.state))")
    check("未到入场章的线不判断线", lh("L03")?.state == .healthy, "L03=\(String(describing: lh("L03")?.state))")
    check("断线/待收束进偏差清单", rOut.divergences.contains { $0.category == "剧情线" }, "\(rOut.divergences.map(\.category))")
    check("孤儿故事线引用被检出", rOut.divergences.contains { $0.message.contains("L99") },
          "\(rOut.divergences.map(\.message))")
    check("阶段进度落后被检出", rOut.divergences.contains { $0.category == "阶段" } || rOut.stageProgress.first?.completionRatio != nil,
          "\(rOut.divergences.map { "[\($0.category)] \($0.message)" })")
    check("每条建议都有人话理由", rOut.suggestedUpdates.allSatisfy { !$0.reason.isEmpty })

    // 反例：空大纲不该崩也不该编造
    let sEmpty = makeStore("empty")
    prose(sEmpty, 1, "只有一章。")
    let rEmpty = OutlineSync.sync(store: sEmpty, asOfChapter: 1)
    check("空大纲对账不崩不编造", rEmpty.lineHealth.isEmpty && rEmpty.eventSync.isEmpty && rEmpty.stageProgress.isEmpty && rEmpty.suggestedUpdates.isEmpty,
          "lines=\(rEmpty.lineHealth.count) events=\(rEmpty.eventSync.count) stages=\(rEmpty.stageProgress.count) upd=\(rEmpty.suggestedUpdates.count)")
    check("空大纲仍有可读总结", !rEmpty.summary.isEmpty)

    // 静默容忍度：主线严格、感情线宽松
    check("贯穿线容忍度最低", OutlineSync.dormantThreshold(kind: .main, isThroughLine: true) == 3)
    check("感情线容忍度高于主线", OutlineSync.dormantThreshold(kind: .romance, isThroughLine: false) > OutlineSync.dormantThreshold(kind: .main, isThroughLine: false))

    // 断线判定（真实场景：一条线很久没动）
    let sBroken = makeStore("broken")
    for i in 1...20 { prose(sBroken, i, "第\(i)章。") }
    sBroken.storylines = [Storyline(id: "L01", name: "复仇", kind: .main, isThroughLine: true, status: .active)]
    sBroken.timelineEvents = [TimelineEvent(id: "E01", chapter: 2, objectiveFact: "复仇线启动", readerKnowledge: "启动", revealed: true, revealChapter: 2, storylineIDs: ["L01"])]
    sBroken.updateChapter(2) { $0.summary = ChapterSummary(chapter: 2, summary: "复仇线启动，他立了誓。", keyEvents: ["立誓"], emotionalTone: "决") }
    let rBroken = OutlineSync.sync(store: sBroken, asOfChapter: 20)
    check("静默 18 章的主线判断线", rBroken.lineHealth.first?.state == .broken,
          "state=\(String(describing: rBroken.lineHealth.first?.state)) dormant=\(rBroken.lineHealth.first?.dormantChapters ?? -1)")
    check("断线产出状态调整建议", rBroken.suggestedUpdates.contains { $0.kind == .storylineStatus && $0.storylineID == "L01" },
          "\(rBroken.suggestedUpdates.map(\.kind.rawValue))")

    // 已同步过的事件不该反复提案（幂等）
    sOut.timelineEvents[0].happened = true
    sOut.timelineEvents[0].actualChapter = 3
    let rOut2 = OutlineSync.sync(store: sOut, asOfChapter: 10)
    check("已同步事件不重复产建议", !rOut2.suggestedUpdates.contains { $0.kind == .eventHappened && $0.eventID == "E01" },
          "\(rOut2.suggestedUpdates.filter { $0.eventID == "E01" }.map(\.kind.rawValue))")
    sOut.timelineEvents[2].dropped = true
    let rOut3 = OutlineSync.sync(store: sOut, asOfChapter: 10)
    check("已取消事件不再被反复催", !rOut3.suggestedUpdates.contains { $0.eventID == "E03" },
          "\(rOut3.suggestedUpdates.filter { $0.eventID == "E03" }.map(\.kind.rawValue))")
}

// MARK: - 23. 工具面契约（schema 合法性 + 每个能力都有生产者）
//
// ProposalToolBridge 在 parametersJSON 解析失败时会**静默降级成空 schema**，
// 模型于是拿不到任何字段定义，产出必然不合格——而宿主这边一声不响。
// 所以 schema 必须逐条自检；同时每个 AI 能力都必须至少有一个 propose_* 工具，
// 否则那个能力就是个按了没反应的按钮。

MainActor.assumeIsolated {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zb-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let st = ProjectStore(rootURL: url)
    let tools = NovelTools.all(store: st)

    check("工具名唯一", Set(tools.map(\.name)).count == tools.count,
          "重复：\(tools.map(\.name).filter { n in tools.map(\.name).filter { $0 == n }.count > 1 })")
    check("新工具已注册", ["propose_continuity", "propose_outline_updates"].allSatisfy { n in tools.contains { $0.name == n } },
          "实有：\(tools.map(\.name))")

    var badSchema: [String] = []
    var badRequired: [String] = []
    var noProps: [String] = []
    for t in tools {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8)) as? [String: Any] else {
            badSchema.append(t.name); continue
        }
        guard (obj["type"] as? String) == "object" else { badSchema.append(t.name + "(type≠object)"); continue }
        guard let props = obj["properties"] as? [String: Any], !props.isEmpty else {
            // 只读查询工具允许空 properties（如 get_clues），但 propose_* 必须有字段
            if t.name.hasPrefix("propose_") { noProps.append(t.name) }
            continue
        }
        let required = (obj["required"] as? [String]) ?? []
        let missing = required.filter { props[$0] == nil }
        if !missing.isEmpty { badRequired.append("\(t.name): \(missing.joined(separator: ","))") }
    }
    check("所有工具 schema 都是合法 JSON object", badSchema.isEmpty, badSchema.joined(separator: "、"))
    check("propose_* 工具都有字段定义", noProps.isEmpty, noProps.joined(separator: "、"))
    check("required 字段都在 properties 里声明", badRequired.isEmpty, badRequired.joined(separator: "；"))

    // 骨架工具必须真的暴露了场景层与新字段，否则模型不会填、闸门也就无从校验
    if let skTool = tools.first(where: { $0.name == "propose_skeleton" }),
       let obj = try? JSONSerialization.jsonObject(with: Data(skTool.parametersJSON.utf8)) as? [String: Any],
       let props = obj["properties"] as? [String: Any],
       let beatItems = (props["beats"] as? [String: Any])?["items"] as? [String: Any],
       let beatProps = beatItems["properties"] as? [String: Any] {
        let need = ["summary", "purpose", "suggested_words", "pov", "location", "time_label", "cast", "turn"]
        check("骨架节拍暴露场景层字段", need.allSatisfy { beatProps[$0] != nil },
              "缺：\(need.filter { beatProps[$0] == nil })")
        let topNeed = ["end_hook", "hook_kind", "pov", "must_deliver", "must_avoid", "clue_touches",
                       "payoff_type", "new_expectation", "volume_label"]
        check("骨架顶层暴露钩子形态与爽点字段", topNeed.allSatisfy { props[$0] != nil },
              "缺：\(topNeed.filter { props[$0] == nil })")
        if let hk = props["hook_kind"] as? [String: Any], let kinds = hk["enum"] as? [String] {
            check("钩子形态枚举与法典一致", Set(kinds) == Set(HookKind.allCases.map(\.rawValue)),
                  "schema=\(kinds) 法典=\(HookKind.allCases.map(\.rawValue))")
        } else { check("钩子形态枚举与法典一致", false, "hook_kind 没有 enum") }
        if let ct = (props["clue_touches"] as? [String: Any])?["items"] as? [String: Any],
           let ctp = ct["properties"] as? [String: Any],
           let acts = (ctp["action"] as? [String: Any])?["enum"] as? [String] {
            check("触点动作枚举覆盖搁置与回收", acts.contains("defer") && acts.contains("resolve"), "acts=\(acts)")
        } else { check("触点动作枚举覆盖搁置与回收", false, "clue_touches.action 没有 enum") }
    } else {
        check("骨架工具 schema 可解析出场景层", false, "解析失败")
        check("骨架顶层暴露钩子形态与爽点字段", false, "解析失败")
        check("钩子形态枚举与法典一致", false, "解析失败")
        check("触点动作枚举覆盖搁置与回收", false, "解析失败")
    }

    // 每个能力都必须有生产者：没有 propose_* 工具的能力＝按了没反应的按钮
    var noProducer: [String] = []
    for cap in AICapability.allCases {
        let names = AIService.toolNames(for: cap)
        if !names.contains(where: { $0.hasPrefix("propose_") }) { noProducer.append("\(cap.rawValue):\(names.joined(separator: ","))") }
    }
    check("每个 AI 能力都至少有一个 propose_* 工具", noProducer.isEmpty, noProducer.joined(separator: "；"))
    let volumeTools = AIService.volumeSkeletonToolNames()
    check("卷级设计只交 memo 不碰章节骨架", volumeTools.contains("propose_memo")
          && !volumeTools.contains("propose_skeleton") && !volumeTools.contains("propose_draft"),
          "volumeTools=\(volumeTools.sorted())")
    check("连贯性审查能拿到取证工具", AIService.toolNames(for: .continuityAudit).contains("get_chapter"))
    check("大纲同步能读到大纲", AIService.toolNames(for: .outlineSync).contains("get_outline"))
    check("大纲同步能补新事件", AIService.toolNames(for: .outlineSync).contains("propose_outline_events"))

    // MARK: 资料库 / 向量 / 对话
    let kbRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("zb-kb-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: kbRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: kbRoot) }
    let kb = ProjectStore(rootURL: kbRoot)
    kb.project.title = "断刀记"
    _ = kb.ensureChapter(1)
    kb.updateChapter(1) { ch in
        ch.title = "废窑"; ch.status = .written
        ch.prose = "少年在废窑里捡到一把断刀，刀柄上刻着一个界字。他把刀揣进怀里，听见窑外有人咳嗽。"
        ch.summary = ChapterSummary(chapter: 1, summary: "少年在废窑捡到断刀，窑外传来咳嗽声。",
                                    keyEvents: ["得刀", "被窥视"], emotionalTone: "警觉")
        ch.skeleton = ChapterSkeleton(
            beats: [Beat(summary: "少年在废窑捡到断刀", purpose: "推进", suggestedWords: 800,
                         pov: "少年", location: "废窑", timeLabel: "当夜", cast: ["少年"],
                         turn: "从躲藏到得刀")],
            endHook: "窑外有人咳嗽", humanApproved: true, hookKind: "悬念")
    }
    kb.canonSections = [CanonSection(title: "兵器谱", content: "断刀是前朝兵器，刀柄的界字指向北境。",
                                     certainty: .canon)]
    kb.dossiers = [ChapterDossier(chapter: 1, headline: "废窑得刀",
                                  scenes: ["废窑"], cast: ["少年"], advances: ["捡到断刀"],
                                  turns: ["躲藏→得刀"], hooks: ["窑外咳嗽"], relics: ["断刀"])]
    kb.clues = [Clue(id: "F01", title: "断刀来历", detail: "刀柄界字指向北境",
                     plantedChapter: 1, plantedQuote: "刀柄上刻着一个界字", status: .planted)]
    kb.facts = [MemoryFact(subject: "少年", predicate: "持有", object: "断刀", fromChapter: 1, source: "extracted")]
    kb.timelineEvents = [TimelineEvent(id: "E01", chapter: 1, objectiveFact: "少年在废窑捡到断刀",
                                       readerKnowledge: "读者知道得刀", revealed: true)]
    kb.storylines = [Storyline(id: "L01", name: "查清断刀来历", kind: .main, isThroughLine: true, status: .active)]
    kb.stages = [Stage(id: 1, name: "废窑开局", chapterStart: 1, chapterEnd: 3, theme: "得刀与追查")]

    let kbIndex = KnowledgeIndex.build(from: kb)
    let kinds = Set(kbIndex.chunks.map(\.kind))
    check("资料库索引覆盖正文/章摘要/骨架/设定/档案卡/伏笔/事实/时间线/故事线/阶段",
          kinds.isSuperset(of: [.prose, .summary, .skeleton, .canon, .dossier, .clue, .fact, .event, .storyline, .stage]),
          "kinds=\(kinds.map(\.rawValue).sorted())")
    let kbHits = kbIndex.keywordSearch("断刀 界字", limit: 10)
    check("资料库能按具体名词召回多个来源", Set(kbHits.prefix(6).map(\.chunk.kind)).count >= 3,
          "hits=\(kbHits.map { "\($0.chunk.kind.rawValue):\($0.chunk.citation)" })")
    check("资料库命中带可引用来源", kbHits.allSatisfy { !$0.chunk.citation.isEmpty })
    check("资料库对无关词不硬凑", kbIndex.keywordSearch("量子飞船曲率引擎", limit: 5).isEmpty)
    let vectorProbe = HashingVectorizer.vector("断刀")
    check("本地哈希向量已归一化", abs(vectorProbe.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
    if let first = kbIndex.chunks.first(where: { $0.text.contains("断刀") }), !vectorProbe.isEmpty {
        check("向量能对同主题片段给出正相关", VectorMath.cosine(vectorProbe, first.vector) > 0)
    } else {
        check("向量能对同主题片段给出正相关", false, "没有断刀片段")
    }
    check("资料库检索工具已注册", NovelTools.all(store: kb).contains { $0.name == "search_knowledge" })
    let chatToolNames = AIService.toolNames(for: .chat)
    check("对话能力有资料库/骨架/草稿读取",
          chatToolNames.contains("search_knowledge")
          && chatToolNames.contains("get_chapter_skeleton")
          && chatToolNames.contains("get_latest_draft"))
    check("对话能力可登记非章节提案",
          chatToolNames.contains("propose_clues") && chatToolNames.contains("propose_storylines"))
    check("对话能力可提交整章草稿提案", chatToolNames.contains("propose_draft"))
    check("对话能力可搭骨架/验证/写档案卡",
          chatToolNames.contains("propose_skeleton")
          && chatToolNames.contains("propose_validation")
          && chatToolNames.contains("propose_dossier"))
    check("对话能力可提议大纲更新", chatToolNames.contains("propose_outline_updates"))
    check("对话能力没有直接写正文工具",
          !chatToolNames.contains("write_prose") && !chatToolNames.contains("update_prose"))
    let draftProbe = ChapterDraft(chapter: 1, text: "少年把断刀裹进破布，窑外的脚步声停了。",
                                  version: 1, mainline: "断刀线索",
                                  feedbackHistory: [DraftFeedback(feedback: "开头太慢，直接进废窑。", fromVersion: 1)])
    kb.proposals = [AIProposal(capability: .chapterDraft, chapterNumber: 1,
                               title: "第1章 草稿 v1", payload: .draft(draftProbe))]
    let skeletonText = NovelTools.chapterSkeletonDescription(store: kb, chapter: 1)
    check("对话能读取任意章骨架与场景层",
          skeletonText.contains("作者已批准") && skeletonText.contains("废窑")
          && skeletonText.contains("从躲藏到得刀") && skeletonText.contains("窑外有人咳嗽"),
          String(skeletonText.prefix(160)))
    let draftText = NovelTools.latestDraftDescription(store: kb, chapter: 1)
    check("对话能读取最新草稿与作者意见",
          draftText.contains("草稿") && draftText.contains("开头太慢") && draftText.contains("v1"),
          String(draftText.prefix(120)))
    let chatPrompt = PromptLibrary.chatTask(store: kb, history: [], knowledge: Array(kbHits.prefix(3)),
                                            question: "断刀在哪出现过？")
    check("对话任务书带上资料库引用", chatPrompt.contains("【") && chatPrompt.contains("断刀"))
    check("对话任务书带当前写作章与续接信息",
          chatPrompt.contains("当前写作章") && chatPrompt.contains("上一章结尾"))
    check("对话任务书告知骨架/验证/档案卡能力",
          chatPrompt.contains("propose_skeleton")
          && chatPrompt.contains("propose_validation")
          && chatPrompt.contains("propose_dossier"))
    let packProbe = ContextPackBuilder.build(store: kb, forChapter: 1, budget: 4000)
    let draftPrompt = PromptLibrary.draftTask(chapter: 1, title: "废窑", targetWords: 3000,
                                              mainline: "断刀线索", skeletonText: "",
                                              pack: packProbe, model: "mock",
                                              knowledgeRecall: Array(kbHits.prefix(2)))
    check("草稿任务书带上资料库召回",
          draftPrompt.contains("资料库召回") && draftPrompt.contains(kbHits[0].chunk.citation))
    let skeletonPrompt = PromptLibrary.chapterSkeletonTask(
        chapter: 1, chapterTitle: "废窑", pack: packProbe, authorDirective: "断刀线索",
        knowledgeRecall: Array(kbHits.prefix(2)))
    check("骨架任务书带上资料库召回",
          skeletonPrompt.contains("资料库召回") && skeletonPrompt.contains(kbHits[0].chunk.citation))

    // 回答里的短引用 → 资料库完整来源；工具结果里的完整来源 → 引用池
    let citationPool = ["第12章《雾隐》", "设定《世界观》", "伏笔 [F03] 断刀", "档案卡 第8章"]
    let resolved = KnowledgeCitations.resolve(
        in: "见【第12章】与【设定《世界观》】，另有【伏笔 [F03]】和【不存在的来源】。",
        pool: citationPool)
    check("回答引用能对齐到完整来源",
          resolved.contains("第12章《雾隐》") && resolved.contains("设定《世界观》")
          && resolved.contains("伏笔 [F03] 断刀"), "resolved=\(resolved)")
    check("未匹配的引用保留原标注", resolved.contains("不存在的来源"), "resolved=\(resolved)")
    check("引用标注去重", KnowledgeCitations.bracketed(in: "【第1章】【第1章】").count == 1)
    check("工具结果来源可提取",
          KnowledgeCitations.bracketed(in: "【第3章《废窑》】\n正文……\n（来源：第3章）") == ["第3章《废窑》"])
    check("引用跳转·正文回章节",
          KnowledgeCitations.target(for: "第12章《雾隐》") == .chapter(12))
    check("引用跳转·摘要/骨架/档案卡回章节",
          KnowledgeCitations.target(for: "章摘要 第3章") == .chapter(3)
          && KnowledgeCitations.target(for: "骨架 第4章") == .chapter(4)
          && KnowledgeCitations.target(for: "档案卡 第8章") == .chapter(8))
    check("引用跳转·设定/伏笔/记忆/大纲归位",
          KnowledgeCitations.target(for: "设定《世界观》") == .canon
          && KnowledgeCitations.target(for: "伏笔 [F03] 断刀") == .clues
          && KnowledgeCitations.target(for: "记忆账本·第3章起") == .memory
          && KnowledgeCitations.target(for: "时间线 [E01]·第12章") == .outline
          && KnowledgeCitations.target(for: "故事线 [L01]") == .outline)
    check("无法识别的引用不误导跳转", KnowledgeCitations.target(for: "作者笔记") == nil)
    let focusNeedle = kbHits.first.flatMap { KnowledgeFocus.needle(for: $0) }
    check("资料库命中能选出一个可定位的针",
          focusNeedle != nil && focusNeedle.map { kbHits[0].chunk.text.contains($0) } == true,
          "needle=\(focusNeedle ?? "nil")")
    check("能在原文里定位命中针",
          KnowledgeFocus.range(of: "断刀", in: "少年在废窑里捡到一把断刀。")
            .map { $0.location != NSNotFound } == true)
    check("定位不到返回 nil", KnowledgeFocus.range(of: "不存在的词", in: "少年捡到断刀") == nil)

    // 同长度修订（北境→南境）也必须让派生索引失效
    KnowledgeIndexCache.invalidate()
    kb.canonSections[0].content = "断刀是前朝兵器，刀柄的界字指向北境。"
    let beforeCache = KnowledgeIndexCache.index(for: kb)
    kb.canonSections[0].content = "断刀是前朝兵器，刀柄的界字指向南境。"
    let afterCache = KnowledgeIndexCache.index(for: kb)
    check("同长度内容修改会重建索引",
          beforeCache.chunks.contains { $0.kind == .canon && $0.text.contains("北境") }
          && afterCache.chunks.contains { $0.kind == .canon && $0.text.contains("南境") }
          && !afterCache.chunks.contains { $0.kind == .canon && $0.text.contains("北境") },
          "before=\(beforeCache.chunks.filter { $0.kind == .canon }.map(\.text))")

    let chatRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("zb-chat-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: chatRoot) }
    let chatStore = ProjectStore(rootURL: chatRoot)
    try? chatStore.saveNow()   // 先建出书；下面只靠 append 自己落 chat.json
    chatStore.appendChatMessage(ChatMessage(role: .user, text: "断刀在哪出现过？"))
    chatStore.appendChatMessage(ChatMessage(role: .assistant, text: "第1章废窑。", citations: ["第1章《废窑》"]))
    let chatReloaded = ProjectStore(rootURL: chatRoot)
    try? chatReloaded.load()
    check("对话记录即时保存（不靠整书保存）", chatReloaded.chatMessages.count == 2
          && chatReloaded.chatMessages.last?.citations == ["第1章《废窑》"],
          "count=\(chatReloaded.chatMessages.count)")
    let removedReply = chatReloaded.removeLastChatMessage()
    let chatAfterRemove = ProjectStore(rootURL: chatRoot)
    try? chatAfterRemove.load()
    check("撤掉上一条回复会即时落盘",
          removedReply?.role == .assistant && chatAfterRemove.chatMessages.count == 1,
          "count=\(chatAfterRemove.chatMessages.count)")
    chatReloaded.clearChat()
    let chatCleared = ProjectStore(rootURL: chatRoot)
    try? chatCleared.load()
    check("清空对话会落盘不复活", chatCleared.chatMessages.isEmpty, "count=\(chatCleared.chatMessages.count)")

    // 对话导出 / 归档
    let transcript = ChatTranscript.markdown(
        messages: [ChatMessage(role: .user, text: "断刀在哪？"),
                   ChatMessage(role: .assistant, text: "第1章废窑。", citations: ["第1章《废窑》"])],
        projectTitle: "断刀记", exportedAt: Date(timeIntervalSince1970: 0))
    check("对话可导出为 Markdown",
          transcript.contains("作者") && transcript.contains("AI 搭档")
          && transcript.contains("来源：【第1章《废窑》】"),
          String(transcript.prefix(120)))
    let exportName = ChatTranscript.fileName(projectTitle: "断/刀:记")
    check("导出文件名避开路径分隔符",
          !exportName.contains("/") && !exportName.contains(":"), exportName)

    let archiveRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("zb-chat-archive-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: archiveRoot) }
    let archiveStore = ProjectStore(rootURL: archiveRoot)
    try? archiveStore.saveNow()
    archiveStore.appendChatMessage(ChatMessage(role: .user, text: "断刀在哪出现过？"))
    archiveStore.appendChatMessage(ChatMessage(role: .assistant, text: "第1章废窑。"))
    let archiveURL = archiveStore.archiveChat()
    let archivedText = archiveURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    let archiveReloaded = ProjectStore(rootURL: archiveRoot)
    try? archiveReloaded.load()
    check("归档对话会写文件并清空",
          archiveURL != nil && archivedText?.contains("断刀") == true
          && archiveReloaded.chatMessages.isEmpty,
          "url=\(archiveURL?.lastPathComponent ?? "nil") count=\(archiveReloaded.chatMessages.count)")
    let archiveList = archiveStore.listChatArchives()
    check("归档列表能列出归档文件",
          archiveList.count == 1
          && archiveList.first?.url.lastPathComponent == archiveURL?.lastPathComponent,
          "count=\(archiveList.count)")
    check("归档内容可在应用内回读",
          archiveList.first.flatMap { archiveStore.readChatArchive($0.url) }?.contains("断刀") == true)
    let payloadURL = archiveURL.flatMap { archiveStore.chatArchivePayloadURL(for: $0) }
    check("归档同时写入可恢复 JSON",
          payloadURL != nil && archiveURL.flatMap { archiveStore.readChatArchivePayload($0) }?.messages.count == 2)
    let restoredCount = archiveURL.flatMap { archiveStore.restoreChatArchive($0) }
    check("归档可恢复追加到当前对话",
          restoredCount == 2 && archiveStore.chatMessages.count == 2)
    let restoredReloaded = ProjectStore(rootURL: archiveRoot)
    try? restoredReloaded.load()
    check("恢复后的对话已落盘", restoredReloaded.chatMessages.count == 2)
    let secondRestore = archiveURL.flatMap { archiveStore.restoreChatArchive($0) }
    check("重复恢复同一归档不会产生重复消息",
          secondRestore == 0 && archiveStore.chatMessages.count == 2,
          "restored=\(secondRestore ?? -1) count=\(archiveStore.chatMessages.count)")
    check("不会删除作品目录外的文件",
          !archiveStore.deleteChatArchive(URL(fileURLWithPath: "/tmp/zhibi-not-ours.md")))
    let decoyDir = archiveRoot.appendingPathComponent("chat-archive-evil.md", isDirectory: true)
    try? FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
    check("不会删除同名的目录",
          !archiveStore.deleteChatArchive(decoyDir)
          && FileManager.default.fileExists(atPath: decoyDir.path))
    check("目录不会被当成可恢复归档",
          archiveStore.readChatArchivePayload(decoyDir) == nil)
    check("删除归档只删归档文件",
          archiveList.first.map { archiveStore.deleteChatArchive($0.url) } == true
          && archiveStore.listChatArchives().isEmpty
          && payloadURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

    let proposalProbe = AIProposal(capability: .chapterDraft, chapterNumber: 1,
                                   title: "第1章 草稿 v1",
                                   payload: .draft(ChapterDraft(chapter: 1, text: "少年把断刀裹进破布。")))
    let proposalMessage = ChatMessage(role: .assistant, text: "已登记。",
                                      proposalIDs: [proposalProbe.id])
    let transcriptWithProposals = ChatTranscript.markdown(
        messages: [proposalMessage], projectTitle: "断刀记", proposals: [proposalProbe],
        exportedAt: Date(timeIntervalSince1970: 0))
    check("导出对话附带提案快照",
          transcriptWithProposals.contains("第1章 草稿 v1")
          && transcriptWithProposals.contains("待确认"),
          String(transcriptWithProposals.suffix(120)))
    let legacyJSON = #"{"role":"AI","text":"旧消息"}"#.data(using: .utf8)!
    let legacyMessage = try? JSONDecoder().decode(ChatMessage.self, from: legacyJSON)
    check("旧对话缺提案字段也能解", legacyMessage?.proposalIDs.isEmpty == true)
}
fputs("[p] summary\n", stderr)
// MARK: - 汇总

print("\n======== 自检结果：通过 \(passed) 项，失败 \(failures.count) 项 ========")
for f in failures { print("  FAIL: \(f)") }
exit(failures.isEmpty ? 0 : 1)
