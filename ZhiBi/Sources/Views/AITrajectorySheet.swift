import SwiftUI

// MARK: - AI 轨迹面板：实时状态 + 会话历史
//
// 数据源 AIService.trajectory（内存，会话内保留，上限 200 条）。
// 运行中顶部显示当前步骤与流式输出；历史区按时间倒序，失败红色。

struct AITrajectorySheet: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：当前状态
            HStack(spacing: ZBSpace.sm) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(Color.accentColor)
                Text("AI 轨迹").font(.headline)
                Spacer()
                if ai.running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(ai.runningCapability?.rawValue ?? "").font(.caption.bold())
                    }
                } else {
                    Text("空闲 · 本次会话 \(ai.trajectory.count) 条轨迹")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Button("清空") { ai.trajectory = []; ai.currentStep = "" }
                    .controlSize(.small)
                    .disabled(ai.trajectory.isEmpty)
            }
            .padding(ZBSpace.md)

            Divider()

            if ai.running {
                runningSection
            } else if let err = ai.lastError, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(ZBSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }

            historySection
        }
        .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 560)
    }

    /// 运行中：当前步骤 + 流式输出实时滚动
    private var runningSection: some View {
        VStack(alignment: .leading, spacing: ZBSpace.xs) {
            HStack(spacing: ZBSpace.xs) {
                ProgressView().controlSize(.small)
                Text(ai.currentStep.isEmpty ? "处理中…" : ai.currentStep)
                    .font(.caption.bold())
            }
            if !ai.streamPreview.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(ai.streamPreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("tail")
                    }
                    .frame(height: 110)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .cornerRadius(6)
                    .onChange(of: ai.streamPreview) { _ in
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                }
            }
        }
        .padding(ZBSpace.sm)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
        .padding(.horizontal, ZBSpace.md)
        .padding(.top, ZBSpace.sm)
    }

    private var historySection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if ai.trajectory.isEmpty {
                    Text("还没有轨迹——跑一次任意 AI 能力（搭大纲/写草稿/验证…）就会在这里留下完整轨迹。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                ForEach(ai.trajectory) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.at.formatted(.dateTime.hour().minute().second()))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 64, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(e.capability)
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.event)
                                .font(.caption)
                                .foregroundStyle(e.isError ? Color.red : .primary)
                            if !e.detail.isEmpty {
                                Text(e.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(ZBSpace.md)
        }
    }
}
