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

    // MARK: 场景层（v2 新增）
    //
    // 只有"要发生什么"不足以做连贯性审查——审查需要知道**谁看见的、在哪、什么时候、有谁在场**。
    // 加了场景层之后，SkeletonGate 能校验视角漂移与人物同时出现在两地，ContextPack 能按场景
    // 精准回灌相关设定，草稿也不再靠模型自己猜空间关系。
    //
    // 这些字段是老骨架文件里没有的新键：Swift 合成的 Decodable 对"带默认值的非可选字段"
    // 缺键会直接抛 keyNotFound（实测），所以必须显式实现 init(from:) 用 decodeIfPresent 兜底，
    // 否则用户已有的 skeleton.json 会整份解不出来、静默丢骨架。

    /// 视角人物：这一拍贴着谁写（一章内不应漂移，换视角要分节）
    var pov: String = ""
    /// 场景地点
    var location: String = ""
    /// 时间标记（何时；相对或绝对都行，用于时间线倒挂检测）
    var timeLabel: String = ""
    /// 出场人物（用于「同一人两地在场」与称呼一致性检查）
    var cast: [String] = []
    /// 本拍的转折：从什么变成什么。没有转折的拍是过渡，全章都是过渡就是注水
    var turn: String = ""

    init(id: UUID = UUID(), summary: String = "", purpose: String = "", clueIDs: [String] = [],
         suggestedWords: Int = 0, draftText: String = "", done: Bool = false,
         pov: String = "", location: String = "", timeLabel: String = "",
         cast: [String] = [], turn: String = "") {
        self.id = id
        self.summary = summary
        self.purpose = purpose
        self.clueIDs = clueIDs
        self.suggestedWords = suggestedWords
        self.draftText = draftText
        self.done = done
        self.pov = pov
        self.location = location
        self.timeLabel = timeLabel
        self.cast = cast
        self.turn = turn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        clueIDs = try c.decodeIfPresent([String].self, forKey: .clueIDs) ?? []
        suggestedWords = try c.decodeIfPresent(Int.self, forKey: .suggestedWords) ?? 0
        draftText = try c.decodeIfPresent(String.self, forKey: .draftText) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        pov = try c.decodeIfPresent(String.self, forKey: .pov) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        timeLabel = try c.decodeIfPresent(String.self, forKey: .timeLabel) ?? ""
        cast = try c.decodeIfPresent([String].self, forKey: .cast) ?? []
        turn = try c.decodeIfPresent(String.self, forKey: .turn) ?? ""
    }

    /// 场景信息完整度 0-1（SkeletonGate 用来判「骨架是否可执行」）
    var sceneCompleteness: Double {
        let fields: [Bool] = [!pov.isEmpty, !location.isEmpty, !timeLabel.isEmpty, !cast.isEmpty, !turn.isEmpty]
        return Double(fields.filter { $0 }.count) / Double(fields.count)
    }
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

    // MARK: v2 新增（同样需要显式 init(from:) 兼容老 skeleton.json）

    /// 章尾钩子的形态（HookKind.rawValue）——用来检查是否连续多章用同一种钩子（套版感）
    var hookKind: String = ""
    /// 本章主视角（整章贴着谁写）
    var pov: String = ""
    /// 本章要兑现的爽点类型（CraftCodex.payoffTypes 里的措辞或作者自拟）
    var payoffType: String = ""
    /// 本章挂上的新期待（揭 1 埋 1 的"埋"，可验证、有时限）
    var newExpectation: String = ""
    /// 本章所属卷/阶段名（卷弧结构的定位）
    var volumeLabel: String = ""

    init(beats: [Beat] = [], endHook: String = "", mustDeliver: [String] = [],
         mustAvoid: [String] = [], clueTouches: [ClueTouch] = [],
         proposedByAI: Bool = false, humanApproved: Bool = false, approvedAt: Date? = nil,
         hookKind: String = "", pov: String = "", payoffType: String = "",
         newExpectation: String = "", volumeLabel: String = "") {
        self.beats = beats
        self.endHook = endHook
        self.mustDeliver = mustDeliver
        self.mustAvoid = mustAvoid
        self.clueTouches = clueTouches
        self.proposedByAI = proposedByAI
        self.humanApproved = humanApproved
        self.approvedAt = approvedAt
        self.hookKind = hookKind
        self.pov = pov
        self.payoffType = payoffType
        self.newExpectation = newExpectation
        self.volumeLabel = volumeLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beats = try c.decodeIfPresent([Beat].self, forKey: .beats) ?? []
        endHook = try c.decodeIfPresent(String.self, forKey: .endHook) ?? ""
        mustDeliver = try c.decodeIfPresent([String].self, forKey: .mustDeliver) ?? []
        mustAvoid = try c.decodeIfPresent([String].self, forKey: .mustAvoid) ?? []
        clueTouches = try c.decodeIfPresent([ClueTouch].self, forKey: .clueTouches) ?? []
        proposedByAI = try c.decodeIfPresent(Bool.self, forKey: .proposedByAI) ?? false
        humanApproved = try c.decodeIfPresent(Bool.self, forKey: .humanApproved) ?? false
        approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        hookKind = try c.decodeIfPresent(String.self, forKey: .hookKind) ?? ""
        pov = try c.decodeIfPresent(String.self, forKey: .pov) ?? ""
        payoffType = try c.decodeIfPresent(String.self, forKey: .payoffType) ?? ""
        newExpectation = try c.decodeIfPresent(String.self, forKey: .newExpectation) ?? ""
        volumeLabel = try c.decodeIfPresent(String.self, forKey: .volumeLabel) ?? ""
    }

    /// 最近若干章的钩子形态是否重复（套版感检测由 SkeletonGate 调用）
    var hasSceneLayer: Bool { beats.contains { $0.sceneCompleteness > 0 } }
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
