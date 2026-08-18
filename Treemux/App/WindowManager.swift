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
    /// Always reset to `false` once the cascade finishes (even if app
    /// termination is later cancelled) so future detach/restore cycles work.
    var isShuttingDown = false

    /// Observer token for `NSWindow.willCloseNotification` on child windows.
    /// Registered in `launchMain()` so the manager detects child-window closes
    /// driven by the user clicking the red × (which otherwise never route back
    /// to `closeChild(_:)`).
    @ObservationIgnored private var childWillCloseObserver: NSObjectProtocol?

    /// Confirmation boundary for closing the main window while detached child
    /// windows are still open. Injected in tests so policy can be verified
    /// without entering an AppKit modal loop.
    @ObservationIgnored private let mainWindowCloseConfirmation: @MainActor (Int) -> Bool

    init(
        store: WorkspaceStore,
        mainWindowCloseConfirmation: @escaping @MainActor (Int) -> Bool = WindowManager.presentMainWindowCloseConfirmation
    ) {
        self.store = store
        self.mainWindowCloseConfirmation = mainWindowCloseConfirmation
    }

    deinit {
        if let token = childWillCloseObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Creates and shows the main workspace window. Idempotent: a no-op if the
    /// main window is already launched. Also registers the child-window
    /// `willCloseNotification` observer used to detect user-driven child-window
    /// closes (the red ×) — without it, closing a detached window would never
    /// route back to `closeChild(_:)` and the node would stay hidden forever.
    func launchMain() {
        guard mainWindowContext == nil else { return }
        registerChildWillCloseObserverIfNeeded()
        let ctx = WindowContext(store: store, kind: .main)
        ctx.windowManager = self
        ctx.show()
        mainWindowContext = ctx
    }

    /// Registers the `NSWindow.willCloseNotification` observer that drives
    /// child-window close detection. Idempotent (no-op if already registered).
    /// The observer lives for the manager's lifetime and dispatches to
    /// `handleChildWindowClose(_:)` for any window whose autosave name starts
    /// with `"treemux.detach."`.
    private func registerChildWillCloseObserverIfNeeded() {
        guard childWillCloseObserver == nil else { return }
        childWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  window.frameAutosaveName.hasPrefix("treemux.detach.") else { return }
            Task { @MainActor in
                self.handleChildWindowClose(window)
            }
        }
    }

    /// Called (via the willCloseNotification observer) when a detached child
    /// window closes. Locates the owning `WindowContext` by window identity and
    /// routes through `closeChild(_:)` so the detached-ref restore side-effect
    /// runs (the node reappears in the main sidebar). During cascade shutdown
    /// (`isShuttingDown == true`) `closeChild` skips the restore — that path is
    /// driven by `handleMainWindowWillClose()` and already tears the contexts
    /// down directly, so this is effectively a no-op for cascade closes.
    func handleChildWindowClose(_ window: NSWindow) {
        guard let ctx = childContexts.first(where: { $0.ownsWindow(window) }) else { return }
        closeChild(ctx)
    }

    /// Resolves the command context owned by `window`. Menu shortcuts use this
    /// boundary so workspace-sensitive actions follow the active window rather
    /// than the main window's global store selection.
    func commandContext(for window: NSWindow) -> WindowCommandContext? {
        if let mainWindowContext, mainWindowContext.ownsWindow(window) {
            return mainWindowContext.commandContext
        }
        return childContexts.first(where: { $0.ownsWindow(window) })?.commandContext
    }

    /// Tears off `ref` into its own window and records it as detached so the
    /// main sidebar hides it. No-op if `ref` is invalid (the referenced node
    /// no longer exists) or already detached.
    func detach(_ ref: DetachedNodeRef) {
        guard store.isValid(ref) else { return }
        // Avoid double-detach: a second window for the same ref would desync
        // the sidebar filter and persist duplicate state.
        guard !store.isDetached(ref) else { return }
        guard !store.detachedNodes.contains(where: { overlaps($0, ref) }) else { return }
        store.detachedNodes.insert(ref)
        moveMainSelectionAway(from: ref)
        let ctx = WindowContext(store: store, kind: .detached(ref))
        ctx.windowManager = self
        childContexts.append(ctx)
        ctx.show()
    }

    /// A detached sidebar node is owned by its child window. If the main
    /// window was displaying that exact node, move it to the nearest attached
    /// scope so both windows never drive the same active tab state.
    private func moveMainSelectionAway(from ref: DetachedNodeRef) {
        switch ref {
        case .worktree(let workspaceID, let worktreeID):
            guard store.selectedWorkspaceID == worktreeID,
                  let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
                return
            }
            if let rootPath = workspace.repositoryRoot?.path ?? workspace.sshTarget?.remotePath,
               workspace.activeWorktreePath != rootPath {
                workspace.switchToWorktree(rootPath)
            }
            store.selectWorkspace(workspace.id)
        case .workspace, .remoteGroup:
            guard selectionIsOwned(by: ref) else { return }
            store.selectedWorkspaceID = firstAttachedWorkspaceID()
        }
    }

    private func selectionIsOwned(by ref: DetachedNodeRef) -> Bool {
        guard let selectedWorkspace = store.selectedWorkspace else { return false }
        switch ref {
        case .workspace(let workspaceID):
            return selectedWorkspace.id == workspaceID
        case .worktree(_, let worktreeID):
            return store.selectedWorkspaceID == worktreeID
        case .remoteGroup(let key):
            guard let target = selectedWorkspace.sshTarget else { return false }
            return WorkspaceStore.remoteGroupKey(for: target) == key
        }
    }

    private func firstAttachedWorkspaceID() -> UUID? {
        store.sidebarWorkspaces.first { workspace in
            !store.detachedNodes.contains { ref in
                switch ref {
                case .workspace(let workspaceID):
                    return workspaceID == workspace.id
                case .worktree:
                    return false
                case .remoteGroup(let key):
                    guard let target = workspace.sshTarget else { return false }
                    return WorkspaceStore.remoteGroupKey(for: target) == key
                }
            }
        }?.id
    }

    private func overlaps(_ lhs: DetachedNodeRef, _ rhs: DetachedNodeRef) -> Bool {
        if case .worktree = lhs, case .worktree = rhs {
            return false
        }
        return !workspaceIDs(ownedBy: lhs).intersection(workspaceIDs(ownedBy: rhs)).isEmpty
    }

    private func workspaceIDs(ownedBy ref: DetachedNodeRef) -> Set<UUID> {
        switch ref {
        case .workspace(let workspaceID):
            return [workspaceID]
        case .worktree(let workspaceID, _):
            return [workspaceID]
        case .remoteGroup(let key):
            return Set(store.workspacesInRemoteGroup(key).map(\.id))
        }
    }

    /// Called when a child window is closed by the user. Restores the node's
    /// visibility in the main sidebar by removing it from `detachedNodes` —
    /// unless we're cascading shutdown, in which case the ref stays detached.
    /// Idempotent: a no-op if `ctx` is no longer tracked.
    func closeChild(_ ctx: WindowContext) {
        // Guard against double-close: the willCloseNotification observer and
        // an explicit call can both fire for the same context. Once removed
        // from childContexts, subsequent notifications are no-ops.
        guard childContexts.contains(where: { $0 === ctx }) else { return }
        if !isShuttingDown, case .detached(let ref) = ctx.kind {
            store.detachedNodes.remove(ref)
        }
        ctx.closeImmediately()
        childContexts.removeAll { $0 === ctx }
    }

    /// Called by the main window's delegate before AppKit commits the close.
    /// A main window with no detached children keeps the normal close path;
    /// otherwise the user must explicitly accept the cascade.
    func shouldCloseMainWindow() -> Bool {
        guard !childContexts.isEmpty else { return true }
        return mainWindowCloseConfirmation(childContexts.count)
    }

    private static func presentMainWindowCloseConfirmation(childCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Close All Windows?")
        let format = String(localized: "%lld detached windows are still open. Closing the main window will close all windows and quit Treemux.")
        alert.informativeText = String(format: format, Int64(childCount))

        let closeAll = alert.addButton(withTitle: String(localized: "Close All Windows"))
        closeAll.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\r"

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Main window is closing: cascade-close every child without triggering
    /// per-node restore, then terminate the app.
    ///
    /// Sets `isShuttingDown` first so `closeChild(_:)` invocations (and any
    /// NSWindowDelegate close events that route back through) skip the
    /// detached-ref removal path. `isShuttingDown` is ALWAYS reset to `false`
    /// before requesting termination, so that if `applicationShouldTerminate`
    /// returns `.terminateCancel` (user clicks Cancel on the unsaved-changes
    /// prompt) the flag is not left stuck `true` — which would break all
    /// future detach/restore cycles.
    ///
    /// If termination is cancelled, the main window has already been torn down
    /// by this cascade, leaving the user with no visible window. Recovery
    /// happens in two places: (1) this method schedules a deferred check on
    /// the main queue that rebuilds the main window once the terminate
    /// sequence unwinds (the unsaved-changes alert runs on the main run loop,
    /// so by the time the deferred block runs we know the outcome); and
    /// (2) `AppDelegate.applicationDidBecomeActive` calls
    /// `TreemuxApp.ensureMainWindowAfterCascadeIfNeeded()` as a belt-and-
    /// suspenders recovery when the app next becomes active.
    func handleMainWindowWillClose() {
        isShuttingDown = true
        for ctx in childContexts {
            ctx.closeImmediately()
        }
        childContexts.removeAll()
        // Reset BEFORE requesting termination. If the user cancels the
        // unsaved-changes prompt the app stays alive with this flag already
        // restored, so subsequent detach/close cycles behave correctly.
        // The detached refs intentionally stay removed: children were torn
        // down and the main window is gone too, so there's nothing to
        // restore into the sidebar until the app relaunches.
        isShuttingDown = false
        mainWindowContext = nil
        // Defer the recovery check: if NSApp.terminate is cancelled (the
        // unsaved-changes prompt's runModal returns Cancel), the app stays
        // alive with no main window. By the time this async block runs the
        // modal loop has unwound, so mainWindowContext == nil reliably
        // means "termination was cancelled" — rebuild the window.
        DispatchQueue.main.async { [weak self] in
            self?.recoverMainWindowIfCancelled()
        }
        NSApp.terminate(nil)
    }

    /// Rebuilds the main window if the cascade tore it down but the app is
    /// still alive (termination was cancelled). No-op when the main window is
    /// already present or when there are still child windows (which would mean
    /// we're mid-multi-window, not in the cancel-recovery case).
    func recoverMainWindowIfCancelled() {
        guard mainWindowContext == nil, childContexts.isEmpty else { return }
        launchMain()
        restoreChildWindows()
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
        for ref in store.detachedNodes {
            moveMainSelectionAway(from: ref)
        }
    }
}
