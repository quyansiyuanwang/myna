import SwiftUI
import AppKit

/// 模型 / 思考强度小弹窗使用的无边框子窗口。
///
/// `NSPopover` 嵌在聊天面板（本身也是 `NSPopover`）里时，`show(relativeTo:of:preferredEdge:)`
/// 的定位矩形会被忽略（实测 `preferredEdge` 取 `.minY` / `.maxY` 落点完全相同，弹窗会跑到面板中部），
/// 因此这里改用子窗口按屏幕坐标精确摆放。
final class ModelPopupWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 模型 / 思考强度小弹窗的显示控制。
@MainActor
final class ModelPopupController {
    static let shared = ModelPopupController()

    private var window: ModelPopupWindow?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// 弹窗宽度（与输入栏模型按钮大致对齐的紧凑宽度）。
    private let width: CGFloat = 268

    var isShown: Bool { window?.isVisible == true }

    /// 下发外观：无边框子窗口需要显式设置才能与聊天面板保持一致。
    func setAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
    }

    /// 在宿主窗口（聊天面板或聊天窗口）输入栏上方、靠右显示弹窗。
    ///
    /// - Parameters:
    ///   - bottomInset: 输入栏自身高度（含底部内边距），弹窗紧贴其上。
    ///   - rightInset: 距宿主窗口右边缘的距离（让弹窗与模型按钮对齐）。
    func show(theme: ChatTheme, host: NSWindow, bottomInset: CGFloat, rightInset: CGFloat) {
        let hosting = NSHostingController(rootView: ModelControlPanel(theme: theme))
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.height < 60 || size.height > 600 { size.height = 120 }
        size.width = width
        hosting.view.frame = NSRect(origin: .zero, size: size)

        let w: ModelPopupWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = ModelPopupWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless],
                                 backing: .buffered,
                                 defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .popUpMenu
            w.appearance = AppearanceOption.from(SettingsStore.shared.settings.appearance).nsAppearance
            w.isReleasedWhenClosed = false
            w.contentViewController = hosting
            window = w
        }
        w.setContentSize(size)
        // 紧贴输入栏上方，右边缘与宿主窗口对齐后回退 rightInset。
        let origin = NSPoint(x: host.frame.maxX - rightInset - width,
                             y: host.frame.minY + bottomInset + 6)
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.makeKeyAndOrderFront(nil)
        installOutsideMonitor()
        installResignObserver(for: w)
    }

    func hide() {
        removeOutsideMonitor()
        window?.orderOut(nil)
    }

    // MARK: - 点击外部关闭

    /// 全局监听其它应用的点击；本应用内的点击由弹窗失去 key 状态处理。
    private func installOutsideMonitor() {
        removeOutsideMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isShown else { return }
                ModelPopupState.shared.isOpen = false
            }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    /// 弹窗失去 key（例如点击了聊天面板其它位置）时同步关闭状态。
    private func installResignObserver(for w: NSWindow) {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: w,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if ModelPopupState.shared.isOpen { ModelPopupState.shared.isOpen = false }
            }
        }
    }
}
