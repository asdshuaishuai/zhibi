import SwiftUI

// MARK: - 记忆中枢（Agent 记忆模组）：事实账本 / 矛盾体检 / 人物归一

struct MemoryView: View {
    @ObservedObject var store: ProjectStore
    var vm: AppViewModel?

    enum Tab: String, CaseIterable {
        case ledger = "事实账本"
        case conflicts = "矛盾体检"
        case subjects = "人物归一"
        case dossiers = "长程档案"
    }

    @State private var tab: Tab = .ledger
    @State private var showReaderOnly = false
    @State private var atChapter = 9999   // 9999 = 尚未初始化；onAppear 落到当前章
    @State private var searchText = ""
    @State private var consolidationNote: String?
    @State private var newAliasTarget = ""
    @State private var newAliasInput = ""
    @State private var pendingDeleteFactID: UUID?
    @State private var confirmConsolidate = false

    private var stats: MemoryHub.LedgerStats { MemoryHub.ledgerStats(store: store) }

    private var visibleFacts: [MemoryFact] {
        store.facts
            .filter { $0.isValid(atChapter: atChapter) }
            .filter { showReaderOnly ? $0.publicToReader : true }
            .filter { searchText.isEmpty || "\($0.subject)\($0.predicate)\($0.object)".localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.fromChapter < $1.fromChapter }
    }

