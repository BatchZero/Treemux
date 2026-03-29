//
//  SidebarRowView.swift
//  Treemux

import AppKit

/// Custom row view that draws an inset rounded-rectangle selection.
final class SidebarRowView: NSTableRowView {
    var selectionFillColor: NSColor = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.26, alpha: 1)
    var selectionStrokeColor: NSColor = NSColor(calibratedRed: 0.25, green: 0.54, blue: 0.87, alpha: 0.9)

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
