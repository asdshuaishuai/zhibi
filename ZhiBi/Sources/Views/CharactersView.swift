import SwiftUI

// MARK: - 人物卡：由双时态事实机械折叠（NarraCat character_cards 纪律：不另行记账）

struct CharactersView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var vm: AppViewModel
    @State private var newSubject = ""
    @State private var pendingDeleteFactID: UUID?

    private struct CharacterCard: Identifiable {
        var id: String { name }
        var name: String
        var facts: [MemoryFact]
        var lastChapter: Int
    }

    /// 只折叠对读者可见的公开事实；暗线事实进"作者底牌"区
    private var cards: [CharacterCard] {
        let valid = store.facts.filter { $0.isValid(atChapter: 9999) }
        var bySubject: [String: [MemoryFact]] = [:]
        for f in valid { bySubject[f.subject, default: []].append(f) }
        return bySubject.map { name, fs in
            CharacterCard(name: name, facts: fs.sorted { $0.fromChapter < $1.fromChapter },
                          lastChapter: fs.map(\.fromChapter).max() ?? 0)
        }.sorted { $0.lastChapter > $1.lastChapter }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("人物卡").font(.headline)
                Text("由记忆事实自动折叠生成——账房归我们，卡片是派生视图")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                TextField("新人物名", text: $newSubject)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("建档（登记一条事实）") {
                    let name = newSubject.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    store.facts.append(MemoryFact(subject: name, predicate: "状态", object: "",
                                                  fromChapter: max(1, store.currentChapter - 1),
                                                  source: "authored"))
                    newSubject = ""
                    store.saveSoon()
                    vm.showToast("已建档：点卡片里的「状态」即可补充身份/处境")
                }
                .controlSize(.small)
                .disabled(newSubject.isEmpty)
            }
            .padding(12)

            if cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("还没有人物事实。\n写完章节用「让 AI 记一笔」，或在这里手动建档；建档后点事实文字即可编辑。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 10)], spacing: 10) {
                        ForEach(cards) { card in
                            characterCard(card)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    @State private var traceExpanded: Set<String> = []

    /// 档案卡实体轨迹：该人物在全书哪些章出现过（含别名）
    /// 全部人物的轨迹一次算完（body 内共享同一索引；原先每张卡各建一次全书索引）
    private var allTraces: [String: [ChapterDossier]] {
        guard !store.dossiers.isEmpty else { return [:] }
        let index = DossierIndex.cached(for: store.dossiers)
        var out: [String: [ChapterDossier]] = [:]
        for card in cards {
            var names = [card.name]
            if let a = store.characterAliases.first(where: { $0.canonicalName == card.name }) {
                names.append(contentsOf: a.aliases)
            }
            var result: [Int: ChapterDossier] = [:]
            for n in names {
                for d in index.entityTrace(n) { result[d.chapter] = d }
            }
            out[card.name] = result.values.sorted { $0.chapter < $1.chapter }
        }
        return out
    }

    private func entityTrace(_ name: String) -> [ChapterDossier] {
        allTraces[name] ?? []
    }

    private func characterCard(_ card: CharacterCard) -> some View {
        let aliases = store.characterAliases.first { $0.canonicalName == card.name }?.aliases ?? []
        let secrets = card.facts.filter { !$0.publicToReader }
        let trace = entityTrace(card.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.name).font(.callout.bold())
                if !aliases.isEmpty {
                    Text(aliases.joined(separator: "／")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("最近：第\(card.lastChapter)章").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(card.facts.suffix(5).reversed()) { f in
                HStack(alignment: .top, spacing: 5) {
                    Text("[\(f.predicate)]").font(.caption2.monospaced()).foregroundStyle(.teal)
                    TextField("补充状态/身份", text: Binding(
                        get: { store.facts.first { $0.id == f.id }?.object ?? f.object },
                        set: { newValue in
                            guard let idx = store.facts.firstIndex(where: { $0.id == f.id }) else { return }
                            store.facts[idx].object = newValue
                            store.saveSoon()
                        }))
                        .textFieldStyle(.plain)
                        .font(.caption)
                    Spacer()
                    Text("第\(f.fromChapter)章起").font(.caption2).foregroundStyle(.tertiary)
                    Button(role: .destructive) {
                        pendingDeleteFactID = f.id
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).controlSize(.mini)
                        .accessibilityLabel("删除这条人物事实")
                }
            }
            if !trace.isEmpty {
                Divider()
                Button {
                    if traceExpanded.contains(card.name) { traceExpanded.remove(card.name) }
                    else { traceExpanded.insert(card.name) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: traceExpanded.contains(card.name) ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Label("档案轨迹：\(trace.count) 章", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.caption2.bold())
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                if traceExpanded.contains(card.name) {
                    ForEach(trace) { d in
                        HStack(alignment: .top, spacing: 6) {
                            Text("第\(d.chapter)章").font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.headline).font(.caption2)
                                if !d.relics.isEmpty {
                                    Text(d.relics.prefix(2).joined(separator: "；"))
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !secrets.isEmpty {
                Divider()
                Label("作者底牌 \(secrets.count) 条（读者未知）", systemImage: "eye.slash")
                    .font(.caption2.bold()).foregroundStyle(.orange)
                ForEach(secrets.reversed()) { f in
                    Text("• \(f.predicate)\(f.object)（第\(f.fromChapter)章起）")
                        .font(.caption2).foregroundStyle(.orange.opacity(0.9))
                }
            }
        }
        .padding(10)
        .zbGlass(cornerRadius: 10)
        .confirmationDialog("删除这条人物事实？", isPresented: Binding(
            get: { pendingDeleteFactID != nil },
            set: { if !$0 { pendingDeleteFactID = nil } })) {
            Button("删除", role: .destructive) {
                if let id = pendingDeleteFactID {
                    store.facts.removeAll { $0.id == id }
                    store.saveSoon()
                }
                pendingDeleteFactID = nil
            }
            Button("取消", role: .cancel) { pendingDeleteFactID = nil }
        } message: {
            Text("只从事实账本删除，不改正文。")
        }
    }
}
