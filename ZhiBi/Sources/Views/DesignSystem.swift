import SwiftUI
import AppKit

// MARK: - 执笔设计系统：朱砂 × 墨 × 宣纸（明暗双态动态色）

enum ZB {
    // 主题色
    static let vermillion = Color(red: 0.784, green: 0.298, blue: 0.204)
    static let vermillionDeep = Color(red: 0.663, green: 0.216, blue: 0.149)
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let teal = Color(red: 0.13, green: 0.55, blue: 0.55)

    /// 明暗自适应色
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 卡片底色
    static let card = dynamic(
        light: NSColor(srgbRed: 1.0, green: 0.996, blue: 0.984, alpha: 1),
        dark: NSColor(srgbRed: 0.142, green: 0.140, blue: 0.146, alpha: 1))

    /// 页面底色（微暖）
    static let canvas = dynamic(
        light: NSColor(srgbRed: 0.969, green: 0.957, blue: 0.933, alpha: 1),
        dark: NSColor(srgbRed: 0.106, green: 0.104, blue: 0.110, alpha: 1))

    /// 边线
    static let hairline = dynamic(
        light: NSColor(srgbRed: 0.82, green: 0.79, blue: 0.73, alpha: 1),
        dark: NSColor(white: 0.30, alpha: 1))

    /// 纸面编辑区底色
    static let paper = dynamic(
        light: NSColor(srgbRed: 0.995, green: 0.988, blue: 0.968, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.123, blue: 0.128, alpha: 1))
}

// MARK: - 卡片修饰符

struct ZBCardStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .padding(padding)
                .background(ZB.card)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ZB.hairline.opacity(0.8)))
        } else if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
                .padding(padding)
                .background(ZB.card)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ZB.hairline.opacity(0.55)))
        }
    }
}

extension View {
    func zbCard(padding: CGFloat = 12) -> some View {
        modifier(ZBCardStyle(padding: padding))
    }
}

// MARK: - 芯片（状态/标签）

struct ZBChip: View {
    let text: String
    var color: Color = .accentColor
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(filled ? color : color.opacity(0.14))
            .foregroundStyle(filled ? Color.white : color)
            .clipShape(Capsule())
    }
}

// MARK: - 封面占位（书籍卡片用：标题首字 + 由书名哈希定的暖色渐变）

struct BookCoverTile: View {
    let title: String
    var size: CGFloat = 52
    var width: CGFloat?
    var height: CGFloat?

    static let palette: [(Color, Color)] = [
        (Color(red: 0.78, green: 0.32, blue: 0.22), Color(red: 0.45, green: 0.16, blue: 0.12)),
        (Color(red: 0.20, green: 0.42, blue: 0.52), Color(red: 0.10, green: 0.22, blue: 0.30)),
        (Color(red: 0.36, green: 0.50, blue: 0.28), Color(red: 0.18, green: 0.28, blue: 0.14)),
        (Color(red: 0.48, green: 0.38, blue: 0.62), Color(red: 0.24, green: 0.18, blue: 0.36)),
        (Color(red: 0.72, green: 0.50, blue: 0.22), Color(red: 0.38, green: 0.26, blue: 0.10)),
    ]

    static func colors(for title: String) -> (Color, Color) {
        let h = abs(title.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) })
        return palette[h % palette.count]
    }

    private var colors: (Color, Color) {
        Self.colors(for: title)
    }

    private var glyph: String {
        String(title.prefix(1))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(glyph)
                .font(.system(size: (height ?? size) * 0.38, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: width ?? size, height: height ?? size)
        .clipShape(RoundedRectangle(cornerRadius: (width ?? size) * 0.07))
        .overlay(RoundedRectangle(cornerRadius: (width ?? size) * 0.07).strokeBorder(Color.white.opacity(0.18)))
        .overlay(
            // 书脊高光
            LinearGradient(colors: [.white.opacity(0.14), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: (width ?? size) * 0.12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        )
    }
}
