//
//  TabGrouping.swift
//  Treemux
//
//  Pure helper that partitions tabs into file-browser and terminal groups for
//  the grouped tab bar, preserving each group's relative order.
//

import Foundation

enum TabGrouping {
    static func partition<T>(_ items: [T], kindOf: (T) -> WorkspaceTabKind) -> (files: [T], shell: [T]) {
        var files: [T] = []
        var shell: [T] = []
        for item in items {
            switch kindOf(item) {
            case .fileBrowser: files.append(item)
            case .terminal: shell.append(item)
            }
        }
        return (files, shell)
    }
}
