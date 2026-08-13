//
//  DetachPasteboardItem.swift
//  Treemux

import AppKit
import Foundation

/// Wraps a pasteboard item that carries both the legacy reorder payload
/// (workspace IDs / remote-group key) AND a `DetachedNodeRef` for tear-off.
///
/// The two coexist on the same drag session so that:
/// - in-list reordering keeps working (the existing `validateDrop`/`acceptDrop`
///   paths read the legacy `com.treemux.workspace.ids` /
///   `com.treemux.remote-group.key` types), and
/// - the tear-off path (Task 9's `draggingSession(endedAt:)`) can read the new
///   `com.treemux.detach.ref` type to spawn a detached child window when the
///   drag ends outside any valid drop target.
///
/// The detach payload is the JSON encoding of `ref` (UTF-8 string), so it
/// round-trips cleanly through `JSONDecoder` on the receiving side.
final class DetachPasteboardItem: NSObject, NSPasteboardWriting {
    /// Pasteboard type written for the tear-off ref. Read by the tear-off
    /// machinery (Task 9) to decide whether a drag that ended with no valid
    /// drop target should spawn a new detached window.
    static let detachType = NSPasteboard.PasteboardType("com.treemux.detach.ref")

    /// The detached-node identity carried by this drag session.
    let ref: DetachedNodeRef

    /// Optional legacy payload (reorder type -> raw string value) written
    /// alongside the detach ref so existing reorder logic keeps working.
    /// Empty for nodes that have no reorder payload (e.g. worktree).
    let legacyReorderPayload: [(NSPasteboard.PasteboardType, String)]

    init(ref: DetachedNodeRef,
         legacyReorderPayload: [(NSPasteboard.PasteboardType, String)] = []) {
        self.ref = ref
        self.legacyReorderPayload = legacyReorderPayload
    }

    // MARK: - NSPasteboardWriting

    func writableTypes(for pasteboard: NSPasteboard?) -> [NSPasteboard.PasteboardType] {
        // Detach type first so consumers that prefer it win; then append the
        // legacy reorder types so the reorder path can still see the payload.
        var types: [NSPasteboard.PasteboardType] = [Self.detachType]
        types.append(contentsOf: legacyReorderPayload.map { $0.0 })
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.detachType {
            // Encode the ref as a JSON string so the receiver can decode it
            // back into a `DetachedNodeRef` without any custom format.
            guard let data = try? JSONEncoder().encode(ref) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        // Fall back to the legacy raw string for reorder compatibility.
        return legacyReorderPayload.first(where: { $0.0 == type })?.1
    }
}
