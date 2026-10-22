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

extension NovelProject {
    private enum Keys: String, CodingKey {
        case id, title, genre, premise, targetChapters, chapterWordTarget, createdAt
        case authorIntent, currentFocus, styleNotes, coverStyle, dailyWords
    }

    /// 显式解码：早期 project.json 没有 targetChapters / authorIntent / styleNotes 等键。
    /// 合成解码对「带默认值的非可选字段」缺键会直接抛错，整个项目就打不开了。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名作品"
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        premise = try c.decodeIfPresent(String.self, forKey: .premise) ?? ""
        targetChapters = try c.decodeIfPresent(Int.self, forKey: .targetChapters) ?? 100
        chapterWordTarget = try c.decodeIfPresent(Int.self, forKey: .chapterWordTarget) ?? 3000
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        authorIntent = try c.decodeIfPresent(String.self, forKey: .authorIntent) ?? ""
        currentFocus = try c.decodeIfPresent(String.self, forKey: .currentFocus) ?? ""
        styleNotes = try c.decodeIfPresent(String.self, forKey: .styleNotes) ?? ""
        coverStyle = try c.decodeIfPresent(Int.self, forKey: .coverStyle)
        dailyWords = try c.decodeIfPresent([String: Int].self, forKey: .dailyWords)
    }
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
    /// 设定分类（CanonCategory.rawValue；旧档无此键解码为默认值）
    var category: String = CanonCategory.uncategorized.rawValue
    var updatedAt: Date = Date()
}

extension CanonSection {
    private enum Keys: String, CodingKey {
        case id, title, content, certainty, category, updatedAt
    }

    /// 旧 sections.json 没有 category / updatedAt 键，缺键不能让整份设定索引解不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .certainty) {
            certainty = Certainty(rawValue: raw) ?? .tentative
        } else {
            certainty = .tentative
        }
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? CanonCategory.uncategorized.rawValue
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 设定分类（设定页按此分组；AI 归类提案写回这里）
enum CanonCategory: String, Codable, CaseIterable {
    case worldview = "世界观"
    case faction = "势力人物"
    case powerSystem = "修炼体系"
    case plotOutline = "剧情大纲"
    case themeRules = "题材规则"
    case uncategorized = "未分类"

    static func match(_ raw: String) -> CanonCategory {
        CanonCategory(rawValue: raw) ?? .uncategorized
    }
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

extension Storyline {
    private enum Keys: String, CodingKey {
        case id, name, kind, isThroughLine, status, entryChapter, plannedPayoffChapter, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .kind) {
            kind = StorylineKind(rawValue: raw) ?? .other
        } else {
            kind = .other
        }
        isThroughLine = try c.decodeIfPresent(Bool.self, forKey: .isThroughLine) ?? false
        if let raw = try c.decodeIfPresent(String.self, forKey: .status) {
            status = ActiveStatus(rawValue: raw) ?? .active
        } else {
            status = .active
        }
        entryChapter = try c.decodeIfPresent(Int.self, forKey: .entryChapter)
        plannedPayoffChapter = try c.decodeIfPresent(Int.self, forKey: .plannedPayoffChapter)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
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

extension Stage {
    private enum Keys: String, CodingKey {
        case id, name, chapterStart, chapterEnd, theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        chapterStart = try c.decodeIfPresent(Int.self, forKey: .chapterStart) ?? 1
        chapterEnd = try c.decodeIfPresent(Int.self, forKey: .chapterEnd) ?? chapterStart
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? ""
    }
}


// MARK: - 封面风格（书架卡牌用，随 project.json 持久化）

enum CoverStyle {
    static let count = 5

    static func defaultIndex(for title: String) -> Int {
        let h = abs(title.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) })
        return h % count
    }
}
