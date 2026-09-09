import Foundation

// MARK: - 伏笔 / 线索台账（F 编号）

enum ClueScale: String, Codable, CaseIterable {
    case small = "小（本弧内）"
    case medium = "中（本卷内）"
    case major = "大（跨卷）"
}

/// 五档节奏（InkOS payoffTiming）：决定多久不动算过期
enum ClueTiming: String, Codable, CaseIterable {
    case immediate = "即刻（约3章）"
    case nearTerm = "近期（约5章）"
    case midArc = "中程（约8章）"
    case slowBurn = "慢热（约12章）"
    case endgame = "终局（16章+）"

    /// 超过多少章未推进视为过期（InkOS HOOK_TIMING_PROFILES 精简版）
    var overdueAfterChapters: Int {
        switch self {
        case .immediate: return 3
        case .nearTerm: return 5
        case .midArc: return 8
        case .slowBurn: return 12
        case .endgame: return 16
        }
    }
}

enum ClueStatus: String, Codable, CaseIterable {
    case planted = "已埋"
    case developing = "推进中"
    case resolved = "已回收"
    case deferred = "已搁置"
    case abandoned = "已放弃"
}

struct ClueActionLog: Codable, Identifiable {
    var id: UUID = UUID()
    var chapter: Int
    var kind: ClueActionKind
    var note: String = ""
    var at: Date = Date()
}

struct Clue: Codable, Identifiable {
    var id: String = ""            // "F01"
    var title: String = ""
    var detail: String = ""
    var scale: ClueScale = .medium
    var timing: ClueTiming = .midArc
    var importance: String = "中"   // 高/中/低
    var plantedChapter: Int = 0
    /// 种下时的原文片段（InkOS hook debt：兑现时回灌给作者对照）
    var plantedQuote: String = ""
    var targetPayoffChapter: Int?
    var status: ClueStatus = .planted
    var lastActionChapter: Int = 0
    var actions: [ClueActionLog] = []

    /// 相对当前章是否过期
    func isOverdue(currentChapter: Int) -> Bool {
        guard status == .planted || status == .developing else { return false }
        return currentChapter - lastActionChapter >= timing.overdueAfterChapters
    }
}

// MARK: - 双时态事实（NarraCat/InkOS 记忆库）

struct MemoryFact: Codable, Identifiable {
    var id: UUID = UUID()
    /// 主语（角色/势力/物）
    var subject: String = ""
    /// 受控谓词：位于 / 获得 / 失去 / 知道 / 相信 / 关系 / 状态 / 目标 / 承诺 / 死亡 / 身份 / 其他
    var predicate: String = ""
    var object: String = ""
    var fromChapter: Int = 0
    /// 失效章（nil = 仍然有效）
    var invalidatedAtChapter: Int?
    /// 是否为读者已知的公开事实（secretKnown=false 表示读者还不知道，仅作者账本）
    var publicToReader: Bool = true
    /// extracted = 从正文提取；authored = 作者钦定
    var source: String = "extracted"
    var note: String = ""

    func isValid(atChapter chapter: Int) -> Bool {
        if let inv = invalidatedAtChapter { return chapter < inv || fromChapter > inv }
        return true
    }
}

struct CharacterAlias: Codable, Identifiable {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var aliases: [String] = []
}
