//
//  ScrollSync.swift
//  Treemux
//

import AppKit
import CodeEditSourceEditor
import Observation

/// Pure proportional-scroll calculations shared by the AppKit and SwiftUI
/// sides of the split document viewer.
enum ScrollSyncMetrics {
    static func fraction(offsetY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollableHeight = contentHeight - viewportHeight
        guard scrollableHeight > 0 else { return 0 }
        return min(max(offsetY / scrollableHeight, 0), 1)
    }

    static func offsetY(fraction: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollableHeight = max(0, contentHeight - viewportHeight)
        return min(max(fraction, 0), 1) * scrollableHeight
    }
}

/// Shared proportional scroll event for a split document viewer. `revision`
/// makes repeated publications observable even when their fractions match.
@Observable final class ScrollSync {
    enum Driver: Equatable {
        case none
        case source
        case render
    }

    private(set) var fraction: CGFloat = 0
    private(set) var driver: Driver = .none
    private(set) var revision = 0

    func publish(fraction: CGFloat, from driver: Driver) {
        guard driver != .none else { return }
        self.fraction = min(max(fraction, 0), 1)
        self.driver = driver
        revision &+= 1
    }

    func finish(_ driver: Driver) {
        guard self.driver == driver else { return }
        self.driver = .none
    }
}

/// Editor-side bridge between CodeEditSourceEditor's AppKit scroll view and
/// the shared split-view scroll event.
final class ScrollSyncCoordinator: TextViewCoordinator {
    private let sync: ScrollSync
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private var suppressNextPublication = false

    init(sync: ScrollSync) {
        self.sync = sync
    }

    deinit {
        removeObserver()
    }

    func prepareCoordinator(controller: TextViewController) {
        scrollView = controller.scrollView
    }

    func controllerDidAppear(controller: TextViewController) {
        scrollView = controller.scrollView
        installObserver(on: controller.scrollView.contentView)
    }

    func controllerDidDisappear(controller: TextViewController) {
        removeObserver()
    }

    func destroy() {
        removeObserver()
        scrollView = nil
    }

    /// Applies a render-originated event without publishing the resulting
    /// AppKit bounds notification back to the render pane.
    func applyFractionFromRender() {
        guard let scrollView else { return }
        let targetY = ScrollSyncMetrics.offsetY(
            fraction: sync.fraction,
            contentHeight: scrollView.documentView?.frame.height ?? 0,
            viewportHeight: scrollView.contentView.bounds.height
        )
        guard abs(scrollView.contentView.bounds.origin.y - targetY) > 0.5 else { return }

        suppressNextPublication = true
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.suppressNextPublication = false
        }
    }

    private func installObserver(on clipView: NSClipView) {
        removeObserver()
        clipView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.sourceDidScroll()
        }
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func sourceDidScroll() {
        if suppressNextPublication {
            suppressNextPublication = false
            return
        }
        guard let scrollView else { return }
        sync.publish(
            fraction: ScrollSyncMetrics.fraction(
                offsetY: scrollView.contentView.bounds.origin.y,
                contentHeight: scrollView.documentView?.frame.height ?? 0,
                viewportHeight: scrollView.contentView.bounds.height
            ),
            from: .source
        )
    }
}
