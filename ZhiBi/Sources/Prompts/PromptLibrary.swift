import Foundation

// MARK: - Prompt 库
// 综合 InkOS（规划师/写手契约/结算铁律）、NarraCat（任务书/五类客观审校）、
// oh-story（细纲契约/三档授权/7 Gate）与 Humanizer v4.1（去AI味方法论）。

enum PromptLibrary {
    /// 通用人格：编辑搭档，不写正文，产出皆为提案
    static let persona = """
    你是一本中文小说的编辑搭档。这本书由作者亲笔写作；你的职责是规划、记账、查错、给建议。
    铁律：
    1. 你永远不写正文。你的所有产出都通过 propose_* 工具登记为"提案"，由作者在收件箱里确认、修改或拒绝。
    2. 完成与否以提案落盘为准，不要在文字里声称"已完成/已保存/已采纳"。
    3. 对作者说话只用作者词汇（人话），不要输出字段名、英文枚举、工程黑话。
    4. 做到就说做到，没做到就说没做到，不用"已充分考虑"这类话糊弄。
    """

    static func systemInstruction(for capability: AICapability) -> String {
        persona + "\n\n当前任务：" + taskBrief(for: capability)
    }

    private static func taskBrief(for capability: AICapability) -> String {
        switch capability {
        case .framework:
            return "为新书搭建初始框架：主线故事线 + 关键事件时间线 + 背景设定文档。分别用 propose_storylines / propose_outline_events / propose_canon 提案，全部提交给作者审阅。"
        case .outlineTimeline:
            return "构建核心大纲：故事线 + 事件时间线。用 propose_storylines 与 propose_outline_events 提案。"
        case .clueLedger:
            return "盘点伏笔/线索台账。用 propose_clues 提案。"
        case .chapterSkeleton:
            return "为指定章节搭骨架。用 propose_skeleton 提案。"
        case .chapterDraft:
            return "按作者主线与骨架撰写整章草稿，用 propose_draft 提交全文。这是提案：作者会审查并给修改意见，采纳前不进正文。"
        case .chapterRevise:
            return "按作者修改意见修订草稿，用 propose_draft 提交修订后的完整全文（新版本，不是补丁）。"
        case .memoryExtract:
            return "从作者刚写完的正文提取记忆包。用 propose_memory 提案。"
        case .validation:
            return "对指定章节做一致性审校。用 propose_validation 提案。"
        case .continuityAudit:
            return "对全书做连贯性审校与伏笔烂账排查。用 propose_continuity 提案。宿主已用确定性代码扫过一遍（死者复出/位置跳跃/时间线倒挂/伏笔台账烂账），你的职责是补它查不出来的部分：动机断裂、能力与资源前后不一致、人物性格漂移、称谓与身份混乱、因果链缺口。"
        case .outlineSync:
            return "把大纲与真实剧情对账并给出更新建议。用 propose_outline_updates 提案。宿主已用确定性代码算出「计划 vs 实际」的偏差与剧情线健康度，你的职责是判断这些偏差是该改大纲还是该改后文，并补出大纲里已经明显过时或缺失的事件。"
        case .deslop:
            return "对指定章节做去AI味诊断并给逐处修改建议。用 propose_deslop 提案。"
        case .recallMemo:
            return "基于上下文包给作者写本章备忘。用 propose_memo 提案。"
        }
    }

    /// 创作法典片段（流派档案 + 网文创作法 + 传统文学创作法），按能力裁剪后注入任务书。
    /// 这是"吸收经典网文与传统文学创作风格/哲学/理念"的落点：不是塞一段鸡汤，
    /// 而是让每个能力都拿到与它相关的那部分法典。
    static func craft(for capability: AICapability, genre: String, written: Int = 0, target: Int = 100) -> String {
        CraftCodex.codex(for: capability, genreText: genre, progress: (written, target))
    }

    // MARK: - 大纲时间线

