import AppKit
import SwiftUI

/// 主窗口侧边栏选中项（由 MainWindowController 跨层写入，弹层点厂商行时定位详情页）。
@MainActor
final class MainWindowSelection: ObservableObject {
    @Published var item: SidebarItem? = .overview
}

/// 主窗口（NavigationSplitView 详情窗口）的单例管理。
/// 平时应用是纯菜单栏 Agent（.accessory，无 Dock 图标）；主窗口打开时切 .regular
/// 让 Dock / Cmd+Tab 可见，主窗口关闭且 DeepSeek 登录窗口也没开时切回 .accessory。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let store: QuotaStore
    private let selection = MainWindowSelection()
    private var window: NSWindow?

    init(store: QuotaStore) {
        self.store = store
    }

    /// 打开主窗口；指定厂商时把侧边栏选中项切到该厂商详情页。
    func open(selecting kind: ProviderKind?) {
        if let kind {
            selection.item = .provider(kind)
        } else if window == nil {
            selection.item = .overview
        }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 重估激活策略：主窗口或 DeepSeek 登录窗口任一可见时保持 .regular，都关了退回纯菜单栏。
    func updateActivationPolicy() {
        let mainVisible = window?.isVisible ?? false
        if !mainVisible, !DeepSeekWebSession.shared.isLoginWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Quota Bar"
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: MainWindowView(store: store, selection: selection)
        )
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        // willClose 时 isVisible 仍为 true，延迟到窗口真正关闭后再重估。
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy()
        }
    }
}
