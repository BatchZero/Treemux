//
//  SidebarCellView.swift
//  Treemux

import AppKit
import SwiftUI

/// Hosts a SwiftUI sidebar row inside an NSTableCellView via NSHostingView.
final class SidebarCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func apply(content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hostingView
        }
    }
}
