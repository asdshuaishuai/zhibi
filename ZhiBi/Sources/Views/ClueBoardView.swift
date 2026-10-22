import SwiftUI

// MARK: - 伏笔台账（F 编号 · 五档节奏 · 状态看板 + 断线预警）

struct ClueBoardView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @State private var filter: FilterKind = .active
    @State private var editing: Clue?
    @State private var pendingDeleteID: String?

    enum FilterKind: String, CaseIterable {
        case active = "活跃"
        case all = "全部"
        case overdue = "已过期"
        case resolved = "已回收"
    }

    private var currentChapter: Int { max(1, store.currentChapter - 1) }

    private var filtered: [Clue] {
        let base = store.clues
        switch filter {
        case .active: return base.filter { $0.status == .planted || $0.status == .developing }
        case .overdue: return base.filter { $0.isOverdue(currentChapter: currentChapter) }
        case .resolved: return base.filter { $0.status == .resolved }
        case .all: return base
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("伏笔台账").font(.headline)
                Text("揭1埋1：每回收一条，同时埋 1-2 条新钩子")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(FilterKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Button("新建") { addClue() }
                    .controlSize(.small)
                Button {
                    Task { await vm.ai.runClueInventory(store: store, config: vm.config, scope: "") }
                } label: { Label("AI 盘点（提案）", systemImage: "sparkles") }
                    .controlSize(.small)
                    .disabled(vm.ai.running)
            }
            .padding(.horizontal, 12)

            healthBar
                .padding(.horizontal, 12)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "link.circle").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(filter == .all
                         ? "台账空。\n写到正文里埋下的每一颗种子，都值得一条台账——含种下时的原文片段。"
                         : "当前筛选下没有伏笔。\n切到「全部」查看完整台账，或点「新建」补一条。")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(of: Clue.self, selection: .constant(Set<Clue.ID>())) {
                    TableColumn("编号") { c in
                        Text(c.id).font(.caption.monospaced()).foregroundStyle(.orange)
                    }.width(50)
                    TableColumn("标题 / 详情") { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.callout.bold())
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    TableColumn("量级") { c in Text(c.scale.rawValue).font(.caption) }.width(90)
                    TableColumn("节奏") { c in Text(c.timing.rawValue).font(.caption) }.width(110)
                    TableColumn("埋于") { c in Text("第\(c.plantedChapter)章").font(.caption.monospacedDigit()) }.width(64)
                    TableColumn("最近动作") { c in
                        let gap = currentChapter - c.lastActionChapter
                        Text(c.lastActionChapter > 0 ? "第\(c.lastActionChapter)章（隔\(gap)章）" : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(c.isOverdue(currentChapter: currentChapter) ? Color.red : Color.secondary)
                    }.width(110)
                    TableColumn("状态") { c in statusMenu(c) }.width(92)
                    TableColumn("目标章") { c in
                        Text(c.targetPayoffChapter.map { "第\($0)章" } ?? "—").font(.caption.monospacedDigit())
                    }.width(70)
                    TableColumn("") { c in
                        HStack(spacing: 4) {
                            Button { editing = c } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).controlSize(.mini)
                                .help("编辑伏笔")
                            Button(role: .destructive) { pendingDeleteID = c.id } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).controlSize(.mini)
                                .help("删除伏笔")
                        }
                    }.width(56)
                } rows: {
                    ForEach(filtered) { c in
                        TableRow(c)
                    }
                }
            }
        }
        .sheet(item: $editing) { clue in
            ClueEditSheet(store: store, clue: clue)
        }
        .confirmationDialog("删除伏笔 [\(pendingDeleteID ?? "")]？", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } })) {
            Button("删除（不可撤销）", role: .destructive) {
                if let id = pendingDeleteID {
                    store.clues.removeAll { $0.id == id }
                    store.saveSoon()
                    vm.showToast("已删除伏笔 [\(id)]")
                }
                pendingDeleteID = nil
            }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("动作日志会一并删除；正文不会改动。如果只是暂时不写，建议把状态改成「已放弃」保留记录。")
        }
    }

    private var healthBar: some View {
        let active = store.clues.filter { $0.status == .planted || $0.status == .developing }
        let overdue = active.filter { $0.isOverdue(currentChapter: currentChapter) }
        // 近 5 章的 揭/埋 比（InkOS 揭1埋1）
        let recentWindow = max(1, currentChapter - 4)...max(1, currentChapter)
        let resolvedRecent = store.clues.flatMap(\.actions).filter { recentWindow.contains($0.chapter) && ($0.kind == .resolve || $0.kind == .reveal) }.count
        let plantedRecent = store.clues.flatMap(\.actions).filter { recentWindow.contains($0.chapter) && $0.kind == .plant }.count
        return HStack(spacing: 14) {
            Label("活跃 \(active.count)\(active.count > 12 ? "（>12 拥挤）" : "")", systemImage: "link")
                .foregroundStyle(active.count > 12 ? Color.orange : Color.secondary)
            Label("过期 \(overdue.count)", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(overdue.isEmpty ? Color.secondary : Color.red)
            Label("近5章 揭\(resolvedRecent)/埋\(plantedRecent)", systemImage: "arrow.triangle.swap")
                .foregroundStyle(plantedRecent < resolvedRecent ? Color.orange : Color.secondary)
            Spacer()
            if overdue.count > 0 {
                Text("过期钩子必须处置：推进 / 显式搁置 / 放弃")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }

    private func statusMenu(_ c: Clue) -> some View {
        Menu {
            ForEach(ClueStatus.allCases, id: \.self) { s in
                Button(s.rawValue) {
                    guard let idx = store.clues.firstIndex(where: { $0.id == c.id }) else { return }
                    store.clues[idx].status = s
                    // 状态变更也是「一次动作」：不记日志的话 lastActionChapter 停在埋设章，
                    // 「最近动作」列与过期提示会失真
                    let kind: ClueActionKind
                    switch s {
                    case .resolved: kind = .resolve
                    case .deferred: kind = .defer
                    case .abandoned: kind = .resolve
                    default: kind = .develop
                    }
                    store.logClueAction(clueID: c.id, chapter: currentChapter, kind: kind,
                                        note: "状态改为「\(s.rawValue)」")
                    // logClueAction 会按动作类型推导状态（如 resolve→已回收）；
                    // 作者明确选的状态必须覆盖它，否则「已放弃」会被写成「已回收」。
                    if let idx = store.clues.firstIndex(where: { $0.id == c.id }) {
                        store.clues[idx].status = s
                        store.saveSoon()
                    }
                    vm.showToast("[\(c.id)] \(c.title) → \(s.rawValue)")
                }
            }
            Divider()
            Button("记一笔推进（本章）") {
                store.logClueAction(clueID: c.id, chapter: currentChapter, kind: .develop)
                vm.showToast("[\(c.id)] 已记推进（第\(currentChapter)章）")
            }
        } label: {
            Text(c.status.rawValue)
                .font(.caption.bold())
                .foregroundStyle(c.status == .resolved ? .green : (c.status == .deferred || c.status == .abandoned) ? .gray : .blue)
        }
        .menuStyle(.borderlessButton)
    }

    private func addClue() {
        var c = Clue()
        c.id = store.nextClueID()
        c.title = "新伏笔"
        c.plantedChapter = currentChapter
        c.lastActionChapter = currentChapter
        c.actions = [ClueActionLog(chapter: currentChapter, kind: .plant, note: "手动登记")]
        store.clues.append(c)
        store.saveSoon()
        editing = c   // 建完立刻打开编辑，避免留下一条改不掉的占位记录
    }
}

// MARK: - 伏笔编辑（标题/详情/量级/节奏/章号都是可维护字段）

private struct ClueEditSheet: View {
    @ObservedObject var store: ProjectStore
    let clue: Clue
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var detail = ""
    @State private var scale: ClueScale = .medium
    @State private var timing: ClueTiming = .midArc
    @State private var importance = "中"
    @State private var plantedChapter = 1
    @State private var targetChapter = ""
    @State private var plantedQuote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("伏笔 [\(clue.id)]").font(.headline)
                Spacer()
                Text(clue.status.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("标题").foregroundStyle(.secondary)
                    TextField("例如：断刀上的缺口", text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("详情").foregroundStyle(.secondary)
                    TextField("这条伏笔到底是什么、指向什么", text: $detail).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("量级").foregroundStyle(.secondary)
                    Picker("", selection: $scale) {
                        ForEach(ClueScale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                GridRow {
                    Text("节奏").foregroundStyle(.secondary)
                    Picker("", selection: $timing) {
                        ForEach(ClueTiming.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                GridRow {
                    Text("重要度").foregroundStyle(.secondary)
                    Picker("", selection: $importance) {
                        ForEach(["高", "中", "低"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                GridRow {
                    Text("埋设章").foregroundStyle(.secondary)
                    Stepper("第\(plantedChapter)章", value: $plantedChapter, in: 1...9999)
                }
                GridRow {
                    Text("目标回收章").foregroundStyle(.secondary)
                    TextField("留空 = 未定", text: $targetChapter).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                GridRow {
                    Text("种下原文").foregroundStyle(.secondary)
                    TextField("正文里的原句（兑现时对照）", text: $plantedQuote).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            title = clue.title
            detail = clue.detail
            scale = clue.scale
            timing = clue.timing
            importance = clue.importance
            plantedChapter = max(1, clue.plantedChapter)
            targetChapter = clue.targetPayoffChapter.map(String.init) ?? ""
            plantedQuote = clue.plantedQuote
        }
    }

    private func save() {
        guard let idx = store.clues.firstIndex(where: { $0.id == clue.id }) else { dismiss(); return }
        store.clues[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.clues[idx].detail = detail
        store.clues[idx].scale = scale
        store.clues[idx].timing = timing
        store.clues[idx].importance = importance
        store.clues[idx].plantedChapter = plantedChapter
        store.clues[idx].plantedQuote = plantedQuote
        let trimmed = targetChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        store.clues[idx].targetPayoffChapter = Int(trimmed)
        store.saveSoon()
        dismiss()
    }
}
