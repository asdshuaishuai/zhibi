# 执笔 (ZhiBi) — 人类主导的 AI 协同小说写作软件

> 一句话：**AI 可以搭骨架、写整章草稿、记台账、查矛盾；所有 AI 正文以提案存在，人审查、修改、采纳后才进入正文。**

设计融合了三套成熟体系的精华，并以 Vercel fx (libfx) 的 agent 模型为基座：

| 来源 | 借鉴的核心机制 |
|------|----------------|
| **InkOS** | "模型提议，宿主裁决"；伏笔五档节奏 (payoffTiming) + open/advance/resolve 账本；hook debt 原文回灌；状态 delta 结算；去AI味三层防线；`author_intent` / `current_focus` 人类控制文档 |
| **NarraCat** | "账房归我们、花归用户、尺归读者"；双时态事实三元组记忆；WritingContextPack 确定性造包（热/温/贯穿线常驻层 + token 预算）；审校只查五类客观错误；编辑两档制、保存永远先落盘 |
| **oh-story** | 细纲=写前契约 + 三档新增物授权；"作者真相 vs 读者已知"双时间线；单一 JSON 权威 + 派生视图；强制停靠点；story-deslop 7 Gate |
| **SkillHub 去AI味技能** (Humanizer v4.1 / 去除AI味专家) | "不是A而是B"三毒判定；L1 硬规则→L4 活人感四层自检；五维诊断分级（轻/中/重）；禁用词表；"改最少、只改怎么说" |
| **fx.sh (libfx)** | Agent = 一段内存会话；`prompt() → Turn(事件流)`；Checkpoint 由宿主持久化；工具/凭据/指令全部由宿主提供 |

## 人机协同边界（产品铁律）

1. **AI 可以写整章草稿，但不能直接改正文。** 现在有 `propose_draft`：草稿只能以提案形态存在，作者采纳前不进 `prose.md`，采纳时自动快照可回滚。工具面里**不存在任何直接写正文的工具**。
2. **会改书的 AI 产出一律是"提案"（Proposal）。** 整章草稿、大纲事件、时间线、线索、章节骨架、卷级弧光、记忆事实、验证报告、连贯性审查、埋点修复方案、大纲同步建议、去AI味建议——全部进入提案收件箱，由作者 **接受 / 拒绝 / 修改**；骨架、伏笔、设定等采纳后仍可在对应台账继续修改。接受前不入库。
3. **确定性代码做账房，LLM 只做花。** 骨架覆盖核对、骨架闸门打分、伏笔合同对账、全书连贯性扫描、大纲计划 vs 实际对账、字数统计、AI 味 25 项扫描、时间线冲突检出——全部零 LLM 成本；LLM 只用于理解与建议。
4. **审校只查客观错误**（连续性矛盾 / 设定违背 / 骨架锚点不可识别 / 伏笔合同未兑现 / 物理不可能 / 动机断裂 / 能力资源不一致 / 性格漂移 / 称谓身份混乱 / 因果缺口 / 承诺失约），只报告不改正文；文风好坏不评。
5. **正文以人定稿为准。** 人的每一次编辑直接保存；AI 草稿只有作者采纳时才写入 `prose.md`，采纳前自动快照。
6. **强制停靠点。** AI 完成一次任务即停，产出提案等人裁决；没有"继续写下一章"的连跑。两个经过论证的例外：
   - 骨架闸门的自我修正回路：闸门查出阻塞项时把问题清单回给模型，让它在同一轮里重交一版——产出仍然是提案，作者取用哪版由他决定。
   - 一键成章（`AIService.runAutoPipeline`）：草稿 → 一致性审查 → 去AI味 自动串起来。判据是「需要人裁决的是**什么进正文**，不是**要不要点四下鼠标**」——这三步的产出全是提案，串起来不损害裁决权，最后仍然停在采纳之前。**骨架不代批**：骨架是写前契约、属于正典决定，没有已批准的骨架时这一步只出骨架提案并停下。

## AI 能力清单（会改书的产出以提案交付）

