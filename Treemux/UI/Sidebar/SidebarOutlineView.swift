//
//  SidebarOutlineView.swift
//  Treemux

import AppKit

/// NSOutlineView subclass that forwards keyboard events and provides context menus.
final class SidebarOutlineView: NSOutlineView {
    var activateSelection: (() -> Void)?
    var toggleExpansionForSelection: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activateSelection?()    // Return / Enter
        case 49: toggleExpansionForSelection?() // Space
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}
