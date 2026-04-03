//
//  WorkspaceSessionController.swift
//  Treemux
//

import Foundation

/// Manages multiple ShellSessions for a workspace's split pane layout.
/// Each pane in the layout tree has a corresponding ShellSession that is
/// lazily created and started when the pane first becomes visible.
@MainActor
final class WorkspaceSessionController: ObservableObject {
    @Published private(set) var sessions: [UUID: ShellSession] = [:]
    @Published var layout: SessionLayoutNode
    @Published var focusedPaneID: UUID? {
        didSet {
            updateSessionFocusStates()
        }
    }
    @Published var zoomedPaneID: UUID?

    /// Called after pane operations to notify the workspace model of state changes.
    var onPaneStateChanged: (() -> Void)?

    private let workingDirectory: String
    private let sshTarget: SSHTarget?

    // MARK: - Initialization

    init(workingDirectory: String, sshTarget: SSHTarget? = nil) {
        self.workingDirectory = workingDirectory
        self.sshTarget = sshTarget
        let initialPaneID = UUID()
        self.layout = .pane(PaneLeaf(paneID: initialPaneID))
        self.focusedPaneID = initialPaneID
    }

    /// Creates a controller restoring a previously saved layout and pane snapshots.
    /// If savedLayout is nil or paneSnapshots is empty, falls back to single-pane default.
    convenience init(
        workingDirectory: String,
        sshTarget: SSHTarget? = nil,
        savedLayout: SessionLayoutNode?,
        paneSnapshots: [PaneSnapshot],
        focusedPaneID: UUID?,
        zoomedPaneID: UUID?
    ) {
        self.init(workingDirectory: workingDirectory, sshTarget: sshTarget)

        guard let savedLayout = savedLayout, !paneSnapshots.isEmpty else { return }

        // Restore the saved layout tree
        self.layout = savedLayout

        // Create sessions from saved snapshots
        let snapshotMap = Dictionary(paneSnapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for paneID in savedLayout.paneIDs {
            let snapshot = snapshotMap[paneID]
            var backend = snapshot?.backend ?? .defaultBackend(for: sshTarget)

            // If the pane had a detected tmux session, reattach instead of starting a fresh shell.
            if let tmuxSession = snapshot?.detectedTmuxSession {
                switch backend {
                case .localShell:
                    backend = .tmuxAttach(TmuxAttachConfig(
                        sessionName: tmuxSession,
                        windowIndex: nil,
                        isRemote: false,
                        sshTarget: nil
                    ))
                case .ssh(let sshConfig):
                    backend = .tmuxAttach(TmuxAttachConfig(
                        sessionName: tmuxSession,
                        windowIndex: nil,
                        isRemote: true,
                        sshTarget: sshConfig.target
                    ))
                default:
                    break
                }
            }

            let session = ShellSession(
                id: paneID,
                backendConfiguration: backend,
                preferredWorkingDirectory: snapshot?.workingDirectory ?? workingDirectory
            )
            session.onFocus = { [weak self] in
                self?.focusedPaneID = paneID
            }
            session.onWorkspaceAction = { [weak self] action in
                self?.handleWorkspaceAction(action, from: paneID)
            }
            session.startIfNeeded()
            sessions[paneID] = session
        }

        // Restore focus and zoom state
        self.focusedPaneID = focusedPaneID ?? savedLayout.paneIDs.first
        self.zoomedPaneID = zoomedPaneID
    }

    // MARK: - Session management

    /// Returns the session for the given pane, creating and starting it if needed.
    func ensureSession(for paneID: UUID) -> ShellSession {
        if let existing = sessions[paneID] { return existing }
        let session = ShellSession(
            id: paneID,
            backendConfiguration: .defaultBackend(for: sshTarget),
            preferredWorkingDirectory: workingDirectory
        )
        session.onFocus = { [weak self] in
            self?.focusedPaneID = paneID
        }
        session.onWorkspaceAction = { [weak self] action in
            self?.handleWorkspaceAction(action, from: paneID)
        }
        session.startIfNeeded()
        sessions[paneID] = session
        return session
    }

    /// Returns the session for the given pane without creating it.
    func session(for paneID: UUID) -> ShellSession? {
        sessions[paneID]
    }

    // MARK: - Pane splitting

    /// Splits the given pane along the specified axis, inserting a new pane.
    func splitPane(_ paneID: UUID, axis: SplitAxis, placement: PaneSplitPlacement = .after) {
        let newPaneID = UUID()
        if layout.split(paneID: paneID, axis: axis, newPaneID: newPaneID, placement: placement) {
            focusedPaneID = newPaneID
        }
        onPaneStateChanged?()
    }

    // MARK: - Pane closing

    /// Closes the given pane, terminating its session and collapsing the layout.
    /// Returns `true` if this was the last pane (caller should close the tab
    /// via `Workspace.closeTab`, which handles session termination).
    @discardableResult
    func closePane(_ paneID: UUID) -> Bool {
        let allIDs = layout.paneIDs
        if allIDs.count <= 1 {
            // Last pane — signal the caller to close the tab instead.
            // Don't terminate here; closeTab() handles full cleanup.
            return true
        }

        sessions[paneID]?.terminate()
        sessions.removeValue(forKey: paneID)
        layout.removePane(paneID)

        if focusedPaneID == paneID {
            focusedPaneID = layout.paneIDs.first
        }
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        }
        onPaneStateChanged?()
        return false
    }