| 能力 | 触发 | 产出 |
|------|------|------|
| 构建核心大纲 / 事件时间线 | 作者点击"AI 建时间线" | TimelineEvent 提案（作者真相 + 读者已知双栏）、Storyline 提案 |
| 大纲实时同步 | 大纲页"同步大纲" | 宿主确定性对账（计划 vs 实际 / 剧情线健康度 / 阶段完成度）+ LLM 判断该改大纲还是改后文 → OutlineUpdate 提案 |
| 线索 / 埋点登记 | 作者点击"AI 盘点伏笔" | Clue 提案（含五档节奏、种下原文） |
| 章节骨架 | 章节页/流水线"生成骨架提案" | 场景层 Beat 骨架（pov/location/time_label/cast/turn）+ 章尾钩子与钩子形态 + 硬交付 + 伏笔触点合同 + 爽点类型 + 新期待 + 所属卷；**宿主闸门当场打分，阻塞项退回重修** |
| 卷级弧光 | 流水线"规划整卷弧光" | 20-40 章的起承转合分布、章级路标、伏笔收支表、期待感账、本卷禁区（memo 提案） |
| 分段写作 | 流水线"分段写" | 按骨架节拍切块、逐块带上一块的实际结尾续写，拼装成**一份**草稿提案（每块都剥掉围栏与开场白） |
| 一键成章 | 流水线"一键跑到底" | 自动串起草稿 → 一致性审查 → 去AI味三份提案，停在采纳前；骨架不代批 |
| 一键写作 / 按意见修订 | 流水线"写草稿"/"按意见修复"；右侧对话也可发起草稿提案 | 整章草稿提案（版本化，采纳才进正文，采纳前自动快照） |
| 编辑对话 | 右侧"对话"窗 | 检索资料库后回答并标来源；可提交整章草稿、骨架、一致性验证、档案卡与大纲更新等提案，回答本身不直接改书 |
| 记忆提取 / 旁路记录 | 写完点"让 AI 记一笔" | MemoryFact 三元组 + 章节摘要 + 新伏笔候选（草稿态） |
| 一键验证 | 点击"一键验证" | 确定性报告（骨架覆盖/伏笔合同/AI味 lint）+ LLM 五类客观错误报告 |
| 全书连贯性审查 | 大纲页"全书连贯性审查" | 确定性 20 类扫描（死者复出/位置跳跃/人称漂移/时间线倒挂/伏笔台账烂账/骨架触点矛盾/结构完整性）+ LLM 六类需要理解的错误 + **埋点修复方案（可逐条一键采纳，只改台账不动正文）** |
| 一键召回 | 点击"一键召回" | ContextPack（前章结尾逐字 / 近章摘要 / 活跃伏笔 / 角色状态 / 贯穿线），可再让 AI 出"写作备忘" |
| 去AI味 | 点击"去AI味" | 确定性 25 项 lint 分级 + LLM 逐处修改建议（原文片段→替换），逐条采纳 |

## 创作法典（CraftCodex）

`Services/Craft/CraftCodex.swift` 把两套创作法沉淀成**代码可消费**的知识，而不是 prompt 里的鸡汤：

- **13 个流派档案**（GenreProfile）：读者预期 / 题材禁区 / 可用爽点形态 / 开篇律 / 节奏参数 / 体系通胀控制。自由文本题材模糊匹配，长别名优先。
- **网文创作法**（WebNovelCraft）：黄金三章、期待感管理、爽点类型学、打脸循环、金手指代价律、卷弧结构、主角能动性。
- **传统文学创作法**（LiteraryCraft）：草蛇灰线、白描、意象、留白、视角与叙述距离、典型环境中的典型人物、春秋笔法、起承转合、文气、复调。
- **断章钩子类型学**（HookKind）：悬念/危机/反转/信息差/承诺/情绪/登场，每种带"最容易写砸的方式"。
- 两条消费路径：① `codex(for:genreText:progress:)` 按能力裁剪后由 `AIService.run` 集中注入每次调用；② `hookConcreteness` / `classifyHook` / `tensionDensity` 作为确定性度量被 AILint 与 SkeletonGate 直接调用。

