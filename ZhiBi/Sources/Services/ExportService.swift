import Foundation

// MARK: - 导出
// 1) 合并稿：全书单文件（发布/投稿用）
// 2) oh-story 目录回写：大纲/ 设定/ 正文/ 追踪/_tracking-state.json——
//    与社区工作流互通，AI 与脚本可以继续消费这套目录

enum ExportService {
    struct Result {
        var url: URL
        var filesWritten: Int
    }

    static func exportRoot() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("执笔导出", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 全书合并为一个 markdown/txt
    @MainActor
    static func exportManuscript(store: ProjectStore, format: String = "md") throws -> Result {
        let stamp = ProjectStore.fileStamp()
        let dir = exportRoot().appendingPathComponent("\(ProjectLayout.safeFileName(store.project.title))-合并稿", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(ProjectLayout.safeFileName(store.project.title)).\(format)")

        var out = "# \(store.project.title)\n\n"
        if !store.project.genre.isEmpty { out += "题材：\(store.project.genre)\n\n" }
        if !store.project.premise.isEmpty { out += "> \(store.project.premise)\n\n" }
        for ch in store.chapters where !ch.prose.isEmpty {
            out += "---\n\n"
            out += "## 第\(ch.number)章 \(ch.title)\n\n"
            out += ch.prose.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        try Disk.write(Data(out.utf8), to: fileURL)
        return Result(url: fileURL, filesWritten: 1)
    }

    /// 分卷 TXT：每 perVolume 章一个文件（网文平台上传友好）
    @MainActor
    static func exportVolumeTxt(store: ProjectStore, perVolume: Int = 20) throws -> Result {
        let dir = exportRoot().appendingPathComponent("\(ProjectLayout.safeFileName(store.project.title))-分卷", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let drafted = store.chapters.filter { !$0.prose.isEmpty }
        let chunks = drafted.byChunks(of: perVolume)
        var count = 0
        for (volumeIndex, chunk) in chunks.enumerated() {
            let first = chunk.first?.number ?? 0
            let last = chunk.last?.number ?? 0
            var text = store.project.title + " 第\(volumeIndex + 1)卷（第\(first)-\(last)章）\n\n"
            for ch in chunk {
                let trimmed = ch.prose.trimmingCharacters(in: .whitespacesAndNewlines)
                text += "第\(ch.number)章 \(ch.title)\n\n" + trimmed + "\n\n"
            }
            let fileName = String(format: "第%02d卷(%03d-%03d).txt", volumeIndex + 1, first, last)
            try Disk.write(Data(text.utf8), to: dir.appendingPathComponent(fileName))
            count += 1
        }
        return Result(url: dir, filesWritten: count)
    }

    /// 回写 oh-story 目录规范
    @MainActor
    static func exportOhStory(store: ProjectStore) throws -> Result {
        let dir = exportRoot().appendingPathComponent("\(ProjectLayout.safeFileName(store.project.title))-ohstory-\(ProjectStore.fileStamp())", isDirectory: true)
        var count = 0

        func write(_ text: String, _ rel: String) throws {
            try Disk.write(Data(text.utf8), to: dir.appendingPathComponent(rel))
            count += 1
        }

        // 大纲：主线大纲 + 细纲一文件
        var outline = "# 《\(store.project.title)》主线大纲\n\n"
        if !store.project.premise.isEmpty { outline += "核心：\(store.project.premise)\n\n" }
        outline += "## 故事线\n\n"
        for l in store.storylines {
            outline += "- [\(l.id)] \(l.name)（\(l.kind.rawValue)\(l.isThroughLine ? "·贯穿" : "")｜\(l.status.rawValue)）\(l.notes)\n"
        }
        outline += "\n## 阶段\n\n"
        for s in store.stages {
            outline += "- 第\(s.id)阶段「\(s.name)」（第\(s.chapterStart)-\(s.chapterEnd)章）：\(s.theme)\n"
        }
        outline += "\n## 事件时间线（作者真相 ｜ 读者已知）\n\n"
        for e in store.timelineEvents {
            let reader = e.revealed ? e.readerKnowledge : "未揭示（读者以为：\(e.readerKnowledge)）"
            outline += "- [\(e.id)] 第\(e.chapter)章｜真相：\(e.objectiveFact)｜读者：\(reader)\n"
        }
        try write(outline, "大纲/主线大纲.md")

        for ch in store.chapters {
            guard let sk = ch.skeleton, !sk.beats.isEmpty else { continue }
            var detail = "# 细纲_第\(String(format: "%03d", ch.number))章_\(ch.title)\n\n"
            detail += "状态：\(ch.status.rawValue)\(sk.humanApproved ? "（骨架已批准）" : "")\n\n"
            detail += "## 节拍\n\n"
            for (i, b) in sk.beats.enumerated() {
                detail += "\(i + 1). \(b.summary)（\(b.purpose)\(b.suggestedWords > 0 ? "｜约\(b.suggestedWords)字" : "")）\(b.clueIDs.isEmpty ? "" : "｜触点：\(b.clueIDs.joined(separator: " "))")\n"
            }
            if !sk.endHook.isEmpty { detail += "\n章尾钩子：\(sk.endHook)\n" }
            if !sk.mustDeliver.isEmpty { detail += "硬交付：\(sk.mustDeliver.joined(separator: "；"))\n" }
            if !sk.mustAvoid.isEmpty { detail += "禁止：\(sk.mustAvoid.joined(separator: "；"))\n" }
            if !sk.clueTouches.isEmpty {
                detail += "\n## 伏笔触点\n\n"
                for t in sk.clueTouches {
                    detail += "- [\(t.clueID)] \(t.action.rawValue)：\(t.requirement)\n"
                }
            }
            try write(detail, "大纲/细纲_第\(String(format: "%03d", ch.number))章_\(safeName(ch.title)).md")
        }

        // 设定
        for section in store.canonSections {
            try write(section.content, "设定/\(safeName(section.title)).md")
        }

        // 正文
        for ch in store.chapters where !ch.prose.isEmpty {
            try write(ch.prose, "正文/第\(String(format: "%03d", ch.number))章_\(safeName(ch.title.isEmpty ? "未命名" : ch.title)).md")
        }

        // 追踪：_tracking-state.json（我们字段的投影，best-effort 兼容）+ 派生 md
        let drafted = store.chapters.filter { !$0.prose.isEmpty }.map(\.number)
        var state: [String: Any] = [
            "project": [
                "title": store.project.title,
                "type": "long",
                "language": "zh-CN",
                "exported_from": "zhibi",
                "exported_at": ISO8601DateFormatter().string(from: Date()),
            ],
            "chapters": [
                "drafted": drafted,
                "completed": store.chapters.filter { $0.status == .done || $0.status == .polished }.map(\.number),
                "next_chapter": store.currentChapter,
            ],
            "stages_overview": store.stages.map { s in
                ["id": s.id, "name": s.name, "theme": s.theme, "chapter_start": s.chapterStart, "chapter_end": s.chapterEnd]
            },
            "active_foreshadowing": store.clues
                .filter { $0.status == .planted || $0.status == .developing }
                .map { c in ["id": c.id, "name": c.title, "detail": c.detail, "planted_chapter": c.plantedChapter,
                             "timing": c.timing.rawValue, "scale": c.scale.rawValue, "last_action_chapter": c.lastActionChapter] },
            "storylines": store.storylines.map { l in
                ["id": l.id, "name": l.name, "kind": l.kind.rawValue, "through_line": l.isThroughLine, "status": l.status.rawValue]
            },
            "timeline_events": store.timelineEvents.map { e in
                ["id": e.id, "chapter": e.chapter, "objective_fact": e.objectiveFact,
                 "reader_knowledge": e.readerKnowledge, "revealed": e.revealed]
            },
            "facts": store.facts.map { f in
                ["subject": f.subject, "predicate": f.predicate, "object": f.object,
                 "from_chapter": f.fromChapter, "invalidated_at_chapter": f.invalidatedAtChapter ?? NSNull(),
                 "public_to_reader": f.publicToReader]
            },
        ]
        if let next = store.chapter(store.currentChapter), let sk = next.skeleton, !sk.mustDeliver.isEmpty {
            state["next_chapter_commitments"] = [
                "next_chapter": next.number,
                "title_suggestion": next.title,
                "must_fulfill": sk.mustDeliver,
            ]
        }
        let stateData = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        try Disk.write(stateData, to: dir.appendingPathComponent("追踪/_tracking-state.json"))
        count += 1

        // 伏笔.md + 上下文.md（派生视图）
        var clueMd = "# 伏笔台账\n\n| 编号 | 标题 | 状态 | 埋于 | 最近动作 | 节奏 | 详情 |\n|---|---|---|---|---|---|---|\n"
        for c in store.clues {
            clueMd += "| \(c.id) | \(c.title) | \(c.status.rawValue) | 第\(c.plantedChapter)章 | 第\(c.lastActionChapter)章 | \(c.timing.rawValue) | \(c.detail.replacingOccurrences(of: "\n", with: " ")) |\n"
        }
        try write(clueMd, "追踪/伏笔.md")

        let n = store.currentChapter
        let pack = ContextPackBuilder.build(store: store, forChapter: n, budget: 8000)
        try write("# 上下文（第\(n)章写作前速览）\n\n" + pack.asText, "追踪/上下文.md")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Result(url: dir, filesWritten: count)
    }

    private static func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "")
    }
}


extension Array {
    func byChunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
