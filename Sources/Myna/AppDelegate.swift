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
        // 面板模式：不透明度与尺寸
        if let p = popover {
            p.contentViewController?.view.window?.alphaValue = s.windowOpacity
            let size = NSSize(width: s.windowWidth, height: s.windowHeight)
            if p.contentSize != size { p.contentSize = size }
        }
        // 用户修改默认窗口尺寸：清除自动保存的框架并立即应用
        if let lw = lastWindowW, lw != s.windowWidth || lastWindowH != s.windowHeight {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame MynaWindow")
            window?.setContentSize(NSSize(width: s.windowWidth, height: s.windowHeight))
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
        w.minSize = NSSize(width: 380, height: 480)
        w.contentView = NSHostingView(rootView: chatView())
        w.delegate = self
        w.level = s.alwaysOnTop ? .floating : .normal
        w.alphaValue = s.windowOpacity
        w.center()
        w.setFrameAutosaveName("MynaWindow")
        window = w
        return w
    }

    private func chatView() -> ChatView {
        ChatView(
            model: model,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onClose: { [weak self] in self?.hideWindow() },
            onResize: { [weak self] size in self?.resizePanel(to: size) }
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

    /// 面板拖拽调整尺寸（来自界面右下角的手柄）。
    func resizePanel(to size: CGSize) {
        let w = max(360, min(1200, size.width))
        let h = max(320, min(1400, size.height))
        popover?.contentSize = NSSize(width: w, height: h)
        SettingsStore.shared.settings.windowWidth = w
        SettingsStore.shared.settings.windowHeight = h
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Myna 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.level = .floating
            settingsWindow = w
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