    static func outlineTimelineTask(premise: String, canon: String, notes: String, targetChapters: Int) -> String {
        """
        请基于以下材料构建这本书的核心大纲。

        ## 书籍信息
        书名/题材/一句话核心：\(premise)
        目标体量：约 \(targetChapters) 章
        作者补充：\(notes.isEmpty ? "（无）" : notes)

        ## 已有设定
        \(canon.isEmpty ? "（暂无设定文档）" : String(canon.prefix(6000)))

        ## 要求（InkOS 规划纪律）
        1. 先提故事线（propose_storylines）：一条主线 + 至多 3 条重要支线；贯穿全书的主线标 is_through_line。
        2. 再提事件时间线（propose_outline_events）：8-20 个关键事件，覆盖开篇期(10-15%)→发展期(50-60%)→高潮期(20-25%)→收尾期(5-10%)。
        3. 每个事件必须写两条：objective_fact 是"作者真相"（客观发生了什么，含隐瞒的底牌）；reader_knowledge 是"读者已知"（读者此刻被告知了什么）。未揭晓的真相 revealed=false——这是悬念管理的基础。
        4. 主动制造"还没兑现但快要兑现"的缺口；重大反转要有前置伏笔位。
        5. 赌注递增：每个阶段的核心冲突比上一阶段更重。
        """
    }

    // MARK: - 新书初始框架（创建即搭）

    static func bootstrapFrameworkTask(premise: String, canon: String, notes: String, targetChapters: Int) -> String {
        """
        这是一本刚创建的新书。基于以下最小材料搭建初始框架。你只产出提案——不写正文、不改设定库，作者审阅采纳后才生效。

        ## 书籍信息
        \(premise)
        目标体量：约 \(targetChapters) 章
        作者补充：\(notes.isEmpty ? "（无）" : notes)

        ## 已有设定
        \(canon.isEmpty ? "（新书，暂无设定）" : String(canon.prefix(6000)))

        ## 三件套（按顺序提案）
        1. **背景设定框架（propose_canon，2-4 篇）**：先立世界规则——至少覆盖：核心设定/力量体系或规则、主要势力/人物框架、题材惯例与禁区。每篇一个主题，Markdown 可含表格；作者还没定的事标 tentative，有意留白的标 blank。
        2. **故事线（propose_storylines）**：一条主线（is_through_line）+ 至多 2 条支线；每条写清起止与赌注。
        3. **关键事件时间线（propose_outline_events，8-16 个）**：覆盖开篇(10-15%)→发展(50-60%)→高潮(20-25%)→收尾(5-10%)。每个事件写 objective_fact（作者真相，含底牌）与 reader_knowledge（读者此刻已知），未揭晓的 revealed=false。

        ## 纪律
        - 一切从作者的一句话核心出发，不自嗨加戏；一句话没有的信息，用最保守的版本并标 tentative。
        - 重大反转必须预留前置伏笔位（在事件里点出）。
        - 语言克制，不要形容词堆砌；设定文档是给作者看的施工图，不是宣传语。
        """
    }

    // MARK: - 章节骨架（InkOS 规划师 memo 精髓）

