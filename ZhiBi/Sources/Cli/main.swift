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
            ImportService.apply(summary, into: store)
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

fputs("[p] s1\n", stderr)
// MARK: - 1. 字数统计

fputs("[probe] s1 中文字数\n", stderr)
let sample = "他捏碎了手中的茶杯，滚烫的茶水流过指缝。"
check("中文字数统计（含标点，网文口径）", WordStats.chineseCount(sample) == 20, "实际 \(WordStats.chineseCount(sample))")

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
func runStoreTests(tmp: URL) throws {
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

    // 5.2 快照与回滚
    let snap = store2.snapshotProse(chapter: 2, tag: "test")
    store2.updateChapter(2) { $0.prose = "改坏了。" }
    store2.restoreSnapshot(chapter: 2, name: snap ?? "")
    check("快照回滚", store2.chapter(2)?.prose.contains("夜风很冷") == true)

    // 5.3 确定性验证：章1 伏笔合同应通过；章2 应检出跨章重复
    let report1 = Validator.deterministicReport(store: store2, chapter: 1)
    check("章1伏笔合同无 blocker", !report1.allIssues.contains { $0.category == "伏笔合同" && $0.severity == .blocker })
    let report2 = Validator.deterministicReport(store: store2, chapter: 2)
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

fputs("[p] summary\n", stderr)
// MARK: - 汇总

print("\n======== 自检结果：通过 \(passed) 项，失败 \(failures.count) 项 ========")
for f in failures { print("  FAIL: \(f)") }
exit(failures.isEmpty ? 0 : 1)
