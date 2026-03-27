//
//  SidebarIconCustomizationSheet.swift
//  Treemux
//

import SwiftUI

// MARK: - SidebarIconEditorCard

/// A reusable card that lets the user pick a symbol, palette, and fill style for a sidebar icon.
struct SidebarIconEditorCard: View {
    let title: String
    let subtitle: String?
    @Binding var icon: SidebarItemIcon
    var randomizer: () -> SidebarItemIcon = SidebarItemIcon.random

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Icon preview + title + Random button
            HStack(alignment: .center, spacing: 12) {
                SidebarItemIconView(icon: icon, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Random") { icon = randomizer() }
            }

            // Row 2: Symbol picker dropdown
            Picker("Symbol", selection: $icon.symbolName) {
                ForEach(SidebarIconCatalog.symbols, id: \.systemName) { symbol in
                    Label(symbol.title, systemImage: symbol.systemName).tag(symbol.systemName)
                }
            }

            // Row 3: Fill style segmented control
            Picker("Style", selection: $icon.fillStyle) {
                ForEach(SidebarIconFillStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            // Row 4: Palette grid
            VStack(alignment: .leading, spacing: 8) {
                Text("Palette")
                    .font(.system(size: 11, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], spacing: 8) {
                    ForEach(SidebarIconPalette.allCases) { palette in
                        Button {
                            icon.palette = palette
                        } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [palette.descriptor.gradientStart, palette.descriptor.gradientEnd],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            icon.palette == palette ? Color.white.opacity(0.9) : palette.descriptor.border,
                                            lineWidth: icon.palette == palette ? 2 : 1
                                        )
                                )
                                .frame(width: 34, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(palette.title)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - SidebarIconCustomizationSheet

/// A sheet that allows customizing the sidebar icon for a workspace, worktree, or app default.
struct SidebarIconCustomizationSheet: View {
    let request: SidebarIconCustomizationRequest
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var icon = SidebarItemIcon.repositoryDefault

    private var title: String {
        store.sidebarIconRequestTitle(request)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Customize Sidebar Icon")
                .font(.system(size: 20, weight: .semibold))

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            SidebarIconEditorCard(
                title: "Icon",
                subtitle: "Choose a symbol, palette, and fill treatment",
                icon: $icon,
                randomizer: randomizer
            )

            HStack {
                Spacer()
                Button("Reset") {
                    store.resetSidebarIcon(for: request.target)
                    dismiss()
                }
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    store.updateSidebarIcon(icon, for: request.target)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            icon = store.sidebarIconSelection(for: request.target)
        }
    }

    private var randomizer: () -> SidebarItemIcon {
        switch request.target {
        case .workspace(let workspaceID):
            if store.workspaces.first(where: { $0.id == workspaceID })?.kind == .repository {
                return SidebarItemIcon.randomRepository
            }
            return SidebarItemIcon.random
        case .appDefaultRepository, .worktree, .appDefaultWorktree, .appDefaultRemote:
            return SidebarItemIcon.randomRepository
        case .appDefaultLocalTerminal:
            return SidebarItemIcon.random
        }
    }
}
