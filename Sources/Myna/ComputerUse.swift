import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers
import PiKit

/// Computer use：截屏 / OCR / 窗口列表 / 鼠标 / 键盘。
///
/// 屏幕相关工具需要「屏幕录制」权限；鼠标与键盘事件需要「辅助功能」权限。
/// 工具在设置里可整体关闭（`screen_access_enabled` / `computer_control_enabled`）。
enum ComputerUse {

    /// 读取屏幕类工具。
    static let screenTools: Set<String> = [
        "screenshot", "read_screen", "list_windows", "view_image",
    ]

    /// 控制类工具。
    static let controlTools: Set<String> = [
        "activate_app", "mouse_move", "mouse_click", "mouse_drag", "scroll",
        "key_press", "type_text", "wait",
    ]

    static var allTools: Set<String> { screenTools.union(controlTools) }

    // MARK: - 分发

    static func run(_ name: String, args: [String: Any]) -> String {
        let settings = SettingsStore.shared.settings
        if screenTools.contains(name), !settings.screenAccessEnabled {
            return "屏幕访问已被设置关闭（设置 → 工具 → 电脑操作 → 允许读取屏幕）。"
        }
        if controlTools.contains(name), !settings.computerControlEnabled {
            return "鼠标 / 键盘控制已被设置关闭（设置 → 工具 → 电脑操作 → 允许控制鼠标键盘）。"
        }
        do {
            switch name {
            case "screenshot":
                let capture = try capture(args: args)
                return capture.summary
            case "read_screen":
                return try readScreen(args: args, ocrEnabled: settings.screenOCREnabled)
            case "list_windows":
                return windowsSummary()
            case "activate_app":
                return try activateApp(args["name"] as? String ?? "")
            case "mouse_move":
                return try mouseMove(args)
            case "mouse_click":
                return try mouseClick(args)
            case "mouse_drag":
                return try mouseDrag(args)
            case "scroll":
                return try scroll(args)
            case "key_press":
                return try keyPress(args)
            case "type_text":
                return try typeText(args["text"] as? String ?? "")
            case "wait":
                let ms = max(0, min(args["ms"] as? Int ?? 500, 10_000))
                usleep(useconds_t(ms * 1000))
                return "已等待 \(ms) 毫秒"
            case "view_image":
                return try imageText(path: args["path"] as? String ?? "")
            default:
                return "未知电脑操作：\(name)"
            }
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    /// `screenshot` 的包运行时结果：视觉模型默认同时收到图片，省掉一次
    /// `view_image` 往返；`attach=false` 可强制只返回路径。
    static func screenshotResult(args: [String: Any]) -> ToolResult {
        do {
            let capture = try capture(args: args)
            let attach = args["attach"] as? Bool ?? true
            guard attach, SettingsStore.shared.settings.supportsVision else {
                return ToolResult(text: capture.summary)
            }
            let encoded = try encodeImage(path: capture.path)
            return ToolResult(content: [
                .text(TextContent(text: capture.summary)),
                .image(ImageContent(data: encoded.base64, mimeType: encoded.mime)),
            ])
        } catch {
            return ToolResult(text: "截图失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// `view_image` 的包运行时结果：文本 + 图片块。
    /// 文本模型会忽略图片块，因此始终附上可读的描述与建议。
    static func imageResult(path rawPath: String) -> ToolResult {
        do {
            let encoded = try encodeImage(path: rawPath)
            var text = "图片：\(encoded.path)（\(encoded.width)x\(encoded.height)，原图 \(encoded.originalWidth)x\(encoded.originalHeight)，\(SelfControlAPI.humanSize(encoded.bytes))）。"
                + (encoded.downscaled ? "已缩放后发送。" : "")
            if !SettingsStore.shared.settings.supportsVision {
                text += " 当前模型未声明支持图片输入，已只返回路径与尺寸；读屏请用 read_screen（本地 OCR）。要启用视觉，请在「模型 → 编辑 → 支持图片输入」中勾选。"
                return ToolResult(text: text)
            }
            text += " 图片已随工具结果附加。"
            return ToolResult(content: [
                .text(TextContent(text: text)),
                .image(ImageContent(data: encoded.base64, mimeType: encoded.mime)),
            ])
        } catch {
            return ToolResult(text: "读取图片失败：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - 截屏

    struct Capture {
        var path: String
        var pixelWidth: Int
        var pixelHeight: Int
        var region: CGRect
        var frontApp: String
        var frontTitle: String
        var windowID: Int?

        var summary: String {
            var lines = [
                "截图：\(path)",
                "像素：\(pixelWidth)x\(pixelHeight)",
                "区域（屏幕坐标，左上原点）：\(Int(region.origin.x)),\(Int(region.origin.y)),\(Int(region.width)),\(Int(region.height))",
            ]
            if let windowID { lines.append("窗口 id：\(windowID)") }
            lines.append("前台应用：\(frontApp.isEmpty ? "未知" : frontApp)")
            if !frontTitle.isEmpty { lines.append("前台窗口：\(frontTitle)") }
            lines.append("可继续用 view_image 查看原图，或用 read_screen 获取 OCR 文本。")
            return lines.joined(separator: "\n")
        }
    }

    static func capture(args: [String: Any]) throws -> Capture {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ComputerUseError.permission("需要「屏幕录制」权限。请在 设置 → 工具 → 电脑操作 → 权限 中申请，授权后重启 Myna。")
        }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: SelfControlAPI.screenshotsDir, withIntermediateDirectories: true)

        var target = (args["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            target = SelfControlAPI.screenshotsDir + "/shot-\(SelfControlAPI.stamp())-\(UUID().uuidString.prefix(4)).png"
        } else {
            target = NSString(string: target).expandingTildeInPath
        }
        guard target.hasSuffix(".png") || target.hasSuffix(".jpg") || target.hasSuffix(".jpeg") else {
            throw ComputerUseError.message("截图路径需以 .png / .jpg 结尾")
        }
        try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)

        var command = "screencapture -x"
        if target.hasSuffix(".jpg") || target.hasSuffix(".jpeg") { command += " -t jpg" } else { command += " -t png" }

        var region = mainDisplayBounds()
        var windowID: Int?
        let windowArg = (args["window"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !windowArg.isEmpty {
            let window = try resolveWindow(windowArg)
            windowID = window.id
            region = window.bounds
            command += " -l \(window.id) -o"
        } else if let raw = args["region"] as? String, !raw.isEmpty {
            guard let rect = parseRegion(raw) else {
                throw ComputerUseError.message("region 格式应为 x,y,w,h（屏幕坐标，左上原点）")
            }
            region = rect
            command += " -R \(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
        } else {
            let display = args["display"] as? Int ?? 1
            if display > 0 {
                command += " -D \(display)"
                region = displayBounds(display - 1)
            } else {
                region = CGRect.zero
            }
        }
        let result = ToolRunner.sh(command + " " + ToolRunner.q(target), timeout: 20)
        guard fm.fileExists(atPath: target),
              let size = (try? fm.attributesOfItem(atPath: target))?[.size] as? NSNumber,
              size.intValue > 512 else {
            throw ComputerUseError.message("截图失败：\(result.isEmpty ? "系统未返回原因" : result)")
        }

        let pixels = pixelSize(of: target)
        let front = NSWorkspace.shared.frontmostApplication
        let windows = windowList()
        let frontWindow = windows.first { $0.pid == front?.processIdentifier }
        return Capture(path: target,
                       pixelWidth: pixels.width,
                       pixelHeight: pixels.height,
                       region: region,
                       frontApp: front?.localizedName ?? front?.bundleIdentifier ?? "",
                       frontTitle: frontWindow?.title ?? "",
                       windowID: windowID)
    }

    private static func mainDisplayBounds() -> CGRect {
        CGRect(x: 0, y: 0,
               width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())) / mainDisplayScale(),
               height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())) / mainDisplayScale())
    }

    private static func displayBounds(_ index: Int) -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return mainDisplayBounds() }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard index >= 0, index < Int(count) else { return mainDisplayBounds() }
        let bounds = CGDisplayBounds(ids[index])
        return bounds.width > 0 ? bounds : mainDisplayBounds()
    }

    private static func mainDisplayScale() -> CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func pixelSize(of path: String) -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        return ((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
    }

    static func parseRegion(_ raw: String) -> CGRect? {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" })
            .compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - 窗口

    struct WindowInfo {
        var id: Int
        var owner: String
        var title: String
        var bounds: CGRect
        var pid: pid_t
    }

    static func windowList() -> [WindowInfo] {
        let options = CGWindowListOption.optionOnScreenOnly.union(.excludeDesktopElements)
        guard let raw = CGWindowListCopyWindowInfo(options,
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { info -> WindowInfo? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNumber.int32Value != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            return WindowInfo(id: id, owner: owner, title: title,
                              bounds: bounds, pid: pidNumber.int32Value)
        }
        .sorted { lhs, rhs in
            if abs(lhs.bounds.origin.y - rhs.bounds.origin.y) > 8 {
                return lhs.bounds.origin.y < rhs.bounds.origin.y
            }
            return lhs.bounds.origin.x < rhs.bounds.origin.x
        }
    }

    static func windowsSummary() -> String {
        let windows = windowList()
        guard !windows.isEmpty else { return "（没有可见窗口）" }
        return windows.prefix(40).map { window in
            let title = window.title.isEmpty ? "（无标题）" : window.title
            return "id=\(window.id)\t\(window.owner)\t\(title)\t\(Int(window.bounds.origin.x)),\(Int(window.bounds.origin.y)),\(Int(window.bounds.width)),\(Int(window.bounds.height))"
        }.joined(separator: "\n")
    }

    static func resolveWindow(_ raw: String) throws -> WindowInfo {
        let windows = windowList()
        if let id = Int(raw), let match = windows.first(where: { $0.id == id }) {
            return match
        }
        let query = raw.lowercased()
        if let match = windows.first(where: {
            $0.title.lowercased().contains(query) || $0.owner.lowercased().contains(query)
        }) {
            return match
        }
        throw ComputerUseError.message("没有找到窗口「\(raw)」。可先用 list_windows 查看。")
    }

    static func activateApp(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ComputerUseError.message("缺少应用名称") }
        let app = ToolRunner.appName(name)
        let result = ToolRunner.sh("open -a \(ToolRunner.q(app))", timeout: 10)
        if result.contains("Unable to find") || result.contains("does not exist") {
            throw ComputerUseError.message("找不到应用「\(name)」")
        }
        usleep(350_000)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return "已激活 \(app)；当前前台应用：\(front.isEmpty ? "未知" : front)"
    }

    // MARK: - OCR

    static func readScreen(args: [String: Any], ocrEnabled: Bool) throws -> String {
        let capture = try capture(args: args)
        var lines = [capture.summary]
        if !ocrEnabled {
            lines.append("OCR 已在设置中关闭；可改用 view_image（需要模型支持图片输入）。")
            return lines.joined(separator: "\n")
        }
        let maxChars = max(500, min(args["max_chars"] as? Int ?? 6_000, 20_000))
        let observations = try recognizeText(in: capture.path)
        if observations.isEmpty {
            lines.append("未识别到文字（可能是纯图形界面）。可改用 view_image 查看截图。")
            return lines.joined(separator: "\n")
        }
        lines.append("识别文本（坐标是相对截图的 0-1 比例，原点左上）：")
        var text = ""
        for observation in observations {
            let box = observation.boundingBox
            let x = box.origin.x
            let y = 1 - box.origin.y - box.height
            let line = String(format: "[%.3f,%.3f,%.3f,%.3f] %@",
                              x, y, box.width, box.height, observation.text)
            if text.count + line.count + 1 > maxChars { break }
            text += line + "\n"
        }
        lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    struct TextObservation {
        var text: String
        var boundingBox: CGRect
    }

    static func recognizeText(in path: String) throws -> [TextObservation] {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ComputerUseError.message("无法读取截图：\(path)")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).compactMap { observation -> TextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextObservation(text: text, boundingBox: observation.boundingBox)
        }
        return observations.sorted { lhs, rhs in
            let ly = lhs.boundingBox.origin.y + lhs.boundingBox.height
            let ry = rhs.boundingBox.origin.y + rhs.boundingBox.height
            if abs(ly - ry) > 0.02 { return ly > ry }
            return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }
    }

    // MARK: - 鼠标

    static func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func point(from args: [String: Any], xKey: String = "x", yKey: String = "y") throws -> CGPoint {
        guard let x = number(args[xKey]), let y = number(args[yKey]) else {
            throw ComputerUseError.message("缺少坐标 \(xKey) / \(yKey)")
        }
        return CGPoint(x: x, y: y)
    }

    private static func number(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    private static func requireAccessibility() throws {
        if AXIsProcessTrusted() { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        throw ComputerUseError.permission("需要「辅助功能」权限才能控制鼠标与键盘。请在 设置 → 工具 → 电脑操作 → 权限 中授权，然后重启 Myna。")
    }

    private static func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func move(to point: CGPoint) {
        guard let source = eventSource(),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func mouseMove(_ args: [String: Any]) throws -> String {
        try requireAccessibility()
        let target = try point(from: args)
        move(to: target)
        usleep(30_000)
        let now = mouseLocation()
        return "鼠标已移动到 \(Int(now.x)),\(Int(now.y))"
    }

    private static func mouseButtonTypes(_ raw: String) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch raw.lowercased() {
        case "right": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "center": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }

    static func mouseClick(_ args: [String: Any]) throws -> String {
        try requireAccessibility()
        var target: CGPoint?
        if args["x"] != nil || args["y"] != nil { target = try point(from: args) }
        let button = mouseButtonTypes(args["button"] as? String ?? "left")
        let clicks = max(1, min(args["clicks"] as? Int ?? 1, 3))
        let location = target ?? mouseLocation()
        if target != nil { move(to: location); usleep(30_000) }
        guard let source = eventSource() else { throw ComputerUseError.message("无法创建事件源") }
        for click in 1...clicks {
            let down = CGEvent(mouseEventSource: source, mouseType: button.down,
                               mouseCursorPosition: location, mouseButton: button.button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down?.post(tap: .cghidEventTap)
            usleep(30_000)
            let up = CGEvent(mouseEventSource: source, mouseType: button.up,
                             mouseCursorPosition: location, mouseButton: button.button)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up?.post(tap: .cghidEventTap)
            if click < clicks { usleep(70_000) }
        }
        let name = args["button"] as? String ?? "left"
        return "已在 \(Int(location.x)),\(Int(location.y)) 用 \(name) 键点击 \(clicks) 次"
    }

    static func mouseDrag(_ args: [String: Any]) throws -> String {
        try requireAccessibility()
        let fx = number(args["from_x"]) ?? number(args["x1"])
        let fy = number(args["from_y"]) ?? number(args["y1"])
        let tx = number(args["to_x"]) ?? number(args["x2"])
        let ty = number(args["to_y"]) ?? number(args["y2"])
        guard let fx, let fy, let tx, let ty else {
            throw ComputerUseError.message("拖拽需要 from_x / from_y / to_x / to_y")
        }
        let from = CGPoint(x: fx, y: fy)
        let to = CGPoint(x: tx, y: ty)
        let durationMS = max(100, min(args["duration_ms"] as? Int ?? 400, 5_000))
        let duration = Double(durationMS) / 1000
        let button = mouseButtonTypes(args["button"] as? String ?? "left")
        guard let source = eventSource() else { throw ComputerUseError.message("无法创建事件源") }
        move(to: from)
        usleep(30_000)
        let down = CGEvent(mouseEventSource: source, mouseType: button.down,
                           mouseCursorPosition: from, mouseButton: button.button)
        down?.post(tap: .cghidEventTap)
        let dragType: CGEventType
        switch button.button {
        case .right: dragType = .rightMouseDragged
        case .center: dragType = .otherMouseDragged
        default: dragType = .leftMouseDragged
        }
        let steps = 24
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t,
                                y: from.y + (to.y - from.y) * t)
            let drag = CGEvent(mouseEventSource: source, mouseType: dragType,
                               mouseCursorPosition: point, mouseButton: button.button)
            drag?.post(tap: .cghidEventTap)
            usleep(useconds_t(duration / Double(steps) * 1_000_000))
        }
        let up = CGEvent(mouseEventSource: source, mouseType: button.up,
                         mouseCursorPosition: to, mouseButton: button.button)
        up?.post(tap: .cghidEventTap)
        return "已从 \(Int(fx)),\(Int(fy)) 拖拽到 \(Int(tx)),\(Int(ty))"
    }

    static func scroll(_ args: [String: Any]) throws -> String {
        try requireAccessibility()
        let dy = Int(number(args["dy"]) ?? number(args["y"]) ?? 0)
        let dx = Int(number(args["dx"]) ?? number(args["x"]) ?? 0)
        guard dx != 0 || dy != 0 else { throw ComputerUseError.message("scroll 需要 dx 或 dy") }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource(), units: .pixel,
                                  wheelCount: 2, wheel1: Int32(clamping: dy),
                                  wheel2: Int32(clamping: dx), wheel3: 0) else {
            throw ComputerUseError.message("无法创建滚动事件")
        }
        event.post(tap: .cghidEventTap)
        return "已滚动 dx=\(dx) dy=\(dy)"
    }

    // MARK: - 键盘

    static func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "command": 55, "shift": 56, "capslock": 57, "option": 58, "alt": 58, "control": 59, "ctrl": 59,
            "right": 124, "left": 123, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        return map[key.lowercased()]
    }

    static func keyPress(_ args: [String: Any]) throws -> String {
        try requireAccessibility()
        let raw = (args["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ComputerUseError.message("缺少 key") }
        guard let code = keyCode(for: raw) else {
            throw ComputerUseError.message("不支持的按键「\(raw)」；输入文本请用 type_text")
        }
        var flags: CGEventFlags = []
        for modifier in (args["modifiers"] as? [String] ?? []) {
            switch modifier.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        guard let source = eventSource(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ComputerUseError.message("无法创建键盘事件")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        let mods = flags.isEmpty ? "" : " + \(args["modifiers"] as? [String] ?? [])"
        return "已按键 \(raw)\(mods)"
    }

    static func typeText(_ text: String) throws -> String {
        try requireAccessibility()
        guard !text.isEmpty else { return "没有可输入的文字" }
        guard let source = eventSource() else { throw ComputerUseError.message("无法创建事件源") }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 16, units.count)
            let chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { break }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            usleep(12_000)
            index = end
        }
        return "已输入 \(text.count) 个字符"
    }

    // MARK: - 图片

    struct EncodedImage {
        var path: String
        var base64: String
        var mime: String
        var width: Int
        var height: Int
        var originalWidth: Int
        var originalHeight: Int
        var bytes: Int
        var downscaled: Bool
    }

    static func encodeImage(path rawPath: String, maxPixels: Int = 1568) throws -> EncodedImage {
        let path = NSString(string: rawPath).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw ComputerUseError.message("图片不存在：\(path)")
        }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ComputerUseError.message("无法解码图片：\(path)")
        }
        let originalWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let originalHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ComputerUseError.message("无法缩放图片：\(path)")
        }
        let width = image.width
        let height = image.height
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ComputerUseError.message("无法编码 JPEG")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ComputerUseError.message("无法编码 JPEG")
        }
        return EncodedImage(path: path,
                            base64: (data as Data).base64EncodedString(),
                            mime: "image/jpeg",
                            width: width, height: height,
                            originalWidth: originalWidth, originalHeight: originalHeight,
                            bytes: data.length,
                            downscaled: width < originalWidth || height < originalHeight)
    }

    static func imageText(path rawPath: String) throws -> String {
        let encoded = try encodeImage(path: rawPath)
        return "已读取图片 \(encoded.path)：\(encoded.width)x\(encoded.height)（原图 \(encoded.originalWidth)x\(encoded.originalHeight)，JPEG \(SelfControlAPI.humanSize(encoded.bytes))）。" +
            " 包运行时会把它作为图片块发送给模型；若模型不支持图片输入，请改用 read_screen。"
    }
}

enum ComputerUseError: Error, LocalizedError {
    case permission(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .permission(let text): return text
        case .message(let text): return text
        }
    }
}

