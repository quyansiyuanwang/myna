import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var settingsWindow: NSWindow?
    let model = ChatModel()
    let hotKey = HotKeyManager()
    private var cancellables = Set<AnyCancellable>()
    private var lastHotkey: String?
    private var lastLaunchAtLogin: Bool?
    private var lastOnTop: Bool?
    private var lastAppearance: String?
    private var lastDock: Bool?
    private var lastIcon: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        hotKey.onPressed = { [weak self] in self?.hotKeyPressed() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "AiSiri") {
                button.image = img
            } else {
                button.title = "AI"
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
    }

    private func applySettings(_ s: AppSettings) {
        if lastHotkey != s.hotkey {
            lastHotkey = s.hotkey
            hotKey.register(combo: s.hotkey)
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
            statusItem.button?.image = NSImage(systemSymbolName: s.menuBarIcon, accessibilityDescription: "AiSiri")
        }
        window?.alphaValue = s.windowOpacity
    }

    // MARK: - 主菜单

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 AiSiri", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        w.title = "AiSiri"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 380, height: 480)
        w.contentView = NSHostingView(rootView: ChatView(model: model, onOpenSettings: { [weak self] in self?.openSettings() }))
        w.delegate = self
        w.level = s.alwaysOnTop ? .floating : .normal
        w.alphaValue = s.windowOpacity
        w.center()
        w.setFrameAutosaveName("AiSiriWindow")
        window = w
        return w
    }

    func showWindow(startVoice: Bool) {
        let w = ensureWindow()
        model.windowVisible = true
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if startVoice { model.startVoice() }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            model.windowVisible = false
            if SettingsStore.shared.settings.clearOnClose { model.clear() }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AiSiri 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 状态栏

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if let w = window, w.isVisible {
            model.windowVisible = false
            w.orderOut(nil)
        } else {
            showWindow(startVoice: false)
        }
    }

    func hotKeyPressed() {
        // 录音中：再次按下结束（并按设置决定是否发送）
        if model.isRecording {
            model.stopVoice(send: SettingsStore.shared.settings.hotkeyAutoSend)
            return
        }
        showWindow(startVoice: true)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 AiSiri", action: #selector(openItem), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func openItem() { showWindow(startVoice: false) }

    // MARK: - 开机自启

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let la = NSString(string: "~/Library/LaunchAgents/com.local.aisiri.plist").expandingTildeInPath
        if enabled {
            let app = NSString(string: "~/Applications/AiSiri.app").expandingTildeInPath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.local.aisiri</string>
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