    static func chapterSkeletonTask(chapter n: Int, chapterTitle: String, pack: ContextPack,
                                    authorDirective: String, craft: String = "",
                                    gateReport: String = "", prevHookKinds: String = "") -> String {
        """
        请为第\(n)章「\(chapterTitle)」搭骨架。你不写正文——你只规划这章要完成什么、兑现什么、不要做什么。

        ## 上下文（宿主已按预算组装，可信）
        \(pack.asText)

        ## 作者对本章的直接要求（最高优先级）
        \(authorDirective.isEmpty ? "（无，按大纲与上下文推进）" : authorDirective)

        ## 创作法典（题材契约 + 两套创作法，按它的标准规划）
        \(craft.isEmpty ? "（未注入）" : craft)
        \(prevHookKinds.isEmpty ? "" : "\n## 近几章已用过的钩子形态（本章要换一种，避免套版）\n\(prevHookKinds)")}

        ## 规划纪律（InkOS）
        1. 3-6 个节拍；每节拍一句"人话"写清要发生的具体事件，不写字段名。
        2. 每节拍给功能定位（推进/爽点/埋伏笔/收钩子/情绪/过渡）与建议字数；场景要有"当下目标→阻力→有意义的转折"。
        3. **每个节拍都要填场景层**（这是连贯性审查的取证基础，缺了后面查不了）：
           - pov：这一拍贴着谁写（全章统一一个视角；要换视角就在 must_deliver 里写明切点）
           - location：具体地点（不要写"某处"）
           - time_label：时间标记（"当夜""三日后清晨"都行，但要能和相邻拍对上）
           - cast：在场人物（用台账里的本名，不要用别名混着写）
           - turn：这一拍的转折，从什么变成什么（没有转折的拍就是过场，不要全章都是过场）
        4. 万物皆饵：日常/过渡节拍的每一笔也要是未来剧情的伏笔或钩子。
        5. 揭1埋1：本章每回收一个伏笔，同时至少埋 1 个新钩子。clue_touches 里写清本章对每条活跃伏笔的动作（plant/develop/reveal）与硬要求；**到期未动的伏笔必须进合同**（推进它，或显式标 defer）。
        6. 章尾钩子：写清收在什么画面、指向哪里（用具体物件/事件，不用"他不知道的是"这类空泛预告），并在 hook_kind 里标明形态（悬念/危机/反转/信息差/承诺/情绪/登场）。
        7. 硬交付（must_deliver）：读者等了最久的那件事，本章必须兑现或明确推进。
        8. 禁止项（must_avoid）：至少写一条反 AI 指纹约束（"结尾不要决定+接纳+成长三连"或"章末不写主题总结"），再写本章题材禁区里最容易踩的那条。
        9. 本章要兑现的爽点类型填 payoff_type；本章挂上的新期待填 new_expectation（必须可验证——读者能核对它兑现了没有）；所属卷/阶段填 volume_label。
        10. 若上下文之间冲突，信"上一章摘要"（剧情已实际发生）。
        11. 本节拍表是写给作者看的写前契约：把最值得作者自由发挥的地方在节拍说明里点名"放开写"，把不能碰的写进 must_avoid。
        12. 叙事架构提示（挑着用别用满）：最大的揭露放本章后段；因果链允许断一节（某件事自有来历，不全由上一拍推出）；情绪表达行为优先、身体化只留给峰值。
        \(gateReport.isEmpty ? "" : "\n## 宿主闸门对上一版骨架的检查结果（这一版必须逐条修掉）\n\(gateReport)")}
        """
    }

    // MARK: - 卷骨架（批量：一次规划连续多章的弧光，再逐章细化）

    static func volumeSkeletonTask(fromChapter start: Int, toChapter end: Int, pack: ContextPack,
                                   authorDirective: String, craft: String = "",
                                   existingOutline: String = "") -> String {
        """
        请为第\(start)–\(end)章（共 \(end - start + 1) 章）规划**卷级弧光**。这一轮不逐章搭骨架——先把这一段当一个完整中篇来设计，作者认可后再逐章细化。

        ## 上下文（宿主已按预算组装，可信）
        \(pack.asText)

        ## 已有大纲与时间线（这一段原本计划发生什么）
        \(existingOutline.isEmpty ? "（空）" : existingOutline)

        ## 作者对这一段的要求（最高优先级）
        \(authorDirective.isEmpty ? "（无，按大纲推进）" : authorDirective)

        ## 创作法典
        \(craft.isEmpty ? "（未注入）" : craft)

        ## 要交付什么（用 propose_memo 提交一份卷级设计，作者看完才逐章搭骨架）
        按起承转合给这一段的弧光，逐条写清：
        1. **本卷核心冲突**：谁要什么、被谁挡住、代价是什么；比上一段重在哪里（赌注递增）。
        2. **四拍分布**：起（第几章，新处境）／承（第几章，受挫一次）／转（第几章，变量进场改变局面性质）／合（第几章，卷末大兑现 + 抛下一卷钩子）。
        3. **章级路标**：逐章一行——第N章要推进哪条剧情线、兑现或挂起哪个期待、钩子形态用哪一种（整卷钩子形态要轮换，不要连续三章同型）。
        4. **伏笔收支表**：这一段要回收哪些旧伏笔（写 F 编号）、要埋哪些新的、哪些到期了必须处理。
        5. **期待感账**：这一段结束时，读者手上还握着哪几个未兑现的期待（即时/近期/长期各至少一个）。
        6. **本卷禁区**：这段最容易踩的题材禁区与最可能崩的地方（战力/资源/信息通胀）。

        ## 纪律
        - 不要写正文，不要逐章写满节拍——这一轮只交弧光与路标。
        - 每章的路标必须具体到"能据此搭骨架"，不要写"推进剧情"这种废话。
        - 与已有大纲冲突时，明确指出冲突点并给两个选项（改大纲 / 改本段规划），让作者裁决。
        """
    }

