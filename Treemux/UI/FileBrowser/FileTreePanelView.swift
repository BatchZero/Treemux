//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI

struct FileTreePanelView: View {
    let controller: FileBrowserTabController
    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeManager.self) private var theme

    @State private var scrollPosition: ScrollPosition
    /// The offset we're restoring to, captured at mount.
    @State private var restoreTarget: CGFloat
    /// Live mirror of the scroll offset. Persisted to the controller only on
    /// disappear — never continuously — so a transient reflow value during the
    /// restore window can never corrupt the saved offset.
    @State private var liveOffset: CGFloat
    /// True while still restoring. Ends only once the offset converges on the
    /// target *after* the content has settled.
    @State private var restoring: Bool
    /// Set when the first full reload settles. The seed briefly lands on the
    /// target before the remote tree reflows, so convergence must not be
    /// accepted until content is settled — otherwise we'd finish early and the
    /// later reflow would be mistaken for the user's position.
    @State private var contentSettled = false

    init(controller: FileBrowserTabController) {
        self.controller = controller
        let target = controller.treeScrollOffset
        _restoreTarget = State(initialValue: target)
        _liveOffset = State(initialValue: target)
        // Nothing to restore when already at the top.
        _restoring = State(initialValue: target > 0)
        // Seed the position with the cached offset so the restore happens
        // during the first layout pass — not afterwards in onAppear, where a
        // transient 0 would race it and win.
        var initial = ScrollPosition()
        initial.scrollTo(y: target)
        _scrollPosition = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            FileTreeErrorBanner(controller: controller)
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                // A plain VStack (not LazyVStack) gives the ScrollView a
                // deterministic content height, so offset-based scroll
                // restoration is reliable. A lazy stack can't scroll to an
                // offset beyond its currently-realized rows, which made restore
                // clamp short for positions further down. The tree's nested
                // rows are already rendered eagerly and the root list is capped
                // by truncation (Load more), so eager layout is bounded.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.visibleRows()) { row in
                        FileTreeRow(
                            row: row,
                            density: store.settings.fileTree.density,
                            controller: controller,
                            themeID: theme.activeTheme.id
                        )
                        .equatable()
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollPosition($scrollPosition)
            // Mirror the live offset locally. We persist it to the controller
            // only on disappear (below), so a transient offset during the
            // restore window can never clobber the saved value.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                liveOffset = newValue
                // Finish restoring only when the offset reaches the target
                // AFTER content has settled — never during the initial reflow,
                // when the seed momentarily hits the target before the remote
                // tree grows.
                if restoring, contentSettled, abs(newValue - restoreTarget) <= 1 {
                    restoring = false
                }
            }
            // Each full reload settles the content; re-assert the target until
            // the restore converges. A bounded fallback ends the restore in the
            // rare case the target is no longer reachable (content shrank).
            .onChange(of: controller.treeContentGeneration) { _, _ in
                guard restoring else { return }
                contentSettled = true
                scrollPosition.scrollTo(y: restoreTarget)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    restoring = false
                }
            }
            // Seed the restore during the first layout pass for the instant
            // (local, cached) case where content is already present.
            .onAppear {
                if restoring { scrollPosition.scrollTo(y: restoreTarget) }
            }
            // Persist where the user actually ended up, captured on leave.
            .onDisappear {
                controller.treeScrollOffset = liveOffset
            }
        }
        .background(theme.paneBackground)
    }
}

private struct FileTreeToolbar: View {
    let controller: FileBrowserTabController

