import SwiftUI

// MARK: - Agent 轨迹面板：右侧边缘常驻「对话窗」
//
// 数据源 AIService.trajectory（内存倒序存储 + 磁盘保留最近 200 条，跨会话可回看）。
// 展示为对话式时间线（正序）：一次 AI 运行 = 一段会话块——「开始处理」是分节头，
// 工具调用/结果/异常是气泡；运行中底部实时显示当前步骤与流式输出，自动滚到最新。

struct AgentTrajectoryPanel: View {
    @ObservedObject var ai: AIService
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false

    /// trajectory 新在前；对话窗旧在上、新在下
    private var chronological: [AIService.AITraceEntry] { ai.trajectory.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            if ai.running {
                liveTail
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: ZBSpace.xs) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(Color.accentColor)
            Text("Agent 轨迹").font(.headline)
            if ai.running {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(ai.runningCapability?.rawValue ?? "").font(.caption2.bold())
                }
            } else {
                Text("空闲 · \(ai.trajectory.count) 条")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(ai.trajectory.isEmpty)
            .help("清空轨迹（同时删除磁盘历史）")
            .confirmationDialog("清空 AI 轨迹？", isPresented: $confirmClear) {
                Button("清空（不可撤销）", role: .destructive) { ai.clearTrajectory() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会同时删除磁盘上的轨迹历史，重启后不会恢复。")
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("收起轨迹面板（⌘⇧J）")
        }
        .padding(.horizontal, ZBSpace.sm)
        .padding(.vertical, ZBSpace.xs + 2)
    }

    // MARK: 对话区（正序时间线）

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if chronological.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 26)).foregroundStyle(.tertiary)
                            Text("还没有轨迹。\n跑一次任意 AI 能力（搭大纲/写草稿/设定归类…），完整 agent 轨迹会像对话一样在这里展开。")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    ForEach(Array(chronological.enumerated()), id: \.element.id) { idx, e in
                        if e.event == "开始处理" {
                            runHeader(e)
                        } else {
                            bubble(e, isFirstOfRun: idx == 0 || chronological[idx - 1].event == "开始处理")
                        }
                    }
                    Color.clear.frame(height: 1).id("panel-tail")
                }
                .padding(ZBSpace.sm)
            }
            .onChange(of: ai.trajectory.count) { _ in
                proxy.scrollTo("panel-tail", anchor: .bottom)
            }
            .onChange(of: ai.streamPreview) { _ in
                guard ai.running else { return }
                proxy.scrollTo("panel-tail", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("panel-tail", anchor: .bottom)
            }
        }
    }

    /// 一次运行的分节头：能力名 + 开始时间
    private func runHeader(_ e: AIService.AITraceEntry) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(ZB.hairline).frame(height: 1)
            Label(e.capability, systemImage: "play.fill")
                .font(.caption2.bold())
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
            Text(e.at.formatted(.dateTime.hour().minute().second()))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Rectangle().fill(ZB.hairline).frame(height: 1)
        }
        .padding(.top, 6)
    }

    /// 气泡：事件 + 细节，按语义着色（工具调用强调 / 工具完成绿 / 错误红）
    private func bubble(_ e: AIService.AITraceEntry, isFirstOfRun: Bool) -> some View {
        let isToolCall = e.event.hasPrefix("调用 ")
        let bg: Color = e.isError ? .red.opacity(0.10)
            : e.event == "工具完成" ? .green.opacity(0.08)
            : isToolCall ? Color.accentColor.opacity(0.08)
            : Color.secondary.opacity(0.07)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(e.event)
                    .font(.caption)
                    .fontWeight(isToolCall || e.isError ? .semibold : .regular)
                    .foregroundStyle(e.isError ? Color.red : .primary)
                    .lineLimit(2)
                Spacer()
                Text(e.at.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !e.detail.isEmpty {
                Text(e.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .cornerRadius(9)
        .padding(.top, isFirstOfRun ? 2 : 0)
    }

    // MARK: 运行中：底部实时区（当前步骤 + 流式输出，像「正在输入」）

    private var liveTail: some View {
        VStack(alignment: .leading, spacing: ZBSpace.xs) {
            Divider()
            HStack(spacing: ZBSpace.xs) {
                ProgressView().controlSize(.small)
                Text(ai.currentStep.isEmpty ? "处理中…" : ai.currentStep)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
            }
            if !ai.streamPreview.isEmpty {
                ScrollViewReader { p in
                    ScrollView {
                        Text(ai.streamPreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("live-tail")
                    }
                    .frame(height: 120)
                    .onChange(of: ai.streamPreview) { _ in
                        p.scrollTo("live-tail", anchor: .bottom)
                    }
                }
            }
            if let err = ai.lastError, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(3)
            }
        }
        .padding(.horizontal, ZBSpace.sm)
        .padding(.bottom, ZBSpace.sm)
        .background(Color.accentColor.opacity(0.05))
    }
}
