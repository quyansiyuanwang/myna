import Carbon.HIToolbox
import AppKit
import SwiftUI
import Combine
import ApplicationServices

/// 热键注册结果。
enum HotKeyStatus: Equatable {
    case ok
    case invalid
    case conflict
    case failed(Int32)
    case needsAccessibility

    var isOK: Bool { self == .ok }

    var message: String {
        switch self {
        case .ok: return ""
        case .invalid: return "组合键无效：需带 ⌃⌥⇧⌘ 之一，或使用 F1–F12"
        case .conflict: return "该组合键已被其他应用占用，请换一个"
        case .failed(let code): return "注册失败（错误码 \(code)），请换一个组合键"
        case .needsAccessibility: return "双击触发需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权 AiSiri"
        }
    }
}

/// 全局热键（Carbon，无需辅助功能权限）。支持任意可录入的组合键。
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    /// 最近一次注册结果，供设置界面提示冲突。
    @Published private(set) var status: HotKeyStatus = .ok

    private var hotKeyRef: EventHotKeyRef?
    private var eventRef: EventHandlerRef?
    var onPressed: (() -> Void)?

    @discardableResult
    func register(combo: String) -> HotKeyStatus {
        unregister()
        // 双击修饰键：需要全局监听（辅助功能权限）
        if HotKeyManager.isDoubleTap(combo) {
            guard let flag = HotKeyManager.doubleTapFlag(combo) else {
                status = .invalid
                return .invalid
            }
            let ok = startDoubleTap(flag)
            status = ok ? .ok : .needsAccessibility
            return status
        }
        // 非法组合（如无修饰键的单键）不注册，避免把普通打字变成全局热键
        guard HotKeyManager.isValid(combo) else {
            status = .invalid
            return .invalid
        }
        let (keyCode, modifiers) = HotKeyManager.parse(combo)
        guard let keyCode else {
            status = .invalid
            return .invalid
        }
        let signature: OSType = 0x41495352 // 'AISR'
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onPressed?() }
            return noErr
        }, 1, &eventType, selfPtr, &eventRef)

        let os = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        let result: HotKeyStatus
        if os == noErr {
            result = .ok
        } else if os == eventHotKeyExistsErr {
            result = .conflict
        } else {
            result = .failed(os)
        }
        status = result
        return result
    }

    func unregister() {
        stopDoubleTap()
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let e = eventRef { RemoveEventHandler(e); eventRef = nil }
    }

    deinit { unregister() }

    // MARK: - 双击修饰键监听

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var targetFlag: NSEvent.ModifierFlags?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var lastTap: Date?

    /// 开始监听双击。返回 false 表示缺少辅助功能权限。
    private func startDoubleTap(_ flag: NSEvent.ModifierFlags) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        targetFlag = flag
        previousFlags = []
        lastTap = nil
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handler(event)
            return event
        }
        return globalMonitor != nil || localMonitor != nil
    }

    private func stopDoubleTap() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        targetFlag = nil
        lastTap = nil
    }

    /// 只在「单独按下目标修饰键」时计入，连续两次（默认 350ms 内）触发。
    private func handleFlags(_ event: NSEvent) {
        guard let target = targetFlag else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wasDown = previousFlags.contains(target)
        let isDown = flags.contains(target)
        previousFlags = flags
        guard !wasDown, isDown else { return }                 // 只处理按下
        guard flags.subtracting(target).isEmpty else {          // 不允许同时按其他修饰键
            lastTap = nil
            return
        }
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last) < 0.35 {
            lastTap = nil
            DispatchQueue.main.async { [weak self] in self?.onPressed?() }
        } else {
            lastTap = now
        }
    }

    // MARK: - 键位表

    struct KeyDef {
        let name: String
        let code: UInt32
        let display: String
    }

    /// 可绑定的按键。字母 / 数字 / 标点 / 空格 / 编辑键 / 方向键 / F1–F12。
    static let keys: [KeyDef] = [
        KeyDef(name: "a", code: UInt32(kVK_ANSI_A), display: "A"),
        KeyDef(name: "b", code: UInt32(kVK_ANSI_B), display: "B"),
        KeyDef(name: "c", code: UInt32(kVK_ANSI_C), display: "C"),
        KeyDef(name: "d", code: UInt32(kVK_ANSI_D), display: "D"),
        KeyDef(name: "e", code: UInt32(kVK_ANSI_E), display: "E"),
        KeyDef(name: "f", code: UInt32(kVK_ANSI_F), display: "F"),
        KeyDef(name: "g", code: UInt32(kVK_ANSI_G), display: "G"),
        KeyDef(name: "h", code: UInt32(kVK_ANSI_H), display: "H"),
        KeyDef(name: "i", code: UInt32(kVK_ANSI_I), display: "I"),
        KeyDef(name: "j", code: UInt32(kVK_ANSI_J), display: "J"),
        KeyDef(name: "k", code: UInt32(kVK_ANSI_K), display: "K"),
        KeyDef(name: "l", code: UInt32(kVK_ANSI_L), display: "L"),
        KeyDef(name: "m", code: UInt32(kVK_ANSI_M), display: "M"),
        KeyDef(name: "n", code: UInt32(kVK_ANSI_N), display: "N"),
        KeyDef(name: "o", code: UInt32(kVK_ANSI_O), display: "O"),
        KeyDef(name: "p", code: UInt32(kVK_ANSI_P), display: "P"),
        KeyDef(name: "q", code: UInt32(kVK_ANSI_Q), display: "Q"),
        KeyDef(name: "r", code: UInt32(kVK_ANSI_R), display: "R"),
        KeyDef(name: "s", code: UInt32(kVK_ANSI_S), display: "S"),
        KeyDef(name: "t", code: UInt32(kVK_ANSI_T), display: "T"),
        KeyDef(name: "u", code: UInt32(kVK_ANSI_U), display: "U"),
        KeyDef(name: "v", code: UInt32(kVK_ANSI_V), display: "V"),
        KeyDef(name: "w", code: UInt32(kVK_ANSI_W), display: "W"),
        KeyDef(name: "x", code: UInt32(kVK_ANSI_X), display: "X"),
        KeyDef(name: "y", code: UInt32(kVK_ANSI_Y), display: "Y"),
        KeyDef(name: "z", code: UInt32(kVK_ANSI_Z), display: "Z"),
        KeyDef(name: "0", code: UInt32(kVK_ANSI_0), display: "0"),
        KeyDef(name: "1", code: UInt32(kVK_ANSI_1), display: "1"),
        KeyDef(name: "2", code: UInt32(kVK_ANSI_2), display: "2"),
        KeyDef(name: "3", code: UInt32(kVK_ANSI_3), display: "3"),
        KeyDef(name: "4", code: UInt32(kVK_ANSI_4), display: "4"),
        KeyDef(name: "5", code: UInt32(kVK_ANSI_5), display: "5"),
        KeyDef(name: "6", code: UInt32(kVK_ANSI_6), display: "6"),
        KeyDef(name: "7", code: UInt32(kVK_ANSI_7), display: "7"),
        KeyDef(name: "8", code: UInt32(kVK_ANSI_8), display: "8"),
        KeyDef(name: "9", code: UInt32(kVK_ANSI_9), display: "9"),
        KeyDef(name: "space", code: UInt32(kVK_Space), display: "Space"),
        KeyDef(name: "return", code: UInt32(kVK_Return), display: "↩"),
        KeyDef(name: "tab", code: UInt32(kVK_Tab), display: "⇥"),
        KeyDef(name: "escape", code: UInt32(kVK_Escape), display: "⎋"),
        KeyDef(name: "delete", code: UInt32(kVK_Delete), display: "⌫"),
        KeyDef(name: "forwarddelete", code: UInt32(kVK_ForwardDelete), display: "⌦"),
        KeyDef(name: "left", code: UInt32(kVK_LeftArrow), display: "←"),
        KeyDef(name: "right", code: UInt32(kVK_RightArrow), display: "→"),
        KeyDef(name: "up", code: UInt32(kVK_UpArrow), display: "↑"),
        KeyDef(name: "down", code: UInt32(kVK_DownArrow), display: "↓"),
        KeyDef(name: "home", code: UInt32(kVK_Home), display: "↖"),
        KeyDef(name: "end", code: UInt32(kVK_End), display: "↘"),
        KeyDef(name: "pageup", code: UInt32(kVK_PageUp), display: "⇞"),
        KeyDef(name: "pagedown", code: UInt32(kVK_PageDown), display: "⇟"),
        KeyDef(name: "-", code: UInt32(kVK_ANSI_Minus), display: "-"),
        KeyDef(name: "=", code: UInt32(kVK_ANSI_Equal), display: "="),
        KeyDef(name: "[", code: UInt32(kVK_ANSI_LeftBracket), display: "["),
        KeyDef(name: "]", code: UInt32(kVK_ANSI_RightBracket), display: "]"),
        KeyDef(name: "\\", code: UInt32(kVK_ANSI_Backslash), display: "\\"),
        KeyDef(name: ";", code: UInt32(kVK_ANSI_Semicolon), display: ";"),
        KeyDef(name: "'", code: UInt32(kVK_ANSI_Quote), display: "'"),
        KeyDef(name: ",", code: UInt32(kVK_ANSI_Comma), display: ","),
        KeyDef(name: ".", code: UInt32(kVK_ANSI_Period), display: "."),
        KeyDef(name: "/", code: UInt32(kVK_ANSI_Slash), display: "/"),
        KeyDef(name: "`", code: UInt32(kVK_ANSI_Grave), display: "`"),
        KeyDef(name: "f1", code: UInt32(kVK_F1), display: "F1"),
        KeyDef(name: "f2", code: UInt32(kVK_F2), display: "F2"),
        KeyDef(name: "f3", code: UInt32(kVK_F3), display: "F3"),
        KeyDef(name: "f4", code: UInt32(kVK_F4), display: "F4"),
        KeyDef(name: "f5", code: UInt32(kVK_F5), display: "F5"),
        KeyDef(name: "f6", code: UInt32(kVK_F6), display: "F6"),
        KeyDef(name: "f7", code: UInt32(kVK_F7), display: "F7"),
        KeyDef(name: "f8", code: UInt32(kVK_F8), display: "F8"),
        KeyDef(name: "f9", code: UInt32(kVK_F9), display: "F9"),
        KeyDef(name: "f10", code: UInt32(kVK_F10), display: "F10"),
        KeyDef(name: "f11", code: UInt32(kVK_F11), display: "F11"),
        KeyDef(name: "f12", code: UInt32(kVK_F12), display: "F12"),
    ]

    static let byName: [String: KeyDef] = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
    static let byCode: [UInt32: KeyDef] = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0) })

    static func def(forKeyCode code: UInt32) -> KeyDef? { byCode[code] }

    // MARK: - 解析与显示

    /// 解析 "option+shift+k" → (虚拟键码, 修饰键)
    static func parse(_ combo: String) -> (UInt32?, UInt32) {
        var mods: UInt32 = 0
        var key: UInt32? = nil
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "option", "alt": mods |= UInt32(optionKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            case "command", "cmd": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            default:
                if let def = byName[part] { key = def.code }
            }
        }
        return (key, mods)
    }

    /// 从 NSEvent 修饰键得到规范名称（顺序固定）。
    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        return names
    }

    /// 人类可读的组合键显示，如 "⌥⇧K"。
    static func display(_ combo: String) -> String {
        if isDoubleTap(combo) { return doubleTapDisplay(combo) }
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        func has(_ names: [String]) -> Bool { parts.contains { names.contains($0) } }
        var s = ""
        if has(["control", "ctrl"]) { s += "⌃" }
        if has(["option", "alt"]) { s += "⌥" }
        if has(["shift"]) { s += "⇧" }
        if has(["command", "cmd"]) { s += "⌘" }
        if let key = parts.first(where: { byName[$0] != nil }) {
            s += byName[key]?.display ?? key.uppercased()
        }
        return s
    }

    /// 组合键是否合法（至少一个修饰键，或单个功能键）。
    static func isValid(_ combo: String) -> Bool {
        if isDoubleTap(combo) { return doubleTapFlag(combo) != nil }
        let (key, mods) = parse(combo)
        guard let key, byCode[key] != nil else { return false }
        if mods != 0 { return true }
        let def = byCode[key]
        return def?.name.hasPrefix("f") == true
    }

    // MARK: - 双击修饰键

    static let doubleTapModifiers: [(value: String, label: String, flag: NSEvent.ModifierFlags)] = [
        ("double:option", "⌥ Option", .option),
        ("double:control", "⌃ Control", .control),
        ("double:command", "⌘ Command", .command),
        ("double:shift", "⇧ Shift", .shift),
    ]

    static func isDoubleTap(_ combo: String) -> Bool { combo.hasPrefix("double:") }

    static func doubleTapFlag(_ combo: String) -> NSEvent.ModifierFlags? {
        doubleTapModifiers.first { $0.value == combo }?.flag
    }

    static func doubleTapDisplay(_ combo: String) -> String {
        switch combo {
        case "double:option": return "⌥ ⌥"
        case "double:control": return "⌃ ⌃"
        case "double:command": return "⌘ ⌘"
        case "double:shift": return "⇧ ⇧"
        default: return combo
        }
    }

    /// 弹出系统辅助功能授权提示。
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 快速预设（仍作为快捷选择保留）。
    static let presets: [(value: String, label: String)] = [
        ("option+space", "⌥ Space"),
        ("control+space", "⌃ Space"),
        ("option+command+space", "⌥⌘ Space"),
        ("command+shift+space", "⇧⌘ Space"),
        ("control+option+space", "⌃⌥ Space"),
        ("f5", "F5"),
        ("f6", "F6"),
        ("f7", "F7"),
    ]
}