    // MARK: - Focus navigation

    /// Moves focus to the next pane in traversal order.
    func focusNext() {
        guard let current = focusedPaneID else { return }
        focusedPaneID = layout.paneID(in: .next, from: current)
        onPaneStateChanged?()
    }

    /// Moves focus to the previous pane in traversal order.
    func focusPrevious() {
        guard let current = focusedPaneID else { return }
        focusedPaneID = layout.paneID(in: .previous, from: current)
        onPaneStateChanged?()
    }

    /// Moves focus in a directional manner (left/right/up/down).
    func focusDirection(_ direction: PaneFocusDirection) {
        guard let current = focusedPaneID else { return }
        if let target = layout.paneID(in: direction, from: current) {
            focusedPaneID = target
        }
        onPaneStateChanged?()
    }

    /// Focuses the given pane directly.
    func focus(_ paneID: UUID) {
        focusedPaneID = paneID
        sessions[paneID]?.focus()
        onPaneStateChanged?()
    }

    // MARK: - Zoom

    /// Toggles zoom on the currently focused pane.
    func toggleZoom() {
        if zoomedPaneID != nil {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = focusedPaneID
        }
        onPaneStateChanged?()
    }

    // MARK: - Layout manipulation

    /// Updates the fraction of a split divider.
    func updateSplitFraction(splitID: UUID, fraction: Double) {
        _ = layout.updateFraction(splitID: splitID, fraction: fraction)
    }

    /// Equalizes all split fractions.
    func equalizeSplits() {
        layout.equalizeSplits()
        onPaneStateChanged?()
    }

    /// Resizes the split containing the focused pane in the given direction.
    func resizeFocusedSplit(direction: PaneFocusDirection, amount: UInt16) {
        guard let current = focusedPaneID else { return }
        _ = layout.resizeSplit(containing: current, toward: direction, amount: amount)
        onPaneStateChanged?()
    }

    // MARK: - Snapshots

    /// Returns pane snapshots for all panes in layout traversal order.
    func sessionSnapshots() -> [PaneSnapshot] {
        layout.paneIDs.compactMap { paneID in
            sessions[paneID]?.snapshot()
        }
    }

    // MARK: - Termination

    /// Terminates all sessions.
    func terminateAll() {
        for session in sessions.values {
            session.terminate()
        }
        sessions.removeAll()
    }

    // MARK: - Private

    private func updateSessionFocusStates() {
        for (paneID, session) in sessions {
            session.setFocused(paneID == focusedPaneID)
        }
    }

    private func handleWorkspaceAction(_ action: TerminalWorkspaceAction, from paneID: UUID) {
        switch action {
        case .createSplit(let axis, let placement):
            splitPane(paneID, axis: axis, placement: placement)
        case .focusPane(let direction):
            focusDirection(direction)
        case .focusNextPane:
            focusNext()
        case .focusPreviousPane:
            focusPrevious()
        case .resizeFocusedSplit(let direction, let amount):
            resizeFocusedSplit(direction: direction, amount: amount)
        case .equalizeSplits:
            equalizeSplits()
        case .togglePaneZoom:
            toggleZoom()
        case .closePane:
            closePane(paneID)
        }
    }
}
