import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var settingsWindow: NSWindow?
    /// 下拉面板模式使用的 popover
    var popover: NSPopover?
    let model = ChatModel()
    let hotKey = HotKeyManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastHotkey: String?
    private var lastHotkeyOpen: String?
    private var lastHotkeyClear: String?
    private var lastHotkeyMode: String?
    private var lastLaunchAtLogin: Bool?
    private var lastOnTop: Bool?
    private var lastAppearance: String?
    private var lastDock: Bool?
    private var lastIcon: String?
    private var lastIconSize: Double?
    private var lastWindowW: Double?
    private var lastWindowH: Double?
    /// 正在把窗口的真实尺寸同步回设置，避免 applySettings 再次回写造成循环
    private var isSyncingWindowFrame = false
    /// 正在拖拽手柄调整面板/窗口尺寸，期间不干预 popover 尺寸、不写回设置
    private var isResizingPanel = false
    /// 拖拽过程中最近一次的目标尺寸，拖拽结束时一次性落盘
    private var pendingResizeSize: CGSize?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LocalResources.ensureDirectories()
        MCPManager.shared.start()
        installMainMenu()
        hotKey.onPressed = { [weak self] in self?.hotKeyPressed() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = statusImage(for: SettingsStore.shared.settings.menuBarIcon) {
                button.image = img
            } else {
                button.title = "Myna"
            }
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 设置变化时实时生效
        SettingsStore.shared.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.applySettings(s) }
            .store(in: &cancellables)

        // 启动时应用一次
        applySettings(SettingsStore.shared.settings)

        // 调试/自动化：启动后打开窗口（MYNA_OPEN_ON_LAUNCH=1）
        if ProcessInfo.processInfo.environment["MYNA_OPEN_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showWindow(startVoice: false)
            }
        }

        // 调试/自动化：启动后打开设置并跳到指定分区（MYNA_OPEN_SETTINGS=model）
        if let raw = ProcessInfo.processInfo.environment["MYNA_OPEN_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if let section = SettingsSection(rawValue: raw) {
                    SettingsNavigator.shared.open(section)
                }
                self?.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.flush()
        ConversationStore.shared.flush()
        MCPManager.shared.shutdown()
    }

    private func applySettings(_ s: AppSettings) {
        if lastHotkey != s.hotkey || lastHotkeyOpen != s.hotkeyOpen || lastHotkeyClear != s.hotkeyClear || lastHotkeyMode != s.hotkeyMode {
            lastHotkey = s.hotkey
            lastHotkeyOpen = s.hotkeyOpen
            lastHotkeyClear = s.hotkeyClear
            lastHotkeyMode = s.hotkeyMode
            let release: (() -> Void)? = s.hotkeyMode == "pushToTalk"
                ? { [weak self] in self?.hotKeyReleased() }
                : nil
            hotKey.register(combo: s.hotkey, onRelease: release)
            hotKey.registerExtra("open", combo: s.hotkeyOpen) { [weak self] in
                self?.showWindow(startVoice: false)
            }
            hotKey.registerExtra("clear", combo: s.hotkeyClear) { [weak self] in
                self?.model.clear()
            }
        }
        if lastOnTop != s.alwaysOnTop {
            lastOnTop = s.alwaysOnTop
            window?.level = s.alwaysOnTop ? .floating : .normal
        }
        if lastLaunchAtLogin != s.launchAtLogin {
            lastLaunchAtLogin = s.launchAtLogin
            applyLaunchAtLogin(s.launchAtLogin)
        }
        if lastAppearance != s.appearance {
            lastAppearance = s.appearance
            NSApp.appearance = AppearanceOption.from(s.appearance).nsAppearance
        }
        if lastDock != s.showInDock {
            lastDock = s.showInDock
            NSApp.setActivationPolicy(s.showInDock ? .regular : .accessory)
        }
        if lastIcon != s.menuBarIcon {
            lastIcon = s.menuBarIcon
            statusItem.button?.image = statusImage(for: s.menuBarIcon)
        }
        // 菜单栏图标尺寸变化时重新应用
        if lastIconSize != s.menuBarIconSize {
            lastIconSize = s.menuBarIconSize
            statusItem.button?.image = statusImage(for: s.menuBarIcon)
        }
        // 面板模式：不透明度与尺寸。拖拽手柄期间不改动 popover 尺寸，避免与手势抢占。
        if let p = popover {
            p.contentViewController?.view.window?.alphaValue = s.windowOpacity
            if !isResizingPanel {
                let size = NSSize(width: s.windowWidth, height: s.windowHeight)
                if p.contentSize != size { p.contentSize = size }
            }
        }
        // 仅当尺寸由设置界面改动（而非窗口/面板自身同步写回）时，才应用到窗口；
        // 使用 setContentSize 保留系统自动保存的窗口位置，不再清除 "NSWindow Frame MynaWindow"。
        if !isSyncingWindowFrame,
           let lw = lastWindowW, lw != s.windowWidth || lastWindowH != s.windowHeight {
            if let w = window {
                let target = NSSize(width: s.windowWidth, height: s.windowHeight)
                if w.contentRect(forFrameRect: w.frame).size != target { w.setContentSize(target) }
            }
        }
        lastWindowW = s.windowWidth
        lastWindowH = s.windowHeight
        window?.alphaValue = s.windowOpacity
    }

    /// 菜单栏图标：`custom` 用内置模板图（自动适配浅/深色），否则按 SF Symbol 名解析。
    func statusImage(for icon: String) -> NSImage? {
        if icon == "custom" {
            if let img = NSImage(named: "MenuBarTemplate") {
                img.isTemplate = true
                if img.size.height > 0 {
                    let h = CGFloat(SettingsStore.shared.settings.menuBarIconSize)
                    img.size = NSSize(width: h * img.size.width / img.size.height, height: h)
                }
                return img
            }
            return NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Myna")
        }
        return NSImage(systemSymbolName: icon, accessibilityDescription: "Myna")
    }

    // MARK: - 主菜单

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "市场…", action: #selector(openMarketplace), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 Myna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 独立聊天窗口

    func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let s = SettingsStore.shared.settings
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: s.windowWidth, height: s.windowHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Myna"
        w.isReleasedWhenClosed = false
        // 与 resizePanel 的钳制保持一致
        w.minSize = NSSize(width: Self.minPanelWidth, height: Self.minPanelHeight)
        // 允许拖拽窗口背景移动窗口
        w.isMovableByWindowBackground = true
        w.contentView = NSHostingView(rootView: chatView())
        w.delegate = self
        w.level = s.alwaysOnTop ? .floating : .normal
        w.alphaValue = s.windowOpacity
        // 恢复上次的位置与尺寸；仅在无记录时居中，随后开启自动保存
        if !w.setFrameUsingName("MynaWindow") { w.center() }
        w.setFrameAutosaveName("MynaWindow")
        window = w
        dumpWindow("chat", w)
        return w
    }

    /// 打印窗口关键属性，便于运行时验证拖拽/缩放配置（仅 MYNA_DEBUG=1）。
    private func dumpWindow(_ name: String, _ w: NSWindow) {
        guard ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" else { return }
        let mask = w.styleMask
        var flags: [String] = []
        if mask.contains(.titled) { flags.append("titled") }
        if mask.contains(.closable) { flags.append("closable") }
        if mask.contains(.miniaturizable) { flags.append("miniaturizable") }
        if mask.contains(.resizable) { flags.append("resizable") }
        let content = w.contentRect(forFrameRect: w.frame).size
        dbg("WINDOWDUMP name=\(name) styleMask=\(mask.rawValue)[\(flags.joined(separator: "|"))] "
            + "movableByBackground=\(w.isMovableByWindowBackground) minSize=\(w.minSize) "
            + "autosave=\(w.frameAutosaveName) contentSize=\(content) frame=\(w.frame) "
            + "contentMin=\(w.contentMinSize) contentMax=\(w.contentMaxSize)")
    }

    private func chatView() -> ChatView {
        ChatView(
            model: model,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onClose: { [weak self] in self?.hideWindow() },
            onResize: { [weak self] size in self?.resizePanel(to: size) },
            onResizeEnd: { [weak self] in self?.endResizePanel() }
        )
    }

    /// 下拉面板：锚定状态栏图标，`.transient` 使其在点击外部/失活时自动关闭。
    func ensurePopover() -> NSPopover {
        if let p = popover { return p }
        let s = SettingsStore.shared.settings
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentSize = NSSize(width: s.windowWidth, height: s.windowHeight)
        p.contentViewController = NSHostingController(rootView: chatView())
        p.delegate = self
        popover = p
        return p
    }

    func hideWindow() {
        model.windowVisible = false
        if SettingsStore.shared.settings.panelMode {
            popover?.performClose(nil)
        } else {
            window?.orderOut(nil)
        }
        if SettingsStore.shared.settings.clearOnClose { model.clear() }
    }

    /// 面板/窗口尺寸下限、上限，与 NSWindow.minSize 保持一致。
    static let minPanelWidth: CGFloat = 360
    static let minPanelHeight: CGFloat = 320
    static let maxPanelWidth: CGFloat = 1200
    static let maxPanelHeight: CGFloat = 1400

    private func clampPanelSize(_ size: CGSize) -> CGSize {
        CGSize(width: min(Self.maxPanelWidth, max(Self.minPanelWidth, size.width)),
               height: min(Self.maxPanelHeight, max(Self.minPanelHeight, size.height)))
    }

    /// 拖拽手柄实时调整尺寸（来自界面右下角）：只应用到 popover/窗口，不写回设置。
    func resizePanel(to size: CGSize) {
        let clamped = clampPanelSize(size)
        isResizingPanel = true
        pendingResizeSize = clamped
        let target = NSSize(width: clamped.width, height: clamped.height)
        popover?.contentSize = target
        if let win = window, win.contentRect(forFrameRect: win.frame).size != target { win.setContentSize(target) }
    }

    /// 拖拽结束：把最终尺寸一次性写回设置，避免拖拽过程中反复落盘、互相抢占。
    func endResizePanel() {
        defer {
            isResizingPanel = false
            pendingResizeSize = nil
        }
        guard let clamped = pendingResizeSize else { return }
        isSyncingWindowFrame = true
        // 宽高一次性赋值，避免中间态（新宽 + 旧高）触发 applySettings 把窗口改回去
        var s = SettingsStore.shared.settings
        s.windowWidth = Double(clamped.width)
        s.windowHeight = Double(clamped.height)
        SettingsStore.shared.settings = s
        isSyncingWindowFrame = false
    }

    func showWindow(startVoice: Bool) {
        dbg("showWindow panelMode=\(SettingsStore.shared.settings.panelMode) button=\(statusItem.button != nil)")
        model.windowVisible = true
        if SettingsStore.shared.settings.panelMode {
            guard let button = statusItem.button else { return }
            let p = ensurePopover()
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 透明度需要作用在 popover 自身的窗口上
            p.contentViewController?.view.window?.alphaValue = SettingsStore.shared.settings.windowOpacity
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let w = ensureWindow()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if startVoice { model.startVoice() }
    }

    func popoverDidClose(_ notification: Notification) {
        model.windowVisible = false
        if SettingsStore.shared.settings.clearOnClose { model.clear() }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            model.windowVisible = false
            if SettingsStore.shared.settings.clearOnClose { model.clear() }
        }
    }

    /// 窗口边缘拖拽缩放：把真实内容尺寸写回设置（拖拽手柄期间跳过，由 endResizePanel 统一处理）。
    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // 拖拽手柄期间由 endResizePanel 统一落盘，避免与手势互相抢占
        guard !isResizingPanel else { return }
        syncWindowSizeToSettings()
    }

    /// 窗口移动：位置由 `setFrameUsingName` / `setFrameAutosaveName` 自动记忆，无需手动写盘。
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
    }

    private func syncWindowSizeToSettings() {
        guard !isSyncingWindowFrame, let w = window else { return }
        let size = w.contentRect(forFrameRect: w.frame).size
        let cur = SettingsStore.shared.settings
        guard abs(cur.windowWidth - Double(size.width)) >= 0.5
                || abs(cur.windowHeight - Double(size.height)) >= 0.5 else { return }
        isSyncingWindowFrame = true
        // 宽高一次性赋值，避免中间态（新宽 + 旧高）触发 applySettings 把窗口改回去
        var s = cur
        s.windowWidth = Double(size.width)
        s.windowHeight = Double(size.height)
        SettingsStore.shared.settings = s
        isSyncingWindowFrame = false
    }

    /// 面板模式下失焦即隐藏（窗口模式）。
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        guard !SettingsStore.shared.settings.panelMode else { return }
        // 窗口模式：不自动隐藏
    }

    @objc func openSettings() {
        // 面板模式下先收起聊天面板，避免其高层级遮挡设置窗口
        if SettingsStore.shared.settings.panelMode { hideWindow() }
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Myna 设置"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 620, height: 460)
            w.contentView = NSHostingView(rootView: SettingsView())
            // 恢复上次的位置与尺寸；仅在无记录时居中，随后开启自动保存
            if !w.setFrameUsingName("MynaSettingsWindow") { w.center() }
            w.setFrameAutosaveName("MynaSettingsWindow")
            w.level = .floating
            settingsWindow = w
            dumpWindow("settings", w)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 打开设置并直接跳到「市场」分区。
    @objc func openMarketplace() {
        SettingsNavigator.shared.open(.market)
        openSettings()
    }

    // MARK: - 状态栏

    /// 仅在 MYNA_DEBUG=1 时写日志，便于排查启动与窗口问题。
    private func dbg(_ m: String) {
        guard ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" else { return }
        let line = "\(Date()) \(m)\n"
        if let d = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: "/tmp/myna-debug.log") {
                fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
            } else {
                try? line.write(toFile: "/tmp/myna-debug.log", atomically: true, encoding: .utf8)
            }
        }
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if SettingsStore.shared.settings.panelMode {
            if let p = popover, p.isShown { hideWindow() } else { showWindow(startVoice: false) }
            return
        }
        dbg("statusClicked")
        if let w = window, w.isVisible {
            hideWindow()
        } else {
            showWindow(startVoice: false)
        }
    }

    func hotKeyPressed() {
        // 长按说话：按下即开始聆听（不做切换）
        if SettingsStore.shared.settings.hotkeyMode == "pushToTalk" {
            guard !model.isRecording else { return }
            if model.busy { model.cancel() }
            showWindow(startVoice: true)
            return
        }
        // 切换模式：录音中再次按下结束（并按设置决定是否发送）
        if model.isRecording {
            model.stopVoice(send: SettingsStore.shared.settings.hotkeyAutoSend)
            return
        }
        // 正在回答：打断并开始聆听
        if model.busy { model.cancel() }
        showWindow(startVoice: true)
    }

    /// 长按说话：松开即结束并发送。
    func hotKeyReleased() {
        guard SettingsStore.shared.settings.hotkeyMode == "pushToTalk" else { return }
        if model.isRecording { model.stopVoice(send: true) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 Myna", action: #selector(openItem), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "市场…", action: #selector(openMarketplace), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func openItem() { showWindow(startVoice: false) }

    // MARK: - 开机自启

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let la = NSString(string: "~/Library/LaunchAgents/com.local.myna.plist").expandingTildeInPath
        if enabled {
            let app = NSString(string: "~/Applications/Myna.app").expandingTildeInPath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.local.myna</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(app)</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(atPath: (la as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? plist.write(toFile: la, atomically: true, encoding: .utf8)
            ToolRunner.sh("launchctl unload \(ToolRunner.q(la)) 2>/dev/null; launchctl load \(ToolRunner.q(la)) 2>/dev/null")
        } else {
            ToolRunner.sh("launchctl unload \(ToolRunner.q(la)) 2>/dev/null; rm -f \(ToolRunner.q(la))")
        }
    }
}
