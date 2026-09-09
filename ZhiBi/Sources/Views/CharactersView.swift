import SwiftUI

// MARK: - 人物卡：由双时态事实机械折叠（NarraCat character_cards 纪律：不另行记账）

struct CharactersView: View {
    @ObservedObject var store: ProjectStore
    @State private var newSubject = ""

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
                    guard !newSubject.isEmpty else { return }
                    store.facts.append(MemoryFact(subject: newSubject, predicate: "状态", object: "（待登记）",
                                                  fromChapter: 1, source: "authored"))
                    newSubject = ""
                    store.saveSoon()
                }
                .controlSize(.small)
                .disabled(newSubject.isEmpty)
            }
            .padding(12)

            if cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("还没有人物事实。\n写完章节用「让 AI 记一笔」，或在这里手动建档。")
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

    private func characterCard(_ card: CharacterCard) -> some View {
        let aliases = store.characterAliases.first { $0.canonicalName == card.name }?.aliases ?? []
        let secrets = card.facts.filter { !$0.publicToReader }
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
                    Text(f.object).font(.caption)
                    Spacer()
                    Text("第\(f.fromChapter)章起").font(.caption2).foregroundStyle(.tertiary)
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
    }
}