    // MARK: - 全书连贯性审校（在确定性审查之上补 LLM 才能查的部分）

    static func continuityAuditTask(asOfChapter n: Int, deterministicFindings: String,
                                    digest: String, craft: String = "") -> String {
        """
        请对全书（截至第\(n)章）做连贯性审校，用 propose_continuity 提案。

        ## 宿主确定性扫描已发现（可信，不要重复报这些，直接在此基础上补）
        \(deterministicFindings.isEmpty ? "（暂无）" : deterministicFindings)

        ## 全书梗概（宿主组装：各章摘要 + 关键事件 + 台账 + 剧情线）
        \(digest)

        ## 题材禁区（违背这些也算连贯性问题）
        \(craft.isEmpty ? "（未注入）" : craft)

        ## 你的职责：只查确定性代码查不出来的那六类
        1. **动机断裂**：人物做了这件事，但此前建立的性格/处境/利益不支持他这么做。
        2. **能力与资源不一致**：某项能力/道具/人脉/金钱此前用过或明确没有，后文的用法与之矛盾（含战力与财富通胀失控）。
        3. **人物性格漂移**：同一个人前后像两个人，且文中没有给出变化的理由与过程。
        4. **称谓与身份混乱**：同一人物称呼前后不一致、身份/辈分/职位对不上。
        5. **因果链缺口**：结果出现了，但导致它的环节从未发生过（不是"留白"，是"漏写"）。
        6. **承诺失约**：文中明确许下的约定/期限/誓言到期未兑现，也没人提起。

        ## 纪律
        - 每条 issue 必须带 evidence（引用具体章号与原句）与 suggestion（怎么修）。引不出证据就不要报。
        - 不要报风格、节奏、文笔问题——那是作者主权，且不属于连贯性。
        - 不要重复宿主已经查出的机械性错误（死者复出、位置跳跃、时间线倒挂、伏笔台账烂账）。
        - 没有问题就返回空列表，不要为了凑数硬造。
        """
    }

    // MARK: - 大纲同步（把静态计划变成活文档）

    static func outlineSyncTask(asOfChapter n: Int, deterministicFindings: String,
                                craft: String = "") -> String {
        """
        请把大纲与真实剧情对账，并用 propose_outline_updates 提交更新建议。

        ## 宿主确定性对账结果（可信，这是你的取证基础）
        \(deterministicFindings.isEmpty ? "（暂无）" : deterministicFindings)

        ## 创作法典（判断偏差该改大纲还是该改后文时，按它的节奏参数与卷弧结构判）
        \(craft.isEmpty ? "（未注入）" : craft)

        ## 你的职责
        1. 对宿主标出的每个「计划 vs 实际」偏差，判断：这件事是**已经发生了只是大纲没更新**，还是**真的漏写了**，还是**该取消**。给出理由与证据。
        2. 对断线/停滞的剧情线，给出处置建议：本段内唤醒、显式转为蛰伏、还是收束。不要建议凭空加戏。
        3. 补出大纲里已经明显过时或缺失的关键事件（用 new_event），每个都要写 objective_fact（作者真相）与 reader_knowledge（读者已知）。
        4. 若某条线的 planned_payoff_chapter 已过而线还没收束，给出新的收束章建议。

        ## 纪律
        - 大纲是作者的正典。你只提建议，作者采纳才生效；不要声称已更新。
        - 每条建议必须写 reason（凭什么这么判）与 evidence（命中了哪一章的什么内容）。
        - 不要为了让大纲好看而把没发生的事标成已发生。
        - 建议数量控制在最必要的范围内，一次给 30 条更新等于没给。
        """
    }

    // MARK: - 记忆提取（InkOS 结算铁律）

