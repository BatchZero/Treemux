//
//  ScrollWheelHorizontalRedirect.swift
//  Treemux
//

import SwiftUI
import AppKit

/// Transparent, click-through overlay that redirects a plain mouse scroll
/// wheel (vertical) into a horizontal-scroll callback, while leaving trackpad
/// gestures (`hasPreciseScrollingDeltas`) to the native ScrollView. Intended to
/// sit as an `.overlay` covering a horizontal tab bar.
struct ScrollWheelHorizontalRedirect: NSViewRepresentable {
    /// Vertical wheel delta (`event.scrollingDeltaY`) for a mouse wheel fired
    /// over this overlay. Receiver maps it to a horizontal scroll offset.
    let onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelMonitorView {
        WheelMonitorView(onWheel: onWheel)
    }

    func updateNSView(_ nsView: WheelMonitorView, context: Context) {
        nsView.onWheel = onWheel
    }

    /// Click-through NSView that observes scroll-wheel events through a local
    /// monitor. Using a monitor (not an overridden `scrollWheel`) keeps the
    /// view transparent to the tabs beneath it.
    final class WheelMonitorView: NSView {
        var onWheel: (CGFloat) -> Void
        private var monitor: Any?

        init(onWheel: @escaping (CGFloat) -> Void) {
            self.onWheel = onWheel
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Click-through: never become the hit-test target so clicks/drags reach
        // the tabs below. The scroll monitor works independently of hit-testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                installMonitor()
            }
        }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // Trackpad → leave to native horizontal scrolling.
                if event.hasPreciseScrollingDeltas { return event }
                // Only redirect a vertical-dominant wheel that is over this bar.
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                self.onWheel(event.scrollingDeltaY)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
