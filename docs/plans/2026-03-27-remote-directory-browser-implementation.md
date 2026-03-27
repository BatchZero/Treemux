# Remote Directory Browser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> **For Claude:** REQUIRED SUB-SKILL: Use /ui-ux-pro-max for Task 5 (RemoteDirectoryBrowser UI).

**Goal:** Replace manual path input for remote repositories with an SFTP-based visual directory browser, matching the local NSOpenPanel experience.

**Architecture:** New `SFTPService` actor wraps Citadel library for async SFTP operations. `RemoteDirectoryBrowser` Sheet presents a tree-style directory view with lazy-loading. `OpenProjectSheet` remote mode gains a "Choose..." button mirroring local mode.

**Tech Stack:** Swift, SwiftUI, Citadel (SFTP/SSH via SwiftNIO), macOS

---

### Task 1: Add Citadel SPM Dependency

**Files:**
- Modify: `Treemux.xcodeproj/project.pbxproj` (via Xcode CLI or manual edit)

**Step 1: Add Citadel package reference**

Use `xcodebuild` or manually add the SPM dependency to the Xcode project. The package URL is `https://github.com/orlandos-nl/Citadel` with an appropriate version (use the latest stable release, e.g. from 0.7.0 up to next major).

Run:
```bash
# First check latest Citadel version
curl -s https://api.github.com/repos/orlandos-nl/Citadel/tags | head -20

# Add via swift package command or manual pbxproj edit
# Since this is an Xcode project (not Package.swift), add via:
# Xcode > File > Add Package Dependencies > https://github.com/orlandos-nl/Citadel
```

Alternatively, add the package dependency entries directly to `project.pbxproj`:
- `XCRemoteSwiftPackageReference` for Citadel
- `XCSwiftPackageProductDependency` for `Citadel` product in the main target

**Step 2: Verify the project builds**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

**Step 3: Commit**

```bash
git add Treemux.xcodeproj/project.pbxproj
git commit -m "chore: add Citadel SPM dependency for SFTP support"
```

---

### Task 2: Create SFTPDirectoryEntry Model

**Files:**
- Create: `Treemux/Services/SFTP/SFTPDirectoryEntry.swift`

**Step 1: Create the model file**

```swift
//
//  SFTPDirectoryEntry.swift
//  Treemux
//

import Foundation

/// Represents a single directory entry from a remote SFTP listing.
struct SFTPDirectoryEntry: Identifiable, Comparable, Hashable {
    let id = UUID()
    let name: String
    let path: String

    static func < (lhs: SFTPDirectoryEntry, rhs: SFTPDirectoryEntry) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // Exclude id from hashing/equality (it's auto-generated)
    static func == (lhs: SFTPDirectoryEntry, rhs: SFTPDirectoryEntry) -> Bool {
        lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}
```

**Step 2: Verify build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

**Step 3: Commit**

```bash
git add Treemux/Services/SFTP/SFTPDirectoryEntry.swift
git commit -m "feat: add SFTPDirectoryEntry model"
```

---

### Task 3: Create SFTPService Actor

**Files:**
- Create: `Treemux/Services/SFTP/SFTPService.swift`
- Reference: `Treemux/Domain/SSHTarget.swift` (for SSHTarget struct)

**Step 1: Create the SFTPService actor**