    static func memoryExtractTask(chapter n: Int, prose: String, knownClues: String, knownFacts: String) -> String {
        """
        作者刚写完第\(n)章正文（人写，你是记录员）。请提取记忆包并用 propose_memory 提案。

        ## 正文
        \(String(prose.prefix(12000)))

        ## 已知伏笔台账（用于判重与识别新钩子）
        \(knownClues.isEmpty ? "（空）" : String(knownClues.prefix(1500)))

        ## 已有事实（用于归一判重，别重复登记）
        \(knownFacts.isEmpty ? "（空）" : String(knownFacts.prefix(1500)))

        ## 结算铁律
        1. 只提取正文中明确描写的事件和状态变化。不要推断、预测、脑补。正文只写到角色走到门口，就不能记"已进入房间"。
        2. summary 200-500 字；key_events 3-8 条；emotional_tone 一句话。
        3. facts 用三元组（主语/谓词/宾语），谓词从受控表里选；只登记会跨章影响写作的状态，鸡毛蒜皮不记。
        4. 作者账本性质的暗线事实（读者视角还不知道的底牌）public_to_reader=false。
        5. 顺手盘点：正文里新冒出的、值得追踪的钩子/物件/承诺 → new_clues（附种下原文片段）；已有伏笔被推进的，只登记新钩子，推进动作由作者在台账上手动记账。
        6. 不要把"再次提到"当成新事实。
        """
    }

    // MARK: - 验证（NarraCat 五类客观错误）

    static func validationTask(chapter n: Int, prose: String, skeleton: String, pack: ContextPack, draftMode: Bool = false) -> String {
        let header = draftMode ? "本章文本（流水线草稿，尚未入库）" : "本章正文（作者亲笔）"
        return """
        请对第\(n)章做一致性审校，用 propose_validation 提案。

        ## \(header)
        \(String(prose.prefix(12000)))

        ## 本章骨架
        \(skeleton.isEmpty ? "（无）" : skeleton)

        ## 台账与状态（取证依据，可用 get_chapter / get_clues / get_facts / get_canon 追查其他章）
        \(pack.asText)

        ## 审校纪律
        1. 只查五类客观错误——能指出证据、能被验证的错误：①连续性矛盾（与近章摘要/角色状态/事实冲突）②设定违背（与设定文档冲突）③骨架锚点不可识别（骨架要求的核心戏在正文里找不到，二元判定）④伏笔合同未兑现（clue_touches 要求的 plant/develop/reveal 在正文里没有可定位的兑现段）⑤物理不可能。
        2. 每条 issue 必须带 evidence（引用正文原句）与 suggestion（怎么修）。引不出证据就不要报。
        3. 风格、节奏、文笔好坏——一概不评、不提。那是作者的主权。
        4. 没有问题就返回空列表。审校是找问题，不是验证正确性，但也不能为了凑数硬造问题。
        """
    }

    // MARK: - 去AI味（三 pass：叙事架构 → 篇章推进 → 措辞；融合 Humanizer v4.1 / oh-story 7 Gate / sepia 三 pass）

    /// 模型叙事层指纹（sepia model-fingerprints，节选修正面；正文由人写时仅作为审校者自身倾向提示）
    static func narrativeFingerprint(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("claude") {
            return """
            Claude 家（实测最易识别）：事件升级最平缓、叙事声音全程均匀——重写建议要让赌注和强度"跳变"；偏好尾声与闪前式收尾、安静的结尾——默认禁尾声，在动作中收束；几乎不写梦；场景氛围易滑向诡异阴郁——换气质；句法层（厂商自述）：爱用"有格调的比喻"代替直白说法——有直白说法时建议直说。
            """
        }
        if m.contains("gpt") {
            return """
            GPT 家：八卦式闲笔多（人物登场即互嚼往事）、时间镜头拉得过长；爱加旁白解释自己刚说的话——重写建议砍闲笔、砍自我修正旁白；短句易缺失——补短句制造节奏。
            """
        }
        if m.contains("gemini") {
            return """
            Gemini 家：环境与感官描写浓密度偏高、场景易"明信片化"——建议把第三种感官删掉；排比与列表倾向重——拆三连。
            """
        }
        if m.contains("deepseek") {
            return """
            DeepSeek 家：前置交代重（信息在故事开动前全部发完）——建议砍简报，让信息在动作中段漏出；因果链过整——建议断一环。
            """
        }
        if m.contains("kimi") || m.contains("moonshot") {
            return """
            Kimi 家：情绪身体化密度高、复述式对白多——重写建议把情绪转成行为或直接命名，对白只留推进信息的部分。
            """
        }
        return "未知模型：不套指纹，只按通用三 pass 检查。"
    }

