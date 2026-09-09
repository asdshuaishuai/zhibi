# 执笔 (ZhiBi) — 人类主导的 AI 协同小说写作软件

> 一句话：**AI 负责搭骨架、记台账、查矛盾；人负责写正文。AI 永远不直接写一个字的正文。**

设计融合了三套成熟体系的精华，并以 Vercel fx (libfx) 的 agent 模型为基座：

| 来源 | 借鉴的核心机制 |
|------|----------------|
| **InkOS** | "模型提议，宿主裁决"；伏笔五档节奏 (payoffTiming) + open/advance/resolve 账本；hook debt 原文回灌；状态 delta 结算；去AI味三层防线；`author_intent` / `current_focus` 人类控制文档 |
| **NarraCat** | "账房归我们、花归用户、尺归读者"；双时态事实三元组记忆；WritingContextPack 确定性造包（热/温/贯穿线常驻层 + token 预算）；审校只查五类客观错误；编辑两档制、保存永远先落盘 |
| **oh-story** | 细纲=写前契约 + 三档新增物授权；"作者真相 vs 读者已知"双时间线；单一 JSON 权威 + 派生视图；强制停靠点；story-deslop 7 Gate |
| **SkillHub 去AI味技能** (Humanizer v4.1 / 去除AI味专家) | "不是A而是B"三毒判定；L1 硬规则→L4 活人感四层自检；五维诊断分级（轻/中/重）；禁用词表；"改最少、只改怎么说" |
| **fx.sh (libfx)** | Agent = 一段内存会话；`prompt() → Turn(事件流)`；Checkpoint 由宿主持久化；工具/凭据/指令全部由宿主提供 |

## 人机协同边界（产品铁律）

1. **没有"AI 写正文"这个功能。** `AICapability` 枚举里不存在 prose 生成；agent 工具面里没有能写正文的工具。
2. **AI 的一切产出都是"提案"（Proposal）。** 大纲事件、时间线、线索、章节骨架、记忆事实、验证报告、去AI味建议——全部进入提案收件箱，由作者 **接受 / 修改后接受 / 拒绝**。接受前不入库。
3. **确定性代码做账房，LLM 只做花。** 骨架覆盖核对、伏笔合同对账、字数统计、AI 味 L1 硬规则扫描、时间线冲突检出——全部零 LLM 成本；LLM 只用于理解与建议。
4. **审校只查客观错误**（连续性矛盾 / 设定违背 / 骨架锚点不可识别 / 伏笔合同未兑现 / 物理不可能），只报告不改正文；文风好坏不评。
5. **正文永远先落盘。** 人的每一次编辑直接保存；记忆同步、影响评估都是事后行为。
6. **强制停靠点。** AI 完成一次任务即停，产出提案等人裁决；没有"继续写下一章"的连跑。

## AI 能力清单（全部以提案形式交付）

| 能力 | 触发 | 产出 |
|------|------|------|
| 构建核心大纲 / 事件时间线 | 作者点击"AI 建时间线" | TimelineEvent 提案（作者真相 + 读者已知双栏）、Storyline 提案 |
| 线索 / 埋点登记 | 作者点击"AI 盘点伏笔" | Clue 提案（含五档节奏、种下原文） |
| 章节骨架 | 在章节页点击"AI 搭骨架" | Beat 骨架 + 章尾钩子 + 硬交付 + 伏笔触点（作者在骨架上改、填） |
| 记忆提取 / 旁路记录 | 写完点"让 AI 记一笔" | MemoryFact 三元组 + 章节摘要 + 新伏笔候选（草稿态） |
| 一键验证 | 点击"一键验证" | 确定性报告（骨架覆盖/伏笔合同/AI味 lint）+ LLM 五类客观错误报告 |
| 一键召回 | 点击"一键召回" | ContextPack（前章结尾逐字 / 近章摘要 / 活跃伏笔 / 角色状态 / 贯穿线），可再让 AI 出"写作备忘" |
| 去AI味 | 点击"去AI味" | 确定性 lint 分级 + LLM 逐处修改建议（原文片段→替换），逐条采纳 |

## Agent 基座（fx 模型同构）

libfx 没有 Swift SDK，因此按其文档模型在 Swift 内同构实现 `AgentCore`：

- `FxAgent`：一段内存会话。`prompt(_:tools:)` 返回 `FxTurn`（`AsyncThrowingStream<FxEvent>`，事件：`textDelta / toolCall / finished`）；`checkpoint()` 序列化会话状态，由宿主（项目目录）持久化；`close()`。
- **宿主三提供**：指令（系统 prompt = PromptLibrary）、工具（仅 `propose_*` 结构化提案工具 + 只读查询工具）、凭据（API Key 存 macOS 钥匙串）。
- `AgentTransport` 两个实现：
  - `OpenAICompatibleTransport`（默认）：SSE 流式 chat/completions + tool-calling 循环，兼容 DeepSeek / GLM / Moonshot / OpenAI / Ollama 等。
  - `ACPTransport`（实验）：以 ACP 客户端身份 spawn `fx acp` 子进程（newline JSON-RPC 2.0 over stdio，先 `initialize` 再 `session/new`/`session/prompt`）。
- **裁决机制**：模型调用 `propose_*` 工具 → 宿主把 payload 建成提案并回复"已登记为提案，等待作者确认"。不存在任何把内容写入正文的工具，模型口头声明不算数，一切以落盘提案 + 人的点击为准。

## 数据与磁盘布局（人随时可以拿走自己的稿子）

```
<项目>.zhibi/
├── project.json          # 书名/题材/目标/作者意图/当前焦点/文风主权
├── canon/                # 设定（人可手改 markdown；frontmatter 带确定度 canon/tentative/open）
├── outline.json          # 故事线 L 编号 + 时间线事件 E 编号（作者真相|读者已知）+ 阶段
├── clues.json            # 伏笔台账（F 编号、五档节奏、种下原文、行动日志）
├── memory.json           # 双时态事实三元组 + 角色别名
├── proposals/inbox.json  # AI 提案收件箱（pending/accepted/rejected）
├── chapters/ch-NNN/
│   ├── meta.json         # 标题/状态/字数
│   ├── prose.md          # 人的正文（权威，纯 markdown）
│   ├── skeleton.json     # 章节骨架（AI 提案 → 人修改批准）
│   └── summary.json      # 人确认后的章节摘要
└── checkpoints/          # FxAgent checkpoint 状态
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
    ├── Models/               # Novel / Chapter / Clue / Memory / Proposal / Review
    ├── Persistence/          # ProjectStore（JSON+md 原子落盘）、ProjectLayout、KeychainStore
    ├── AgentCore/            # FxAgent / AgentTransport / OpenAICompatibleTransport / ACPTransport / NovelTools / AgentConfig
    ├── Services/             # AIService / ContextPackBuilder / Validator / AILint / DeslopService / ImportService / WordStats
    ├── Prompts/PromptLibrary.swift
    ├── ViewModels/AppViewModel.swift
    └── Views/                # Root / Sidebar / Welcome / Outline / ChapterEditor / ClueBoard / Memory / ProposalInbox / Review / Canon / Settings
```
