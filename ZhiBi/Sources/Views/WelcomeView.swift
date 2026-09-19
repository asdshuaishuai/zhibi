import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ZStack {
            switch vm.screen {
            case .welcome:
                WelcomeView(vm: vm)
            case .project:
                if let store = vm.store {
                    ProjectWorkspaceView(vm: vm, store: store)
                }
            }
        }
        .sheet(isPresented: $vm.showImportPreview) {
            ImportPreviewSheet(vm: vm)
        }
        .fileImporter(isPresented: $vm.requestImportViaPanel,
                      allowedContentTypes: [.text, .utf8PlainText, .data, .folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                vm.beginImport(urls: urls)
            }
        }
    }
}

// MARK: - 欢迎页

enum ShelfLayout: String, CaseIterable {
    case grid = "网格"
    case shelf = "书架"
    case list = "列表"
}

struct WelcomeView: View {
    @ObservedObject var vm: AppViewModel
    @AppStorage("shelfLayout") private var shelfLayout: ShelfLayout = .grid
    @State private var showCreate = false
    @State private var projectPendingDelete: ProjectRef?
    @State private var newTitle = ""
    @State private var newGenre = ""
    @State private var newPremise = ""
    @State private var buildFramework = true

    /// 常用题材快选（点一下填入，可再手改）
    static let genreChips = ["东方玄幻", "都市异能", "科幻末世", "悬疑推理", "历史权谋", "仙侠修真", "无限流", "言情世情"]

