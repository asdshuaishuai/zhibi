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
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var attrs = query
        attrs[kSecValueData as String] = data
        // 本机专用：不随整机备份迁移到他人设备
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            assertionFailure("Keychain 写入失败：\(status)")
            return false
        }
        return true
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
    var temperature: Double = 0.5
    var contextTokenBudget: Int = 12000
    var autoSave: Bool = true

    static func load() -> AgentConfig {
        var c = (try? Disk.readJSON(AgentConfig.self, from: settingsURL())) ?? AgentConfig()
        c.apiKey = KeychainStore.load()
        return c
    }

    func persist() {
        KeychainStore.save(apiKey)
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
