import Foundation

// MARK: - AI 能力清单
//
// 铁律不是"AI 不能写正文"，而是"AI 的任何产出（含整章草稿）都只能以提案形态存在，
// 作者采纳前不落正文，采纳时自动快照可回滚"。chapterDraft 产出的是草稿提案，不是正文。

enum AICapability: String, Codable, CaseIterable {
    case framework = "搭建框架"
    case outlineTimeline = "大纲事件时间线"
    case clueLedger = "线索埋点台账"
    case chapterSkeleton = "章节骨架"
    case chapterDraft = "一键写作"
    case chapterRevise = "按意见修复"
    case memoryExtract = "记忆提取"
    case validation = "一致性验证"
    case continuityAudit = "全书连贯性审查"
    case outlineSync = "大纲同步"
    case deslop = "去AI味"
    case recallMemo = "写作备忘"
}

// MARK: - 整章草稿（流水线产物；采纳前不进正文）

struct DraftFeedback: Codable, Identifiable {
    var id: UUID = UUID()
    var feedback: String = ""
    var fromVersion: Int = 0
    var at: Date = Date()
}

struct ChapterDraft: Codable {
    var chapter: Int = 0
    var text: String = ""
    var version: Int = 1
    var mainline: String = ""
    var feedbackHistory: [DraftFeedback] = []
}

// MARK: - 设定文档提案（背景框架落地：AI 只提案，人批准后入设定库）

struct CanonDocProposal: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String            // 设定文档标题（世界观 / 势力人物 / 修炼体系…）
    var content: String = ""     // Markdown 正文（可含表格）
    var certainty: String = "tentative"  // canon / tentative / blank
}

// MARK: - 提案负载

enum ProposalPayload: Codable {
    case outlineEvents([TimelineEvent])
    case storylines([Storyline])
    case clues([Clue])
    case skeleton(ChapterSkeleton)
    case draft(ChapterDraft)
    case memoryPack(facts: [MemoryFact], summary: ChapterSummary, newClueCandidates: [Clue])
    case report(ValidationReport)
    case deslop(DeslopReport)
    case memo(String)
    case canon([CanonDocProposal])
    /// 埋点修复：可一键采纳的伏笔台账修正（ContinuityAuditor 产出）
    case clueFixes([ClueFix])
    /// 大纲同步：可一键采纳的大纲更新（OutlineSync 产出）
    case outlineUpdates([OutlineUpdate])
}

enum ProposalStatus: String, Codable {
    case pending = "待确认"
    case accepted = "已采纳"
    case rejected = "已拒绝"
}

struct AIProposal: Codable, Identifiable {
    var id: UUID = UUID()
    var capability: AICapability
    var chapterNumber: Int?
    var title: String = ""
    /// AI 的说明（人话：它做了什么、为什么）
    var note: String = ""
    var payload: ProposalPayload
    var status: ProposalStatus = .pending
    var createdAt: Date = Date()
    var decidedAt: Date?
}

// MARK: - 验证报告

enum Severity: String, Codable, Comparable {
    case blocker = "阻塞"
    case warning = "警告"
    case note = "备注"

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        let order: [Severity] = [.blocker, .warning, .note]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

struct ValidationIssue: Codable, Identifiable {
    var id: UUID = UUID()
    var severity: Severity = .warning
    /// 分类：骨架覆盖 / 伏笔合同 / 连续性 / 设定违背 / 时间线 / 物理不可能 / AI味
    var category: String = ""
    var message: String = ""
    var evidence: String = ""
    var suggestion: String = ""
}

struct ValidationReport: Codable {
    var chapter: Int = 0
    var deterministicIssues: [ValidationIssue] = []
    var aiIssues: [ValidationIssue] = []
    var lintSummary: LintSummary?
    var checkedAt: Date = Date()

    var allIssues: [ValidationIssue] { (deterministicIssues + aiIssues).sorted { $0.severity < $1.severity } }
}

// MARK: - 去AI味报告

struct DeslopSuggestion: Codable, Identifiable {
    var id: UUID = UUID()
    /// Gate A-G（oh-story 7 Gate）或 L1-L4（Humanizer）
    var gate: String = ""
    var original: String = ""
    var replacement: String = ""
    var reason: String = ""
    var applied: Bool = false
}

struct DeslopReport: Codable {
    var chapter: Int = 0
    /// 轻度 / 中度 / 重度
    var grade: String = ""
    var lint: LintSummary?
    var suggestions: [DeslopSuggestion] = []
    var checkedAt: Date = Date()
}
