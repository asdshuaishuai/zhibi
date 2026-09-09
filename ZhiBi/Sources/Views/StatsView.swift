import SwiftUI

// MARK: - 写作统计：14 天柱状图 + 连续天数 + 总览

struct StatsView: View {
    @ObservedObject var store: ProjectStore
    @AppStorage("dailyGoal") private var dailyGoal = 2000

    private struct DayBar: Identifiable {
        let id: Int
        let label: String   // "9/3"
        let words: Int
        let isToday: Bool
    }

    private var bars: [DayBar] {
        let daily = store.project.dailyWords ?? [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let labelF = DateFormatter()
        labelF.dateFormat = "M/d"
        var out: [DayBar] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = ProjectStore.todayKey(date)
            out.append(DayBar(id: offset,
                              label: labelF.string(from: date),
                              words: daily[key] ?? 0,
                              isToday: offset == 0))
        }
        return out
    }

    private var totalWords: Int {
        store.chapters.reduce(0) { $0 + $1.wordCount }
    }

    /// 连续写作天数：从今天（或昨天）往回连续 >0 的天数
    private var streak: Int {
        let daily = store.project.dailyWords ?? [:]
        var streak = 0
        var offset = 0
        // 今天若还没写，从昨天开始数
        if (daily[ProjectStore.todayKey()] ?? 0) == 0 { offset = 1 }
        while true {
            let date = Calendar.current.date(byAdding: .day, value: -offset - streak, to: Date()) ?? Date()
            let words = daily[ProjectStore.todayKey(date)] ?? 0
            if words > 0 { streak += 1 } else { break }
            if streak > 365 { break }
        }
        return streak
    }

    private var maxDay: Int {
        max(dailyGoal, bars.map(\.words).max() ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.accentColor)
                Text("写作统计").font(.headline)
                Text("账本来自每次编辑的净增字数；导入与 AI 草稿采纳的口径见各自说明")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(14)

            HStack(spacing: 26) {
                bigStat("\(totalWords)", "全书字数", color: .primary)
                bigStat("\(store.todayWordCount())", "今日净增", color: .accentColor)
                bigStat("\(streak)", "连续天数", color: streak >= 3 ? .green : .secondary)
                bigStat("\(dailyGoal)", "每日目标", color: .secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            chart
                .frame(height: 180)
                .padding(14)

            Spacer(minLength: 0)
        }
        .background(ZB.canvas)
    }

    private func bigStat(_ value: String, _ title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var chart: some View {
        Canvas { context, size in
            let chartHeight = size.height - 26
            let slot = size.width / CGFloat(bars.count)
            let barWidth = slot * 0.52

            // 每日目标虚线
            let goalY = chartHeight * (1 - CGFloat(dailyGoal) / CGFloat(maxDay))
            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: goalY))
            dash.addLine(to: CGPoint(x: size.width, y: goalY))
            context.stroke(dash, with: .color(.secondary.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            for (i, bar) in bars.enumerated() {
                let x = slot * CGFloat(i) + (slot - barWidth) / 2
                let h = bar.words > 0
                    ? chartHeight * CGFloat(bar.words) / CGFloat(maxDay)
                    : 0
                if h > 0 {
                    let rect = CGRect(x: x, y: chartHeight - h, width: barWidth, height: h)
                    let color = bar.isToday ? Color.accentColor : Color.accentColor.opacity(0.45)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
                }
                // 日期标签
                context.draw(Text(bar.label)
                    .font(.system(size: 9))
                    .foregroundStyle(bar.isToday ? Color.primary : Color.secondary),
                    at: CGPoint(x: x + barWidth / 2, y: chartHeight + 10))
                // 连续天数的点
                if bar.words >= dailyGoal {
                    context.fill(Path(ellipseIn: CGRect(x: x + barWidth / 2 - 2, y: chartHeight - h - 8,
                                                        width: 4, height: 4)),
                                 with: .color(.green))
                }
            }
        }
        .zbCard(padding: 8)
    }
}
