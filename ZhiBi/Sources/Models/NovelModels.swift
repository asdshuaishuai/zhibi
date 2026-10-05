import Foundation

// MARK: - 书籍

struct NovelProject: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String = "未命名作品"
    var genre: String = ""
    var premise: String = ""
    var targetChapters: Int = 100
    var chapterWordTarget: Int = 3000
    var createdAt: Date = Date()
    /// 作者意图（inkos: author_intent.md）——人的长期意图，最高优先级之一
    var authorIntent: String = ""
    /// 当前焦点（inkos: current_focus.md）——最近在盯什么
    var currentFocus: String = ""
    /// 文风主权（oh-story: 设定/文风.md）——用户自写，AI 不得覆盖
    var styleNotes: String = ""
    /// 书架封面风格（0-4，nil = 按书名哈希自动）
    var coverStyle: Int? = nil
    /// 每日净增字数（key = yyyy-MM-dd）——写作进度账本
    var dailyWords: [String: Int]? = nil
}

/// 确定度三态（NarraCat 立项卡）
enum Certainty: String, Codable, CaseIterable {
    case canon = "已定"
    case tentative = "暂定"
    case open = "有意留白"
}

// MARK: - 设定

struct CanonSection: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var content: String = ""
    var certainty: Certainty = .tentative
    var updatedAt: Date = Date()
}

// MARK: - 故事线（oh-story L 编号 / NarraCat storylines）

enum StorylineKind: String, Codable, CaseIterable {
    case main = "主线"
    case growth = "成长线"
    case romance = "感情线"
    case faction = "势力线"
    case mystery = "悬疑线"
    case rivalry = "对手线"
    case world = "世界线"
    case other = "其他"
}

enum ActiveStatus: String, Codable, CaseIterable {
    case active = "进行中"
    case dormant = "蛰伏"
    case resolved = "已收束"
}

struct Storyline: Codable, Identifiable {
    var id: String = ""            // "L01"
    var name: String = ""
    var kind: StorylineKind = .main
    var isThroughLine: Bool = false // 贯穿线：造包时永不丢弃
    var status: ActiveStatus = .active
    var entryChapter: Int?
    var plannedPayoffChapter: Int?
    var notes: String = ""
}

// MARK: - 时间线事件（oh-story 双时间线：作者真相 vs 读者已知）

struct TimelineEvent: Codable, Identifiable {
    var id: String = ""             // "E01"
    var chapter: Int = 0            // 发生在第几章
    var objectiveFact: String = ""  // 作者真相（客观事实）
    var readerKnowledge: String = ""// 读者已知（读者此刻被告知了什么）
    var revealed: Bool = false      // 读者是否已知情
    var revealChapter: Int?
    var storylineIDs: [String] = []
    var notes: String = ""

    // MARK: 大纲实时同步（v2 新增）
    //
    // 大纲过去是建书时一次性生成的静态计划，作者写了几十章后它就和真实剧情脱节。
    // OutlineSync 把「计划」与「实际」对账后产出更新提案，作者采纳才写回这几个字段——
    // 于是大纲变成随写作推进的活文档，而不是一份越来越不可信的旧计划书。
    //
    // 老 outline.json 没有这些键，Swift 合成 Decodable 缺键会抛 keyNotFound，
    // 因此显式实现 init(from:) 用 decodeIfPresent 兜底，避免整份大纲解不出来。

    /// 计划事件是否已在正文里发生（OutlineSync 对账 + 作者采纳后写入）
    var happened: Bool = false
    /// 作者决定取消这个计划事件（不删记录——保留"曾经计划过什么"的痕迹）
    var dropped: Bool = false
    /// 实际发生章（与 chapter 不同时说明剧情偏移了）
    var actualChapter: Int?
    /// 对账证据/说明（人话，作者看得出凭什么这么判）
    var syncNote: String = ""
    /// 最近一次同步时间
    var syncedAt: Date?

    init(id: String = "", chapter: Int = 0, objectiveFact: String = "", readerKnowledge: String = "",
         revealed: Bool = false, revealChapter: Int? = nil, storylineIDs: [String] = [], notes: String = "",
         happened: Bool = false, dropped: Bool = false, actualChapter: Int? = nil,
         syncNote: String = "", syncedAt: Date? = nil) {
        self.id = id
        self.chapter = chapter
        self.objectiveFact = objectiveFact
        self.readerKnowledge = readerKnowledge
        self.revealed = revealed
        self.revealChapter = revealChapter
        self.storylineIDs = storylineIDs
        self.notes = notes
        self.happened = happened
        self.dropped = dropped
        self.actualChapter = actualChapter
        self.syncNote = syncNote
        self.syncedAt = syncedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter) ?? 0
        objectiveFact = try c.decodeIfPresent(String.self, forKey: .objectiveFact) ?? ""
        readerKnowledge = try c.decodeIfPresent(String.self, forKey: .readerKnowledge) ?? ""
        revealed = try c.decodeIfPresent(Bool.self, forKey: .revealed) ?? false
        revealChapter = try c.decodeIfPresent(Int.self, forKey: .revealChapter)
        storylineIDs = try c.decodeIfPresent([String].self, forKey: .storylineIDs) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        happened = try c.decodeIfPresent(Bool.self, forKey: .happened) ?? false
        dropped = try c.decodeIfPresent(Bool.self, forKey: .dropped) ?? false
        actualChapter = try c.decodeIfPresent(Int.self, forKey: .actualChapter)
        syncNote = try c.decodeIfPresent(String.self, forKey: .syncNote) ?? ""
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
    }

    /// 剧情是否偏离了原计划
    var isDiverged: Bool {
        guard let actual = actualChapter else { return false }
        return actual != chapter
    }
}

// MARK: - 阶段 / 卷

struct Stage: Codable, Identifiable {
    var id: Int
    var name: String = ""
    var chapterStart: Int = 1
    var chapterEnd: Int = 1
    var theme: String = ""
}


// MARK: - 封面风格（书架卡牌用，随 project.json 持久化）

enum CoverStyle {
    static let count = 5

    static func defaultIndex(for title: String) -> Int {
        let h = abs(title.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) })
        return h % count
    }
}
