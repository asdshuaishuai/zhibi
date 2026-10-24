import Foundation

// MARK: - 作者与 AI 的对话记录（项目级；AI 仍然只能以提案改书）

enum ChatRole: String, Codable {
    case user = "作者"
    case assistant = "AI"
}

struct ChatMessage: Codable, Identifiable {
    var id: UUID = UUID()
    var role: ChatRole = .user
    var text: String = ""
    var at: Date = Date()
    /// 这次回答引用到的资料库条目（chapter / canon / clue…）
    var citations: [String] = []
    /// 这次回答新登记的提案；导出/归档时据此附带提案快照
    var proposalIDs: [UUID] = []
    var isError: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, role, text, at, citations, proposalIDs, isError
    }

    init(role: ChatRole, text: String, citations: [String] = [],
         proposalIDs: [UUID] = [], isError: Bool = false) {
        self.role = role
        self.text = text
        self.citations = citations
        self.proposalIDs = proposalIDs
        self.isError = isError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let raw = try c.decodeIfPresent(String.self, forKey: .role) {
            role = ChatRole(rawValue: raw) ?? .user
        } else {
            role = .user
        }
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        citations = try c.decodeIfPresent([String].self, forKey: .citations) ?? []
        proposalIDs = try c.decodeIfPresent([UUID].self, forKey: .proposalIDs) ?? []
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

// MARK: - 对话导出 / 归档

/// 归档的可恢复快照：Markdown 给人读，JSON 给应用恢复。
/// 恢复只追加消息，不把旧提案重新塞回收件箱（避免重复审批）。
struct ChatArchivePayload: Codable {
    var version: Int = 1
    var projectTitle: String = ""
    var archivedAt: Date = Date()
    var messages: [ChatMessage] = []
    var proposals: [AIProposal] = []
}

enum ChatTranscript {
    /// 导出成作者能直接读的 Markdown：角色、时间、正文、来源一目了然。
    static func markdown(messages: [ChatMessage], projectTitle: String,
                         proposals: [AIProposal] = [],
                         exportedAt: Date = Date()) -> String {
        let title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "# 《\(title.isEmpty ? "未命名作品" : title)》· 与 AI 的对话记录",
            "",
            "- 导出时间：\(exportedAt.formatted(date: .numeric, time: .standard))",
            "- 消息数：\(messages.count)",
            ""
        ]
        guard !messages.isEmpty else {
            lines.append("（没有对话记录）")
            return lines.joined(separator: "\n")
        }
        for message in messages {
            lines.append("---")
            lines.append("")
            let who = message.role == .user ? "作者" : "AI 搭档"
            lines.append("## \(who) · \(message.at.formatted(date: .numeric, time: .shortened))")
            lines.append("")
            if message.isError {
                lines.append("> ⚠️ 这次运行失败或被停止")
                lines.append("")
            }
            lines.append(message.text)
            if !message.citations.isEmpty {
                lines.append("")
                lines.append("来源：" + message.citations.map { "【\($0)】" }.joined(separator: " "))
            }
            let linked = message.proposalIDs.compactMap { id in
                proposals.first { $0.id == id }
            }
            if !linked.isEmpty {
                lines.append("")
                lines.append("#### 本次登记的提案")
                lines.append("")
                for proposal in linked {
                    let chapter = proposal.chapterNumber.map { "第\($0)章 · " } ?? ""
                    lines.append("- **\(proposal.capability.rawValue)** · \(chapter)\(proposal.title)（\(proposal.status.rawValue)）")
                    if !proposal.note.isEmpty {
                        lines.append("  - 说明：\(String(proposal.note.prefix(200)))")
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func fileName(projectTitle: String, at date: Date = Date()) -> String {
        let title = safeComponent(projectTitle, fallback: "未命名作品")
        return "《\(title)》对话记录-\(fileStamp.string(from: date)).md"
    }

    static func archiveFileName(at date: Date = Date()) -> String {
        "chat-archive-\(archiveStamp.string(from: date)).md"
    }

    /// 书名可能包含 `/`、`:` 等不能进文件名的字符。
    static func safeComponent(_ raw: String, fallback: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()

    private static let archiveStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
