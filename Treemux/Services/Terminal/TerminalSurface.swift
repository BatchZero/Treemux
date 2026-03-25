//
//  TerminalSurface.swift
//  Treemux
//

import AppKit
import Foundation

// MARK: - Terminal viewport status

struct TerminalViewportStatus: Equatable {
    var total: UInt64
    var offset: UInt64
    var length: UInt64

    var progress: Double? {
        let maxOffset = max(Int64(total) - Int64(length), 0)
        guard maxOffset > 0 else { return nil }
        return Double(offset) / Double(maxOffset)
    }
}

// MARK: - Terminal surface status snapshot

struct TerminalSurfaceStatusSnapshot: Equatable {
    var rendererHealthy = true
    var searchQuery: String?
    var searchTotal: Int?
    var searchSelected: Int?
    var isReadOnly = false
    var viewport: TerminalViewportStatus?
}

// MARK: - Terminal engine kind

enum TerminalEngineKind: String, Codable, CaseIterable {
    case libghosttyPreferred

    var displayName: String {
        "libghostty"
    }
}

// MARK: - Terminal surface controller protocol

@MainActor
protocol TerminalSurfaceController: AnyObject {
    var resolvedEngine: TerminalEngineKind { get }
    var view: NSView { get }
    var onResize: ((Int, Int) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
    var onWorkingDirectoryChange: ((String?) -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    var onStatusChange: ((TerminalSurfaceStatusSnapshot) -> Void)? { get set }
    func sendText(_ text: String)
    func focus()
    func setFocused(_ isFocused: Bool)
    func beginSearch(initialText: String?)
    func updateSearch(_ text: String)
    func searchNext()
    func searchPrevious()
    func endSearch()
    func toggleReadOnly()
}

// MARK: - Managed terminal session surface controller protocol

@MainActor
protocol ManagedTerminalSessionSurfaceController: TerminalSurfaceController {
    var managedPID: Int32? { get }
    var isManagedSessionRunning: Bool { get }
    var needsConfirmQuit: Bool { get }
    var onProcessExit: ((Int32?) -> Void)? { get set }
    func updateLaunchConfiguration(_ configuration: TerminalLaunchConfiguration)
    func startManagedSessionIfNeeded()
    func restartManagedSession()
    func terminateManagedSession()
}

// MARK: - Terminal surface factory

enum TerminalSurfaceFactory {
    @MainActor
    static func make(
        preferred _: TerminalEngineKind,
        launchConfiguration: TerminalLaunchConfiguration
    ) -> ManagedTerminalSessionSurfaceController {
        return TreemuxGhosttyController(launchConfiguration: launchConfiguration)
    }
}

// MARK: - Text finder action helper

func treemuxTextFinderAction(for sender: Any?) -> NSTextFinder.Action? {
    guard let menuItem = sender as? NSMenuItem else { return nil }
    return NSTextFinder.Action(rawValue: menuItem.tag)
}

// MARK: - Search binding helpers

enum TreemuxGhosttySearchNavigation: String {
    case previous
    case next
}

func treemuxGhosttySearchBindingAction(for query: String) -> String {
    "search:\(query)"
}

func treemuxGhosttySearchNavigationBindingAction(_ direction: TreemuxGhosttySearchNavigation) -> String {
    "navigate_search:\(direction.rawValue)"
}

// MARK: - Drag-and-drop text helper

func treemuxTerminalDropText(fileURLs: [URL], plainText: String?) -> String? {
    let quotedPaths = fileURLs
        .filter(\.isFileURL)
        .map(\.path)
        .filter { !$0.isEmpty }
        .map(\.shellQuoted)

    if !quotedPaths.isEmpty {
        return quotedPaths.joined(separator: " ")
    }

    guard let plainText, !plainText.isEmpty else { return nil }
    return plainText
}
