//
//  TreemuxGhosttyClipboardSupport.swift
//  Treemux
//

import AppKit
import Foundation
import GhosttyKit

// MARK: - Pasteboard resolution

@MainActor
func treemuxGhosttyPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
    switch location {
    case GHOSTTY_CLIPBOARD_STANDARD:
        return .general
    case GHOSTTY_CLIPBOARD_SELECTION:
        return NSPasteboard(name: NSPasteboard.Name("com.treemux.selection"))
    default:
        return nil
    }
}

// MARK: - Clipboard payload

struct TreemuxGhosttyClipboardPayload: Sendable {
    let mimeType: String
    let text: String

    nonisolated var isPlainText: Bool {
        mimeType == "text/plain"
            || mimeType == "text/plain;charset=utf-8"
            || mimeType == "public.utf8-plain-text"
            || mimeType == NSPasteboard.PasteboardType.string.rawValue
    }

    nonisolated var pasteboardType: NSPasteboard.PasteboardType? {
        if isPlainText {
            return .string
        }
        return NSPasteboard.PasteboardType(rawValue: mimeType)
    }
}

// MARK: - Write clipboard items

@MainActor
func treemuxGhosttyWriteClipboard(_ items: [TreemuxGhosttyClipboardPayload], to pasteboard: NSPasteboard) {
    let supportedTypes = items.compactMap(\.pasteboardType)
    guard !supportedTypes.isEmpty else { return }

    pasteboard.clearContents()
    pasteboard.declareTypes(supportedTypes, owner: nil)
    for item in items {
        guard let type = item.pasteboardType else { continue }
        pasteboard.setString(item.text, forType: type)
    }
}

// MARK: - Best string extraction

extension NSPasteboard {
    var treemuxGhosttyBestString: String? {
        string(forType: .string)
            ?? string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
    }
}