## 确定性引擎（账房）

| 引擎 | 职责 | 产出 |
|------|------|------|
| `Validator` | 单章：骨架覆盖、伏笔合同、过期伏笔、AI味、字数、跨章重复 | ValidationIssue |
| `ContinuityAuditor` | 全书：20 类连贯性检查 + 伏笔台账烂账 | ValidationIssue + **ClueFix（7 种修复动作）** |
| `OutlineSync` | 计划 vs 实际对账：事件四态判定、剧情线健康度、阶段完成度 | EventSync / LineHealth / StageProgress + **OutlineUpdate** |
| `SkeletonGate` | 骨架作为"写前契约"的可执行度打分（11 组检查） | GateIssue + 0-100 分 |
| `AILint` | 25 项 AI 味与网文结构信号扫描 + 过度修正反检 | LintSummary |
| `MemoryHub` | 事实去重、别名归一、矛盾体检 | ConsolidationReport |

修复类产出（ClueFix / OutlineUpdate）都必须经提案通道：`ProjectStore.applyClueFix` / `applyOutlineUpdate` 只在作者采纳时被调用，且**只改账本与大纲，永不改正文**。

### 对账打分：为什么不是纯 Jaccard

计划事件是「一句话梗概」，正文是「展开的句子」，两者体量天然不对等。纯双字组 Jaccard 会被长度差惩罚——实测「少年捡到断刀」对「少年在废窑里捡到一把断刀」只有 **0.23**，够不着 0.25 的门槛，于是明明写了的事件被判成「未发生」，大纲对账整块失灵。

`OutlineSync.matchScore(fact:unit:intersection:)` 因此在短边 ≥ 4 个双字组时，取 Jaccard 与**包含度**（交集 / 短边）× 0.85 的较大值：包含度回答的才是对账真正要问的问题——「计划里说的这几件事，正文是不是都写了」。打折是为了让「短边被完全覆盖」不至于和「两边几乎一模一样」同分；短边 < 4 个双字组时不启用，否则两三个字的碎片到处都能"被完全覆盖"。`bestMatch` 的剪枝上界同步放宽到覆盖两条路，否则体量悬殊但确实命中的单元会被提前剪掉。

### 性能纪律：view body 里不做重算

`OutlineSync.sync` 要读各章正文做双字组匹配，300 章量级是秒级的主线程开销。所以大纲页的对账结果放在 `@State` 里，用 `.task(id: 粗签名)` 触发重算，**粗签名只含结构（章数/事件/故事线/阶段/台账），故意不含字数**——含字数的话作者每敲一个字都会全量对账一遍，那比"稍微陈旧"糟得多。正文改动后由「重新对账」按钮显式刷新。同理，`MemoryGraphView` 用 `GraphCache.stamp` 只在账本规模变化时重建图。

### 视图纪律：卡片不要在横向 ScrollView 里变高

骨架的拍卡片排在 `ScrollView(.horizontal)` 里，而外层是 `NavigationSplitView` 的分栏。这类结构下**任何"点一下让卡片变高"的控件都会崩**：横向 ScrollView 的高度取最高卡片，卡片一变高就反推分栏宿主的尺寸约束，而这一步发生在 AppKit 正在跑约束更新的过程中——`NSHostingView.SizeConstraints.update` → `SplitViewChildController` → 再进 `setNeedsUpdateConstraints`，重入直接 abort（实测，不是理论）。

所以「场景层」用 **popover** 打开而不是在卡片里 `DisclosureGroup` 展开：popover 是独立窗口，不参与父视图布局，卡片高度恒定。写新面板时同理——要么高度恒定，要么把可变高度的部分放进 popover / sheet / 独立 inspector。

### 工具面契约：schema 不能静默降级

`ProposalToolBridge` 在 `parametersJSON` 解析失败时会降级成空 schema，模型于是拿不到字段定义、产出必然不合格，而宿主一声不响。因此自检里有一节专门校验：每个工具的 schema 都是合法 JSON object、`propose_*` 都有字段定义、`required` 里的字段都在 `properties` 中声明、骨架工具确实暴露了场景层与钩子形态枚举（且枚举与 `HookKind` 一致）、**每个 `AICapability` 都至少有一个 `propose_*` 工具**（没有生产者的能力就是个按了没反应的按钮）。

