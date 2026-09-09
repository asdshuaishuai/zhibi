import SwiftUI
import AppKit

@main
struct ZhiBiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var vm: AppViewModel

    init() {
        let model = AppViewModel()
        _vm = StateObject(wrappedValue: model)
        AppDelegate.activeModel = model
    }

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入大纲 / 设定 / 正文…") {
                    vm.requestImportViaPanel = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    let item = NSMenuItem()
                    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        Settings {
            SettingsView(vm: vm)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var activeModel: AppViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q/关窗落在 1 秒防抖窗口内也不丢最后一次编辑
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.activeModel?.store?.saveNow_forced()
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApp 就绪后应用存储的外观偏好
        if let mode = AppDelegate.activeModel?.appearanceMode {
            AppearanceMode.apply(mode)
        }
    }
}
