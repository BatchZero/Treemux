//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI
import UniformTypeIdentifiers

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
    /// Owned here (not inside `FileTreeToolbar`) so Cmd+F, handled at the
    /// panel level via `.onKeyPress`, can drive focus down into the
    /// toolbar's search field via `FocusState<Bool>.Binding`.
    @FocusState private var searchFocused: Bool

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
            FileTreeToolbar(controller: controller, searchFocused: $searchFocused)
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
                            themeID: theme.activeTheme.id,
                            searchQuery: controller.searchQuery,
                            showingRecursiveResults: controller.showingRecursiveResults
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
                controller.cancelPendingUpload()
            }
        }
        .background(theme.paneBackground)
        // Cmd+F focuses the toolbar's search field, regardless of which
        // subview currently has keyboard focus within the panel.
        .onKeyPress(.init("f"), phases: .down) { press in
            if press.modifiers.contains(.command) {
                searchFocused = true
                return .handled
            }
            return .ignored
        }
        .safeAreaInset(edge: .bottom) {
            if controller.isTransferActive, let coordinator = controller.transferCoordinator {
                FileTransferProgressView(
                    coordinator: coordinator,
                    retry: { controller.retryTransfer() },
                    cancel: { controller.cancelTransfer() }
                )
            }
        }
        .alert(
            LocalizedStringKey("Confirm Upload"),
            isPresented: Binding(
                get: { controller.pendingUpload != nil },
                set: { presented in
                    if !presented { controller.cancelPendingUpload() }
                }
            )
        ) {
            Button(LocalizedStringKey("Upload")) {
                controller.confirmPendingUpload()
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                controller.cancelPendingUpload()
            }
        } message: {
            if let request = controller.pendingUpload {
                Text(String.localizedStringWithFormat(
                    String(localized: "Upload to: %@"),
                    request.destination
                ))
            }
        }
        .alert(
            LocalizedStringKey("An item already exists"),
            isPresented: Binding(
                get: { controller.transferCoordinator?.pendingConflict != nil },
                set: { presented in
                    if !presented, controller.transferCoordinator?.pendingConflict != nil {
                        controller.resolveTransferConflict(.cancelAll)
                    }
                }
            )
        ) {
            Button(LocalizedStringKey("Overwrite"), role: .destructive) {
                controller.resolveTransferConflict(.overwrite)
            }
            Button(LocalizedStringKey("Skip")) {
                controller.resolveTransferConflict(.skip)
            }
            Button(LocalizedStringKey("Cancel All"), role: .cancel) {
                controller.resolveTransferConflict(.cancelAll)
            }
        } message: {
            if let conflict = controller.transferCoordinator?.pendingConflict {
                Text(String.localizedStringWithFormat(
                    String(localized: "A destination item already exists at %@."),
                    conflict.destinationPath
                ))
            }
        }
        .sheet(
            isPresented: Binding(
                get: { controller.transferSummary != nil },
                set: { if !$0 { controller.dismissTransferSummary() } }
            )
        ) {
            if let summary = controller.transferSummary {
                FileTransferSummaryView(summary: summary) {
                    controller.dismissTransferSummary()
                }
            }
        }
    }
}

private struct FileTreeToolbar: View {
    /// `@Bindable` (rather than plain `let`) so the search field below can
    /// bind directly to `controller.searchQuery` via `$controller.searchQuery`.
    @Bindable var controller: FileBrowserTabController
    /// Focus binding owned by `FileTreePanelView`, so Cmd+F (handled at the
    /// panel level) can focus this field regardless of what else has focus.
    var searchFocused: FocusState<Bool>.Binding
    @Environment(ThemeManager.self) private var theme
    @State private var isRootUploadTargeted = false

