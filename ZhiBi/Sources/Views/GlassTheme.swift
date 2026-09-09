import SwiftUI
import AppKit

// MARK: - 液态玻璃主题助手
// macOS 26+ 使用原生 Liquid Glass；旧系统回退为材质 + 细边线。

/// 液态玻璃表面（尊重「减少透明度」无障碍设置：回退为实底）
struct ZBGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat
    var interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(ZB.card)
                .cornerRadius(cornerRadius)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(ZB.hairline.opacity(0.8)))
        } else if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(ZB.hairline.opacity(0.55)))
        }
    }
}

extension View {
    /// 液态玻璃表面
    @ViewBuilder
    func zbGlass(cornerRadius: CGFloat = 10, interactive: Bool = false) -> some View {
        modifier(ZBGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// 玻璃按钮样式（主按钮用 prominent 变体请直接用 .buttonStyle(.glassProminent)）
    @ViewBuilder
    func zbGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
