import Foundation

enum WordStats {
    /// 中文字符数（网文计字口径：CJK + 中文标点之外的实义字符；这里按主流口径只数 CJK 与全角字符）
    static func chineseCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }.count
    }

    static func approxTokens(_ text: String) -> Int {
        // 中文近似 1 字 ≈ 1.5 token，取 2/3 字符数为保守估计
        max(1, chineseCount(text) * 3 / 2)
    }
}

/// 项目磁盘布局：正文是 md（人读人写可带走），结构是 JSON（机器权威）
enum ProjectLayout {
    /// 文件名/目录名安全化：拒绝路径分隔符与父目录引用
    static func safeFileName(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: "_") }
        if out.isEmpty || out == "." || out == "_" { out = "untitled" }
        return out
    }

    static func chaptersDir(_ root: URL) -> URL { root.appendingPathComponent("chapters", isDirectory: true) }
    static func chapterDir(_ root: URL, number: Int) -> URL {
        chaptersDir(root).appendingPathComponent(String(format: "ch-%03d", number), isDirectory: true)
    }
    static func canonDir(_ root: URL) -> URL { root.appendingPathComponent("canon", isDirectory: true) }
    static func proposalsFile(_ root: URL) -> URL { root.appendingPathComponent("proposals/inbox.json") }
    static func outlineFile(_ root: URL) -> URL { root.appendingPathComponent("outline.json") }
    static func cluesFile(_ root: URL) -> URL { root.appendingPathComponent("clues.json") }
    static func memoryFile(_ root: URL) -> URL { root.appendingPathComponent("memory.json") }
    static func projectFile(_ root: URL) -> URL { root.appendingPathComponent("project.json") }
    static func checkpointsDir(_ root: URL) -> URL { root.appendingPathComponent("checkpoints", isDirectory: true) }
    static func proseFile(_ root: URL, number: Int) -> URL {
        chapterDir(root, number: number).appendingPathComponent("prose.md")
    }
}

struct ProjectRef: Codable, Identifiable {
    var id: UUID
    var title: String
    var url: URL
    var lastOpenedAt: Date

    init(id: UUID = UUID(), title: String, url: URL, lastOpenedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.lastOpenedAt = lastOpenedAt
    }
}

/// 磁盘原子写
enum Disk {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("." + url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try write(try enc.encode(value), to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: try Data(contentsOf: url))
    }

    static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
