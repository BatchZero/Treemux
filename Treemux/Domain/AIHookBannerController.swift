//
//  AIHookBannerController.swift
//  Treemux
//

import Combine
import Foundation
import SwiftUI

/// Decides when to show a hook-install banner for a given workspace, based on
/// detected AI tools, install status, and the user's persisted skip list.
/// One controller instance per WorkspaceModel; the view passes it in via @StateObject.
@MainActor
final class AIHookBannerController: ObservableObject {
    @Published var pendingInvitation: BannerInvitation?

    struct BannerInvitation: Identifiable {
        let id = UUID()
        let kind: AIToolKind
        let target: HookTarget
        let displayName: String
        let configPath: String
    }

    /// Per-app-launch dismissal set, NOT persisted. Persisted skips live in
    /// `AppSettings.aiHookSkippedKeys`.
    private var transientSkippedKeys: Set<String> = []

    /// Re-evaluate whether a banner should show for the given workspace.
    /// Pass the relevant inputs by value to avoid retaining references.
    func evaluate(
        workspace: WorkspaceModel,
        appSettings: AppSettings,
        installer: AIHookInstaller? = nil
    ) async {
        let installer = installer ?? AIHookInstaller()
        guard appSettings.aiActivityHintsEnabled else {
            pendingInvitation = nil
            return
        }

        // Look across the active session controller for any session with a detected AI tool.
        let detectedKinds = collectDetectedKinds(in: workspace)
        guard !detectedKinds.isEmpty else {
            // No AI agent currently running. Don't dismiss an existing invitation
            // immediately (the user may have just blinked); leave it.
            return
        }

        let target: HookTarget = {
            if let ssh = workspace.sshTarget { return .remote(ssh) }
            return .local
        }()

        for kind in detectedKinds {
            let key = skipKey(workspace: workspace, kind: kind, target: target)
            if appSettings.aiHookSkippedKeys.contains(key) { continue }
            if transientSkippedKeys.contains(key) { continue }
            // Currently presenting a different invitation: don't replace it.
            if let existing = pendingInvitation, existing.kind == kind { return }

            let fs: AIHookFileSystem = {
                switch target {
                case .local: return LocalHookFileSystem()
                case .remote(let t): return RemoteHookFileSystem(target: t)
                }
            }()
            let status: HookStatus
            do {
                status = try await installer.inspect(kind, fs: fs)
            } catch {
                continue
            }
            if status == .detectedNotInstalled,
               let provider = installer.provider(for: kind) {
                pendingInvitation = BannerInvitation(
                    kind: kind,
                    target: target,
                    displayName: provider.displayName,
                    configPath: provider.configFile
                )
                return
            }
        }
    }

    func dismissTransient() {
        if let key = currentKey {
            transientSkippedKeys.insert(key)
        }
        pendingInvitation = nil
    }

    func dismissAndPersist(workspace: WorkspaceModel, appSettings: inout AppSettings) {
        if let key = currentKey {
            if !appSettings.aiHookSkippedKeys.contains(key) {
                appSettings.aiHookSkippedKeys.append(key)
            }
        }
        pendingInvitation = nil
    }

    private var currentKey: String? {
        guard let invitation = pendingInvitation else { return nil }
        return "\(invitation.target.id):\(invitation.kind.rawValue)"
    }

    private func skipKey(workspace: WorkspaceModel, kind: AIToolKind, target: HookTarget) -> String {
        "\(target.id):\(kind.rawValue)"
    }

    private func collectDetectedKinds(in workspace: WorkspaceModel) -> Set<AIToolKind> {
        var kinds: Set<AIToolKind> = []
        // Iterate the active session controller's sessions. tabControllers itself
        // is private — sessionController exposes the active tab's controller. For
        // T19 purposes, monitoring the active controller is sufficient: if the
        // user launches an AI agent, they're in the active tab.
        if let controller = workspace.sessionController {
            for session in controller.sessions.values {
                if let detection = session.detectedAITool {
                    kinds.insert(detection.kind)
                }
            }
        }
        return kinds
    }
}
