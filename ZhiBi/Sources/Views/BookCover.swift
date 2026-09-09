import SwiftUI

/// 封面视图：style 决定构图，颜色由书名哈希决定（同一本书换风格不换色系）
struct BookCover: View {
    let title: String
    var style: Int
    var width: CGFloat = 132
    var height: CGFloat = 182

    private var colors: (Color, Color) { BookCoverTile.colors(for: title) }
    private var glyph: String { String(title.prefix(1)) }
    private var titleChars: [Character] { Array(title.prefix(7)) }

    var body: some View {
        Group {
            switch style {
            case 1: horizontalTitle
            case 2: sealStyle
            case 3: inkLandscape
            case 4: bambooStyle
            default: verticalSpine
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.07))
        .overlay(RoundedRectangle(cornerRadius: width * 0.07).strokeBorder(Color.white.opacity(0.18)))
        .overlay(
            LinearGradient(colors: [.white.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
        )
    }

    /// 0 竖排书名（书脊式）+ 竹席纹
    private var verticalSpine: some View {
        ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: height * 0.028) {
                ForEach(0..<9, id: \.self) { _ in
                    Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
                }
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: height * 0.016) {
                ForEach(Array(titleChars.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: width * 0.145, weight: .semibold, design: .serif))
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
            cornerSeal
        }
    }

    /// 1 横排大字（书衣双框）
    private var horizontalTitle: some View {
        ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer()
                Text(title)
                    .font(.system(size: width * 0.13, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, width * 0.1)
                Spacer()
                ornamentLine
                    .padding(.horizontal, width * 0.22)
                    .padding(.bottom, height * 0.1)
            }
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                .padding(width * 0.05)
        }
    }

    /// 2 朱砂印（米白纸面 + 大印）
    private var sealStyle: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.90, blue: 0.83),
                                    Color(red: 0.87, green: 0.83, blue: 0.73)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: height * 0.06) {
                ZStack {
                    RoundedRectangle(cornerRadius: width * 0.09)
                        .fill(LinearGradient(colors: [ZB.vermillion, ZB.vermillionDeep],
                                             startPoint: .top, endPoint: .bottom))
                    Text(glyph)
                        .font(.system(size: width * 0.30, weight: .bold, design: .serif))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .frame(width: width * 0.42, height: width * 0.42)
                .rotationEffect(.degrees(-3))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(title)
                    .font(.system(size: width * 0.10, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0.22, green: 0.19, blue: 0.15))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, width * 0.08)
            }
        }
    }

    /// 3 水墨远山（山影 + 白色题签）
    private var inkLandscape: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.22),
                                    Color(red: 0.07, green: 0.08, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                mountainLayer(size: geo.size, height: geo.size.height * 0.38, seed: 2, alpha: 0.35)
                mountainLayer(size: geo.size, height: geo.size.height * 0.22, seed: 5, alpha: 0.55)
            }
            VStack {
                Spacer()
                Text(title)
                    .font(.system(size: width * 0.10, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(red: 0.11, green: 0.10, blue: 0.09))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, height * 0.025)
                    .padding(.horizontal, width * 0.07)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.92)))
                    .padding(.horizontal, width * 0.09)
                    .padding(.bottom, height * 0.07)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 4 竹纹竖条
    private var bambooStyle: some View {
        ZStack {
            LinearGradient(colors: [colors.1, colors.0], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    Rectangle()
                        .fill(.white.opacity(i.isMultiple(of: 2) ? 0.05 : 0.02))
                        .frame(width: width / 10)
                }
            }
            Text(title)
                .font(.system(size: width * 0.115, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, width * 0.1)
            VStack {
                Spacer()
                ornamentLine
                    .padding(.horizontal, width * 0.3)
                    .padding(.bottom, height * 0.07)
            }
        }
    }

    // MARK: 复用小件

    private var ornamentLine: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
            Circle().fill(ZB.vermillion.opacity(0.9)).frame(width: 5, height: 5)
            Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
        }
    }

    private var cornerSeal: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("执")
                    .font(.system(size: width * 0.075, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: width * 0.12, height: width * 0.12)
                    .background(RoundedRectangle(cornerRadius: width * 0.025).fill(ZB.vermillion.opacity(0.9)))
                    .rotationEffect(.degrees(-3))
                    .padding(width * 0.045)
            }
        }
    }

    private func mountainLayer(size: CGSize, height: CGFloat, seed: Double, alpha: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            let steps = 28
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let x = size.width * t
                let y = size.height * 0.78
                    - height * (0.6 + 0.4 * sin(t * 5.2 + seed))
                    - height * 0.2 * sin(t * 11.0 + seed * 3)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
        .fill(.white.opacity(alpha * 0.35))
    }
}
