//
//  SidebarRowView.swift
//  Treemux

import AppKit

/// Custom row view that draws an inset rounded-rectangle selection.
final class SidebarRowView: NSTableRowView {
    var selectionFillColor: NSColor = .selectedContentBackgroundColor
    var selectionStrokeColor: NSColor = .clear

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        selectionFillColor.setFill()
        path.fill()
        selectionStrokeColor.setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