    static func deslopTask(chapter n: Int, prose: String, lintSummary: LintSummary, model: String) -> String {
        """
        作者写完了第\(n)章，请做去AI味诊断并给逐处修改建议，用 propose_deslop 提案。

        ## 正文
        \(String(prose.prefix(14000)))

        ## 本地扫描已发现（可信，优先处理）
        \(lintSummary.topIssues.map { "【\($0.kind)】\($0.detail)（\($0.count)处）" }.joined(separator: "\n"))
        粗判：\(lintSummary.grade)｜禁用词密度 \(String(format: "%.1f", lintSummary.bannedPerKilo))/千字\(lintSummary.sentenceLengthSD.map { "｜句长标准差 \(String(format: "%.1f", $0))" } ?? "")

        ## 执行模型指纹（给出重写建议时，别把你自家家族的默认倾向塞回去）
        \(narrativeFingerprint(for: model))

        ## 三 pass 流程（sepia：先架构，后篇章，最后措辞；从 deepest layer 开始修）

        **Pass 1 叙事架构（最高优先，逐项核对并给建议）：**
        1. 主题别解释：查最后三段与叙述者总结句（"这就是…""她终于明白""原来…""所谓…其实是"）——删掉或转成一个具体动作/画面；符号在文内被解释的，删解释留符号。
        2. 单线因果过整：把本章节拍列出来，若每一拍都被上一拍严丝合缝推着走，砍断一环——把某个原因挪到幕后，或插入一件自有来历的事。回声测试：这个转折若把题材重写二十次还会出现吗（好心的陌生人/矛盾顺利化解/按点和解）？会——就换成本故事独有的转折。
        3. 结局三脚架：主角"决定+接纳+成长"三连是数据里最强的结局指纹——至少砍掉一条腿；收尾比"感觉完整"早一拍停。
        4. 情绪模式单一：身体感受独大（81% vs 人类 38%）是重灾区——改为行为优先、直接命名其次（"她怕"是人写的话），身体化只留全章一两个高峰；嗅觉要配给（82% vs 57%）；连续多景"景随情迁"的要拆。
        5. 揭露后置：最大的信息留到最后；全线性叙事建议把一个场景后挪以 staging 信息。

        **Pass 2 篇章推进：**段落-问题序列模板（每段抛问下段作答）；中段松垮；场景开头方式连续雷同；节奏无长短变化——打乱位置与节奏。

        **Pass 3 措辞（Gate A-G + 中文校准）：**
        A 禁用词：仿佛/一丝/眼中闪过/心中一动… → 具体动作或白描
        B 句式：不是A而是B三毒（假靶子/同义替换/无关硬凑）、NNY、二元对比、公式化转折
        C 情绪落地与上面 Pass1.5 一致
        D 节奏：句长平坦处（本地扫描已标）拆一长句或并两短句，**挪词不删意思**
        E 对话：删机械标签；对白吵具体的事（房租、刀、账），不吵哲学
        F 结尾去升华：动作/场景收，不总结不感慨
        G 去解释腔：删"他不知道的是""之所以…是因为"
        中文校准专项：连接词堆叠（和/以及/同时/因此/然而 链式——删连接词让并置承接）；双音节垫话（进行讨论→讨论）；语气词（啊/吧/呢/嘛）可极少量回补（语域允许时）；三连排比留一。

        ## 校准纪律（最重要）
        - **以人类分布为基准，不要直接反转 AI 分布**：人类各项指标多在中段。每篇只挑 **3-5 种**最有力的手法动刀，其余留着——把每条规则用满会形成新的"人味指纹"。
        - 过度修正（通篇破碎短句、全程非线性）也是指纹失败模式，发现要单独提示。
        - 只改"怎么说"不改"说什么"；每条建议 original 必须是正文连续原文（可唯一命中），gate 标 P1架构/P2推进/P3措辞-A~G；拿不准就别报，宁可漏报。
        - 删改总量：轻度≤15%、中度≤25%、重度≤35%。
        """
    }