    var body: some View {
        VStack(spacing: 0) {
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRootUploadTargeted ? theme.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isRootUploadTargeted ? theme.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            }
            .dropDestination(for: URL.self) { urls, _ in
                controller.stageUpload(urls: urls, destination: controller.rootPath)
            } isTargeted: { targeted in
                isRootUploadTargeted = targeted && controller.canAcceptUploadDrop
            }

            searchRow
            statusRow
        }
    }

    /// The search field row: magnifying-glass icon, text field bound to
    /// `controller.searchQuery`, and a clear (×) button when non-empty.
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
            TextField(LocalizedStringKey("Search"), text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused(searchFocused)
                .onSubmit { Task { await controller.performRecursiveSearch() } }
            if !controller.searchQuery.isEmpty {
                Button {
                    controller.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Escalation hint (before Enter) and search-status/error line (after).
    @ViewBuilder
    private var statusRow: some View {
        if !controller.searchQuery.isEmpty && !controller.showingRecursiveResults {
            Text(controller.isRemote
                 ? LocalizedStringKey("Press ⏎ to search the server")
                 : LocalizedStringKey("Press ⏎ to search all files"))
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        if controller.isSearching {
            Text(LocalizedStringKey("Searching…"))
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        } else if controller.showingRecursiveResults {
            Text(controller.searchResults.isEmpty
                 ? LocalizedStringKey("No matches")
                 : LocalizedStringKey("\(controller.searchResults.count) matches"))
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        if let err = controller.searchError {
            Text(err)
                .font(.system(size: 10))
                .foregroundStyle(theme.dangerColor)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .lineLimit(2)
        }
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
    /// The live search query and result-mode flag, passed in (rather than
    /// read from `controller` in the body) so they participate in `==`
    /// below. Without this, a keystroke that narrows the query without
    /// changing the *set* of visible rows (e.g. "a" -> "ab" while the same
    /// single node still matches) would produce an identical
    /// `FileTreeRowModel` array, and the Equatable short-circuit would skip
    /// re-rendering — leaving the highlighted span stale.
    let searchQuery: String
    let showingRecursiveResults: Bool
    @Environment(ThemeManager.self) private var theme
    @State private var isHovered = false
    @State private var isUploadTargeted = false

    // Equality intentionally ignores `controller` (same instance for the
    // whole tree). `theme` itself is environment-driven and excluded from
    // identity, but `themeID` stands in for it so theme switches still
    // invalidate the cached row.
    nonisolated static func == (lhs: FileTreeRow, rhs: FileTreeRow) -> Bool {
        lhs.row == rhs.row && lhs.density == rhs.density && lhs.themeID == rhs.themeID
            && lhs.searchQuery == rhs.searchQuery
            && lhs.showingRecursiveResults == rhs.showingRecursiveResults
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
            nameText(node.name)
                .font(DesignFonts.dataLayer(size: density.fontSize))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = row.symlinkError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dangerColor)
                    .help(error)
            }
            Spacer()
        }
        .frame(height: density.rowHeight)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isUploadTargeted ? theme.accentColor.opacity(0.10)
                      : row.isSelected ? theme.sidebarSelection
                      : isHovered ? theme.textPrimary.opacity(0.06)
                      : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isUploadTargeted ? theme.accentColor : Color.clear,
                    lineWidth: 1.5
                )
        }
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
                if canOpenAsFile(node) {
                    Task { await controller.pinFile(node.path) }
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if showingRecursiveResults {
                    // Flat recursive-search result row: a directory hit reveals
                    // its place in the (now un-filtered) tree; a file hit opens
                    // it and returns to normal browsing.
                    if node.isExpandableDirectory {
                        Task { await controller.revealInTree(node.path) }
                    } else {
                        Task {
                            await controller.activateNode(node)
                            controller.clearSearch()
                        }
                    }
                } else {
                    Task { await controller.activateNode(node) }
                }
            }
        )
        .contextMenu {
            if FileTransferPresentation.canDownload(node, isRemote: controller.isRemote) {
                Button(LocalizedStringKey("Download…")) {
                    controller.chooseDownloadDestination(for: node)
                }
                Divider()
            }
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let destination = FileTransferPresentation.dropDestination(
                    for: node,
                    rootPath: controller.rootPath
                  ) else { return false }
            return controller.stageUpload(urls: urls, destination: destination)
        } isTargeted: { targeted in
            isUploadTargeted = targeted
                && controller.canAcceptUploadDrop
                && FileTransferPresentation.dropDestination(
                    for: node,
                    rootPath: controller.rootPath
                ) != nil
        }
    }

    private func canOpenAsFile(_ node: FileNode) -> Bool {
        guard !node.isExpandableDirectory else { return false }
        guard node.isSymlink else { return true }
        return node.symlinkTargetResolution == .file
    }

    /// Renders `name`, tinting the substring matching the live search query
    /// (live-filter mode only — recursive result rows and empty queries fall
    /// back to a plain `Text`).
    private func nameText(_ name: String) -> Text {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !showingRecursiveResults,
              let range = name.range(of: query, options: [.caseInsensitive]) else {
            return Text(name)
        }
        var attr = AttributedString(name)
        if let lower = AttributedString.Index(range.lowerBound, within: attr),
           let upper = AttributedString.Index(range.upperBound, within: attr) {
            attr[lower..<upper].foregroundColor = theme.accentColor
            attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attr)
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

private struct FileTransferProgressView: View {
    let coordinator: FileTransferCoordinator
    let retry: () -> Void
    let cancel: () -> Void
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(
                    coordinator.state == .paused ? "Transfer paused" : "Transferring files…"
                ))
                    .font(DesignFonts.dataLayer(size: 11))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if coordinator.state == .paused {
                    Button(LocalizedStringKey("Retry"), action: retry)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentColor)
                }
                Button(LocalizedStringKey("Cancel"), action: cancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.dangerColor)
            }
            if coordinator.pendingRetryableError != nil {
                Text(LocalizedStringKey("The connection was interrupted. Retry when it is available."))
                    .font(DesignFonts.dataLayer(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            ProgressView(
                value: Double(coordinator.summary.completedBytes),
                total: Double(max(1, coordinator.summary.totalBytes))
            )
            .tint(theme.accentColor)
            Text(String.localizedStringWithFormat(
                String(localized: "%lld completed, %lld failed"),
                Int64(coordinator.summary.completedItems),
                Int64(coordinator.summary.failedItems)
            ))
                .font(DesignFonts.dataLayer(size: 10))
                .foregroundStyle(theme.textMuted)
        }
        .padding(10)
        .background(theme.paneBackground)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FileTransferSummaryView: View {
    let summary: FileTransferSummary
    let dismiss: () -> Void
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("Transfer Summary"))
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Text(String.localizedStringWithFormat(
                String(localized: "%lld completed, %lld skipped, %lld failed, %lld cancelled"),
                Int64(summary.completedItems),
                Int64(summary.skippedItems),
                Int64(summary.failedItems),
                Int64(summary.cancelledItems)
            ))
                .foregroundStyle(theme.textSecondary)
            if summary.cancelled {
                Text(LocalizedStringKey("The remaining transfer was cancelled."))
                    .foregroundStyle(theme.textSecondary)
            }
            if !summary.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.sourcePath)
                                    .font(DesignFonts.dataLayer(size: 11))
                                    .foregroundStyle(theme.textPrimary)
                                Text(failure.message)
                                    .font(DesignFonts.dataLayer(size: 10))
                                    .foregroundStyle(theme.dangerColor)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button(LocalizedStringKey("Done"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .background(theme.paneBackground)
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
