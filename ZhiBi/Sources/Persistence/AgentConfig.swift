import Foundation
import Security

/// API Key 存 macOS 钥匙串（NarraCat 纪律：凭据不落明文文件）
enum KeychainStore {
    private static let service = "com.zhibi.app.apikey"

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
        ]
        // 清空 key = 删除语义（前置是安全的：没有「删成功、加失败」的中间态）
        guard !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return true
        }
        var attrs = query
        attrs[kSecValueData as String] = data
        // 本机专用：不随整机备份迁移到他人设备
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // update-first：先尝试更新；只有不存在才 add。
        // （旧实现先 Delete 再 Add——add 失败就把旧 key 弄丢了。）
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            return false
        }
        return false
    }

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 传输与模型配置（基座：pi-agent-core 同构核心 + OpenAI 兼容传输；
/// DeepSeek / MiniMax / GLM / Kimi / Ollama 等第三方全部走同一条兼容通道）
struct AgentConfig: Codable {
    var baseURL: String = "https://api.deepseek.com"
    var model: String = "deepseek-flash"
    var apiKey: String = ""   // 仅内存使用；持久化走钥匙串
    var contextTokenBudget: Int = 12000
    var autoSave: Bool = true
    /// 向量模型（OpenAI 兼容 /embeddings）。留空 = 只用本地哈希向量。
    var embeddingModel: String? = nil
    /// 单次 AI 请求硬超时（秒）。可选：旧 settings.json 没有该键时用默认值。
    var requestTimeoutSeconds: Int? = nil

    var effectiveTimeout: Int {
        max(30, min(1800, requestTimeoutSeconds ?? 300))
    }

    /// 上一次 load 的告警（settings.json 损坏被重置等）——设置页展示，不落盘
    static var lastLoadIssue: String?
    /// 上一次钥匙串写入是否失败——保存设置时 UI 提示
    static var lastKeySaveFailed = false

    static func load() -> AgentConfig {
        let url = settingsURL()
        var c: AgentConfig
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                c = try Disk.readJSON(AgentConfig.self, from: url)
                lastLoadIssue = nil
            } catch {
                // 文件在但解析失败：回默认值并告知用户，而不是静默吞掉
                c = AgentConfig()
                lastLoadIssue = "设置文件损坏，已恢复默认值（API Key 不受影响，仍在钥匙串）。可重新保存一次覆盖。"
            }
        } else {
            c = AgentConfig()
            lastLoadIssue = nil
        }
        c.apiKey = KeychainStore.load()
        return c
    }

    func persist() {
        Self.lastKeySaveFailed = !KeychainStore.save(apiKey)
        var c = self
        c.apiKey = ""
        try? Disk.writeJSON(c, to: Self.settingsURL())
    }

    static func settingsURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhiBi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }
}

/// AI 轨迹持久化（跨会话回看；独立小文件，不混进项目数据）
enum TrajectoryStore {
    struct Entry: Codable {
        var at: Date
        var capability: String
        var event: String
        var detail: String
        var isError: Bool
    }

    static func url() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhiBi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-trajectory.json")
    }

    static func load() -> [Entry] {
        // 旧文件可能超过上限：读取时也截到 200，保证面板/内存不会无限增长
        Array(((try? Disk.readJSON([Entry].self, from: url())) ?? []).prefix(200))
    }

    static func save(_ entries: [Entry]) {
        try? Disk.writeJSON(Array(entries.prefix(200)), to: url())
    }
}

/// 项目注册表（多书管理）
enum ProjectRegistry {
    static func registryURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhiBi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("registry.json")
    }

    static func load() -> [ProjectRef] {
        (try? Disk.readJSON([ProjectRef].self, from: registryURL())) ?? []
    }

    static func save(_ projects: [ProjectRef]) {
        try? Disk.writeJSON(projects, to: registryURL())
    }
}