    var body: some View {
        HStack(spacing: 0) {
            // 左侧品牌区：墨色渐变 + 朱砂印
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                HStack(alignment: .center, spacing: 14) {
                    Text("执笔")
                        .font(.system(size: 56, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [ZB.vermillion, ZB.vermillionDeep], startPoint: .top, endPoint: .bottom))
                        Text("执")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(-4))
                }
                Text("人写正文，AI 理账。")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1).padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 13) {
                    featureRow("bone.fill", "AI 搭骨架", "时间线、章节骨架、关键节点由 AI 提案，作者修改批准")
                    featureRow("wand.and.stars", "AI 一键成章", "给一条主线就出整章草稿：审查→修复→记忆/文风审查→采纳入库")
                    featureRow("pencil.line", "人亲笔写作", "所见即所得的富文本手写——与 AI 成章并行，随时切换，字句永远是你的")
                    featureRow("link", "伏笔与记忆中枢", "线索埋点、双时态事实，写到 100 章不忘第 3 章的钩子")
                    featureRow("checkmark.seal", "一键验证 · 一键召回", "一致性体检与上下文召回，只报告不代笔")
                    featureRow("sparkles", "去AI味", "叙事架构→篇章→措辞三 pass，配模型指纹与确定性扫描")
                }
                Spacer()
                Text("本地 Markdown 为王 · API Key 存钥匙串")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(44)
            .frame(minWidth: 380, idealWidth: 470, maxWidth: 520)
            .alert("打不开", isPresented: Binding(
                get: { vm.projectOpenError != nil },
                set: { if !$0 { vm.projectOpenError = nil } })) {
                Button("好") {}
            } message: {
                Text(vm.projectOpenError ?? "")
            }
            .background(
                ZStack {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.115, blue: 0.105),
                                            Color(red: 0.075, green: 0.07, blue: 0.065)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [ZB.vermillion.opacity(0.16), .clear],
                                   center: .topLeading, startRadius: 20, endRadius: 560)
                }
            )

            Divider()

            // 右侧书架：国风背景 + 微信读书式封面卡牌
            ZStack {
                GuofengBackground()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("我的书架").font(.headline)
                        if !vm.projects.isEmpty {
                            Text("共 \(vm.projects.count) 本").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("", selection: $shelfLayout) {
                            ForEach(ShelfLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                        Button {
                            showCreate = true
                        } label: {
                            Label("新建作品", systemImage: "plus")
                        }
                        .zbGlassButton(prominent: true)
                        Button {
                            vm.requestImportViaPanel = true
                        } label: {
                            Label("导入", systemImage: "square.and.arrow.down")
                        }
                        .zbGlassButton()
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                    if vm.projects.isEmpty {
                        VStack(spacing: 12) {
                            BookCoverTile(title: "始", size: 92)
                            Text("书架是空的").font(.title3).bold()
                            Text("新建一本，或导入你已有的 大纲 / 设定 / 追踪 / 正文 目录。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        shelfContent
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .confirmationDialog("删除《\(projectPendingDelete?.title ?? "")》？", isPresented: Binding(
            get: { projectPendingDelete != nil },
            set: { if !$0 { projectPendingDelete = nil } })) {
            Button("移到废纸篓（可恢复）", role: .destructive) {
                if let ref = projectPendingDelete { vm.deleteProject(ref) }
                projectPendingDelete = nil
            }
        } message: {
            Text("整本书会移到废纸篓，需要时可从废纸篓找回。")
        }
    }

    @ViewBuilder
    private var shelfContent: some View {
        let books = vm.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        switch shelfLayout {
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 176), spacing: 26)],
                          spacing: 30) {
                    ForEach(books) { ref in
                        ShelfBookCard(ref: ref, onOpen: { vm.openProject(ref) },
                                      onReveal: { NSWorkspace.shared.activateFileViewerSelecting([ref.url]) },
                                      onDelete: { projectPendingDelete = ref },
                                      onCycleStyle: { await vm.cycleCoverStyle(for: ref) })
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        case .shelf:
            ScrollView {
                let rows = stride(from: 0, to: books.count, by: 4).map {
                    Array(books[$0..<min($0 + 4, books.count)])
                }
                LazyVStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(alignment: .bottom, spacing: 30) {
                            ForEach(rows[r]) { ref in
                                ShelfBookCard(ref: ref, onOpen: { vm.openProject(ref) },
                                              onReveal: { NSWorkspace.shared.activateFileViewerSelecting([ref.url]) },
                                              onDelete: { projectPendingDelete = ref },
                                              onCycleStyle: { await vm.cycleCoverStyle(for: ref) })
                            }
                        }
                        .padding(.horizontal, 26)
                        // 书架层板
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(colors: [ZB.hairline.opacity(0.55), ZB.hairline.opacity(0.25)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(height: 8)
                                .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
                            Rectangle().fill(.white.opacity(0.25)).frame(height: 1).offset(y: -3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        case .list:
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(books) { ref in
                        ShelfListRow(ref: ref,
                                     onOpen: { vm.openProject(ref) },
                                     onReveal: { NSWorkspace.shared.activateFileViewerSelecting([ref.url]) },
                                     onDelete: { projectPendingDelete = ref })
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(ZB.vermillion.opacity(0.85)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold().foregroundStyle(.white)
                Text(desc).font(.caption).foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var shelfFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }
}

// MARK: - 书架卡牌（微信读书式：封面竖排书名 + 章节字数速览）

struct ShelfStats {
    var chapters: Int = 0
    var words: Int = 0
    /// 全书目标字数（目标章数 × 每章目标），用于卡牌底部进度条
    var target: Int?
}

struct ShelfBookCard: View {
    let ref: ProjectRef
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    var onCycleStyle: () async -> Int? = { nil }

    @State private var stats: ShelfStats?
    @State private var style: Int?
    @State private var hovering = false
    @State private var openingFlag = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedStyle: Int { style ?? CoverStyle.defaultIndex(for: ref.title) }

    var body: some View {
        VStack(spacing: 9) {
            cover
                .shadow(color: .black.opacity(hovering ? 0.32 : 0.2), radius: hovering ? 12 : 7, x: 0, y: hovering ? 7 : 4)
                .scaleEffect(hovering ? 1.035 : 1)
            VStack(spacing: 2) {
                Text(ref.title)
                    .font(.callout.bold())
                    .lineLimit(1)
                Text(statsCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(hovering && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: hovering)
        .onTapGesture { onOpen() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在访达中显示") { onReveal() }
            Divider()
            Button("删除…", role: .destructive) { onDelete() }
        }
        .task {
            stats = await loadStats(url: ref.url)
            style = await loadCoverStyle(url: ref.url)
            if let meta = await loadProjectMetaAsync(url: ref.url) {
                let target = max(1, meta.targetChapters) * max(1, meta.chapterWordTarget)
                await MainActor.run { stats?.target = target }
            }
        }
    }

    private var progressFraction: Double? {
        guard let stats, let target = stats.target, target > 0 else { return nil }
        return min(1.0, Double(stats.words) / Double(target))
    }

    private var cover: some View {
        BookCover(title: ref.title, style: resolvedStyle, width: 132, height: 182)
            .overlay(alignment: .bottom) {
                if let frac = progressFraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.35)).frame(height: 3)
                            Rectangle()
                                .fill(frac >= 1.0 ? Color.green : .white)
                                .frame(width: geo.size.width * CGFloat(frac), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button {
                        Task { style = await onCycleStyle() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .help("换一种封面")
                    .transition(.opacity)
                    .padding(6)
                }
            }
    }

    private var statsCaption: String {
        if let stats, stats.chapters > 0 {
            return "\(stats.chapters) 章 · \(stats.words) 字"
        }
        return Self.shelfFormatter.string(from: ref.lastOpenedAt)
    }

    private nonisolated func loadStats(url: URL) async -> ShelfStats {
        ShelfBookCard.loadStats(url: url)
    }

    private nonisolated func loadProjectMetaAsync(url: URL) async -> NovelProject? {
        ShelfBookCard.loadProjectMeta(url: url)
    }

    private nonisolated func loadCoverStyle(url: URL) async -> Int? {
        ShelfBookCard.loadProjectMeta(url: url)?.coverStyle
    }

    private nonisolated static func loadProjectMeta(url: URL) -> NovelProject? {
        let file = url.appendingPathComponent("project.json")
        return try? Disk.readJSON(NovelProject.self, from: file)
    }

    private static let shelfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    /// 轻量统计：读各章 meta.json 的缓存字数（异步，不卡书架）
    static func loadStats(url: URL) -> ShelfStats {
        var result = ShelfStats()
        let chaptersDir = url.appendingPathComponent("chapters", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: chaptersDir, includingPropertiesForKeys: nil) else {
            return result
        }
        for dir in dirs where dir.lastPathComponent.hasPrefix("ch-") {
            let meta = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let ch = try? Disk.readJSON(ChapterMeta.self, from: meta) else { continue }
            let words = ch.cachedWords ?? 0
            if words > 0 { result.chapters += 1 }
            result.words += words
        }
        return result
    }
}

// MARK: - 列表模式行

struct ShelfListRow: View {
    let ref: ProjectRef
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var stats: ShelfStats?
    @State private var openingFlag = false

    var body: some View {
        HStack(spacing: 12) {
            BookCover(title: ref.title, style: CoverStyle.defaultIndex(for: ref.title), width: 42, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.title).font(.callout.bold()).lineLimit(1)
                if let stats, stats.chapters > 0 {
                    Text("\(stats.chapters) 章 · \(stats.words) 字").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(ref.url.deletingPathExtension().lastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button("打开") { onOpen() }
                .zbGlassButton(prominent: true)
                .controlSize(.small)
            Menu {
                Button("在访达中显示") { onReveal() }
                Divider()
                Button("删除…", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
        .padding(10)
        .zbGlass(cornerRadius: 12, interactive: true)
        .contentShape(Rectangle())
        .onTapGesture {
            openingFlag = true
            onOpen()
        }
        .task { stats = await Task.detached { ShelfBookCard.loadStats(url: ref.url) }.value }
        .opacity(openingFlag ? 0.5 : 1)
    }
}

extension WelcomeView {
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建作品").font(.headline)
            Text("只填书名就能开写。给 AI 的原料越具体，框架越准——但也可以后补。")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                TextField("书名", text: $newTitle)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("题材").font(.caption).foregroundStyle(.secondary)
                    FlowChipRow(items: Self.genreChips, selected: $newGenre)
                    TextField("或自填（如：赛博江湖）", text: $newGenre)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("一句话核心（AI 的第一原料）").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $newPremise)
                        .font(.callout)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }

            Toggle("创建后用 AI 搭建框架（主线大纲 + 背景设定）", isOn: $buildFramework)
                .font(.callout)
                .disabled(vm.config.apiKey.isEmpty)
            Text(vm.config.apiKey.isEmpty
                 ? "先在「设置」里配置 API Key 才能用 AI 搭框架；也可以先空手创建。"
                 : "框架全部走提案：AI 只出方案，你在「提案收件箱」逐条审过才算数。")
                .font(.caption2).foregroundStyle(vm.config.apiKey.isEmpty ? Color.orange : Color.secondary)

            HStack {
                Spacer()
                Button("取消") { showCreate = false }
                Button("创建") {
                    let title = newTitle.isEmpty ? "未命名作品" : newTitle
                    vm.createProject(title: title, genre: newGenre, premise: newPremise,
                                     wordTarget: 3000, buildFramework: buildFramework && !vm.config.apiKey.isEmpty)
                    showCreate = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTitle.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// 换行流式 chips（自适应网格，选中态高亮）
struct FlowChipRow: View {
    let items: [String]
    @Binding var selected: String

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(item) {
                    selected = (selected == item) ? "" : item
                }
                .font(.caption)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(selected == item ? Color.accentColor : Color.secondary)
            }
        }
    }
}

// MARK: - 国风背景（宣纸 + 远山）

struct GuofengBackground: View {
    var body: some View {
        ZStack {
            // 宣纸底
            ZB.canvas
            LinearGradient(colors: [ZB.paper.opacity(0.7), ZB.canvas.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
            // 远山两层（水墨剪影）
            Canvas { context, size in
                func mountains(seed: Int, height: CGFloat, alpha: Double) -> Path {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    let steps = 32
                    for i in 0...steps {
                        let t = Double(i) / Double(steps)
                        let x = size.width * t
                        let y = size.height * 0.86
                            - height * (0.6 + 0.4 * sin(t * 5.2 + Double(seed)))
                            - height * 0.25 * sin(t * 11.3 + Double(seed * 3))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    return path
                }
                let far = ZB.dynamic(light: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.52, alpha: 1),
                                     dark: NSColor(white: 0.82, alpha: 1))
                let near = ZB.dynamic(light: NSColor(srgbRed: 0.30, green: 0.34, blue: 0.38, alpha: 1),
                                      dark: NSColor(white: 0.65, alpha: 1))
                context.fill(mountains(seed: 1, height: size.height * 0.10, alpha: 1),
                             with: .color(far.opacity(0.07)))
                context.fill(mountains(seed: 4, height: size.height * 0.06, alpha: 1),
                             with: .color(near.opacity(0.10)))
            }
        }
    }
}

extension String {
    func replacingLastPathComponent() -> String {
        (self as NSString).deletingLastPathComponent
    }
}