工具名到能力的映射抽成 `AIService.toolNames(for:)` 静态单一真相源，生产路径与自检共用同一份——自检自己抄一份等于没测。

### 分段写作：为什么长章不能一次性生成

3000 字以上一次性生成，后半段必然退化：句子开始复读、结尾被草草收掉、骨架后几拍被压缩成一两句交代。`runDraftByScenes` 按节拍的 `suggestedWords` 把骨架切成若干块（单拍不被切开），逐块生成，**每块的 prompt 里带着已经写出来的实际结尾**（尾部 1500 字），要求无缝接住情绪、时态、在场人物与镜头位置；非末块被明确告知"不要收束本章、不要写章尾钩子"，末块才落地钩子。各块文本经 `stripProsePreamble` 剥掉围栏与开场白后拼装，最终只登记**一份**草稿提案——逐块都走 `propose_draft` 的话作者会在收件箱里看到七八个半截草稿。

这里踩过一个坑并已用断言守住：`runDraftByScenes` 走的是 `streamTextOnly`（不带工具、只要正文），**不经过 `run()`**，所以 `run()` 里的创作法典集中注入对它无效——分段写作一度整个丢掉了流派档案与创作法，而它恰恰是最需要"怎么写"指导的路径。凡新增旁路通道，注入必须跟着走。

另一个坑：`runDraftByScenes` 外层已经持有 `running` 运行态，内层若再调用带互斥守卫的 `runTextOnly` 就会必然自锁（"已有 AI 任务在运行"）。因此文本流本体拆成 `streamTextOnly`（不碰 running），由 `runTextOnly` 或分段写作各自接管运行态。

## Agent 基座（fx 模型设计 + OpenAgentSDK 实现）

按 fx 的「模型提议、宿主裁决」模型设计，Swift 侧用 OpenAgentSDK 承载会话：

- **宿主三提供**：指令（系统 prompt = PromptLibrary）、工具（`propose_*` 结构化提案工具 + `search_knowledge` 等只读查询工具）、凭据（API Key 存 macOS 钥匙串）。
- **传输**：OpenAI 兼容 SSE chat/completions + tool-calling 循环，兼容 DeepSeek / GLM / Moonshot / OpenAI / Ollama 与本地端点。没有单独的 ACP 子进程通道；模型不调用工具时，宿主解析围栏 JSON 兜底登记提案（工具名仍受当前能力白名单约束）。
- **对话**：`AIService.sendChat` 走同一套 agent 循环（maxTurns 10），先 `KnowledgeEngine.search` 预取资料，再把选中章骨架/上一章结尾、历史与资料一起交给模型；流式片段进右侧聊天窗，工具调用同步进轨迹窗。作者可在对话底部切换目标章，`propose_draft` / `propose_skeleton` / `propose_validation` / `propose_dossier` / `get_latest_draft` / `get_chapter_skeleton` 都跟随目标章，不再误落到全局下一章。回答里的【第12章】会被对齐到资料库的完整出处（第12章《雾隐》），工具结果里的来源也会并入引用池；来源芯片可点击跳到对应章节/台账。失败可重试，已答可重新生成——两者都会撤掉旧回复、保留原问题，不把同一句提问堆两层。对话历史存 `chat.json`，不是 SDK checkpoint；作者可导出 Markdown，或归档到作品目录（`chat-archive-<时间>.md`）后清空。归档可在应用内列出/预览/在访达中定位/安全删除，并可从同名 JSON 快照恢复到当前对话（只追加消息，不重新登记提案）；每条 AI 回复记录 `proposalIDs`，导出与归档会附带对应提案的状态与说明快照。旧 `chat.json` 缺该字段按空数组解码。
- **会话状态**：每次任务独立，不持久化会话 checkpoint；`checkpoints/` 目录为预留。
- **裁决机制**：模型调用 `propose_*` 工具 → 宿主把 payload 建成提案并回复"已登记为提案，等待作者确认"。整章草稿也走 `propose_draft`；不存在任何绕过提案直接写 `prose.md` 的工具，模型口头声明不算数，一切以落盘提案 + 人的点击为准。

