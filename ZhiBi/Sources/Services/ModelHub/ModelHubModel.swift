import SwiftUI

/// 模型目录选择器状态机：拉目录 → 选供应商 → 选模型 → 写回 AgentConfig。
/// 选型只落 (baseURL, model) 两个字段——基座与传输层对目录零感知。
@MainActor
final class ModelHubModel: ObservableObject {
    @Published var providers: [ModelHub.Provider] = []
    @Published var state: ModelHub.CatalogState = .idle
    @Published var providerID: String = ""          // "" = 自定义端点（不来自目录）
    @Published var modelID: String = ""

    var onPick: ((ModelHub.Entry) -> Void)?

    /// 当前供应商的候选模型（默认只展示支持工具调用的；可展开全部）
    func modelEntries(toolCallOnly: Bool) -> [ModelHub.Model] {
        guard let p = providers.first(where: { $0.id == providerID }) else { return [] }
        return toolCallOnly ? p.models.filter(\.toolCall) : p.models
    }

    var providerEntryCount: String {
        guard let p = providers.first(where: { $0.id == providerID }) else { return "" }
        let usable = p.models.filter(\.toolCall).count
        return "\(usable)/\(p.models.count) 支持工具调用"
    }

    /// 打开设置时按现有配置反查目录选中项（对不上则视为自定义端点）
    func syncSelection(baseURL: String, model: String) {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for p in providers {
            if p.baseURL == normalized, p.models.contains(where: { $0.id == model }) {
                providerID = p.id
                modelID = model
                return
            }
        }
        providerID = ""
        modelID = ""
    }

    func selectProvider(_ id: String, config: AgentConfig) {
        providerID = id
        guard let p = providers.first(where: { $0.id == id }) else { return }
        // 自动选第一个支持工具调用的模型（若无则第一个）
        let model = p.models.first(where: \.toolCall) ?? p.models.first
        if let model {
            modelID = model.id
            onPick?(ModelHub.Entry(
                providerID: p.id, providerName: p.name, baseURL: p.baseURL,
                modelID: model.id, modelName: model.name,
                toolCall: model.toolCall, reasoning: model.reasoning,
                contextLimit: model.contextLimit,
                inputCost: model.inputCost, outputCost: model.outputCost))
        }
    }

    func selectModel(_ id: String) {
        modelID = id
        guard let p = providers.first(where: { $0.id == providerID }),
              let m = p.models.first(where: { $0.id == id }) else { return }
        onPick?(ModelHub.Entry(
            providerID: p.id, providerName: p.name, baseURL: p.baseURL,
            modelID: m.id, modelName: m.name,
            toolCall: m.toolCall, reasoning: m.reasoning,
            contextLimit: m.contextLimit,
            inputCost: m.inputCost, outputCost: m.outputCost))
    }

    func refresh() {
        state = .loading
        Task {
            let (providers, state) = await ModelHub.loadCatalog(forceRefresh: true)
            self.providers = providers
            self.state = state
        }
    }

    func loadInitial() {
        guard providers.isEmpty else { return }
        state = .loading
        Task {
            let (providers, state) = await ModelHub.loadCatalog()
            self.providers = providers
            self.state = state
        }
    }
}

/// 目录状态一行字
extension ModelHub.CatalogState {
    var summary: String {
        switch self {
        case .idle: return "未加载"
        case .loading: return "加载中…"
        case .loaded(let date, let source):
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            let tag = source == .network ? "目录" : "缓存"
            return "\(tag)更新于 \(fmt.string(from: date))"
        case .failed(let message): return "离线（\(message.prefix(40)))"
        }
    }
}
