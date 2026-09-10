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
        startMemoryWatchdog()

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

        // 额度面板：NSPopover 承载 DashboardView，窗口高度随内容条目自适应。
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 620)
        let hosting = NSHostingController(
            rootView: DashboardView(store: store) { [weak self] height in
                self?.updatePopoverContentSize(height: height)
            }
        )
        popover.contentViewController = hosting
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

    /// 内存看门狗：每 60s 检查物理内存占用，超阈值把主线程调用栈写入日志，
    /// 用于在卡死/内存飙升时留下定位证据（无需外部工具）。
    private func startMemoryWatchdog(thresholdMB: Int = 500) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                let mb = Self.currentMemoryMB()
                if mb > thresholdMB {
                    Log.append("MEM", "内存 \(mb)MB 超阈值，主线程栈：\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                }
            }
        }
    }

    private static func currentMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuitMenu(from: button)
        } else {
            togglePopover(from: button)
        }
    }

    /// 根据 DashboardView 实测内容高度调整 popover 尺寸（下限 120，上限 620）。
    /// 高度自适应回调的重入锁：防止 setContentSize → 布局 → 高度回调 → setContentSize 的递归振荡。
    private var isUpdatingPopoverSize = false

    private func updatePopoverContentSize(height: CGFloat) {
        guard let popover else { return }
        let clamped = min(max(height, 120), 620)
        let newSize = NSSize(width: 350, height: clamped)
        guard abs(newSize.height - popover.contentSize.height) > 1 else { return }
        // 布局原子操作（NSPerformVisuallyAtomicChange）内禁止同步重入，
        // 否则会在同一次布局栈中无限递归（历史上导致 CPU 100% + UI 无响应）。
        guard !isUpdatingPopoverSize else { return }
        isUpdatingPopoverSize = true
        DispatchQueue.main.async { [weak self] in
            defer { self?.isUpdatingPopoverSize = false }
            guard let self, let popover = self.popover else { return }
            if abs(newSize.height - popover.contentSize.height) > 1 {
                popover.contentSize = newSize
            }
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 去掉 popover 窗口的不透明底色，让 DashboardView 的毛玻璃材质真正透出桌面。
            if let window = popover?.contentViewController?.view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.makeKey()
            }
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
