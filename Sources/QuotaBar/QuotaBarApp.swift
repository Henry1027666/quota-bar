import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let store = QuotaStore()
    private var activity: NSObjectProtocol?
    private var userRequestedQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // 菜单栏常驻应用：禁用自动终止并声明用户态后台活动，
        // 降低 macOS 将“无窗口”菜单栏应用按 TAL 回收的可能。
        ProcessInfo.processInfo.disableAutomaticTermination("QuotaBar 是常驻菜单栏应用")
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "QuotaBar 常驻菜单栏轮询各厂商额度"
        )

        // 菜单栏图标：左键打开额度面板，右键弹出「退出」菜单（面板内不设退出按钮）。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Quota Bar")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Quota Bar"
        }
        statusItem = item

        // 额度面板：NSPopover 承载 DashboardView
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 620)
        popover.contentViewController = NSHostingController(rootView: DashboardView(store: store))
        self.popover = popover

        // 用户通过右键菜单“退出”时，先标记为显式退出，再发起 terminate。
        NotificationCenter.default.addObserver(
            forName: Notification.Name("QuotaBarUserQuit"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.userRequestedQuit = true
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuitMenu(from: button)
        } else {
            togglePopover(from: button)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    private func showQuitMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出 Quota Bar", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func quitFromMenu() {
        userRequestedQuit = true
        NSApplication.shared.terminate(nil)
    }

    /// macOS 26 在移除/隐藏菜单栏项时会调用 terminate:（无任何退出意图），
    /// 若直接放行，应用会在启动后不久被系统静默回收。这里对“非用户主动退出”一律取消。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userRequestedQuit { return .terminateNow }
        // 登出/重启/关机/osascript quit 等退出 Apple Event 应正常放行。
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEQuitApplication) {
            return .terminateNow
        }
        return .terminateCancel
    }
}

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 无主窗口的菜单栏常驻应用：所有 UI 由 AppDelegate 的 NSStatusItem/NSPopover 提供。
        Settings { EmptyView() }
    }
}
