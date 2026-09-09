import SwiftUI

// MARK: - 大纲：故事线 + 阶段 + 事件时间线（双栏：作者真相 | 读者已知）

struct OutlineView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: ProjectStore
    @State private var newEvent = TimelineEvent()
    @State private var showAddEvent = false
    @State private var outlineNotes = ""

    var body: some View {
        VStack(spacing: 0) {
            // 作者意图 / 当前焦点（人机协同里"人"的接口）
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("作者意图（AI 的最高优先级之一）").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { store.project.authorIntent },
                        set: { store.project.authorIntent = $0; store.saveSoon() }))
                        .font(.callout)
                        .frame(height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前焦点").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { store.project.currentFocus },
                        set: { store.project.currentFocus = $0; store.saveSoon() }))
                        .font(.callout)
                        .frame(height: 64)
                }
            }
            .padding(12)
            Divider()

            HStack {
                Text("故事线").font(.headline)
                Spacer()
                Button("加故事线") {
                    var s = Storyline()
                    let maxL = store.storylines.compactMap { sl -> Int? in
                        guard sl.id.hasPrefix("L"), let n = Int(sl.id.dropFirst()) else { return nil }
                        return n
                    }.max() ?? 0
                    s.id = String(format: "L%02d", maxL + 1)
                    s.name = ""
                    store.storylines.append(s)
                    store.saveSoon()
                }
                .controlSize(.small)
                Button {
                    Task { await vm.ai.runOutlineTimeline(store: store, config: vm.config, notes: outlineNotes) }
                } label: { Label("AI 建大纲（提案）", systemImage: "wand.and.stars") }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            storylinesTable
                .padding(.horizontal, 12)

            // 阶段（卷/单元）编辑条
            HStack {
                Text("阶段").font(.subheadline.bold())
                Spacer()
                Button("加阶段") {
                    let nextID = (store.stages.map(\.id).max() ?? 0) + 1
                    store.stages.append(Stage(id: nextID))
                    store.saveSoon()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.stages) { stage in
                        stageCard(stage)
                    }
                    if store.stages.isEmpty {
                        Text("把全书切成 4-7 个阶段（对应 oh-story 的 stages_overview）：每阶段一个主题一句矛盾。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)

            HStack {
                Text("事件时间线").font(.headline)
                Text("左栏只有你知道，右栏是读者被告知的——信息差就是悬念")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await vm.ai.runOutlineTimeline(store: store, config: vm.config, notes: outlineNotes) }
                } label: { Label("AI 建时间线（提案）", systemImage: "sparkles") }
                .controlSize(.small)
                Button("加事件") { showAddEvent = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            timelineTable
        }
        .sheet(isPresented: $showAddEvent) { addEventSheet }
    }

    private var storylinesTable: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(store.storylines.indices, id: \.self) { i in
                    storylineCard(i)
                }
                if store.storylines.isEmpty {
                    Text("尚无故事线。手动添加，或让 AI 从设定与题材提案。")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func storylineCard(_ i: Int) -> some View {
        let binding = Binding<Storyline>(
            get: { store.storylines.indices.contains(i) ? store.storylines[i] : Storyline() },
            set: { newValue in
                guard store.storylines.indices.contains(i) else { return }
                store.storylines[i] = newValue
                store.saveSoon()
            })
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField("L 编号", text: binding.id)
                    .font(.caption2.monospaced())
                    .frame(width: 44)
                TextField("名称", text: binding.name)
                    .font(.caption.bold())
                Picker("", selection: binding.kind) {
                    ForEach(StorylineKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .controlSize(.mini)
                Button(role: .destructive) {
                    _ = withAnimation { store.storylines.remove(at: i) }
                    store.saveSoon()
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.mini)
            }
            Toggle("贯穿线（造包常驻）", isOn: binding.isThroughLine)
                .font(.caption2)
            HStack {
                Picker("", selection: binding.status) {
                    ForEach(ActiveStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .controlSize(.mini)
                TextField("备注", text: binding.notes)
                    .font(.caption2)
            }
        }
        .padding(8)
        .frame(width: 330)
        .zbGlass(cornerRadius: 8)
    }

    private func stageCard(_ stage: Stage) -> some View {
        let idx = store.stages.firstIndex(where: { $0.id == stage.id })
        return Group {
            if let idx {
                let binding = Binding<Stage>(
                    get: { store.stages[idx] },
                    set: { store.stages[idx] = $0; store.saveSoon() })
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("#\(stage.id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        TextField("阶段名", text: binding.name)
                            .textFieldStyle(.plain)
                            .font(.caption.bold())
                        Button(role: .destructive) {
                            _ = store.stages.remove(at: idx)
                            store.saveSoon()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).controlSize(.mini)
                    }
                    HStack {
                        Stepper("第\(binding.wrappedValue.chapterStart)-\(binding.wrappedValue.chapterEnd)章",
                                value: Binding(get: { store.stages[idx].chapterEnd },
                                               set: { store.stages[idx].chapterEnd = max($0, store.stages[idx].chapterStart); store.saveSoon() }))
                            .font(.caption2)
                    }
                    TextField("主题/核心矛盾", text: binding.theme)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                }
                .padding(8)
                .frame(width: 210)
                .zbGlass(cornerRadius: 8)
            }
        }
    }

    private var timelineTable: some View {
        Table(of: TimelineEvent.self, selection: .constant(Set<TimelineEvent.ID>())) {
            TableColumn("编号") { e in Text(e.id).font(.caption.monospaced()) }.width(50)
            TableColumn("章") { e in Text("第\(e.chapter)章").font(.caption.monospacedDigit()) }.width(64)
            TableColumn("作者真相") { e in
                Text(e.objectiveFact).font(.callout)
            }
            TableColumn("读者已知") { e in
                HStack {
                    if e.revealed {
                        Text(e.readerKnowledge).font(.callout)
                    } else {
                        Label("未揭示", systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            TableColumn("挂线") { e in
                Text(e.storylineIDs.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
            }.width(90)
            TableColumn("") { e in
                HStack {
                    Button(e.revealed ? "标记未揭示" : "标记已揭示") {
                        if let idx = store.timelineEvents.firstIndex(where: { $0.id == e.id && $0.chapter == e.chapter }) {
                            store.timelineEvents[idx].revealed.toggle()
                            store.timelineEvents[idx].revealChapter = store.timelineEvents[idx].revealed ? store.currentChapter : nil
                            store.saveSoon()
                        }
                    }
                    .buttonStyle(.borderless).controlSize(.mini)
                    Button(role: .destructive) {
                        store.timelineEvents.removeAll { $0.id == e.id && $0.chapter == e.chapter }
                        store.saveSoon()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.mini)
                }
            }.width(110)
        } rows: {
            ForEach(store.timelineEvents) { e in
                TableRow(e)
            }
        }
    }

    private var addEventSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增时间线事件").font(.headline)
            Form {
                HStack {
                    TextField("编号（如 E11）", text: $newEvent.id)
                        .frame(width: 120)
                    Stepper("第 \(newEvent.chapter) 章", value: $newEvent.chapter, in: 1...2000)
                }
                TextField("作者真相（客观发生了什么，含底牌）", text: $newEvent.objectiveFact, axis: .vertical)
                TextField("读者已知（读者被告知了什么）", text: $newEvent.readerKnowledge, axis: .vertical)
                Toggle("读者已知情", isOn: $newEvent.revealed)
                TextField("挂接故事线（L01 L02）", text: Binding(
                    get: { newEvent.storylineIDs.joined(separator: " ") },
                    set: { newEvent.storylineIDs = $0.split(separator: " ").map(String.init) }))
            }
            HStack {
                Spacer()
                Button("取消") { showAddEvent = false }
                Button("添加") {
                    if newEvent.id.isEmpty {
                        let maxE = store.timelineEvents.compactMap { e -> Int? in
                            guard e.id.hasPrefix("E"), let n = Int(e.id.dropFirst()) else { return nil }
                            return n
                        }.max() ?? 0
                        newEvent.id = "E\(String(format: "%02d", maxE + 1))"
                    }
                    store.timelineEvents.append(newEvent)
                    store.timelineEvents.sort { ($0.chapter, $0.id) < ($1.chapter, $1.id) }
                    store.saveSoon()
                    newEvent = TimelineEvent()
                    showAddEvent = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
