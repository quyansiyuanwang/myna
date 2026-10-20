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
            // 底部锚点在文档坐标系里的真实位置：比 documentView 高度可靠
            // （LazyVStack 的高度是估算值，会导致「是否贴底」误判）。
            let documentView = scroll.documentView
            let bottomY: CGFloat
            if let documentView {
                bottomY = convert(bounds, to: documentView).maxY
            } else {
                bottomY = 0
            }
            switch role {
            case .position:
                onChange?(offset, bottomY, viewport)
            case .bottomAnchor:
                onChange?(0, bottomY, 0)
            }
        }

        override func layout() {
            super.layout()
            if role == .bottomAnchor { report() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
