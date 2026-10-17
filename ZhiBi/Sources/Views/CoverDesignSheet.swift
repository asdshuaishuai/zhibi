import SwiftUI
import AppKit

// MARK: - 书架级封面设计（对标 story-cover：LLM 直接绘制 SVG 封面）
//
// 不打开项目：从 project.json 读元信息 → LLM 产出 SVG → 实时预览 →
// 作者点「采用为本书封面」才写 cover.svg（提案纪律：采纳前不动盘）。

struct CoverDesignSheet: View {
    let ref: ProjectRef
    @ObservedObject var vm: AppViewModel
    var onAdopted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var authorName = ""
    @State private var mood = ""
    @State private var direction = ""
    @State private var svgCode = ""
    @State private var preview: NSImage?
    @State private var adopted = false
    @State private var metaGenre = ""
    @State private var metaPremise = ""

    private var inputReady: Bool { !vm.ai.running }

    var body: some View {
        VStack(alignment: .leading, spacing: ZBSpace.sm) {
            HStack {
                Text("封面设计").font(.headline)
                Text("《\\(ref.title)》· LLM 直接绘制 SVG").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if vm.ai.running { ProgressView().controlSize(.small) }
            }

            Text("LLM 按 600×800（3:4）直接产出 SVG：渐变背景/装饰形状/书名署名一次成形。预览满意点「采用」，书架立即换上。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("署名（可空）", text: $authorName)
                .textFieldStyle(.roundedBorder)
            TextField("氛围要求（如：压迫感、冷色调、史诗）", text: $mood)
                .textFieldStyle(.roundedBorder)
            TextField("画面方向（如：少年背影 + 断刀 + 雨夜；避免：剧透画面）", text: $direction)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(vm.ai.running ? "绘制中…" : "绘制封面") {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.ai.running)
            }

            if let err = vm.ai.lastError, vm.ai.running == false, svgCode.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let preview {
                HStack(alignment: .top, spacing: ZBSpace.md) {
                    SVGCoverLayer(image: preview)
                        .frame(width: 240, height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ZB.hairline))
                    VStack(alignment: .leading, spacing: ZBSpace.xs) {
                        Text("预览（600×800）").font(.caption).foregroundStyle(.secondary)
                        Text("不满意可改氛围/画面方向再绘一次；书名与署名请核对逐字无误。")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if adopted {
                            Label("已采用——书架即用", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        HStack {
                            Button("复制 SVG") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(svgCode, forType: .string)
                            }
                            .controlSize(.mini)
                            Button(adopted ? "已采用" : "采用为本书封面") {
                                adopt()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(adopted)
                        }
                    }
                    Spacer()
                }
                .padding(.top, ZBSpace.xs)
            }
            Spacer()
        }
        .padding(ZBSpace.lg)
        .frame(minWidth: ZBSpace.Sheet.wide, minHeight: 560)
        .onAppear { loadMeta() }
    }

    private func loadMeta() {
        let projectFile = ref.url.appendingPathComponent("project.json")
        guard let project = try? Disk.readJSON(NovelProject.self, from: projectFile) else { return }
        metaGenre = project.genre
        metaPremise = project.premise
    }

    private func run() {
        svgCode = ""
        adopted = false
        let author = authorName
        let moodText = mood
        let dirText = direction
        Task {
            if let raw = await vm.ai.runCoverSVGForBook(
                config: vm.config,
                bookTitle: ref.title,
                genre: metaGenre,
                premise: metaPremise,
                authorName: author,
                mood: moodText,
                direction: dirText),
               let code = CoverSVG.extractSVG(raw) {
                await MainActor.run {
                    svgCode = code
                    preview = CoverSVG.render(code, width: 240, height: 320)
                }
            }
        }
    }

    private func adopt() {
        guard !svgCode.isEmpty else { return }
        let file = ref.url.appendingPathComponent("cover.svg")
        do {
            try Disk.write(Data(svgCode.utf8), to: file)
            ShelfCoverLoader.invalidate(url: ref.url)
            adopted = true
            onAdopted()
        } catch {
            vm.ai.lastError = "封面写入失败：\\(error.localizedDescription)"
        }
    }
}
