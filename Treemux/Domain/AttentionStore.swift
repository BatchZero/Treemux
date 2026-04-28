//
//  AttentionStore.swift
//  Treemux
//

import Combine
import Foundation

/// Singleton observable store mapping pane UUIDs to their current AI attention
/// state. Replaces the per-`ShellSession` `@Published var aiAttention` storage,
/// which is too deeply nested for SwiftUI/NSOutlineView observers to track.
///
/// Mutations fire `objectWillChange` so any view that holds an `@ObservedObject`
/// or `@EnvironmentObject` reference to the store re-renders automatically.
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    @Published private(set) var attentive: [UUID: AIAttentionState] = [:]

    /// Set the attention state for a given pane. `.none` is normalised to a removal.
    func setAttention(paneID: UUID, state: AIAttentionState) {
        if state == .none {
            attentive.removeValue(forKey: paneID)
        } else {
            attentive[paneID] = state
        }
    }

    /// Clear attention for a single pane (no-op if not currently attentive).
    func clear(paneID: UUID) {
        attentive.removeValue(forKey: paneID)
    }

    /// Clear attention for many panes at once. Used by boundary events
    /// ("user selected this workspace/tab"), which acknowledge attention for
    /// every pane reachable through that selection.
    func clear(paneIDs: some Sequence<UUID>) {
        for id in paneIDs {
            attentive.removeValue(forKey: id)
        }
    }

    /// Returns the state for a pane, or `.none` if not present.
    func state(for paneID: UUID) -> AIAttentionState {
        attentive[paneID] ?? .none
    }

    /// True if any of the given pane IDs is currently attentive.
    func hasAttention(in paneIDs: some Sequence<UUID>) -> Bool {
        for id in paneIDs where attentive[id] != nil {
            return true
        }
        return false
    }

    /// Test helper. Resets all state.
    #if DEBUG
    func resetForTest() {
        attentive.removeAll()
    }
    #endif

    private init() {}
}
