import Foundation
import AppKit

// MARK: - 外观模式：跟随系统 / 浅色 / 深色（全局，含原生 NSTextView）

enum AppearanceMode: String, CaseIterable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// NSApp 在 App.init 阶段尚不存在，必须 nil-safe；启动完成后再调用才能真正生效
    static func apply(_ mode: AppearanceMode) {
        NSApp?.appearance = mode.nsAppearance
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}
