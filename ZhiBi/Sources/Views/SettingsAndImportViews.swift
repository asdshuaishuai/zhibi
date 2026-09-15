import SwiftUI

// MARK: - 导入预览（作者逐项确认后再入库）

struct ImportPreviewSheet: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导入预览").font(.headline)
                if let s = vm.importPreview {
                    Text(s.detectedLayout)
                        .font(.caption).foregroundStyle(.teal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.teal.opacity(0.1))
                        .cornerRadius(6)
                }
                Spacer()
            }

            Toggle("导入为新书", isOn: $vm.importTargetNewProject)
                .font(.callout)
            if vm.importTargetNewProject {
                TextField("新书名", text: $vm.importNewProjectTitle)
                    .textFieldStyle(.roundedBorder)
            } else if let store = vm.store {
                Text("并入当前作品：\(store.project.title)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("当前没有打开的作品，请选择「导入为新书」。").font(.caption).foregroundStyle(.orange)
            }

            if let s = vm.importPreview {
                Text("识别到 \(s.chapters) 章 · \(s.canon) 份设定 · \(s.outlines) 份大纲")
                    .font(.callout.bold())
                Table(of: ImportItem.self, selection: .constant(Set<ImportItem.ID>())) {
                    TableColumn("类型") { item in
                        Picker("", selection: Binding(
                            get: { item.kind },
                            set: { vm.setItemKind(item, $0) })) {
                            ForEach([ImportItem.Kind.chapter, .canon, .outline, .skip], id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.mini)
                    }.width(90)
                    TableColumn("来源") { item in Text(item.sourceName).font(.caption) }
                    TableColumn("标题") { item in Text(item.title).font(.caption) }
                    TableColumn("字数") { item in Text("\(WordStats.chineseCount(item.content))").font(.caption.monospacedDigit()) }.width(70)
                } rows: {
                    ForEach(vm.importPreview?.items ?? []) { item in
                        TableRow(item)
                    }
                }
            }

            HStack {
                Text("导入不会改动你的原目录；结构化伏笔/时间线建议导入后用「AI 盘点伏笔」「AI 建时间线」提案重建。")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                Button("确认导入") {
                    if vm.importTargetNewProject {
                        vm.confirmImport()
                    } else if let store = vm.store {
                        vm.confirmImport(intoExisting: store)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 780, height: 560)
    }
}

extension AppViewModel {
    fileprivate func setItemKind(_ item: ImportItem, _ kind: ImportItem.Kind) {
        guard var preview = importPreview,
              let idx = preview.items.firstIndex(where: { $0.id == item.id }) else { return }
        preview.items[idx].kind = kind
        importPreview = preview
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var vm: AppViewModel

    private let presets: [(name: String, baseURL: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-flash"),
        ("DeepSeek Pro", "https://api.deepseek.com", "deepseek-v4-pro"),
        ("MiniMax M3", "https://api.minimax.cn/v1", "MiniMax-M3"),
        ("MiniMax 高速", "https://api.minimax.cn/v1", "MiniMax-M2.7-highspeed"),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash"),
        ("月之暗面 Kimi", "https://api.moonshot.cn/v1", "moonshot-v1-32k"),
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
        ("本地 Ollama", "http://127.0.0.1:11434/v1", "qwen2.5:14b"),
    ]

    var body: some View {
        Form {
            Section("写作目标") {
                Stepper("每日目标：\(vm.dailyGoal) 字", value: $vm.dailyGoal, in: 200...20000, step: 100)
            }
            Section("外观") {
                Picker("主题", selection: $vm.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Agent 基座（OpenAgentSDK）") {
                Text("核心为 OpenAgentSDK：工具循环、流式与供应商传输都在本地进程内跑；模型侧走 OpenAI 兼容通道，DeepSeek / MiniMax / GLM / Kimi / Ollama 换 baseURL 即换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("模型服务（OpenAI 兼容）") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(presets, id: \.name) { p in
                        Button(p.name) {
                            vm.config.baseURL = p.baseURL
                            vm.config.model = p.model
                        }
                        .controlSize(.small)
                    }
                }
                TextField("Base URL", text: $vm.config.baseURL)
                TextField("模型 ID（如 deepseek-v4-pro / MiniMax-M2.5）", text: $vm.config.model)
                SecureField("API Key（保存到 macOS 钥匙串，不落明文文件）", text: $vm.config.apiKey)
                Text("MiniMax 的思考内容（<think>）会在运行预览里自动过滤。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Section("生成与上下文") {
                Stepper("上下文包预算：≈\(vm.config.contextTokenBudget) tokens", value: $vm.config.contextTokenBudget, in: 2000...32000, step: 1000)
                Toggle("正文自动保存（永远先落盘）", isOn: $vm.config.autoSave)
            }
            HStack {
                Spacer()
                Button("保存设置") {
                    vm.saveConfig()
                    vm.store?.autoSaveEnabled = vm.config.autoSave
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(0)
        .frame(width: 560, height: 480)
    }
}
