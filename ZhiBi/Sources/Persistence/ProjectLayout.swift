import Foundation

enum WordStats {
    /// 正文字数（网文平台口径：CJK 汉字 + 中文标点 + 英文/数字字符）。
    /// 英文名、代号、等级（LV1 / S 级）不再被整段漏计。
    static func chineseCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // CJK 基本区
                || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
                || (0xF900...0xFAFF).contains(scalar.value) // 兼容表意
                || (0x3000...0x303F).contains(scalar.value) // CJK 标点（。、「」等）
                || (0xFF00...0xFFEF).contains(scalar.value) // 全角标点/符号
                || (0x30...0x39).contains(scalar.value)     // 0-9
                || (0x41...0x5A).contains(scalar.value)     // A-Z
                || (0x61...0x7A).contains(scalar.value)     // a-z
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
    /// 文件名长度上限：APFS 单段约 255 UTF-8 字节（中文 3 字节/字），超长标题会写盘失败
    private static let maxNameChars = 80

    static func safeFileName(_ s: String) -> String {
        var cleaned = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: "")
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: "_") }
        var out = cleaned.trimmingCharacters(in: .whitespaces)
        if out.count > maxNameChars { out = String(out.prefix(maxNameChars)) }
        if out.isEmpty || out == "." || out == "_" { out = "untitled" }
        return out
    }

    static func chaptersDir(_ root: URL) -> URL { root.appendingPathComponent("chapters", isDirectory: true) }
    static func chapterDir(_ root: URL, number: Int) -> URL {
        chaptersDir(root).appendingPathComponent(String(format: "ch-%03d", number), isDirectory: true)
    }
    static func canonDir(_ root: URL) -> URL { root.appendingPathComponent("canon", isDirectory: true) }
    static func proposalsFile(_ root: URL) -> URL { root.appendingPathComponent("proposals/inbox.json") }
    /// 已裁决提案归档（热/冷分离：inbox 只存待审，归档不再参与每次保存的重编码）
    static func proposalsArchiveFile(_ root: URL) -> URL { root.appendingPathComponent("proposals/archive.json") }
    static func outlineFile(_ root: URL) -> URL { root.appendingPathComponent("outline.json") }
    /// 大纲三件套落根目录（读与写必须是同一路径——曾因读写不一致导致重启丢故事线）
    static func storylinesFile(_ root: URL) -> URL { root.appendingPathComponent("storylines.json") }
    static func eventsFile(_ root: URL) -> URL { root.appendingPathComponent("events.json") }
    static func stagesFile(_ root: URL) -> URL { root.appendingPathComponent("stages.json") }

    static func cluesFile(_ root: URL) -> URL { root.appendingPathComponent("clues.json") }
    /// 长程记忆：章档案卡
    static func dossiersFile(_ root: URL) -> URL { root.appendingPathComponent("dossiers.json") }
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
    /// 内容签名缓存：同一 URL 写过相同字节就不再落盘。
    /// saveNow 每次保存都重写全部结构文件——大书（数百 canon 节）时这是主线程
    /// 上最大的无谓 I/O（还会触发 FileProvider/iCloud 协调）。
    private struct WriteSignature {
        var hash: Int
        var size: Int
        var mtime: Date?
    }
    private static let signatureLock = NSLock()
    private static var signatures: [String: WriteSignature] = [:]

    static func write(_ data: Data, to url: URL) throws {
        let key = url.path
        let sig = data.hashValue
        // 跳过写的唯一依据必须是「磁盘上现在确实是这份内容」：
        // 文件被删除/被外部改动后，仅凭内存里的内容哈希跳过会让保存变成假成功。
        signatureLock.lock()
        let cached = signatures[key]
        signatureLock.unlock()
        if let cached, cached.hash == sig, cached.size == data.count,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           let writtenAt = cached.mtime,
           abs(mtime.timeIntervalSince(writtenAt)) < 1.0 {
            return
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("." + url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        signatureLock.lock()
        signatures[key] = WriteSignature(hash: sig, size: data.count, mtime: mtime)
        signatureLock.unlock()
    }

    /// 读 JSON：文件不存在 = 正常空档；文件存在但解析失败 = 隔离原文件并返回原因。
    /// 绝不把坏档当成空数组继续跑——下一次保存会用空数组覆盖它。
    static func readJSONOrQuarantine<T: Decodable>(_ type: T.Type, from url: URL,
                                                   label: String) -> (value: T?, note: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            return (try readJSON(type, from: url), nil)
        } catch {
            // 带时间戳，避免第二次损坏把第一次的隔离备份覆盖掉
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let quarantine = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return (nil, "\(label)解析失败（\(error.localizedDescription)），原文件已保留为 \(quarantine.lastPathComponent)，不会用空数据覆盖。")
        }
    }

    /// 外部改动（导入/用户手改/回滚）后让签名失效，强制下次写入落盘
    static func invalidateSignature(_ url: URL) {
        signatureLock.lock(); defer { signatureLock.unlock() }
        signatures.removeValue(forKey: url.path)
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

    /// 读文本。读取失败（含非 UTF-8 编码）时：**把原文件备份为 .corrupt 并返回空串**，
    /// 绝不静默返回空——否则作者第一次敲键盘就会用 saveNow 把原稿覆盖掉。
    /// 返回的第二元素是备份路径（nil = 正常读到的文本）。
    static func readTextOrQuarantine(_ url: URL) -> (text: String, quarantined: URL?) {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return (text, nil)
        }
        // latin1 总能解码：作为兜底显示（不丢内容），同时把原文隔离保留
        let salvage = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        // 时间戳隔离：第二次损坏不能覆盖第一次的备份
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantine = url.appendingPathExtension("corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        return (salvage, quarantine)
    }

    static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
