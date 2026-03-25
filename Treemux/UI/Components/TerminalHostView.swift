//
//  TerminalHostView.swift
//  Treemux
//

import AppKit
import SwiftUI

// MARK: - Terminal host view (NSViewRepresentable bridge)

/// Bridges a ShellSession's terminal NSView into SwiftUI using a container
/// view that manages layout constraints and first-responder focus.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: ShellSession
    var shouldRestoreFocus: Bool = false

    func makeNSView(context: Context) -> TerminalViewContainer {
        let container = TerminalViewContainer()
        container.attach(session.nsView, restoreFocus: shouldRestoreFocus)
        return container
    }

    func updateNSView(_ nsView: TerminalViewContainer, context: Context) {
        nsView.attach(session.nsView, restoreFocus: shouldRestoreFocus)
    }
}

// MARK: - Terminal view container

/// An AppKit container that hosts the Ghostty terminal NSView with proper
/// Auto Layout constraints and optional first-responder restoration.
final class TerminalViewContainer: NSView {
    private weak var hostedView: NSView?

    func attach(_ view: NSView, restoreFocus: Bool) {
        let needsAttach = hostedView !== view || view.superview !== self

        if needsAttach {
            hostedView?.removeFromSuperview()
            view.removeFromSuperview()
            hostedView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        guard restoreFocus, needsAttach else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, let window = self.window ?? view.window else { return }
            if window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        }
    }
}
