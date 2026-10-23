import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    /// 全局引用（供设置界面读取宿主尺寸等）。
    static weak var shared: AppDelegate?

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
    /// 启动时刻：跳过启动阶段自身触发的 didBecomeActive，避免每次开机都弹窗。
    private let launchedAt = Date()
    /// 由激活事件自动带出窗口的时刻；状态栏点击随后不应立刻把它又收起。
    private var autoShownAt: Date?
    /// 上次退出时窗口是否可见；重启 / 安全模式恢复后据此把窗口带回来。
    private static let lastWindowVisibleKey = "myna.lastWindowVisible"
    /// 正在拖拽手柄调整面板/窗口尺寸，期间不干预 popover 尺寸、不写回设置
    private var isResizingPanel = false
    /// 拖拽过程中最近一次的目标尺寸，拖拽结束时一次性落盘
    private var pendingResizeSize: CGSize?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        LocalResources.ensureDirectories()
        MCPManager.shared.start()
        installMainMenu()
        // 后台会话完成通知：点击后切到该会话并呼出面板
        NotificationBridge.shared.configure { [weak self] id in
            // 只设置 currentID 不会触发 ChatModel.load，窗口里仍是旧对话。
            // 必须先确认会话存在，再走 selectConversation（它会载入气泡并切上下文）。
            guard ConversationStore.shared.conversations.contains(where: { $0.id == id }) else { return }
            self?.model.selectConversation(id)
            self?.showWindow(startVoice: false)
        }
        // 调试/自动化：启动后发一条测试通知（MYNA_DEBUG_NOTIFY=1）
        if ProcessInfo.processInfo.environment["MYNA_DEBUG_NOTIFY"] == "1" {
            Task {
                _ = await NotificationBridge.shared.requestAuthorizationIfNeeded()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                NotificationBridge.shared.postBackgroundCompletion(
                    conversationID: ConversationStore.shared.currentID ?? UUID(),
                    title: "测试对话",
                    body: "这是一条后台完成通知的测试消息，用于验证通知与点击跳转。"
                )
            }
        }
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

        // 模型 / 思考强度弹窗开关
        ModelPopupState.shared.$isOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                self.setModelPopupOpen(open)
                if open {
                    if !ModelPopupController.shared.isShown { self.showModelPopup() }
                } else if ModelPopupController.shared.isShown {
                    self.hideModelPopup()
                }
            }
            .store(in: &cancellables)

        // 启动时应用一次
        applySettings(SettingsStore.shared.settings)

        // 启动后在后台按 24 小时节流检查更新：不阻塞启动，失败静默。
        Task { await UpdateCenter.shared.autoCheckIfNeeded() }

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

        // 调试/自动化：启动后自动发一条消息（MYNA_DEBUG_ASK=...），用于量化流式渲染占用
        if let ask = ProcessInfo.processInfo.environment["MYNA_DEBUG_ASK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.showWindow(startVoice: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.model.input = ask
                    self?.model.submit()
                }
            }
        }

        // 安全模式：上一次运行若卡死过，本次以精简渲染启动
        SafeMode.load()

        // 重启 / 安全模式恢复 / 更新后回到上次的窗口状态。启用 Dock 图标的用户
        // 也要能看到窗口；纯菜单栏模式仍保持静默启动。
        let lastVisible = UserDefaults.standard.object(forKey: Self.lastWindowVisibleKey) as? Bool ?? false
        if lastVisible || SettingsStore.shared.settings.showInDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showWindow(startVoice: false)
            }
        }

        // 卡死看门狗：后台探针监测主线程，卡住时落一份现场快照
        StallWatchdog.snapshot = { [weak self] in
            guard let self else { return "（AppDelegate 已释放）" }
            let id = self.model.currentConversationID
            let conv = self.model.conversations.first { $0.id == id }
            let size = AppDelegate.shared?.hostContentSize() ?? .zero
            return """
            body/s=\(Probe.rate)  气泡=\(self.model.bubbles.count)  会话=\(self.model.conversations.count)  \
            当前会话消息=\(conv?.bubbles.count ?? 0)  运行中=\(self.model.busy)  \
            流式长度=\(self.model.streaming.count)  思考长度=\(self.model.thinking.count)
            \(Probe.lastScroll)
            窗口=\(Int(size.width))x\(Int(size.height))  面板模式=\(SettingsStore.shared.settings.panelMode)  \
            性能模式=\(SettingsStore.shared.settings.reduceVisualEffects)  渲染上限=\(SettingsStore.shared.settings.maxRenderedMessages)
            """
        }
        StallWatchdog.start()

        // 调试/自动化：模拟主线程阻塞，用于验证看门狗（MYNA_DEBUG_STALL=秒数）
        if let raw = ProcessInfo.processInfo.environment["MYNA_DEBUG_STALL"], let secs = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                Thread.sleep(forTimeInterval: secs)
            }
        }

        // 调试/自动化：确定性流式探针（MYNA_DEBUG_STREAM=字符数），用于量化渲染开销
        if let raw = ProcessInfo.processInfo.environment["MYNA_DEBUG_STREAM"], let n = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showWindow(startVoice: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.model.runStreamProbe(characters: n)
                }
            }
        }

        // 调试/自动化：运行中切换外观（MYNA_DEBUG_TOGGLE_APPEARANCE=1），用于验证运行时切浅/深色
        if ProcessInfo.processInfo.environment["MYNA_DEBUG_TOGGLE_APPEARANCE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                var s = SettingsStore.shared.settings
                s.appearance = (s.appearance == "light") ? "dark" : "light"
                SettingsStore.shared.settings = s
            }
        }

        // 调试/自动化：模拟面板拖拽缩放（MYNA_DEBUG_RESIZE=1），用于复现缩放回写环路
        if ProcessInfo.processInfo.environment["MYNA_DEBUG_RESIZE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showWindow(startVoice: false)
                for i in 0..<20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3 + Double(i) * 0.05) {
                        self.resizePanel(to: CGSize(width: 480 + Double(i) * 8,
                                                    height: 700 + Double(i) * 25))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.endResizePanel() }
            }
        }
    }

    /// 重启自己（退出安全模式、或看门狗恢复后由外部拉起）。
    ///
    /// 优先走 LaunchAgent + launchd：新进程的 TCC「responsible process」是它自己，
    /// 而不是启动它的终端 / 自动化工具。没有登录项时退回 `open -a`。
    func relaunch() {
        let app = Bundle.main.bundlePath
        let agent = NSString(string: "~/Library/LaunchAgents/com.local.myna.plist").expandingTildeInPath
        let command: String
        if FileManager.default.fileExists(atPath: agent) {
            command = """
            sleep 0.6
            if ! /bin/launchctl print gui/$(id -u)/com.local.myna >/dev/null 2>&1; then
              /bin/launchctl bootstrap gui/$(id -u) "\(agent)"
            fi
            /bin/launchctl kickstart -k gui/$(id -u)/com.local.myna
            """
        } else {
            command = "sleep 0.6; /usr/bin/open -a '\(app)'"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        try? task.run()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.flush()
        ConversationStore.shared.flush()
        MCPManager.shared.shutdown()
    }

    /// 最近一次由「设置」推送出去的窗口 / 面板尺寸。
    ///
    /// 判断「设置是否真的变了」必须拿它与设置值比较，**不能**拿窗口回读值与设置值比较：
    /// 系统会钳制尺寸（例如高度超过屏幕），回读值永远不会等于请求值，
    /// 那样就会与 `windowDidResize` 的尺寸回写形成死循环（曾导致 99% CPU 卡死）。
    private var lastAppliedWindowSize: NSSize?
    private var lastAppliedPopoverSize: NSSize?

    /// 把请求尺寸限制在屏幕可见区域内，避免请求一个系统必然钳制的尺寸。
    private func clampToScreen(_ size: NSSize) -> NSSize {
        guard let visible = NSScreen.main?.visibleFrame.size else { return size }
        return NSSize(width: min(size.width, visible.width),
                      height: min(size.height, visible.height))
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
            let appearance = AppearanceOption.from(s.appearance).nsAppearance
            NSApp.appearance = appearance
            applyAppearanceToWindows(appearance)
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
        let wanted = NSSize(width: s.windowWidth, height: s.windowHeight)
        if let p = popover {
            p.contentViewController?.view.window?.alphaValue = s.windowOpacity
            if !isResizingPanel, lastAppliedPopoverSize != wanted {
                lastAppliedPopoverSize = wanted
                p.contentSize = clampToScreen(wanted)
            }
        }
        // 仅在设置值确实变化（与上次推送值不同）时应用到窗口，且用 clampToScreen 兜底。
        // 不使用窗口回读值比较，也不清除 "NSWindow Frame MynaWindow"（保留窗口位置）。
        if let w = window, !isResizingPanel, lastAppliedWindowSize != wanted {
            lastAppliedWindowSize = wanted
            w.setContentSize(clampToScreen(wanted))
        }
        lastWindowW = s.windowWidth
        lastWindowH = s.windowHeight
        window?.alphaValue = s.windowOpacity
    }

    /// 把外观显式下发到每一个窗口。
    ///
    /// 只设 `NSApp.appearance` 不够：`NSPopover` 的窗口不会可靠地跟随应用外观，
    /// 切到浅色后聊天面板会继续用深色（实测：独立 `NSPanel` 正常，popover 窗口保持旧外观）。
    private func applyAppearanceToWindows(_ appearance: NSAppearance?) {
        window?.appearance = appearance
        settingsWindow?.appearance = appearance
        popover?.contentViewController?.view.window?.appearance = appearance
        ModelPopupController.shared.setAppearance(appearance)
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
        let openMain = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "0")
        openMain.keyEquivalentModifierMask = [.command]
        appMenu.addItem(openMain)
        appMenu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        let palette = NSMenuItem(title: "命令面板…", action: #selector(openCommandPalette), keyEquivalent: "k")
        palette.keyEquivalentModifierMask = [.command]
        appMenu.addItem(palette)
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
        w.appearance = AppearanceOption.from(s.appearance).nsAppearance
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
            onResizeEnd: { [weak self] in self?.endResizePanel() },
            onQuerySize: { [weak self] in self?.hostContentSize() ?? .zero },

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

    /// 模型 / 思考强度弹窗打开期间，把聊天面板从 `.transient` 切成 `.applicationDefined`。
    ///
    /// 否则外层 popover 会把弹窗内的点击当成「点击外部」而抢先关闭，
    /// 导致模型切换动作丢失（这正是早期嵌套 popover 不可用的原因）。
    func setModelPopupOpen(_ open: Bool) {
        guard SettingsStore.shared.settings.panelMode else { return }
        popover?.behavior = open ? .applicationDefined : .transient
    }

    /// 显示模型 / 思考强度小弹窗：输入栏上方、与模型按钮对齐。
    func showModelPopup() {
        let panelMode = SettingsStore.shared.settings.panelMode
        let host: NSWindow? = panelMode ? popover?.contentViewController?.view.window : window
        guard let host else { return }
        let theme = ChatTheme(SettingsStore.shared.settings)
        // 输入栏底部 8pt 内边距 + 34pt 控件高；其下可能还有 18pt 尺寸手柄条。
        let strip: CGFloat = SettingsStore.shared.settings.resizablePanel ? 18 : 0
        let bottomInset = strip + 8 + 34
        // 右边缘：内边距 + 发送按钮 34 + 间距 4。
        let rightInset = theme.density.contentPadding + 34 + 4
        ModelPopupController.shared.show(theme: theme, host: host,
                                         bottomInset: bottomInset, rightInset: rightInset)
    }

    func hideModelPopup() {
        ModelPopupController.shared.hide()
    }

    func hideWindow() {
        // 弹窗可能还开着，先关掉并恢复外层行为，避免下次显示时残留非 transient 状态。
        ModelPopupState.shared.isOpen = false
        setModelPopupOpen(false)
        model.windowVisible = false
        UserDefaults.standard.set(false, forKey: Self.lastWindowVisibleKey)
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
    /// 聊天面板 / 窗口当前的真实内容尺寸（拖拽基准用，避免依赖 keyWindow）。
    func hostContentSize() -> CGSize {
        if SettingsStore.shared.settings.panelMode,
           let win = popover?.contentViewController?.view.window {
            return win.contentRect(forFrameRect: win.frame).size
        }
        if let win = window {
            return win.contentRect(forFrameRect: win.frame).size
        }
        return .zero
    }

    func resizePanel(to size: CGSize) {
        // 先按业务上下限，再按屏幕可见区域钳制：请求一个系统必然拒绝的尺寸会让
        // 「请求值」与「实际值」长期不一致（设置里存的是不可能的值）。
        let bounded = clampPanelSize(size)
        let target = clampToScreen(NSSize(width: bounded.width, height: bounded.height))
        isResizingPanel = true

        // 严格 1:1 跟随手势：拖拽位移多少，尺寸就变多少。
        //
        // 之前这里做过「让右边缘跟手」的补偿（量测 popover 实际右边缘再修正宽度），
        // 但 popover 每次改尺寸都会重新居中，修正量与居中位移互相放大，
        // 导致拖动时尺寸来回剧烈跳动、完全不可用。宁可不跟手，也不能放大位移。
        if SettingsStore.shared.settings.panelMode, let p = popover, p.isShown {
            p.contentSize = target
        } else if let win = window {
            win.setContentSize(target)
        }
        pendingResizeSize = target
        if ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" {
            let actual: NSSize
            if SettingsStore.shared.settings.panelMode, let win = popover?.contentViewController?.view.window {
                actual = win.contentRect(forFrameRect: win.frame).size
            } else if let win = window {
                actual = win.contentRect(forFrameRect: win.frame).size
            } else {
                actual = .zero
            }
            dbg("resize 请求=\(Int(target.width))x\(Int(target.height)) 实际=\(Int(actual.width))x\(Int(actual.height))")
        }
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
        NSApp.unhide(nil)
        // 先激活应用，再 order front。否则 AppKit 会把窗口排到当前应用之下，
        // 用户看到的是「设置/窗口打开了但没出现」。
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = true
        UserDefaults.standard.set(true, forKey: Self.lastWindowVisibleKey)
        if SettingsStore.shared.settings.panelMode {
            guard let button = statusItem.button else { return }
            let p = ensurePopover()
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // 透明度与外观需要作用在 popover 自身的窗口上（popover 窗口不跟随 NSApp.appearance）
            let pw = p.contentViewController?.view.window
            pw?.alphaValue = SettingsStore.shared.settings.windowOpacity
            pw?.appearance = AppearanceOption.from(SettingsStore.shared.settings.appearance).nsAppearance
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let w = ensureWindow()
            // 菜单栏应用没有 Dock 图标时，最小化 / 关闭后的窗口很容易变得不可达。
            // 先还原最小化状态，再强制置前；`makeKeyAndOrderFront` 不会自动 deminiaturize。
            // 窗口可能记住了旧的 Space，切到当前 Space 才能被用户看到。
            w.collectionBehavior.insert(.moveToActiveSpace)
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        if startVoice { model.startVoice() }
    }

    func popoverDidClose(_ notification: Notification) {
        model.windowVisible = false
        UserDefaults.standard.set(false, forKey: Self.lastWindowVisibleKey)
        if SettingsStore.shared.settings.clearOnClose { model.clear() }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            model.windowVisible = false
            UserDefaults.standard.set(false, forKey: Self.lastWindowVisibleKey)
            if SettingsStore.shared.settings.clearOnClose { model.clear() }
        }
    }

    /// 窗口边缘拖拽缩放：把真实内容尺寸写回设置（拖拽手柄期间跳过，由 endResizePanel 统一处理）。
    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        dbg("windowDidResize isResizingPanel=\(isResizingPanel) isSyncing=\(isSyncingWindowFrame)")
        // 拖拽手柄期间由 endResizePanel 统一落盘，避免与手势互相抢占
        guard !isResizingPanel else { return }
        syncWindowSizeToSettings()
    }

    /// 窗口移动：位置由 `setFrameUsingName` / `setFrameAutosaveName` 自动记忆，无需手动写盘。
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
    }

    private func syncWindowSizeToSettings() {
        guard !isSyncingWindowFrame, !isResizingPanel, let w = window else { return }
        let size = w.contentRect(forFrameRect: w.frame).size
        // 若该尺寸正是我们刚推送下去的那个请求值，说明差异只来自系统钳制，
        // 不再回写，否则会与 applySettings 形成死循环。
        if let applied = lastAppliedWindowSize,
           abs(applied.width - size.width) < 0.5,
           abs(applied.height - size.height) < 0.5 {
            return
        }
        let cur = SettingsStore.shared.settings
        guard abs(cur.windowWidth - Double(size.width)) >= 0.5
                || abs(cur.windowHeight - Double(size.height)) >= 0.5 else { return }
        dbg("syncWindowSize \(cur.windowWidth)x\(cur.windowHeight) -> \(size.width)x\(size.height)")
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

    /// 打开聊天面板并呼出命令面板（⌘K）。
    @objc func openCommandPalette() {
        showWindow(startVoice: false)
        NotificationCenter.default.post(name: .mynaShowCommandPalette, object: nil)
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
            w.appearance = AppearanceOption.from(SettingsStore.shared.settings.appearance).nsAppearance
            settingsWindow = w
            dumpWindow("settings", w)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let sw = settingsWindow {
            sw.collectionBehavior.insert(.moveToActiveSpace)
            if sw.isMiniaturized { sw.deminiaturize(nil) }
            sw.makeKeyAndOrderFront(nil)
            sw.orderFrontRegardless()
        }
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
        // 刚由 applicationDidBecomeActive 自动带出的窗口，不要被这次点击立刻收起。
        if let shown = autoShownAt, Date().timeIntervalSince(shown) < 0.6 {
            autoShownAt = nil
            return
        }
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

    @objc func openMainWindow() { showWindow(startVoice: false) }

    /// 通过 Dock / Cmd+Tab 激活且没有任何窗口时，自动带出聊天窗口。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(launchedAt) > 2 else { return }
        let chatVisible = (window?.isVisible ?? false) && !(window?.isMiniaturized ?? false)
        let settingsVisible = (settingsWindow?.isVisible ?? false) && !(settingsWindow?.isMiniaturized ?? false)
        guard !chatVisible, !settingsVisible else { return }
        autoShownAt = Date()
        showWindow(startVoice: false)
    }

    /// 点击 Dock 图标 / 通过 Cmd+Tab 切回时，若没有可见窗口就把聊天窗口带回来。
    ///
    /// `flag` 对「最小化」的窗口也可能为 true，所以还要单独检查 `isMiniaturized`
    /// 与 `isVisible`：菜单栏应用没有 Dock 图标时，最小化窗口很容易变得不可达。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let w = window
        let reachable = (w?.isVisible ?? false) && !(w?.isMiniaturized ?? false)
        if !flag || !reachable {
            showWindow(startVoice: false)
        }
        return true
    }

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
                <string>\(app)/Contents/MacOS/Myna</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(atPath: (la as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            // 只在内容变化时写入。绝不能在这里 `launchctl unload/load`：
            // 直连二进制的 LaunchAgent 一旦 unload，会把当前 App 自己杀掉，
            // RunAtLoad 再拉起，形成无限重启循环。
            let existing = try? String(contentsOfFile: la, encoding: .utf8)
            if existing != plist {
                try? plist.write(toFile: la, atomically: true, encoding: .utf8)
            }
        } else {
            try? FileManager.default.removeItem(atPath: la)
        }
    }
}

extension Notification.Name {
    /// 请求聊天面板呼出 ⌘K 命令面板。
    static let mynaShowCommandPalette = Notification.Name("myna.showCommandPalette")
}
