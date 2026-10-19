import SwiftUI
import AppKit

/// 面板右下角的尺寸手柄。
///
/// 用 AppKit 事件与**屏幕坐标**（`NSEvent.mouseLocation`）计算位移。
///
/// 为什么不用 SwiftUI `DragGesture`：它在视图 / 窗口坐标系里计算 translation，
/// 而拖拽过程中窗口本身正在变大变小（面板模式下面板还会重新居中），
/// 坐标系跟着移动会把位移抵消掉——实测表现为「只跟一半距离并且来回抖动」。
/// 屏幕坐标不受窗口移动影响，位移始终等于光标的真实移动量。
struct ResizeGrip: NSViewRepresentable {
    /// 相对拖拽起点的位移（屏幕坐标，y 轴向上）。
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onDrag = onDrag
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }

    final class GripView: NSView {
        var onDrag: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?

        private var startMouse: NSPoint?
        private var tracking: NSTrackingArea?
        private var hovered = false { didSet { needsDisplay = true } }

        override var isFlipped: Bool { false }
        override var acceptsFirstResponder: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let alpha: CGFloat = hovered ? 0.8 : 0.3
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            guard let base = NSImage(systemSymbolName: "arrow.down.right",
                                     accessibilityDescription: "调整大小"),
                  let image = base.withSymbolConfiguration(config) else { return }
            // 模板图标跟随外观着色
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.secondaryLabelColor.withAlphaComponent(alpha).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            let size = tinted.size
            let origin = NSPoint(x: (bounds.width - size.width) / 2,
                                 y: (bounds.height - size.height) / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovered = true
            NSCursor.crosshair.push()
        }

        override func mouseExited(with event: NSEvent) {
            hovered = false
            NSCursor.pop()
        }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = startMouse else { return }
            let now = NSEvent.mouseLocation
            // 屏幕坐标 y 轴向上，而视图高度向下增长，因此高度取反。
            let delta = CGSize(width: now.x - start.x, height: start.y - now.y)
            if ProcessInfo.processInfo.environment["MYNA_DEBUG"] == "1" {
                let line = "grip 位移=\(Int(delta.width))x\(Int(delta.height)) 光标=\(Int(now.x)),\(Int(now.y))\n"
                if let d = line.data(using: .utf8) {
                    if let fh = FileHandle(forWritingAtPath: "/tmp/myna-debug.log") {
                        fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
                    }
                }
            }
            onDrag?(CGSize(width: now.x - start.x, height: start.y - now.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard startMouse != nil else { return }
            startMouse = nil
            onEnd?()
        }
    }
}
