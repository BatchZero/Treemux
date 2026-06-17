//
//  Notifications.swift
//  Treemux

import Foundation

extension Notification.Name {
    static let treemuxSaveCurrentFile = Notification.Name("treemux.saveCurrentFile")
    /// Posted when the active theme changes. `object` is the new `Theme`.
    static let themeDidChange = Notification.Name("treemux.themeDidChange")
}