    // MARK: - 流水线：一键写作 / 按意见修复（NarraCat 任务书形态）

    static func draftTask(chapter n: Int, title: String, targetWords: Int, mainline: String,
                          skeletonText: String, pack: ContextPack, model: String) -> String {
        """
        请亲笔写第\(n)章整章正文，写完用 propose_draft 提交全文。

        ## 一、这次委托
        第\(n)章「\(title)」。目标字数 \(targetWords) 字左右（±20% 可接受）。
        作者主线要求（最高优先级）：\(mainline.isEmpty ? "（未填，按骨架与大纲推进）" : mainline)

        ## 二、这章的骨架（写前契约）
        \(skeletonText.isEmpty ? "（无骨架——按主线与上下文自拟 3-5 拍结构，先在心里列好再写）" : skeletonText)

        ## 三、前情与状态（宿主组装，可信）
        \(pack.asText)

        ## 四、怎么写（文风主权 + 叙事纪律）
        文风要求：\(pack.blocks.first { $0.title.contains("文风") }?.content ?? "（作者未填，用平实有力的叙事腔）")
        叙事纪律（写作时就做对，别留给修订）：
        1. 情绪行为优先、直接命名其次，身体化描写只留一两个峰值；嗅觉克制。
        2. 因果链允许断一节；至少留一个不解释的细节或松线头。
        3. 最大的信息揭露放在本章后段。
        4. 句长参差：长短句交错，别写等长句串；对白吵具体的事，不吵哲学。
        5. 章末用动作/画面收，禁止总结、感慨、"他终于明白"。
        6. 骨架里每个伏笔触点必须有可定位的兑现段（具体场景动作，不是内心提及）。

        ## 五、执行模型自查（别把这些默认带进正文）
        \(narrativeFingerprint(for: model))

        ## 六、输出
        propose_draft 一次提交全文；note 里一句话说明本稿要点。不要把正文拆进对话。
        """
    }

