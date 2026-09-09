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