    private var openConflicts: [MemoryHub.Conflict] {
        let dismissed = Set(store.dismissedConflicts ?? [])
        return MemoryHub.conflicts(store.facts).filter { !dismissed.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsBar
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            .padding(10)

            switch tab {
            case .ledger: ledgerTab
            case .conflicts: conflictsTab
            case .subjects: subjectsTab
            case .dossiers: dossiersTab
            }
        }
        .background(ZB.canvas)
        .onAppear {
            if atChapter == 9999 { atChapter = max(1, store.currentChapter - 1) }
        }
        // 两个操作共用同一个弹窗：同一视图挂两个 confirmationDialog 会互相抢呈现
        .confirmationDialog(pendingDeleteFactID != nil ? "删除这条事实？" : "整理事实账本？",
                            isPresented: Binding(
                                get: { pendingDeleteFactID != nil || confirmConsolidate },
                                set: { if !$0 { pendingDeleteFactID = nil; confirmConsolidate = false } })) {
            if let id = pendingDeleteFactID {
                Button("删除", role: .destructive) {
                    store.facts.removeAll { $0.id == id }
                    store.saveSoon()
                    pendingDeleteFactID = nil
                }
            } else {
                Button("整理") {
                    let result = MemoryHub.consolidate(facts: store.facts, aliases: store.characterAliases)
                    store.facts = result.facts
                    consolidationNote = result.report.summary
                    store.saveSoon()
                    vm?.showToast("账本已整理：\(result.report.summary)")
                    confirmConsolidate = false
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteFactID = nil
                confirmConsolidate = false
            }
        } message: {
            Text(pendingDeleteFactID != nil
                 ? "只从事实账本删除，不改正文。删除后无法撤销。"
                 : "会清除完全重复事实、按别名归并主语；有效事实不会被删除。此操作没有撤销。")
        }
    }

    // MARK: 头部 + 统计

    private var header: some View {
        HStack {
            Image(systemName: "brain")
                .foregroundStyle(Color.accentColor)
            Text("记忆中枢").font(.headline)
            Text("AI 提取 → 作者验收 → 在此统一整理 → 写作时按预算回灌 agent")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button {
                confirmConsolidate = true
            } label: {
                Label("一键整理（本地）", systemImage: "wand.and.rays")
            }
            .controlSize(.small)
            .help("去重 + 按别名归一主语；不删除有效事实")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statsBar: some View {
        HStack(spacing: 18) {
            stat("总事实", "\(stats.totalFacts)")
            stat("有效", "\(stats.activeFacts)", color: .green)
            stat("已失效", "\(stats.invalidated)", color: .secondary)
            stat("暗线（读者未知）", "\(stats.hiddenFromReader)", color: .orange)
            stat("人物", "\(stats.subjects)")
            stat("章摘要", "\(stats.summaries)")
            Spacer()
            if let note = consolidationNote {
                Text("✓ \(note)").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: 页签 1：事实账本

    // MARK: 长程档案（跨全书检索记忆）

    @State private var dossierQuery = ""
    @State private var dossierQueryDebounced = ""
    @State private var dossierDebounce: _Concurrency.Task<Void, Never>?

    private var dossiersTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ZBSpace.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("检索：人物 / 物件 / 地名 / 任意词（跨全书档案卡）", text: $dossierQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: dossierQuery) { q in
                        dossierDebounce?.cancel()
                        dossierDebounce = _Concurrency.Task {
                            try? await _Concurrency.Task.sleep(nanoseconds: 200_000_000)
                            guard !_Concurrency.Task.isCancelled else { return }
                            await MainActor.run { dossierQueryDebounced = q }
                        }
                    }
                if let vm {
                    // currentChapter 是"下一章"（还没写）；这里要的是最后一个有正文的章
                    let lastWritten = store.chapters.last { !$0.prose.isEmpty }?.number
                    Button("提取最新章档案卡") {
                        if let n = lastWritten {
                            Task { await vm.ai.runDossierExtract(store: store, config: vm.config, chapter: n) }
                        }
                    }
                    .controlSize(.small)
                    .disabled(vm.ai.running || lastWritten == nil)
                    .help("对最近写完的章跑一次档案提取（提案，采纳后入检索库）")
                }
            }
            .padding(10)

            Divider()

            if store.dossiers.isEmpty {
                VStack(spacing: ZBSpace.sm) {
                    Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有档案卡").font(.headline)
                    Text("档案卡是每章的跨全书检索记忆：场景/人物/推进/悬念/关键物件与台词。\n写完后在章节编辑器「AI 协作 → 提取档案卡」或上方按钮生成，采纳后入此库。")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let results: [ChapterDossier] = dossierQueryDebounced.isEmpty
                        ? store.dossiers.sorted { $0.chapter > $1.chapter }
                        : DossierIndex.cached(for: store.dossiers).search(dossierQueryDebounced, limit: 30)
                    LazyVStack(alignment: .leading, spacing: ZBSpace.xs) {
                        if !dossierQueryDebounced.isEmpty {
                            Text("命中 \(results.count) 章").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(results) { d in
                            dossierCard(d)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func dossierCard(_ d: ChapterDossier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("第\(d.chapter)章").font(.caption.bold()).foregroundStyle(Color.accentColor)
                Text(d.headline).font(.callout)
                Spacer()
            }
            if !d.cast.isEmpty {
                Text("出场：" + d.cast.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !d.relics.isEmpty {
                Text("细节：" + d.relics.joined(separator: "；"))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if !d.hooks.isEmpty {
                Text("悬念：" + d.hooks.joined(separator: "；"))
                    .font(.caption2).foregroundStyle(.orange.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(ZBSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZB.card)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZB.hairline.opacity(0.7)))
    }

    private var ledgerTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索主语 / 谓词 / 宾语", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Toggle("仅读者视角", isOn: $showReaderOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Stepper("截至第 \(atChapter) 章", value: $atChapter, in: 1...max(1, store.currentChapter))
                    .font(.caption)
                    .help("只显示在这个章号之前仍然有效的事实")
                Spacer()
                Button("新增事实") {
                    store.facts.append(MemoryFact(fromChapter: atChapter, source: "authored"))
                    store.saveSoon()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Table(of: MemoryFact.self, selection: .constant(Set<MemoryFact.ID>())) {
                TableColumn("主语") { f in TextField("", text: Binding(
                    get: { factByID(f.id)?.subject ?? f.subject },
                    set: { newValue in mutate(f.id) { m in m.subject = newValue } })).font(.callout) }
                TableColumn("谓词") { f in
                    TextField("", text: Binding(
                        get: { factByID(f.id)?.predicate ?? f.predicate },
                        set: { newValue in mutate(f.id) { m in m.predicate = newValue } })).font(.caption)
                }.width(80)
                TableColumn("宾语") { f in TextField("", text: Binding(
                    get: { factByID(f.id)?.object ?? f.object },
                    set: { newValue in mutate(f.id) { m in m.object = newValue } })).font(.callout) }
                TableColumn("起始章") { f in
                    Text("第\(f.fromChapter)章").font(.caption.monospacedDigit())
                }.width(70)
                TableColumn("失效章") { f in
                    HStack {
                        Text(f.invalidatedAtChapter.map { "第\($0)章" } ?? "有效").font(.caption.monospacedDigit())
                            .foregroundStyle(f.invalidatedAtChapter == nil ? Color.green : Color.secondary)
                        if f.invalidatedAtChapter == nil {
                            Button("标记失效") {
                                mutate(f.id) { $0.invalidatedAtChapter = atChapter }
                            }
                            .buttonStyle(.borderless).controlSize(.mini)
                        }
                    }
                }.width(120)
                TableColumn("读者") { f in
                    Text(f.publicToReader ? "已知" : "暗线").font(.caption)
                        .foregroundStyle(f.publicToReader ? Color.secondary : Color.orange)
                }.width(56)
                TableColumn("来源") { f in
                    Text(f.source == "authored" ? "作者钦定" : "提取").font(.caption2).foregroundStyle(.tertiary)
                }.width(70)
                TableColumn("") { f in
                    Button(role: .destructive) {
                        pendingDeleteFactID = f.id
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.mini)
                    .accessibilityLabel("删除这条事实")
                }.width(36)
            } rows: {
                ForEach(visibleFacts) { f in
                    TableRow(f)
                }
            }
        }
    }

    // MARK: 页签 2：矛盾体检

    private var conflictsTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let dismissed = store.dismissedConflicts, !dismissed.isEmpty {
                    HStack {
                        Text("已忽略 \(dismissed.count) 组矛盾提醒").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Button("恢复提醒") {
                            store.dismissedConflicts = []
                            store.saveSoon()
                            vm?.showToast("已恢复全部矛盾提醒")
                        }
                        .controlSize(.mini)
                    }
                }
                if openConflicts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(.system(size: 34)).foregroundStyle(.green)
                        Text("没有待裁决矛盾。").font(.callout).foregroundStyle(.secondary)
                        Text("同一主语同一谓词出现不同宾语时会在这里列出（如『紫渊 位于 临渊区』vs『紫渊 位于 界壁边缘』）。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                ForEach(openConflicts) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ZBChip(text: "\(c.subject) · \(c.predicate)", color: .orange)
                            Spacer()
                            Button("保留两条（不再提醒）") { dismissConflict(c) }
                                .controlSize(.small)
                        }
                        ForEach(c.values, id: \.object) { v in
                            HStack {
                                Text("「\(v.object)」").font(.callout)
                                Text("第\(v.chapter)章起").font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                                Button("以此为准（失效其余）") {
                                    resolveConflict(c, keeping: v.factIDs)
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                    .zbCard()
                }
            }
            .padding(14)
        }
    }

    private func resolveConflict(_ c: MemoryHub.Conflict, keeping keepIDs: [UUID]) {
        let keepSet = Set(keepIDs)
        let others = c.values.flatMap(\.factIDs).filter { !keepSet.contains($0) }
        for id in others {
            if let idx = store.facts.firstIndex(where: { $0.id == id }) {
                store.facts[idx].invalidatedAtChapter = atChapter == 9999 ? (store.facts[idx].fromChapter + 1) : atChapter
            }
        }
        store.saveSoon()
        vm?.showToast("已以此为准，其余事实标记为失效")
    }

    private func dismissConflict(_ c: MemoryHub.Conflict) {
        var list = store.dismissedConflicts ?? []
        list.append(c.id)
        store.dismissedConflicts = list
        store.saveSoon()
        vm?.showToast("已保留两条，并隐藏这组提醒")
    }

    // MARK: 页签 3：人物归一

    private var subjectCounts: [(name: String, count: Int)] {
        Dictionary(grouping: store.facts, by: \.subject)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var subjectsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("把同一人物的多种称呼合并到本名：").font(.caption).foregroundStyle(.secondary)
                TextField("别名（如 小晨）", text: $newAliasInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .font(.caption)
                TextField("归属本名（如 江晨）", text: $newAliasTarget)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .font(.caption)
                Button("添加别名") {
                    let alias = newAliasInput.trimmingCharacters(in: .whitespaces)
                    let target = newAliasTarget.trimmingCharacters(in: .whitespaces)
                    guard !alias.isEmpty, !target.isEmpty else { return }
                    if let idx = store.characterAliases.firstIndex(where: { $0.canonicalName == target }) {
                        if !store.characterAliases[idx].aliases.contains(alias) {
                            store.characterAliases[idx].aliases.append(alias)
                        }
                    } else {
                        store.characterAliases.append(CharacterAlias(canonicalName: target, aliases: [alias]))
                    }
                    let result = MemoryHub.unifySubjects(store.facts, aliases: store.characterAliases)
                    store.facts = result.facts
                    consolidationNote = "已归一 \(result.renamed) 处主语"
                    newAliasInput = ""
                    newAliasTarget = ""
                    store.saveSoon()
                }
                .controlSize(.small)
                .disabled(newAliasInput.isEmpty || newAliasTarget.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(subjectCounts, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.name).font(.callout.bold())
                                Spacer()
                                ZBChip(text: "\(entry.count) 条", color: .accentColor)
                            }
                            let aliasList = store.characterAliases.first { $0.canonicalName == entry.name }?.aliases ?? []
                            if !aliasList.isEmpty {
                                Text("别名：\(aliasList.joined(separator: "／"))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(store.facts.filter { $0.subject == entry.name && $0.isValid(atChapter: 9999) }
                                .sorted { $0.fromChapter < $1.fromChapter }
                                .suffix(2)
                                .map { "\($0.predicate)\($0.object)" }
                                .joined(separator: "；"))
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zbCard(padding: 10)
                    }
                }
                .padding(14)
            }
        }
    }

    /// 字典预查：Table 每行多列调用它。用规模签名缓存（原实现是计算属性，
    /// 每次查表重建整个字典 —— 500 行 × 3 列 = 1500 次/body）
    @State private var factIndexCache: [UUID: MemoryFact] = [:]
    @State private var factIndexStamp = Int.min

    private func ensureFactIndex() -> [UUID: MemoryFact] {
        let stamp = store.facts.count &* 131 &+ store.facts.reduce(0) { $0 &+ $1.fromChapter }
        if stamp != factIndexStamp {
            factIndexStamp = stamp
            factIndexCache = Dictionary(store.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return factIndexCache
    }

    private func factByID(_ id: UUID) -> MemoryFact? {
        ensureFactIndex()[id]
    }

    private func mutate(_ id: UUID, _ change: (inout MemoryFact) -> Void) {
        guard let idx = store.facts.firstIndex(where: { $0.id == id }) else { return }
        change(&store.facts[idx])
        store.saveSoon()
    }
}

// MARK: - 设定

struct CanonView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @State private var selectedSection: UUID?
    @State private var newTitle = ""
    @State private var pendingDeleteSection: CanonSection?

    var body: some View {
        HSplitView {
            List(selection: Binding(
                get: { selectedSection.map(SectionID.init) },
                set: { selectedSection = $0?.id })) {
                let grouped = CanonCategory.allCases.map { cat in
                    (cat, store.canonSections.filter { $0.category == cat.rawValue }
                        .sorted { $0.title < $1.title })
                }.filter { !$0.1.isEmpty }
                ForEach(grouped, id: \.0.rawValue) { group in
                    Section("「\(group.0.rawValue)」 \(group.1.count)") {
                        ForEach(group.1) { s in
                            HStack {
                                Text(s.title).font(.callout)
                                Spacer()
                                Text(s.certainty.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(s.certainty == .canon ? Color.green : (s.certainty == .tentative ? Color.orange : Color.secondary))
                            }
                            .tag(SectionID(s.id))
                            .contextMenu { sectionContextMenu(s) }
                        }
                    }
                }
                HStack {
                    TextField("新文档名", text: $newTitle)
                        .font(.caption)
                    Button("加") {
                        guard !newTitle.isEmpty else { return }
                        if let existing = store.canonSections.first(where: { $0.title == newTitle }) {
                            selectedSection = existing.id   // 同题不新建（否则与磁盘 md 撞名）
                            newTitle = ""
                            return
                        }
                        let s = CanonSection(title: newTitle)
                        store.canonSections.append(s)
                        selectedSection = s.id
                        newTitle = ""
                        store.saveSoon()
                    }
                    .controlSize(.mini)
                }
            }
            .frame(minWidth: 170, idealWidth: 195, maxWidth: 280)

            Group {
            if let sid = selectedSection,
               let idx = store.canonSections.firstIndex(where: { $0.id == sid }) {
                VStack(spacing: 0) {
                    HStack {
                        TextField("标题", text: Binding(
                            get: { store.canonSections.indices.contains(idx) ? store.canonSections[idx].title : "" },
                            set: { newTitle in
                                guard store.canonSections.indices.contains(idx) else { return }
                                let oldTitle = store.canonSections[idx].title
                                if oldTitle != newTitle { store.deleteCanonMarkdown(title: oldTitle) }
                                store.canonSections[idx].title = newTitle
                                store.saveSoon()
                            }))
                            .font(.headline)
                            .textFieldStyle(.plain)
                        Picker("确定度", selection: Binding(
                            get: { store.canonSections.indices.contains(idx) ? store.canonSections[idx].certainty : .tentative },
                            set: { if store.canonSections.indices.contains(idx) { store.canonSections[idx].certainty = $0; store.saveSoon() } })) {
                            ForEach(Certainty.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .controlSize(.small)
                        Picker("类别", selection: Binding(
                            get: { CanonCategory.match(store.canonSections.indices.contains(idx) ? store.canonSections[idx].category : "") },
                            set: { cat in
                                if store.canonSections.indices.contains(idx) {
                                    store.canonSections[idx].category = cat.rawValue
                                    store.saveSoon()
                                }
                            })) {
                            ForEach(CanonCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .controlSize(.small)
                        .help("设定分类——AI 归类提案会写到这里；也可手动改")
                        Button(role: .destructive) {
                            // 与右键菜单走同一个确认流程：最常用的入口不能比右键更危险
                            guard store.canonSections.indices.contains(idx) else { return }
                            pendingDeleteSection = store.canonSections[idx]
                        } label: { Image(systemName: "trash") }
                        .controlSize(.small)
                        .help("删除设定（会先确认）")
                        .accessibilityLabel("删除设定")
                    }
                    .padding(10)
                    Divider()
                    // 所见即所得：默认展示即渲染后的排版，markdown 源码不对外露出
                    RichProseEditor(
                        markdown: Binding(
                            get: { store.canonSections.indices.contains(idx) ? store.canonSections[idx].content : "" },
                            set: { if store.canonSections.indices.contains(idx) { store.canonSections[idx].content = $0; store.saveSoon() } }),
                        baseFont: NSFont.systemFont(ofSize: 14),
                        textColor: NSColor.labelColor)
                    Text("设定是作者主权：AI 只读，不代写。确定度三态：已定（正典）/ 暂定 / 有意留白。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            } else {
                Text("选择或新建设定文档（世界观 / 势力人物 / 修炼体系…）")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .alert("删除设定「\(pendingDeleteSection?.title ?? "")」？", isPresented: Binding(
                get: { pendingDeleteSection != nil },
                set: { if !$0 { pendingDeleteSection = nil } })) {
                Button("取消", role: .cancel) { pendingDeleteSection = nil }
                Button("删除", role: .destructive) {
                    if let s = pendingDeleteSection { deleteSection(s) }
                    pendingDeleteSection = nil
                }
            } message: {
                Text("对应的 md 文件会一并清理。删除后不可在本应用内恢复。")
            }
        }
    }

    // MARK: 右键操作（设定侧栏）

    private func setCategory(_ s: CanonSection, _ cat: CanonCategory) {
        guard let idx = store.canonSections.firstIndex(where: { $0.id == s.id }) else { return }
        store.canonSections[idx].category = cat.rawValue
        store.saveSoon()
        vm.showToast("「\(s.title)」→ \(cat.rawValue)")
    }

    /// 复制一份（含内容；标题撞名自动加后缀）
    private func duplicateSection(_ s: CanonSection) {
        var copy = s
        copy.id = UUID()
        var title = s.title + " 副本"
        var n = 2
        while store.canonSections.contains(where: { $0.title == title }) {
            title = "\(s.title) 副本\(n)"
            n += 1
        }
        copy.title = title
        store.canonSections.append(copy)
        selectedSection = copy.id
        store.saveSoon()
        vm.showToast("已复制为「\(title)」")
    }

    private func revealSection(_ s: CanonSection) {
        let url = ProjectLayout.canonDir(store.rootURL)
            .appendingPathComponent(ProjectLayout.safeFileName(s.title) + ".md")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 删除：内存移除 + 磁盘 md 同步清理（与编辑器垃圾桶按钮同一路径）
    private func deleteSection(_ s: CanonSection) {
        guard let idx = store.canonSections.firstIndex(where: { $0.id == s.id }) else { return }
        let removed = store.canonSections.remove(at: idx)
        if selectedSection == removed.id { selectedSection = nil }
        store.deleteCanonMarkdown(title: removed.title)
        store.saveSoon()
        vm.showToast("已删除「\(removed.title)」（md 已同步清理）")
    }

    /// 右键菜单（拆出独立函数：整段内联会让类型检查超时）
    @ViewBuilder
    private func sectionContextMenu(_ s: CanonSection) -> some View {
        Menu("改类别") {
            ForEach(CanonCategory.allCases, id: \.self) { cat in
                Button(cat.rawValue) { setCategory(s, cat) }
            }
        }
        Divider()
        Button("复制一份") { duplicateSection(s) }
        Divider()
        Button("在访达中显示") { revealSection(s) }
        Divider()
        Button("删除…", role: .destructive) { pendingDeleteSection = s }
    }

    struct SectionID: Hashable {
        let id: UUID
        init(_ id: UUID) { self.id = id }
    }
}
