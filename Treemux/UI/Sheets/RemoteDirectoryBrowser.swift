//
//  RemoteDirectoryBrowser.swift
//  Treemux
//

import SwiftUI

/// Sheet that displays a tree-style remote directory browser via SFTP.
struct RemoteDirectoryBrowser: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteDirectoryBrowserViewModel

    /// Callback to pass selected path back to the caller.
    let onSelect: (String) -> Void

    init(sshTarget: SSHTarget, onSelect: @escaping (String) -> Void) {
        _viewModel = StateObject(
            wrappedValue: RemoteDirectoryBrowserViewModel(sshTarget: sshTarget)
        )
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            pathBar
            Divider()
            directoryContent
            Divider()
            bottomBar
        }
        .frame(width: 480, height: 420)
        .task {
            await viewModel.connect()
        }
        .onDisappear {
            Task { await viewModel.disconnect() }
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Text(String(localized: "Select Remote Directory"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            TextField(String(localized: "/path/to/directory"), text: $viewModel.pathBarText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.navigateTo(path: viewModel.pathBarText) }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if viewModel.isConnecting {
            connectingView
        } else if let error = viewModel.connectionError {
            errorView(error)
        } else if viewModel.rootNodes.isEmpty {
            emptyView
        } else {
            directoryTree
        }
    }

    private var connectingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "Connecting…"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(error)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(String(localized: "Retry")) {
                Task { await viewModel.connect() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        Text(String(localized: "No directories found"))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var directoryTree: some View {
        List(viewModel.rootNodes) { node in
            DirectoryNodeRow(
                node: node,
                selectedPath: $viewModel.selectedPath,
                expandAction: { n in
                    Task { await viewModel.expandNode(n) }
                }
            )
        }
        .listStyle(.sidebar)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let selected = viewModel.selectedPath {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(selected)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(String(localized: "No directory selected"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Open")) {
                if let path = viewModel.selectedPath {
                    onSelect(path)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.selectedPath == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Directory Node Row

/// Recursive row for a single directory node in the tree.
struct DirectoryNodeRow: View {
    @ObservedObject var node: DirectoryNode
    @Binding var selectedPath: String?
    let expandAction: (DirectoryNode) -> Void

    private var isSelected: Bool {
        selectedPath == node.path
    }

    var body: some View {
        if let children = node.children {
            // Node has been loaded (may be empty or have children)
            DisclosureGroup(
                isExpanded: Binding(
                    get: { true },
                    set: { _ in }
                )
            ) {
                childContent(children)
            } label: {
                nodeLabel
            }
        } else {
            // Node not yet loaded — show as expandable
            DisclosureGroup(
                isExpanded: Binding(
                    get: { false },
                    set: { isExpanding in
                        if isExpanding { expandAction(node) }
                    }
                )
            ) {
                if node.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(String(localized: "Loading…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            } label: {
                nodeLabel
            }
        }
    }

    @ViewBuilder
    private func childContent(_ children: [DirectoryNode]) -> some View {
        if children.isEmpty {
            Text(String(localized: "Empty directory"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ForEach(children) { child in
                DirectoryNodeRow(
                    node: child,
                    selectedPath: $selectedPath,
                    expandAction: expandAction
                )
            }
        }
    }

    private var nodeLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 13))
            Text(node.name)
                .lineLimit(1)
                .font(.system(size: 13))

            if let error = node.error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.7))
                    .font(.system(size: 11))
                    .help(error)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .onTapGesture {
            selectedPath = node.path
        }
    }
}