```swift
//
//  SFTPService.swift
//  Treemux
//

import Foundation
import Citadel

/// Actor that manages SFTP connections and directory operations.
actor SFTPService {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    /// Connect to a remote server using the given SSH target.
    func connect(target: SSHTarget) async throws {
        // Build authentication method
        let authMethod: SSHAuthenticationMethod
        if let identityFile = target.identityFile {
            let keyPath = (identityFile as NSString).expandingTildeInPath
            let keyData = try String(contentsOfFile: keyPath, encoding: .utf8)
            authMethod = .privateKey(
                username: target.user ?? "root",
                privateKey: .init(sshEd25519: keyData)
            )
        } else {
            // Try default key paths
            let defaultPaths = [
                "~/.ssh/id_ed25519",
                "~/.ssh/id_rsa"
            ].map { ($0 as NSString).expandingTildeInPath }

            var keyData: String?
            for path in defaultPaths {
                if FileManager.default.fileExists(atPath: path) {
                    keyData = try? String(contentsOfFile: path, encoding: .utf8)
                    if keyData != nil { break }
                }
            }

            if let keyData = keyData {
                authMethod = .privateKey(
                    username: target.user ?? "root",
                    privateKey: .init(sshEd25519: keyData)
                )
            } else {
                // Fallback - will need password prompt in UI layer
                throw SFTPServiceError.noAuthMethodAvailable
            }
        }

        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything()
        )
        self.sshClient = client
        self.sftpClient = try await client.openSFTP()
    }

    /// List subdirectories at the given remote path.
    /// Returns only directories (no files), sorted by name.
    /// Excludes hidden directories (starting with ".").
    func listDirectories(at path: String) async throws -> [SFTPDirectoryEntry] {
        guard let sftp = sftpClient else {
            throw SFTPServiceError.notConnected
        }

        let items = try await sftp.listDirectory(atPath: path)
        return items
            .filter { item in
                let name = item.filename
                // Only directories, skip . and .. and hidden
                return name != "." && name != ".."
                    && !name.hasPrefix(".")
                    && item.attributes.permissions?.isDirectory == true
            }
            .map { item in
                let fullPath = path.hasSuffix("/")
                    ? "\(path)\(item.filename)"
                    : "\(path)/\(item.filename)"
                return SFTPDirectoryEntry(name: item.filename, path: fullPath)
            }
            .sorted()
    }

    /// Resolve the home directory path on the remote server.
    func homeDirectory() async throws -> String {
        guard let sftp = sftpClient else {
            throw SFTPServiceError.notConnected
        }
        // SFTP realpath on "." returns the initial login directory (home)
        let resolved = try await sftp.realpath(".")
        return resolved
    }

    /// Disconnect and clean up resources.
    func disconnect() async {
        try? await sftpClient?.close()
        try? await sshClient?.close()
        sftpClient = nil
        sshClient = nil
    }
}

/// Errors specific to the SFTP service.
enum SFTPServiceError: LocalizedError {
    case notConnected
    case noAuthMethodAvailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SFTP server"
        case .noAuthMethodAvailable:
            return "No SSH authentication method available"
        }
    }
}
```

> **Note:** The exact Citadel API may differ slightly depending on version. The implementer MUST check the actual Citadel API (e.g. `SSHClient.connect` signature, `SSHAuthenticationMethod` enum variants, `SFTPClient.listDirectory` return type, `SFTPFile.attributes.permissions`) and adjust accordingly. Use `import Citadel` then check available types via autocomplete or Citadel's documentation/source.

**Step 2: Verify build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` (may require API adjustments based on Citadel version)

**Step 3: Commit**

```bash
git add Treemux/Services/SFTP/SFTPService.swift
git commit -m "feat: add SFTPService actor for remote directory browsing"
```

---

### Task 4: Create DirectoryNode and RemoteDirectoryBrowserViewModel

**Files:**
- Create: `Treemux/UI/Sheets/RemoteDirectoryBrowserViewModel.swift`

**Step 1: Create the ViewModel file**

```swift
//
//  RemoteDirectoryBrowserViewModel.swift
//  Treemux
//

import Foundation
import SwiftUI

/// Tree node representing a remote directory for the browser UI.
@MainActor
class DirectoryNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    @Published var children: [DirectoryNode]?  // nil = not yet loaded
    @Published var isLoading: Bool = false
    @Published var error: String?

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// ViewModel driving the RemoteDirectoryBrowser sheet.
@MainActor
class RemoteDirectoryBrowserViewModel: ObservableObject {
    @Published var pathBarText: String = ""
    @Published var rootNodes: [DirectoryNode] = []
    @Published var selectedPath: String? = nil
    @Published var isConnecting: Bool = false
    @Published var connectionError: String? = nil

