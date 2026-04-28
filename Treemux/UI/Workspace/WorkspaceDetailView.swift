//
//  WorkspaceDetailView.swift
//  Treemux

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the tab bar (when 2+ tabs), split pane layout, or empty state.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            WorkspaceTabContainerView(workspace: workspace)
                .id(workspace.id)
        }
    }
}

/// Container that manages tab bar visibility and routes to the active tab's content.
private struct WorkspaceTabContainerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel
    @StateObject private var bannerController = AIHookBannerController()
    @State private var pendingPreview: HookPreviewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let invitation = bannerController.pendingInvitation {
                AIHookBanner(
                    displayName: invitation.displayName,
                    configPath: invitation.configPath,
                    onPreview: { Task { await openPreview(invitation) } },
                    onSkip: { bannerController.dismissTransient() },
                    onSkipHost: { skipHost() }
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            // Tab bar: shown when 2+ tabs
            if workspace.tabs.count > 1 {
                WorkspaceTabBarView(workspace: workspace)
            }

            // Content area: dispatch by tab kind
            if let tabID = workspace.activeTabID,
               let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                Group {
                    switch tab.kind {
                    case .terminal:
                        if let controller = workspace.sessionController {
                            WorkspaceSessionDetailView(
                                controller: controller,
                                onCloseTab: { workspace.closeTab(tabID) }
                            )
                        }
                    case .fileBrowser:
                        if let controller = workspace.fileBrowserController(forTabID: tabID) {
                            FileBrowserTabContentView(controller: controller)
                        }
                    }
                }
                .id(tabID)
            } else {
                EmptyTabStateView {
                    workspace.createTab()
                }
            }
        }
        .sheet(item: $pendingPreview) { model in
            HookPreviewSheet(model: model)
        }
        .task(id: workspace.id) {
            await bannerController.evaluate(workspace: workspace, appSettings: store.settings)
        }
        .onReceive(workspace.objectWillChange) { _ in
            // Re-evaluate when workspace state changes (covers detected tool flip-on)
            Task { await bannerController.evaluate(workspace: workspace, appSettings: store.settings) }
        }
    }

    private func openPreview(_ invitation: AIHookBannerController.BannerInvitation) async {
        let installer = AIHookInstaller()
        guard let bundleURL = installer.helperBundleURL else { return }
        let fs: AIHookFileSystem = {
            switch invitation.target {
            case .local: return LocalHookFileSystem()
            case .remote(let t): return RemoteHookFileSystem(target: t)
            }
        }()
        guard let provider = installer.provider(for: invitation.kind) else { return }
        let changes: [HookInstallChange]
        do {
            changes = try await provider.dryRunInstall(fs: fs, helperBundleURL: bundleURL)
        } catch {
            return
        }
        pendingPreview = HookPreviewModel(
            kind: invitation.kind,
            target: invitation.target,
            displayName: invitation.displayName,
            changes: changes,
            onApply: { [bannerController] in
                do {
                    _ = try await installer.install(invitation.kind, fs: fs)
                    bannerController.dismissTransient()
                } catch {
                    // best-effort
                }
            }
        )
    }

    private func skipHost() {
        var settings = store.settings
        bannerController.dismissAndPersist(workspace: workspace, appSettings: &settings)
        store.updateSettings(settings)
    }
}

/// Observes the session controller directly so that layout mutations
/// (e.g. splitPane) propagate to SplitNodeView.
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController
    var onCloseTab: () -> Void

    var body: some View {
        SplitNodeView(
            sessionController: controller,
            node: controller.layout,
            onClosePane: { paneID in
                let wasLast = controller.closePane(paneID)
                if wasLast {
                    onCloseTab()
                }
            }
        )
    }
}