    var body: some View {
        HStack(spacing: 8) {
            Text(URL(fileURLWithPath: controller.rootPath).lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                let dir = controller.selectedFilePath.map { path -> String in
                    // Selected path is a file (sub-tab); create in its directory.
                    (path as NSString).deletingLastPathComponent
                } ?? controller.rootPath
                Task { await controller.beginNewEntry(intent: .folder, in: dir) }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("New Folder"))

            Button {
                let dir = controller.selectedFilePath.map { ($0 as NSString).deletingLastPathComponent }
                    ?? controller.rootPath
                Task { await controller.beginNewEntry(intent: .file, in: dir) }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("New File"))

            Button {
                Task { await controller.refreshTree() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Refresh"))

            Button {
                controller.setShowsHiddenFiles(!controller.showsHiddenFiles)
            } label: {
                Image(systemName: controller.showsHiddenFiles ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Toggle Hidden Files"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FileTreeErrorBanner: View {
    let controller: FileBrowserTabController
    @State private var password: String = ""

    var body: some View {
        Group {
            switch controller.loadError {
            case .generic(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Spacer()
                    Button(LocalizedStringKey("Retry")) {
                        Task { await controller.loadRoot() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.thickMaterial)

            case .needsPassword(let host):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .foregroundStyle(.orange)
                        Text(String.localizedStringWithFormat(
                            String(localized: "Cannot connect to %@"), host))
                            .font(.system(size: 11, weight: .medium))
                    }
                    HStack(spacing: 6) {
                        SecureField(LocalizedStringKey("Enter Password"), text: $password)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button(LocalizedStringKey("Connect")) {
                            let pw = password
                            password = ""
                            Task { await controller.retryWithPassword(pw) }
                        }
                        .controlSize(.small)
                        .disabled(password.isEmpty)
                    }
                }
                .padding(8)
                .background(.thickMaterial)

            case .none:
                EmptyView()
            }
        }
        // Clear the SecureField whenever loadError transitions, so a rejected
        // password doesn't linger in the field across retry attempts.
        .onChange(of: controller.loadError) { _, _ in
            password = ""
        }
    }
}

/// One visible tree row, rendered purely from a FileTreeRowModel value.
/// `controller` is a plain (unobserved) reference used only for actions —
/// re-rendering is driven by the parent recomputing `visibleRows()`.
private struct FileTreeRow: View, Equatable {
    let row: FileTreeRowModel
    let density: TreeDensity
    let controller: FileBrowserTabController
    /// The active theme's identity, passed in from the parent (rather than
    /// read only from `@Environment`) so it participates in `==`.
    /// Without this, an EquatableView short-circuit on theme switch would
    /// skip recomputing rows whose `row`/`density` didn't change, leaving
    /// them painted with the old theme's colors (a half-recolored tree).
    let themeID: String
    @Environment(ThemeManager.self) private var theme
    @State private var isHovered = false

    // Equality intentionally ignores `controller` (same instance for the
    // whole tree). `theme` itself is environment-driven and excluded from
    // identity, but `themeID` stands in for it so theme switches still
    // invalidate the cached row.
    nonisolated static func == (lhs: FileTreeRow, rhs: FileTreeRow) -> Bool {
        lhs.row == rhs.row && lhs.density == rhs.density && lhs.themeID == rhs.themeID
    }

    var body: some View {
        switch row.kind {
        case .node(let node):
            nodeBody(node)
        case .loadMore(let parentPath):
            LoadMoreRow(path: parentPath, depth: row.depth, controller: controller)
        case .editor(let parentPath, let intent):
            NewEntryEditorRow(controller: controller, density: density, depth: row.depth,
                              parentPath: parentPath, intent: intent)
        }
    }

    private func nodeBody(_ node: FileNode) -> some View {
        HStack(spacing: 4) {
            // One hairline per depth level (14pt per level: 1pt line + 13pt trailing).
            ForEach(0..<row.depth, id: \.self) { _ in
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(width: 1, height: density.rowHeight)
                    .padding(.trailing, 13)
            }
            if node.isExpandableDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            // 4×4 git-status dot (clear placeholder keeps name alignment stable).
            if let status = row.status {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
            iconView(node)
                .frame(width: density.fontSize + 3, height: density.fontSize + 3)
            Text(node.name)
                .font(DesignFonts.dataLayer(size: density.fontSize))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(height: density.rowHeight)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(row.isSelected ? theme.sidebarSelection
                      : isHovered ? theme.textPrimary.opacity(0.06)
                      : Color.clear)
        )
        .overlay(alignment: .leading) {
            if row.isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                if !node.isExpandableDirectory {
                    Task { await controller.pinFile(node.path) }
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if node.isExpandableDirectory {
                    Task { await controller.toggleExpand(node.path) }
                } else {
                    Task { await controller.openInTree(node.path) }
                }
            }
        )
        .contextMenu {
            Button(LocalizedStringKey("New Folder")) {
                Task { await controller.beginNewEntry(intent: .folder,
                                                      in: controller.targetDirectory(for: node)) }
            }
            Button(LocalizedStringKey("New File")) {
                Task { await controller.beginNewEntry(intent: .file,
                                                      in: controller.targetDirectory(for: node)) }
            }
            Divider()
            Button(LocalizedStringKey("Copy Absolute Path")) {
                controller.copyPath(node.path, mode: .absolute)
            }
            Button(LocalizedStringKey("Copy Relative Path")) {
                controller.copyPath(node.path, mode: .relative)
            }
            .disabled(node.path == controller.rootPath)
        }
    }

    @ViewBuilder
    private func iconView(_ node: FileNode) -> some View {
        let icon = FileIconCatalog.icon(for: node, isExpanded: row.isExpanded)
        Image(icon.asset)
            .resizable()
            .renderingMode(icon.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(icon.tintRole.map { theme.fileIconTint($0) } ?? theme.textSecondary)
    }

    private func color(for status: FileStatus) -> Color {
        switch status {
        case .untracked: return .gray
        case .modified, .renamed(_): return .orange
        case .added: return .green
        case .deleted: return .red
        }
    }
}

private struct LoadMoreRow: View {
    let path: String
    let depth: Int
    let controller: FileBrowserTabController
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Button {
            Task { await controller.loadMore(path) }
        } label: {
            HStack(spacing: 4) {
                // Mirror NodeRow's depth guide lines so "Load more" lines up with siblings.
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(theme.dividerColor)
                        .frame(width: 1, height: 20)
                        .padding(.trailing, 13)
                }
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("Load more"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// Inline text field for creating a new file/folder under `parentPath`.
/// Rendered in place of a `FileTreeRowModel.Kind.editor` row, aligned with
/// sibling rows via the same depth-hairline / disclosure / git-dot gutters
/// as `FileTreeRow.nodeBody`.
private struct NewEntryEditorRow: View {
    let controller: FileBrowserTabController
    let density: TreeDensity
    let depth: Int
    let parentPath: String
    let intent: NewEntryIntent
    @Environment(ThemeManager.self) private var theme
    @State private var name: String = ""
    @FocusState private var focused: Bool

    private var iconAsset: String { intent == .folder ? "folder" : "file-document-outline" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(theme.dividerColor)
                        .frame(width: 1, height: density.rowHeight)
                        .padding(.trailing, 13)
                }
                Spacer().frame(width: 12)                    // disclosure gutter
                Color.clear.frame(width: 4, height: 4)       // git-dot gutter
                Image(iconAsset)
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: density.fontSize + 3, height: density.fontSize + 3)
                    .foregroundStyle(theme.textSecondary)
                TextField(intent == .folder
                          ? LocalizedStringKey("New Folder")
                          : LocalizedStringKey("New File"), text: $name)
                    .textFieldStyle(.plain)
                    .font(DesignFonts.dataLayer(size: density.fontSize))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .onSubmit { Task { await controller.commitNewEntry(name: name) } }
                    .onExitCommand { controller.cancelNewEntry() }   // Esc
            }
            .frame(height: density.rowHeight)
            .padding(.horizontal, 8)
            if let err = controller.newEntryDraft?.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dangerColor)
                    .padding(.leading, CGFloat(depth) * 14 + 40)
            }
        }
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }
}
