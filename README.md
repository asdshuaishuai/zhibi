# 执笔 (ZhiBi)

**人写正文，AI 理账** —— macOS 原生（SwiftUI）小说写作软件。核心是人机协同：AI 搭骨架、记台账、查矛盾、给建议；正文永远由作者亲笔完成——**结构上就不存在"AI 写正文"这个功能**。

完整设计文档见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

## 亮点功能速览

- **专注模式**（⌘⇧F）：全窗只剩稿纸，侧栏/骨架/速记全部退场；
- **每日目标**：按净增字数记账（删字扣回、导入不计入），头部进度环 + 写作统计页（14 天柱状图 / 连续天数）；
- **一键成章流水线**（⌘⇧W）：主线 → 骨架 → AI 草稿 → 意见修复 → 记忆审查 → 文风审查 → 采纳入库（采纳前自动快照）；
- **全书搜索**（⌘⇧G）：跨章节正文 / 伏笔 / 设定 / 时间线 / 记忆，点击直达；
- **去AI味三 pass**：叙事架构 → 篇章 → 措辞，配模型指纹与本地确定性扫描；
- **导出**：合并稿 / oh-story 目录回写 / 分卷 TXT（每 20 章一卷）；
- **删除即废纸篓**：章节与整本书都可从废纸篓找回。

## 人机协同边界（产品铁律）

| AI 可以（全部以**提案**交付） | AI 永远不可以 |
|---|---|
| 构建核心大纲 / 事件时间线（作者真相 \| 读者已知双栏） | ❌ 直接写正文（无此工具、无此代码路径） |
| 盘点伏笔 / 埋点登记（F 编号、五档节奏、种下原文） | ❌ 未经作者确认改任何台账 |
| 搭章节骨架（节拍 + 章尾钩子 + 硬交付 + 伏笔触点合同） | ❌ 替作者做正典决定 |
| 提取记忆 / 旁路记录（写完点"让 AI 记一笔"） | ❌ 在作者拒绝后保留数据 |
| 一键验证（只查客观错误，只报告不代改） | |
| 去AI味（逐处建议，逐条采纳，采纳前自动快照） | |
| 一键召回（上下文包 + 写作备忘） | |

一切 AI 产出进入 **提案收件箱**，由作者接受 / 修改后接受 / 拒绝。完成与否以落盘为准，不信模型口头声明（InkOS 纪律）。

## Agent 基座

按 [fx (libfx)](https://fx.sh/docs/lib) 的模型在 Swift 内同构实现（libfx 无 Swift SDK）：

- `FxAgent`：一段内存会话；`prompt(_:tools:) → AsyncThrowingStream<FxEvent>`；`checkpoint()` 由宿主持久化到项目目录；`close()`。
- 宿主三提供：**指令**（PromptLibrary）、**工具**（仅 `propose_*` + 只读查询，见 NovelTools）、**凭据**（macOS 钥匙串）。
- 传输：`OpenAICompatibleTransport`（SSE 流式 + tool-calling，默认，兼容 DeepSeek/GLM/Kimi/OpenAI/Ollama）；`ACPTransport`（spawn `fx acp` 子进程走 newline JSON-RPC，实验性，产出以围栏 JSON 回退解析）。

## 构建

```bash
cd zhibi
xcodegen generate
xcodebuild -scheme ZhiBi -configuration Debug build      # App（执笔.app）
xcodebuild -scheme ZhiBiCli -configuration Debug build   # 无头自检 CLI
```

运行 App：从 Xcode 打开运行，或 `open` 构建产物 `执笔.app`。

## App Icon

Icon 由 CoreGraphics 程序化生成（[Scripts/make_icon.swift](Scripts/make_icon.swift)），设计即产品隐喻：宣纸底 · 圆点骨架导轨与关键节点（AI 搭骨架）· 实心墨迹笔画（人写正文）· 朱砂「执」印。

```bash
swift Scripts/make_icon.swift ZhiBi/Sources/Assets.xcassets/AppIcon.appiconset   # 重新生成 1024 母版
# 再用 sips 派生 16~1024 各尺寸（见 appiconset 内现有文件），xcodebuild 重编译即可
```

母版预览：[icon_preview.png](icon_preview.png)。

## 无头自检（不打开 GUI、不碰真实数据）

```bash
ZhiBiCli --real-workspace <你的小说目录>   # 只读扫描真实工作区验证导入
```

29 项自检覆盖：字数统计、AI味 lint 分级、章节名解析、容错 JSON（修复未闭合字符串的追踪文件）、项目存取回环、快照回滚、伏笔合同验证、跨章重复检测、上下文造包、提案接受入库、合并稿导出、oh-story 导出、checkpoint 存取、回退解析器、真实工作区识别。

## 数据与磁盘

```
<书名>.zhibi/
├── project.json          # 书名/题材/作者意图/当前焦点/文风主权
├── canon/                # 设定（三态确定度：已定/暂定/有意留白）
├── outline.json          # 故事线 L 编号 + 事件 E 编号（作者真相|读者已知）+ 阶段
├── clues.json            # 伏笔台账
├── memory.json           # 双时态事实三元组 + 人物别名
├── proposals/inbox.json  # AI 提案收件箱
└── chapters/ch-NNN/
    ├── meta.json         # 状态/骨架/摘要/随手记
    ├── prose.md          # 正文（权威，纯 markdown，随时可带走）
    └── snapshots/        # 版本快照（去AI味采纳前自动创建，可回滚）
```

**导入**：一等支持 oh-story 目录规范（`大纲/ 设定/ 正文/ 追踪/_tracking-state.json`），含容错解析（字符串内裸换行、未闭合引号可自动修复）；通用 markdown/txt 按 `第N章` 启发式分类，逐项确认后入库。

**导出**：① 合并稿单文件；② oh-story 目录回写（大纲/设定/正文/追踪 JSON + 伏笔.md + 上下文.md），与社区工作流互通。

## 去AI味

三层（综合 SkillHub Humanizer v4.1 / oh-story 7 Gate / InkOS ai-tells）：

1. **确定性扫描**（零 LLM 成本，随打字更新）：一级禁用词、"不是A而是B"三毒、NNY 变体、堆叠副词、三字鉴定词、套话填充、公式化转折密度、心理告知占比、章末空泛预告、段落等长（变异系数）、对话标签密度。
2. **五维分级**：轻/中/重度（取最高档）。
3. **AI 逐处建议**：original/replacement/gate/reason，只改"怎么说"不改"说什么"，逐条采纳，首次采纳前自动快照。

## 章节生命周期

```
未规划 → [AI 搭骨架·提案] → 骨架已定(人批准) → 写作中(人写，可按拍填草稿再合入)
      → 初稿 → [一键验证] → 已验证 → [去AI味·逐条采纳] → 已润色 → 定稿
                              ↘ [让 AI 记一笔] → 记忆/伏笔提案 → 人确认入库
```

## 设计来源

- **InkOS**：模型提议/宿主裁决、伏笔五档节奏与账本、hook debt 原文回灌、结算铁律、`author_intent`/`current_focus` 控制文档
- **NarraCat**：账房/花/尺分界、双时态事实、ContextPack 确定性造包、审校只查五类客观错误
- **oh-story**：细纲=写前契约、双时间线（作者真相 vs 读者已知）、强制停靠点、单一 JSON 权威
- **SkillHub 去AI味技能**（Humanizer v4.1 等）：三毒判定、L1 硬规则、五维分级、禁用词表