## 资料库与记忆引擎

`Services/Knowledge/KnowledgeIndex.swift` 把全书资料统一成可检索片段，解决「写到 100 章时 AI 找不到第 3 章那个物件」的问题：

- **来源**：章节正文、章摘要、章节骨架（场景层/钩子/硬交付/伏笔触点）、`canon/*` 设定、`dossiers.json` 章档案卡、伏笔、事实三元组、时间线事件、故事线、阶段；正文/设定按段落到约 600 字切片。
- **关键词**：中文双字/三字滑窗 + 英文数字整词 → 倒排索引 → BM25（含标题加权）；无网络依赖。
- **向量**：每片生成本地 256 维哈希向量（token 哈希 + 符号 + L2 归一化），无网络也能做余弦召回/重排；配置 `embeddingModel` 后调用 OpenAI 兼容 `/embeddings` 对候选片段远程重排，按 16 条分批，失败自动回退并在资料库页标出「远程失败 / 已回退」。
- **缓存**：`KnowledgeIndexCache` 按正文/账本的真实内容签名失效（同长度改字也会重建），索引是派生数据、不落盘。主线程只把 store 读成纯值 `KnowledgeSource` 快照，切片/分词/向量化在 `Task.detached` 后台完成，`KnowledgeIndexProgress` 把确定进度推给资料库页；构建期间内容再变则丢弃旧结果，不让过期索引覆盖新稿。远程嵌入另按「端点 + 模型 + 原文」缓存，避免每次检索重复上传整批正文。
- **消费**：`search_knowledge` 工具（对话/骨架/草稿/修订/审校/连贯性/大纲同步/卷级设计可用）；对话预取 6 条资料，搭骨架按本章指令/上一章摘要/近章钩子召回 4 条，一键写作按主线/骨架/伏笔触点召回 5 条，分段写作每段 4 条，回答携带来源标注。
- **UI**：侧栏「资料库」页可搜索、看来源/相关度/命中词；命中「前往」到章节时，`RichProseEditor` 用命中针滚动并持续高亮原文，作者移动光标或开始打字后撤掉；右侧「对话 / 轨迹」双窗承担日常人机协作。

## 数据与磁盘布局（人随时可以拿走自己的稿子）

```
<项目>.zhibi/
├── project.json          # 书名/题材/目标/作者意图/当前焦点/文风主权
├── canon/                # 设定（人可手改 markdown；frontmatter 带确定度 canon/tentative/open）
├── outline.json          # 故事线 L 编号 + 时间线事件 E 编号（作者真相|读者已知）+ 阶段
├── clues.json            # 伏笔台账（F 编号、五档节奏、种下原文、行动日志）
├── memory.json           # 双时态事实三元组 + 角色别名
├── dossiers.json         # 长程记忆：每章档案卡（场景/人物/推进/拐点/钩子/物件）
├── chat.json             # 作者与 AI 的对话记录（最近 200 条）
├── chat-archive-*.md     # 归档的对话记录（作者主动归档时写入，可读可带走）
├── chat-archive-*.json   # 同次归档的可恢复快照（消息 + 提案；删除归档时一起删）
├── cover.svg             # AI 封面（作者采用后落盘）
├── proposals/inbox.json  # AI 提案收件箱（pending/accepted/rejected）
├── proposals/archive.json # 已裁决提案归档（清空后不复活）
├── chapters/ch-NNN/
│   ├── meta.json         # 标题/状态/字数 + 骨架 + 摘要（瘦身结构：正文不在这里，另有 prose.md）
│   ├── prose.md          # 正文（权威，纯 markdown；手写或采纳 AI 草稿后人工定稿）
│   └── snapshots/        # 覆盖/去AI味前的版本快照（可回滚）
└── checkpoints/          # 预留（当前任务不持久化会话状态）
```

