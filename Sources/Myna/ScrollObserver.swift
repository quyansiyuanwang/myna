import SwiftUI
import AppKit

/// 观测 SwiftUI `ScrollView` 的滚动位置。
///
/// 为什么不用 `GeometryReader` + `PreferenceKey`：SwiftUI 滚动是图层级偏移，
/// 不会触发布局重算，因此滚动时偏好值**不会更新**（实测滚动后取到的仍是初值）。
/// 这里直接找到底层 `NSScrollView` 并监听其内容区 bounds 变化。
struct ScrollObserver: NSViewRepresentable {
    /// 观测角色：位置（滚动偏移/视口）或底部锚点（真实内容底部位置）。
    enum Role: Equatable {
        case position
        case bottomAnchor
    }

    var role: Role = .position
    /// position：(已滚动距离, 底部锚点位置, 视口高度)；bottomAnchor：(0, 锚点位置, 0)
    var onChange: (_ offset: CGFloat, _ bottomY: CGFloat, _ viewport: CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.role = role
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.role = role
        nsView.onChange = onChange
    }

    final class ProbeView: NSView {
        var role: Role = .position
        var onChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        /// 上一次上报的数值，用于丢弃重复回调。
        private var lastReported: (CGFloat, CGFloat, CGFloat) = (-1, -1, -1)
        /// 已经排队、等待本轮布局结束后上报。
        private var reportScheduled = false
        /// 上一次上报的时刻（用于限流）。
        private var lastReportAt = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        private func attach() {
            guard scrollView == nil else { return }
            var candidate: NSView? = superview
            while let view = candidate {
                if let scroll = view as? NSScrollView { scrollView = scroll; break }
                candidate = view.superview
            }
            guard let scroll = scrollView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.report()
            }
            report()
        }

        private func report() {
            guard let scroll = scrollView else { return }
            let offset = scroll.contentView.bounds.origin.y
            let viewport = scroll.contentView.bounds.height
            // 底部锚点位置需要一次跨层级坐标换算（`convert(to:)` 会走视图链），
            // 只有底部锚点角色才需要；位置角色直接跳过——这个换算在滚动时是每个事件一次，
            // 长会话里代价可观。
            var bottomY: CGFloat = 0
            if role == .bottomAnchor, let documentView = scroll.documentView {
                bottomY = convert(bounds, to: documentView).maxY
            } else if role == .position, let documentView = scroll.documentView {
                // 内容底部直接取 documentView 高度，避免再放一个自定义锚点视图；
                // 锚点视图会在每次滚动布局时触发 layout()/异步上报，长列表下开销明显。
                bottomY = documentView.frame.height
            }
            // 限流：正常滚动远达不到这个频率；一旦超过，说明又出现了「上报→重新布局→再上报」
            // 的链条，此时宁可少报也不能空转。
            let now = Date()
            let elapsed = now.timeIntervalSince(lastReportAt)
            if elapsed < 1.0 / 30 {
                scheduleReport()
                return
            }
            lastReportAt = now

            // 数值没变就不回调：每次回调都会让上层写入状态并重新布局。
            let next: (CGFloat, CGFloat, CGFloat) = role == .position
                ? (offset, bottomY, viewport)
                : (0, bottomY, 0)
            let prev = lastReported
            let unchanged = abs(next.0 - prev.0) < 0.5
                && abs(next.1 - prev.1) < 0.5
                && abs(next.2 - prev.2) < 0.5
            guard !unchanged else { return }
            lastReported = next
            onChange?(next.0, next.1, next.2)
        }

        override func layout() {
            super.layout()
            guard role == .bottomAnchor else { return }
            // 绝不能在布局过程中回调！
            // 回调会写 SwiftUI 状态 → 父视图重新布局 → 再次布局本视图 → 再次回调，
            // 形成没有 body 求值的纯布局死循环（表现为 100% CPU 但界面完全不动、
            // `PlatformViewHost.invalidateLayout` 在采样里反复出现）。
            // 推迟到本次布局结束后再上报，并合并同一轮内的多次请求。
            scheduleReport()
        }

        /// 布局结束后的下一轮 runloop 上报一次（同一轮只上报一次）。
        private func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
