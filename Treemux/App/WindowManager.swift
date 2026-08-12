//
//  WindowManager.swift
//  Treemux
//

import AppKit
import Observation
import SwiftUI

/// Owns the main window and any detached child windows, coordinating their
/// lifecycle against `WorkspaceStore.detachedNodes`.
///
/// `WindowManager` replaces the single `WindowContext` ownership previously
/// held by `TreemuxApp`. It is `@Observable` so it can be injected into the
/// SwiftUI environment (`@Environment(WindowManager.self)`) in a later task,
/// letting views react to child-window creation/closure.
///
/// State invariant: a `DetachedNodeRef` is in `store.detachedNodes` if and only
/// if its child `WindowContext` is live (in `childContexts`) — except during
/// cascade shutdown, where refs stay detached to avoid a per-node restore loop.
@MainActor
@Observable
final class WindowManager {
    /// The backing store; drives sidebar visibility and ref validity.
    let store: WorkspaceStore

    /// Context owning the primary workspace window, if launched.
    private(set) var mainWindowContext: WindowContext?

    /// Contexts for torn-off child windows, in creation order.
    private(set) var childContexts: [WindowContext] = []

    /// True during cascade shutdown (main window closing). Suppresses the
    /// per-node detached-state restore that normally fires when a child window
    /// closes, so teardown doesn't round-trip each ref back into the sidebar.
    var isShuttingDown = false

    init(store: WorkspaceStore) {
        self.store = store
    }

    /// Creates and shows the main workspace window. Idempotent: a no-op if the
    /// main window is already launched.
    func launchMain() {
        guard mainWindowContext == nil else { return }
        let ctx = WindowContext(store: store, kind: .main)
        ctx.windowManager = self
        ctx.show()
        mainWindowContext = ctx
    }

    /// Tears off `ref` into its own window and records it as detached so the
    /// main sidebar hides it. No-op if `ref` is invalid (the referenced node
    /// no longer exists) or already detached.
    func detach(_ ref: DetachedNodeRef) {
        guard store.isValid(ref) else { return }
        // Avoid double-detach: a second window for the same ref would desync
        // the sidebar filter and persist duplicate state.
        guard !store.isDetached(ref) else { return }
        store.detachedNodes.insert(ref)
        let ctx = WindowContext(store: store, kind: .detached(ref))
        ctx.windowManager = self
        childContexts.append(ctx)
        ctx.show()
    }

    /// Called when a child window is closed by the user. Restores the node's
    /// visibility in the main sidebar by removing it from `detachedNodes` —
    /// unless we're cascading shutdown, in which case the ref stays detached.
    func closeChild(_ ctx: WindowContext) {
        if !isShuttingDown, case .detached(let ref) = ctx.kind {
            store.detachedNodes.remove(ref)
        }
        ctx.closeImmediately()
        childContexts.removeAll { $0 === ctx }
    }

    /// Main window is closing: cascade-close every child without triggering
    /// per-node restore, then terminate the app.
    ///
    /// Sets `isShuttingDown` first so `closeChild(_:)` invocations (and any
    /// NSWindowDelegate close events that route back through) skip the
    /// detached-ref removal path.
    func handleMainWindowWillClose() {
        isShuttingDown = true
        for ctx in childContexts {
            ctx.closeImmediately()
        }
        childContexts.removeAll()
        NSApp.terminate(nil)
    }

    /// Rebuilds child windows from persisted `detachedNodes`. Called on launch
    /// to restore the previous session's torn-off windows. Stale refs (whose
    /// nodes no longer exist) are dropped from the store.
    func restoreChildWindows() {
        // Snapshot the set so removal during iteration is safe.
        let refs = store.detachedNodes
        for ref in refs {
            guard store.isValid(ref) else {
                store.detachedNodes.remove(ref)
                continue
            }
            let ctx = WindowContext(store: store, kind: .detached(ref))
            ctx.windowManager = self
            childContexts.append(ctx)
            ctx.show()
        }
    }
}
