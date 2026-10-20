import SwiftUI
import AppKit

/// 左侧「用户消息」导航轨。
///
/// 用 AppKit 实现而非 SwiftUI 视图堆叠：预览卡片出现会让 SwiftUI 重建视图树，
/// 逐刻度 / 整轨的 hover 跟踪区随之失效——实测预览一旦显示就无法切换到其它刻度
/// （只有把光标移出面板再回来才恢复）。NSView 的跟踪区不随 SwiftUI 重建丢失。
struct TurnRail: NSViewRepresentable {
    /// 轮次数量
    var count: Int
    /// 当前所在轮次（高亮）
    var activeIndex: Int
    var accent: NSColor
    /// 悬停到某一格（nil 表示离开）
    var onHover: (Int?) -> Void
    /// 点击某一格
    var onSelect: (Int) -> Void

    static let tickHeight: CGFloat = 9
    static let tickSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 6
    static let width: CGFloat = 18

    /// 该数量对应的整体高度。
    static func height(for count: Int) -> CGFloat {
        verticalPadding * 2 + CGFloat(max(count, 0)) * (tickHeight + tickSpacing)
    }

    func makeNSView(context: Context) -> RailView {
        let view = RailView()
        view.configure(count: count, activeIndex: activeIndex, accent: accent,
                       onHover: onHover, onSelect: onSelect)
        return view
    }

    func updateNSView(_ nsView: RailView, context: Context) {
        nsView.configure(count: count, activeIndex: activeIndex, accent: accent,
                         onHover: onHover, onSelect: onSelect)
    }

    final class RailView: NSView {
        private var count = 0
        private var activeIndex = 0
        private var accent: NSColor = .controlAccentColor
        private var onHover: ((Int?) -> Void)?
        private var onSelect: ((Int) -> Void)?
        private var tracking: NSTrackingArea?
        private var hoveredIndex: Int?

        override var isFlipped: Bool { true }

        func configure(count: Int, activeIndex: Int, accent: NSColor,
                       onHover: ((Int?) -> Void)?, onSelect: ((Int) -> Void)?) {
            self.count = count
            self.activeIndex = activeIndex
            self.accent = accent
            self.onHover = onHover
            self.onSelect = onSelect
            needsDisplay = true
        }

        private var step: CGFloat { TurnRail.tickHeight + TurnRail.tickSpacing }

        /// 该 y 对应的刻度下标。
        private func index(at y: CGFloat) -> Int? {
            guard count > 0 else { return nil }
            let raw = Int((y - TurnRail.verticalPadding) / step)
            return (0..<count).contains(raw) ? raw : nil
        }

        private func centerY(_ index: Int) -> CGFloat {
            TurnRail.verticalPadding + CGFloat(index) * step + step / 2
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let next = index(at: point.y)
            guard next != hoveredIndex else { return }
            hoveredIndex = next
            onHover?(next)
        }

        override func mouseExited(with event: NSEvent) {
            guard hoveredIndex != nil else { return }
            hoveredIndex = nil
            onHover?(nil)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let idx = index(at: point.y) { onSelect?(idx) }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard count > 0 else { return }
            let track = NSBezierPath(roundedRect: bounds,
                                     xRadius: bounds.width / 2, yRadius: bounds.width / 2)
            NSColor.primaryAppearanceFill.setFill()
            track.fill()

            for i in 0..<count {
                let active = i == activeIndex
                let w: CGFloat = active ? 6 : 3
                let rect = NSRect(x: (bounds.width - w) / 2,
                                  y: centerY(i) - TurnRail.tickHeight / 2,
                                  width: w,
                                  height: TurnRail.tickHeight)
                let path = NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2)
                (active ? accent : NSColor.secondaryLabelColor.withAlphaComponent(0.35)).setFill()
                path.fill()
            }
        }
    }
}

private extension NSColor {
    /// 导轨底色：极淡的主色，明暗外观都适用。
    static var primaryAppearanceFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.045)
        }
    }
}
