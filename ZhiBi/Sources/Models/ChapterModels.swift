import Foundation

// MARK: - 章节状态（人主导的生命周期）

enum ChapterStatus: String, Codable, CaseIterable {
    case empty = "未规划"
    case skeletoned = "骨架已定"
    case writing = "写作中"
    case written = "初稿完成"
    case checked = "已验证"
    case polished = "已润色"
    case done = "定稿"
}

// MARK: - 章节骨架（AI 搭、人填、人批准）

struct Beat: Codable, Identifiable {
    var id: UUID = UUID()
    /// 这个节点要发生什么（人话，作者可改）
    var summary: String = ""
    /// 功能定位：推进 / 爽点 / 埋伏笔 / 收钩子 / 情绪 / 过渡
    var purpose: String = ""
    /// 关联伏笔 F 编号
    var clueIDs: [String] = []
    var suggestedWords: Int = 0
    /// 人在这个节点上填写的草稿（可整段合入正文）
    var draftText: String = ""
    var done: Bool = false
}

enum ClueActionKind: String, Codable, CaseIterable {
    case plant = "埋设"
    case develop = "推进"
    case reveal = "揭示"
    case resolve = "回收"
    case `defer` = "搁置"
}

struct ClueTouch: Codable, Identifiable {
    var id: UUID = UUID()
    var clueID: String = ""
    var action: ClueActionKind = .plant
    /// 本章对这条伏笔必须做到什么（硬合同）
    var requirement: String = ""
}

struct ChapterSkeleton: Codable {
    var beats: [Beat] = []
    /// 章尾钩子（收在什么画面）
    var endHook: String = ""
    /// 硬交付项：这章必须完成的事
    var mustDeliver: [String] = []
    /// 禁止项：这章不要做什么
    var mustAvoid: [String] = []
    /// 本章伏笔触点合同（计划账本）
    var clueTouches: [ClueTouch] = []
    var proposedByAI: Bool = false
    var humanApproved: Bool = false
    var approvedAt: Date?
}

// MARK: - 章节 meta（磁盘权威：正文在 prose.md，meta.json 只存这个瘦身结构）
//
// saveNow 写入与书架/统计读取必须都用它——直接用 Chapter 解码 meta.json 会因
// 缺 prose 键（keyNotFound）与日期策略不匹配（deferredToDate vs iso8601）而
// 静默丢掉每一章（上轮书架统计恒 0 的根因）。

struct ChapterMeta: Codable {
    var id: UUID = UUID()
    var number: Int
    var title: String = ""
    var status: ChapterStatus = .empty
    var skeleton: ChapterSkeleton?
    var summary: ChapterSummary?
    var notes: [String]?
    var cachedWords: Int?
    var updatedAt: Date = Date()
}

// MARK: - 章节

struct Chapter: Codable, Identifiable {
    var id: UUID = UUID()
    var number: Int
    var title: String = ""
    var status: ChapterStatus = .empty
    /// 人的正文（权威，纯 markdown）
    var prose: String = ""
    var skeleton: ChapterSkeleton?
    var summary: ChapterSummary?
    /// 随手记：写作时顺手记下的关键节点/记忆/埋点候选（旁路记录，人写）
    var notes: [String]? = []
    var updatedAt: Date = Date()
    /// 字数缓存：prose 变更时由 store 更新；nil = 未统计（旧文件/未扫描），读取时现算
    var cachedWords: Int? = nil

    var wordCount: Int { cachedWords ?? WordStats.chineseCount(prose) }
    var noteList: [String] { notes ?? [] }
}

// MARK: - 章节摘要（人确认后入库，供上下文造包）

struct ChapterSummary: Codable {
    var chapter: Int = 0
    /// 200-500 字摘要
    var summary: String = ""
    var keyEvents: [String] = []
    var emotionalTone: String = ""
}