纪律：**正文是 markdown（人读人写人可带走），结构是 JSON（机器权威，程序可校验），UI 里的派生视图一律由代码渲染、不反解析。**

## 章节生命周期（人主导）

```
未规划 → [AI 搭骨架·提案] → 骨架已定(人批准/修改) → 写作中(人写，可按 Beat 填草稿再合入)
      → 初稿(人认可) → [一键验证·报告] → 已验证 → [去AI味·逐条采纳] → 已润色 → 定稿
                                    ↘ [让 AI 记一笔] → 记忆/伏笔提案 → 人确认入库
```

## 目录结构

```
zhibi/
├── project.yml               # xcodegen 规格
├── ARCHITECTURE.md
└── ZhiBi/Sources/
    ├── ZhiBiApp.swift
    ├── Models/               # Novel / Chapter（含场景层 Beat）/ Clue / Memory / Proposal / Review
    ├── Persistence/          # ProjectStore（JSON+md 原子落盘 + applyClueFix/applyOutlineUpdate）、ProjectLayout、KeychainStore
    ├── AgentCore/            # AgentKernel / NovelTools（propose_* + 只读查询，含 propose_continuity / propose_outline_updates）
    ├── Services/
    │   ├── Craft/CraftCodex.swift   # 创作法典：流派档案 + 网文创作法 + 传统文学创作法 + 钩子类型学
    │   ├── Knowledge/               # KnowledgeIndex（十类来源切片 + BM25）/ EmbeddingService（/embeddings + 本地哈希回退）
    │   ├── ContinuityAuditor.swift  # 全书连贯性 20 类扫描 + ClueFix 埋点修复方案
    │   ├── OutlineSync.swift        # 大纲计划 vs 实际对账 + 剧情线健康度 + OutlineUpdate
    │   ├── SkeletonGate.swift       # 骨架作为写前契约的可执行度闸门（11 组检查 + 0-100 分）
    │   ├── AIService / ContextPackBuilder / Validator / AILint / DeslopService
    │   ├── ImportService / ExportService / MarkdownLite / WordStats
    │   ├── MemoryHub / MemoryGraph / ModelHub
    ├── Prompts/PromptLibrary.swift  # 任务书；craft(for:genre:) 把法典按能力裁剪后注入
    ├── ViewModels/AppViewModel.swift
    └── Views/                # Root / Sidebar / Welcome / Outline（大纲对账条 + 创作法典）/ ChapterEditor
                              # / AgentRightPanel（对话 + 轨迹）/ KnowledgeBase / PipelineSheet（骨架闸门 + 卷骨架）
                              # / ClueBoard / Memory / ProposalInbox（埋点修复与大纲更新的逐条采纳）/ Review / Canon / Settings
```

## 向后兼容纪律

`Beat` / `ChapterSkeleton` / `TimelineEvent` 都实现了**显式 `init(from:)`**，逐字段 `decodeIfPresent` 兜底。

原因：Swift 合成的 `Decodable` 对「带默认值的非可选字段」缺键会直接抛 `keyNotFound`（已实测），
所以任何新增字段如果不写显式解码器，用户磁盘上既有的骨架 / 大纲 JSON 会整份解不出来、
静默丢骨架丢大纲。这条对 `LintSummary` 等一切会落盘的模型同样适用——新增字段要么可选，要么配显式解码器。
自检第 21 节里有专门的「老 JSON 向后兼容」断言守着这条。

**反过来更要命：读 meta.json 必须用 `ChapterMeta`，不能用 `Chapter`。** meta.json 是瘦身结构、
没有 `prose` 键，而 `Chapter.prose` 是非可选字段——用 `Chapter` 去解必然抛 `keyNotFound`，
一旦被 `?? Chapter(number:)` 吞掉，每章就退化成空章：表现是「打开工程骨架全没了」，
随后自动保存把骨架从盘上永久抹掉。书架统计那侧早就改成了 `ChapterMeta`，读盘这侧漏了，于是
"数字对得上、编辑器里全丢"（自检 5.1b 现在用「存盘 → 新 store 读回」把这条钉死，只断言内存态是测不出来的）。