// MARK: - 录入控件

/// 捕获按键的 AppKit 视图：进入录入后成为第一响应者，读取下一个组合键。
@MainActor
final class HotKeyRecorderNSView: NSView {
    var onCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onFlagsChanged: (([String]) -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == UInt32(kVK_Escape) { onCancel?(); return }
        guard let def = HotKeyManager.def(forKeyCode: UInt32(event.keyCode)) else {
            NSSound.beep()
            return
        }
        let mods = HotKeyManager.modifierNames(event.modifierFlags)
        let isFunction = def.name.hasPrefix("f") && Int(def.name.dropFirst()) != nil
        guard !mods.isEmpty || isFunction else {
            NSSound.beep()   // 必须带修饰键，或使用功能键
            return
        }
        onCapture?((mods + [def.name]).joined(separator: "+"))
    }

    /// 捕获 ⌘ 组合，避免被菜单当作快捷键吞掉。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        onFlagsChanged?(HotKeyManager.modifierNames(event.modifierFlags))
    }
}

/// SwiftUI 包装：`recording` 为 true 时开始捕获按键。
struct HotKeyRecorderField: NSViewRepresentable {
    var recording: Bool
    var onCapture: (String) -> Void
    var onCancel: () -> Void
    var onFlagsChanged: ([String]) -> Void = { _ in }

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let v = HotKeyRecorderNSView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        v.onFlagsChanged = onFlagsChanged
        v.isRecording = recording
        return v
    }

    func updateNSView(_ v: HotKeyRecorderNSView, context: Context) {
        v.onCapture = onCapture
        v.onCancel = onCancel
        v.onFlagsChanged = onFlagsChanged
        v.isRecording = recording
        if recording, let window = v.window, window.firstResponder !== v {
            DispatchQueue.main.async { window.makeFirstResponder(v) }
        }
    }
}