    /// 分段写作的一小段：只写这几拍，且必须接着上一段的结尾往下写。
    /// 长章一次性生成到后半段必然退化（复读、赶结尾、把后几拍压成一两句交代），
    /// 所以按节拍切块，每块带着"已经写出来的实际结尾"续写，最后由宿主拼成整章。
    static func sceneDraftTask(chapter n: Int, title: String, beatIndex: Int, beatCount: Int,
                               beats: [Beat], isLast: Bool, endHook: String, hookKind: String,
                               mustDeliver: [String], mustAvoid: [String], clueTouches: [ClueTouch],
                               mainline: String, targetWords: Int, pack: ContextPack,
                               previousText: String, model: String) -> String {
        let beatLines = beats.enumerated().map { i, b -> String in
            var line = "\(i + 1). \(b.summary)（\(b.purpose)\(b.suggestedWords > 0 ? "｜约\(b.suggestedWords)字" : "")）"
            var scene: [String] = []
            if !b.pov.isEmpty { scene.append("视角：\(b.pov)") }
            if !b.location.isEmpty { scene.append("地点：\(b.location)") }
            if !b.timeLabel.isEmpty { scene.append("时间：\(b.timeLabel)") }
            if !b.cast.isEmpty { scene.append("在场：\(b.cast.joined(separator: "、"))") }
            if !b.turn.isEmpty { scene.append("转折：\(b.turn)") }
            if !scene.isEmpty { line += "\n   " + scene.joined(separator: "｜") }
            return line
        }.joined(separator: "\n")
        let touchLines = clueTouches.map { "[\($0.clueID)] \($0.action.rawValue)——\($0.requirement)" }.joined(separator: "\n")
        return """
        这是第\(n)章「\(title)」的第 \(beatIndex)/\(beatCount) 段。只写这一段，写完直接停。

        ## 本段要写的节拍（写前契约，逐拍落实）
        \(beatLines)

        ## 本段字数
        约 \(targetWords) 字（±20%）。不要为了凑字数注水，也不要写成提纲。

        ## 作者主线要求（最高优先级）
        \(mainline.isEmpty ? "（未填，按骨架与上下文推进）" : mainline)

        ## 前情与状态（宿主组装，可信）
        \(pack.asText)

        ## 本章已经写出来的部分（你的开头必须无缝接住它的最后一句：情绪、时态、在场人物、镜头位置都要对得上）
        \(previousText.isEmpty ? "（这是本段开头，也是本章开头——直接进入场景，不要写章节标题、不要写任何开场白）" : String(previousText.suffix(1500)))

        ## 本章伏笔触点合同（落在本段的必须写出可定位的兑现段）
        \(touchLines.isEmpty ? "（无）" : touchLines)
        \(isLast ? """

        ## 这是本章最后一段
        章尾钩子必须落地：\(endHook)\(hookKind.isEmpty ? "" : "（\(hookKind)型）")
        钩子要挂在具体的物件、动作或人身上，用画面收，不要总结、不要感慨、不要写"他终于明白"。
        """ : """

        ## 这一段不是结尾
        不要收束本章、不要写章尾钩子、不要做任何总结——写到本段节拍完成就停，把势头留给下一段。
        """)
        \(mustDeliver.isEmpty ? "" : "\n## 本章硬交付（本段涉及的部分必须兑现）\n" + mustDeliver.joined(separator: "\n"))
        \(mustAvoid.isEmpty ? "" : "\n## 禁止\n" + mustAvoid.joined(separator: "\n"))

        ## 写作纪律（写的时候就做对，别留给修订）
        1. 情绪行为优先、直接命名其次，身体化描写只留一两个峰值；嗅觉克制。
        2. 因果链允许断一节；至少留一个不解释的细节或松线头。
        3. 句长参差：长短句交错，别写等长句串；对白吵具体的事，不吵哲学。
        4. 场景层已经给了视角/地点/时间/在场人物——严格按它写，不要漂移视角，不要让不在场的人说话。

        ## 执行模型自查（别把这些默认倾向带进正文）
        \(narrativeFingerprint(for: model))

        ## 输出
        只输出这一段的正文。**不要**输出章节标题、段号、"以下是…"之类的开场白、代码围栏或任何解释。
        """
    }

    static func revisionTask(chapter n: Int, draftText: String, feedback: String,
                             historyText: String, targetWords: Int, styleNotes: String) -> String {
        """
        请按作者修改意见修订第\(n)章草稿，用 propose_draft 提交修订后的完整全文。

        ## 草稿原文（v 当前）
        \(String(draftText.prefix(14000)))

        ## 历次意见（都已执行过，保持住）
        \(historyText.isEmpty ? "（无）" : historyText)

        ## 本次作者意见（最高优先级，逐条落实）
        \(feedback)

        ## 修订纪律
        1. 意见说的每一条都要落实；意见没碰的部分保持原样——不改不是你写的错，别顺手润色。
        2. 目标字数 \(targetWords) 字左右，±20%。
        3. 文风要求：\(styleNotes.isEmpty ? "（沿用原稿语感）" : String(styleNotes.prefix(600)))
        4. 仍然遵守：章末动作收、不总结；情绪行为优先；句长参差。
        5. note 一句话说明本稿改了什么。
        """
    }

    // MARK: - 召回复忘

    static func recallMemoTask(chapter n: Int, pack: ContextPack, authorDirective: String) -> String {
        """
        作者准备写第\(n)章。基于以下上下文包，给作者写一段 2-4 条的写作备忘（人话），用 propose_memo 提案。

        ## 上下文包
        \(pack.asText)

        ## 作者刚说
        \(authorDirective.isEmpty ? "（无）" : authorDirective)

        要求：
        1. 只说"不知道就会写错"的事：最容易踩的连续性雷、必须接住的前章情绪、本章最该兑现的伏笔账、时间线注意点。
        2. 每条一句话，具体可执行；不要空泛鼓励，不要复述全部上下文。
        """
    }
}
