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
        guard let store = AppDelegate.activeModel?.store else { return .terminateNow }
        store.saveNow_forced()
        // 保存失败不能静默退出：否则「最后一次成功保存之后」的编辑静默丢失
        if let err = store.lastSaveError, !err.isEmpty {
            let alert = NSAlert()
            alert.messageText = "退出前保存失败"
            alert.informativeText = err + "\n\n选「取消」可留在应用内重试保存（自动保存会继续尝试）。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "取消退出")
            alert.addButton(withTitle: "仍要退出")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { return .terminateCancel }
            store.lastSaveError = nil
        }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApp 就绪后应用存储的外观偏好
        if let mode = AppDelegate.activeModel?.appearanceMode {
            AppearanceMode.apply(mode)
        }
    }
}
