//
//  SidebarContainerView.swift
//  Treemux

import AppKit
import SwiftUI

/// Container that holds the NSScrollView + NSOutlineView.
final class SidebarContainerView: NSView {
    let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.rowHeight = 36
        outlineView.indentationPerLevel = 12
        outlineView.floatsGroupRows = false
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 4)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Keep the drag session alive after the pointer leaves Treemux so the
        // table-view delegate receives the drag-ended callback for a desktop
        // drop and can turn it into a detached window.
        outlineView.setDraggingSourceOperationMask(.move, forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadOutlineData() { outlineView.reloadData() }
}