    private let sftpService = SFTPService()
    private let sshTarget: SSHTarget

    init(sshTarget: SSHTarget) {
        self.sshTarget = sshTarget
    }

    /// Connect to the remote server and load the home directory.
    func connect() async {
        isConnecting = true
        connectionError = nil
        do {
            try await sftpService.connect(target: sshTarget)
            let home = try await sftpService.homeDirectory()
            pathBarText = home
            let entries = try await sftpService.listDirectories(at: home)
            rootNodes = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    /// Navigate to a specific path (from path bar input).
    func navigateTo(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isConnecting = true
        connectionError = nil
        do {
            let entries = try await sftpService.listDirectories(at: trimmed)
            pathBarText = trimmed
            selectedPath = nil
            rootNodes = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    /// Lazy-load children for a directory node when expanded.
    func expandNode(_ node: DirectoryNode) async {
        guard node.children == nil else { return }  // Already loaded
        node.isLoading = true
        node.error = nil
        do {
            let entries = try await sftpService.listDirectories(at: node.path)
            node.children = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            node.error = error.localizedDescription
            node.children = []  // Mark as loaded (empty) to prevent retry loops
        }
        node.isLoading = false
    }

    /// Disconnect from the server.
    func disconnect() async {
        await sftpService.disconnect()
    }
}
```

**Step 2: Verify build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

**Step 3: Commit**

```bash
git add Treemux/UI/Sheets/RemoteDirectoryBrowserViewModel.swift
git commit -m "feat: add DirectoryNode and RemoteDirectoryBrowserViewModel"
```

---

### Task 5: Create RemoteDirectoryBrowser View

**Files:**
- Create: `Treemux/UI/Sheets/RemoteDirectoryBrowser.swift`
- Reference: `Treemux/UI/Theme/ThemeManager.swift` (for theming consistency)

> **REQUIRED:** Use `/ui-ux-pro-max` skill when implementing this task for design guidance.

**Step 1: Create the view**

The view structure:

```swift
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

    /// Binding to pass selected path back to the caller.
    let onSelect: (String) -> Void

    init(sshTarget: SSHTarget, onSelect: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: RemoteDirectoryBrowserViewModel(sshTarget: sshTarget))
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            Divider()

            // Path bar
            pathBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Directory tree or status
            directoryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar: selected path + action buttons
            bottomBar
                .padding(12)
        }
        .frame(width: 500, height: 450)
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
        .padding(12)
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Path"), text: $viewModel.pathBarText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.navigateTo(path: viewModel.pathBarText) }
                }
        }
    }

    // MARK: - Directory Content

    @ViewBuilder
    private var directoryContent: some View {
        if viewModel.isConnecting {
            VStack {
                ProgressView()
                Text(String(localized: "Connecting..."))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.connectionError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Retry")) {
                    Task { await viewModel.connect() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
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
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if let selected = viewModel.selectedPath {
                Text(selected)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(String(localized: "No directory selected"))
                    .font(.caption)
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
    }
}

// MARK: - Directory Node Row

/// Recursive row for a single directory node in the tree.
struct DirectoryNodeRow: View {
    @ObservedObject var node: DirectoryNode
    @Binding var selectedPath: String?
    let expandAction: (DirectoryNode) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { node.children != nil && !(node.children?.isEmpty ?? true) ? true : false },
                set: { isExpanding in
                    if isExpanding {
                        expandAction(node)
                    }
                }
            )
        ) {
            if node.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            } else if let children = node.children {
                ForEach(children) { child in
                    DirectoryNodeRow(
                        node: child,
                        selectedPath: $selectedPath,
                        expandAction: expandAction
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.blue)
                Text(node.name)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPath = node.path
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedPath == node.path ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
    }
}
```

> **Note:** The `DisclosureGroup` expand binding and tree recursion need careful tuning. The implementer should test expand/collapse behavior thoroughly and adjust the binding logic as needed.

**Step 2: Verify build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

**Step 3: Commit**

```bash
git add Treemux/UI/Sheets/RemoteDirectoryBrowser.swift
git commit -m "feat: add RemoteDirectoryBrowser sheet with tree-style directory view"
```

---

### Task 6: Modify OpenProjectSheet - Add "Choose..." Button to Remote Mode

**Files:**
- Modify: `Treemux/UI/Sheets/OpenProjectSheet.swift` (lines 96-128: remoteModeView)

**Step 1: Add state for browser sheet**

Add to the existing `@State` properties at the top of `OpenProjectSheet` (after line 28):

```swift
@State private var showRemoteBrowser = false
```

**Step 2: Replace remoteModeView**

Replace the current `remoteModeView` (lines 98-128) with the updated version that adds a "Choose..." button after the remote path field:

```swift
private var remoteModeView: some View {
    VStack(alignment: .leading, spacing: 8) {
        if isLoadingTargets {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if sshTargets.isEmpty {
            Text(String(localized: "No SSH hosts found in ~/.ssh/config"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            Text(String(localized: "Server:"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("", selection: $selectedTargetIndex) {
                ForEach(sshTargets.indices, id: \.self) { index in
                    let target = sshTargets[index]
                    Text(targetLabel(target))
                        .tag(index)
                }
            }
            .labelsHidden()

            Text(String(localized: "Remote Path:"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                TextField("/home/user/project", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Choose…")) {
                    showRemoteBrowser = true
                }
                .disabled(sshTargets.isEmpty)
            }
        }
    }
    .sheet(isPresented: $showRemoteBrowser) {
        if selectedTargetIndex < sshTargets.count {
            RemoteDirectoryBrowser(
                sshTarget: sshTargets[selectedTargetIndex]
            ) { selectedPath in
                remotePath = selectedPath
            }
        }
    }
}
```

**Step 3: Verify build**

Run:
```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add Treemux/UI/Sheets/OpenProjectSheet.swift
git commit -m "feat: add Choose button to OpenProjectSheet remote mode"
```

---

### Task 7: Manual Integration Testing

**Step 1: Build and run the app**

```bash
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5
```

Then run:
```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<ID>/Build/Products/Debug/Treemux.app
```

**Step 2: Test checklist**

1. Open the app → click "Open Project..."
2. Switch to "Remote" tab
3. Verify SSH targets load from `~/.ssh/config`
4. Select an SSH target
5. Verify "Choose..." button is enabled
6. Click "Choose..." → verify RemoteDirectoryBrowser sheet opens
7. Verify it connects and shows home directory contents
8. Expand a directory → verify lazy loading works (children appear)
9. Type a path in path bar → press Enter → verify navigation works
10. Click a directory → verify it highlights and selected path shows at bottom
11. Click "Open" → verify path is filled into the remote path field
12. Click "Open" in main sheet → verify workspace is created
13. Verify the new remote workspace appears in sidebar with correct name
14. Verify terminal session connects to the remote server

**Step 3: Test error scenarios**

1. Try connecting to an unavailable server → verify error + retry button
2. Try navigating to a non-existent path → verify error message
3. Close browser without selecting → verify no path change

**Step 4: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "fix: address integration testing feedback for remote directory browser"
```

---

## Task Dependency Graph

```
Task 1 (Citadel SPM)
  ↓
Task 2 (SFTPDirectoryEntry)
  ↓
Task 3 (SFTPService)
  ↓
Task 4 (ViewModel + DirectoryNode)
  ↓
Task 5 (RemoteDirectoryBrowser View)  ← uses /ui-ux-pro-max
  ↓
Task 6 (OpenProjectSheet modification)
  ↓
Task 7 (Integration testing)
```

All tasks are sequential — each depends on the previous one.
