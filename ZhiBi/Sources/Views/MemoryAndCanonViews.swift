import SwiftUI

// MARK: - 记忆中枢（Agent 记忆模组）：事实账本 / 矛盾体检 / 人物归一

struct MemoryView: View {
    @ObservedObject var store: ProjectStore

    enum Tab: String, CaseIterable {
        case ledger = "事实账本"
        case conflicts = "矛盾体检"
        case subjects = "人物归一"
    }

    @State private var tab: Tab = .ledger
    @State private var showReaderOnly = true
    @State private var atChapter = 9999
    @State private var searchText = ""
    @State private var consolidationNote: String?
    @State private var newAliasTarget = ""
    @State private var newAliasInput = ""

    private var stats: MemoryHub.LedgerStats { MemoryHub.ledgerStats(store: store) }

    private var visibleFacts: [MemoryFact] {
        store.facts
            .filter { $0.isValid(atChapter: atChapter) }
            .filter { showReaderOnly || $0.publicToReader }
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
            .frame(width: 420)
            .padding(10)

            switch tab {
            case .ledger: ledgerTab
            case .conflicts: conflictsTab
            case .subjects: subjectsTab
            }
        }
        .background(ZB.canvas)
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
                let result = MemoryHub.consolidate(facts: store.facts, aliases: store.characterAliases)
                store.facts = result.facts
                consolidationNote = result.report.summary
                store.saveSoon()
            } label: {
                Label("一键整理（本地）", systemImage: "wand.and.rays")
            }
            .controlSize(.small)
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

    private var ledgerTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索主语 / 谓词 / 宾语", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Toggle("仅读者视角", isOn: $showReaderOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Stepper("截至第 \(min(atChapter, max(1, store.currentChapter - 1))) 章", value: $atChapter, in: 1...9999)
                    .font(.caption)
                Spacer()
                Button("新增事实") {
                    store.facts.append(MemoryFact(fromChapter: min(atChapter, 9999), source: "authored"))
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
                                mutate(f.id) { $0.invalidatedAtChapter = min(atChapter, 9999) }
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
                        store.facts.removeAll { $0.id == f.id }
                        store.saveSoon()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.mini)
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
                store.facts[idx].invalidatedAtChapter = atChapter == 9999 ? (store.facts[idx].fromChapter + 1) : min(atChapter, 9999)
            }
        }
        store.saveSoon()
    }

    private func dismissConflict(_ c: MemoryHub.Conflict) {
        var list = store.dismissedConflicts ?? []
        list.append(c.id)
        store.dismissedConflicts = list
        store.saveSoon()
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

    private func factByID(_ id: UUID) -> MemoryFact? {
        store.facts.first { $0.id == id }
    }

    private func mutate(_ id: UUID, _ change: (inout MemoryFact) -> Void) {
        guard let idx = store.facts.firstIndex(where: { $0.id == id }) else { return }
        change(&store.facts[idx])
        store.saveSoon()
    }
}

// MARK: - 设定

struct CanonView: View {
    @ObservedObject var store: ProjectStore
    @State private var selectedSection: UUID?
    @State private var newTitle = ""

    var body: some View {
        HSplitView {
            List(selection: Binding(
                get: { selectedSection.map(SectionID.init) },
                set: { selectedSection = $0?.id })) {
                ForEach(store.canonSections) { s in
                    HStack {
                        Text(s.title).font(.callout)
                        Spacer()
                        Text(s.certainty.rawValue)
                            .font(.caption2)
                            .foregroundStyle(s.certainty == .canon ? Color.green : (s.certainty == .tentative ? Color.orange : Color.secondary))
                    }
                    .tag(SectionID(s.id))
                }
                HStack {
                    TextField("新文档名", text: $newTitle)
                        .font(.caption)
                    Button("加") {
                        guard !newTitle.isEmpty else { return }
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
                            set: { if store.canonSections.indices.contains(idx) { store.canonSections[idx].title = $0; store.saveSoon() } }))
                            .font(.headline)
                            .textFieldStyle(.plain)
                        Picker("确定度", selection: Binding(
                            get: { store.canonSections.indices.contains(idx) ? store.canonSections[idx].certainty : .tentative },
                            set: { if store.canonSections.indices.contains(idx) { store.canonSections[idx].certainty = $0; store.saveSoon() } })) {
                            ForEach(Certainty.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            guard store.canonSections.indices.contains(idx) else { return }
                            _ = store.canonSections.remove(at: idx)
                            selectedSection = nil
                            store.saveSoon()
                        } label: { Image(systemName: "trash") }
                        .controlSize(.small)
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
        }
    }

    struct SectionID: Hashable {
        let id: UUID
        init(_ id: UUID) { self.id = id }
    }
}
