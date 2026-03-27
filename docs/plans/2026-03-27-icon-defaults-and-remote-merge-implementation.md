# Icon Defaults Removal & Remote → Repository Merge — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove global default icons for Repository/Remote/Worktree (keep only Terminal), merge `.remote` workspace kind into `.repository`, and rebuild the settings Sidebar Icons tab as an instance-level icon manager.

**Architecture:** Model-first approach — refactor `WorkspaceKindRecord` and `AppSettings` first, then update all consumers (WorkspaceStore, persistence, UI). The settings panel becomes dynamic, reading live workspace instances from the store.

**Tech Stack:** Swift, SwiftUI, XCTest, macOS AppKit integration

---

### Task 1: Remove `.remote` from `WorkspaceKindRecord` and add migration

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:11-15`
- Modify: `Treemux/Persistence/WorkspaceStatePersistence.swift`

**Step 1: Update `WorkspaceKindRecord` enum**

In `Treemux/Domain/WorkspaceModels.swift`, change:

```swift
/// The kind of workspace: local repository, bare terminal, or remote SSH.
enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal
    case remote
}
```

to:

```swift
/// The kind of workspace: local repository or bare terminal.
/// Remote repositories use `.repository` with a non-nil `sshTarget`.
enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal

    // Migration: decode legacy "remote" as "repository"
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "remote" {
            self = .repository
        } else if let value = WorkspaceKindRecord(rawValue: rawValue) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown kind: \(rawValue)")
        }
    }
}
```

**Step 2: Build to check for compiler errors**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -30`

Expected: Compiler errors in files referencing `.remote` — this is expected and will be fixed in subsequent tasks.

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "refactor: remove .remote from WorkspaceKindRecord with migration decoding"
```

---

### Task 2: Update `AppSettings` — remove 3 default icon fields

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift:11-25`

**Step 1: Remove the 3 fields**

In `Treemux/Domain/AppSettings.swift`, change:

```swift
struct AppSettings: Codable, Equatable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var appearance: String = "system"  // "system", "dark", "light"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var aiTools: AIToolSettings = AIToolSettings()
    var shortcutOverrides: [String: ShortcutOverride] = [:]
    var defaultRepositoryIcon: SidebarItemIcon = .repositoryDefault
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
    var defaultRemoteIcon: SidebarItemIcon = .remoteDefault
    var defaultWorktreeIcon: SidebarItemIcon = .worktreeDefault
}
```

to:

```swift
struct AppSettings: Codable, Equatable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var appearance: String = "system"  // "system", "dark", "light"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var aiTools: AIToolSettings = AIToolSettings()
    var shortcutOverrides: [String: ShortcutOverride] = [:]
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
}
```

**Step 2: Commit**

```bash
git add Treemux/Domain/AppSettings.swift
git commit -m "refactor: remove defaultRepositoryIcon, defaultRemoteIcon, defaultWorktreeIcon from AppSettings"
```

---

### Task 3: Clean up `SidebarItemIcon` static defaults

**Files:**
- Modify: `Treemux/Domain/SidebarIcon.swift:477-501`

**Step 1: Remove unused public defaults**

In `Treemux/Domain/SidebarIcon.swift`, change:

```swift
extension SidebarItemIcon {
    static let repositoryDefault = SidebarItemIcon(
        symbolName: "arrow.triangle.branch",
        palette: .blue,
        fillStyle: .gradient
    )

    static let localTerminalDefault = SidebarItemIcon(
        symbolName: "terminal.fill",
        palette: .teal,
        fillStyle: .solid
    )

    static let remoteDefault = SidebarItemIcon(
        symbolName: "globe",
        palette: .orange,
        fillStyle: .gradient
    )

    static let worktreeDefault = SidebarItemIcon(
        symbolName: "circle.fill",
        palette: .mint,
        fillStyle: .solid
    )
}
```

to:

```swift
extension SidebarItemIcon {
    static let localTerminalDefault = SidebarItemIcon(
        symbolName: "terminal.fill",
        palette: .teal,
        fillStyle: .solid
    )
}
```

Note: `repositoryDefault` is referenced in `SidebarIconCatalog.swift` as a fallback in `randomRepository()` and `randomRepository(preferredSeed:avoiding:)`. Those fallback values need to be inlined.

**Step 2: Inline the fallback in `SidebarIconCatalog.swift`**

In `Treemux/Domain/SidebarIconCatalog.swift`, find each reference to `.repositoryDefault` and replace with an inline fallback. There are 3 occurrences:

Line 109 (`randomRepository(avoiding:)`):
```swift
return bestCandidates.randomElement() ?? repositoryDefault
```
→
```swift
return bestCandidates.randomElement() ?? SidebarItemIcon(symbolName: "arrow.triangle.branch", palette: .blue)
```

Line 115 (`randomRepository(avoiding:)`):
```swift
guard let bestScore = scored.map(\.1).max() else {
    return repositoryDefault
}
```
→
```swift
guard let bestScore = scored.map(\.1).max() else {
    return SidebarItemIcon(symbolName: "arrow.triangle.branch", palette: .blue)
}
```

Line 129 (`randomRepository(preferredSeed:avoiding:)`):
```swift
guard let bestScore = scored.map(\.1).max() else {
    return repositoryDefault
}
```
→
```swift
guard let bestScore = scored.map(\.1).max() else {
    return SidebarItemIcon(symbolName: "arrow.triangle.branch", palette: .blue)
}
```

Line 140:
```swift
return bestCandidates.first ?? repositoryDefault
```
→
```swift
return bestCandidates.first ?? SidebarItemIcon(symbolName: "arrow.triangle.branch", palette: .blue)
```

Line 224 (`RepositoryStylePreferences.init`):
```swift
primarySymbolName = orderedSymbols.first ?? SidebarItemIcon.repositoryDefault.symbolName
```
→
```swift
primarySymbolName = orderedSymbols.first ?? "arrow.triangle.branch"
```

**Step 3: Commit**

```bash
git add Treemux/Domain/SidebarIcon.swift Treemux/Domain/SidebarIconCatalog.swift
git commit -m "refactor: remove repositoryDefault, remoteDefault, worktreeDefault static constants"
```

---

### Task 4: Update `SidebarIconCustomizationTarget` and `WorkspaceStore` icon logic

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`

**Step 1: Remove 3 cases from `SidebarIconCustomizationTarget`**

At the bottom of `WorkspaceStore.swift`, change:

```swift
enum SidebarIconCustomizationTarget {
    case workspace(UUID)
    case worktree(workspaceID: UUID, worktreePath: String)
    case appDefaultRepository
    case appDefaultLocalTerminal
    case appDefaultRemote
    case appDefaultWorktree
}
```

to:

```swift
enum SidebarIconCustomizationTarget {
    case workspace(UUID)
    case worktree(workspaceID: UUID, worktreePath: String)
    case appDefaultLocalTerminal
}
```

**Step 2: Update `localWorkspaces` — remove `.remote` check**

Change line 92:

```swift
let real = workspaces.filter { !$0.isArchived && ($0.kind == .repository || $0.kind == .localTerminal) }
```

to:

```swift
let real = workspaces.filter { !$0.isArchived && $0.sshTarget == nil }
```

**Step 3: Update `remoteWorkspaceGroups` filter**

Change line 101:

```swift
let remotes = workspaces.filter { !$0.isArchived && $0.kind == .remote }
```

to:

```swift
let remotes = workspaces.filter { !$0.isArchived && $0.kind == .repository && $0.sshTarget != nil }
```

**Step 4: Update `addRemoteWorkspace` — use `.repository` kind**

Change line 195:

```swift
kind: .remote,
```

to:

```swift
kind: .repository,
```

**Step 5: Rewrite `sidebarIcon(for workspace:)` — use deterministic generation for repositories**

Replace the method (lines 363-375):

```swift
func sidebarIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
    if let override = workspace.workspaceIcon {
        return override
    }
    switch workspace.kind {
    case .repository:
        return settings.defaultRepositoryIcon
    case .localTerminal:
        return settings.defaultLocalTerminalIcon
    case .remote:
        return settings.defaultRemoteIcon
    }
}
```

with:

```swift
func sidebarIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
    if let override = workspace.workspaceIcon {
        return override
    }
    switch workspace.kind {
    case .localTerminal:
        return settings.defaultLocalTerminalIcon
    case .repository:
        let existingIcons = workspaces
            .filter { $0.id != workspace.id && !$0.isArchived && $0.kind == .repository }
            .compactMap { $0.workspaceIcon ?? generatedRepositoryIcon(for: $0) }
        return .randomRepository(
            preferredSeed: workspace.repositoryRoot?.lastPathComponent ?? workspace.name,
            avoiding: existingIcons
        )
    }
}

/// Generates a deterministic icon for a repository workspace (without override).
private func generatedRepositoryIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
    .randomRepository(
        preferredSeed: workspace.repositoryRoot?.lastPathComponent ?? workspace.name,
        avoiding: []
    )
}
```

**Step 6: Simplify `sidebarIcon(for worktree:in:)` — remove global default interception**

Replace the method (lines 379-398):

```swift
func sidebarIcon(for worktree: WorktreeModel, in workspace: WorkspaceModel) -> SidebarItemIcon {
    if let override = workspace.worktreeIconOverrides[worktree.path.path] {
        return override
    }
    if settings.defaultWorktreeIcon != .worktreeDefault {
        return settings.defaultWorktreeIcon
    }
    let generatedIcons = SidebarItemIcon.generatedWorktreeIcons(
        seedSourcesByID: Dictionary(
            uniqueKeysWithValues: workspace.worktrees.map { candidate in
                (candidate.path.path, worktreeIconSeed(for: candidate, in: workspace))
            }
        ),
        overrides: workspace.worktreeIconOverrides
    )
    return generatedIcons[worktree.path.path] ?? .randomRepository(
        preferredSeed: worktreeIconSeed(for: worktree, in: workspace),
        avoiding: []
    )
}
```

with:

```swift
func sidebarIcon(for worktree: WorktreeModel, in workspace: WorkspaceModel) -> SidebarItemIcon {
    if let override = workspace.worktreeIconOverrides[worktree.path.path] {
        return override
    }
    let generatedIcons = SidebarItemIcon.generatedWorktreeIcons(
        seedSourcesByID: Dictionary(
            uniqueKeysWithValues: workspace.worktrees.map { candidate in
                (candidate.path.path, worktreeIconSeed(for: candidate, in: workspace))
            }
        ),
        overrides: workspace.worktreeIconOverrides
    )
    return generatedIcons[worktree.path.path] ?? .randomRepository(
        preferredSeed: worktreeIconSeed(for: worktree, in: workspace),
        avoiding: []
    )
}
```

**Step 7: Simplify `updateSidebarIcon` — remove 3 cases**

Replace the method (lines 408-426):

```swift
func updateSidebarIcon(_ icon: SidebarItemIcon, for target: SidebarIconCustomizationTarget) {
    switch target {
    case .workspace(let workspaceID):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.workspaceIcon = icon
    case .worktree(let workspaceID, let worktreePath):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.worktreeIconOverrides[worktreePath] = icon
    case .appDefaultRepository:
        settings.defaultRepositoryIcon = icon
    case .appDefaultLocalTerminal:
        settings.defaultLocalTerminalIcon = icon
    case .appDefaultRemote:
        settings.defaultRemoteIcon = icon
    case .appDefaultWorktree:
        settings.defaultWorktreeIcon = icon
    }
    saveWorkspaceState()
}
```

with:

```swift
func updateSidebarIcon(_ icon: SidebarItemIcon, for target: SidebarIconCustomizationTarget) {
    switch target {
    case .workspace(let workspaceID):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.workspaceIcon = icon
    case .worktree(let workspaceID, let worktreePath):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.worktreeIconOverrides[worktreePath] = icon
    case .appDefaultLocalTerminal:
        settings.defaultLocalTerminalIcon = icon
    }
    saveWorkspaceState()
}
```

**Step 8: Simplify `resetSidebarIcon` — remove 3 cases**

Replace the method (lines 429-447):

```swift
func resetSidebarIcon(for target: SidebarIconCustomizationTarget) {
    switch target {
    case .workspace(let workspaceID):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.workspaceIcon = nil
    case .worktree(let workspaceID, let worktreePath):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.worktreeIconOverrides[worktreePath] = nil
    case .appDefaultRepository:
        settings.defaultRepositoryIcon = .repositoryDefault
    case .appDefaultLocalTerminal:
        settings.defaultLocalTerminalIcon = .localTerminalDefault
    case .appDefaultRemote:
        settings.defaultRemoteIcon = .remoteDefault
    case .appDefaultWorktree:
        settings.defaultWorktreeIcon = .worktreeDefault
    }
    saveWorkspaceState()
}
```

with:

```swift
func resetSidebarIcon(for target: SidebarIconCustomizationTarget) {
    switch target {
    case .workspace(let workspaceID):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.workspaceIcon = nil
    case .worktree(let workspaceID, let worktreePath):
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.worktreeIconOverrides[worktreePath] = nil
    case .appDefaultLocalTerminal:
        settings.defaultLocalTerminalIcon = .localTerminalDefault
    }
    saveWorkspaceState()
}
```

**Step 9: Simplify `sidebarIconRequestTitle` — remove 3 cases**

Replace the method (lines 450-470):

```swift
func sidebarIconRequestTitle(_ request: SidebarIconCustomizationRequest) -> String {
    switch request.target {
    case .workspace(let id):
        return workspaces.first(where: { $0.id == id })?.name ?? "Workspace"
    case .worktree(let workspaceID, let worktreePath):
        guard let ws = workspaces.first(where: { $0.id == workspaceID }) else {
            return URL(fileURLWithPath: worktreePath).lastPathComponent
        }
        let wtName = ws.worktrees.first(where: { $0.path.path == worktreePath })?.branch
            ?? URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(ws.name) / \(wtName)"
    case .appDefaultRepository:
        return String(localized: "Default Repository Icon")
    case .appDefaultLocalTerminal:
        return String(localized: "Default Terminal Icon")
    case .appDefaultRemote:
        return String(localized: "Default Remote Icon")
    case .appDefaultWorktree:
        return String(localized: "Default Worktree Icon")
    }
}
```

with:

```swift
func sidebarIconRequestTitle(_ request: SidebarIconCustomizationRequest) -> String {
    switch request.target {
    case .workspace(let id):
        return workspaces.first(where: { $0.id == id })?.name ?? "Workspace"
    case .worktree(let workspaceID, let worktreePath):
        guard let ws = workspaces.first(where: { $0.id == workspaceID }) else {
            return URL(fileURLWithPath: worktreePath).lastPathComponent
        }
        let wtName = ws.worktrees.first(where: { $0.path.path == worktreePath })?.branch
            ?? URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(ws.name) / \(wtName)"
    case .appDefaultLocalTerminal:
        return String(localized: "Default Terminal Icon")
    }
}
```

**Step 10: Simplify `sidebarIconSelection(for:)` — remove 3 cases**

Replace the method (lines 473-496):

```swift
func sidebarIconSelection(for target: SidebarIconCustomizationTarget) -> SidebarItemIcon {
    switch target {
    case .workspace(let id):
        guard let ws = workspaces.first(where: { $0.id == id }) else { return settings.defaultRepositoryIcon }
        return ws.workspaceIcon ?? sidebarIcon(for: ws)
    case .worktree(let workspaceID, let worktreePath):
        guard let ws = workspaces.first(where: { $0.id == workspaceID }) else { return settings.defaultWorktreeIcon }
        if let override = ws.worktreeIconOverrides[worktreePath] {
            return override
        }
        guard let wt = ws.worktrees.first(where: { $0.path.path == worktreePath }) else {
            return settings.defaultWorktreeIcon
        }
        return sidebarIcon(for: wt, in: ws)
    case .appDefaultRepository:
        return settings.defaultRepositoryIcon
    case .appDefaultLocalTerminal:
        return settings.defaultLocalTerminalIcon
    case .appDefaultRemote:
        return settings.defaultRemoteIcon
    case .appDefaultWorktree:
        return settings.defaultWorktreeIcon
    }
}
```

with:

```swift
func sidebarIconSelection(for target: SidebarIconCustomizationTarget) -> SidebarItemIcon {
    switch target {
    case .workspace(let id):
        guard let ws = workspaces.first(where: { $0.id == id }) else {
            return .randomRepository()
        }
        return ws.workspaceIcon ?? sidebarIcon(for: ws)
    case .worktree(let workspaceID, let worktreePath):
        guard let ws = workspaces.first(where: { $0.id == workspaceID }),
              let wt = ws.worktrees.first(where: { $0.path.path == worktreePath }) else {
            return .randomRepository()
        }
        if let override = ws.worktreeIconOverrides[worktreePath] {
            return override
        }
        return sidebarIcon(for: wt, in: ws)
    case .appDefaultLocalTerminal:
        return settings.defaultLocalTerminalIcon
    }
}
```

**Step 11: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "refactor: update WorkspaceStore icon resolution and remove .remote references"
```

---

### Task 5: Update UI files — SidebarIconCustomizationSheet, OpenProjectSheet, WorkspaceSidebarView

**Files:**
- Modify: `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift:139-151`
- Modify: `Treemux/UI/Sheets/OpenProjectSheet.swift:170`
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`

**Step 1: Simplify `SidebarIconCustomizationSheet.randomizer`**

In `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift`, replace the `randomizer` computed property (lines 139-151):

```swift
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
```

with:

```swift
private var randomizer: () -> SidebarItemIcon {
    switch request.target {
    case .workspace(let workspaceID):
        if store.workspaces.first(where: { $0.id == workspaceID })?.kind == .repository {
            return SidebarItemIcon.randomRepository
        }
        return SidebarItemIcon.random
    case .worktree:
        return SidebarItemIcon.randomRepository
    case .appDefaultLocalTerminal:
        return SidebarItemIcon.random
    }
}
```

Also update the `@State` default on line 94:

```swift
@State private var icon = SidebarItemIcon.repositoryDefault
```

to:

```swift
@State private var icon = SidebarItemIcon(symbolName: "arrow.triangle.branch", palette: .blue)
```

**Step 2: Update `OpenProjectSheet` — use `.repository` for remote**

In `Treemux/UI/Sheets/OpenProjectSheet.swift` line 170, change:

```swift
store.addRemoteWorkspace(target: updatedTarget, name: target.displayName)
```

This method already sets `kind: .remote` internally. Since we updated `addRemoteWorkspace` in Task 4 to use `.repository`, no additional change needed here. But verify the method signature still works.

**Step 3: Commit**

```bash
git add Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift Treemux/UI/Sheets/OpenProjectSheet.swift
git commit -m "refactor: simplify icon customization sheet and update remote project creation"
```

---

### Task 6: Rebuild Settings Sidebar Icons tab as instance-level icon manager

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:356-395`

**Step 1: Update `SidebarIconsSettingsView`**

Replace the entire `SidebarIconsSettingsView` struct (lines 358-395) with:

```swift
private struct SidebarIconsSettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    /// Repository workspaces (non-archived) for the instance-level icon list.
    private var repositoryWorkspaces: [WorkspaceModel] {
        store.workspaces.filter { !$0.isArchived && $0.kind == .repository }
    }

    var body: some View {
        Form {
            // Global default: Terminal only
            Section(String(localized: "Default")) {
                SidebarIconEditorCard(
                    title: String(localized: "Terminal"),
                    subtitle: String(localized: "Default icon for local terminals"),
                    icon: $settings.defaultLocalTerminalIcon,
                    randomizer: SidebarItemIcon.random
                )
            }

            // Per-repository instance icons
            ForEach(repositoryWorkspaces) { workspace in
                Section(workspace.name) {
                    // Workspace icon row
                    WorkspaceIconRow(workspace: workspace)

                    // Worktree icon rows
                    ForEach(workspace.worktrees) { worktree in
                        WorktreeIconRow(workspace: workspace, worktree: worktree)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A clickable row showing a workspace's current icon. Tapping opens the customization sheet.
private struct WorkspaceIconRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        Button {
            store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .workspace(workspace.id)
            )
        } label: {
            HStack(spacing: 10) {
                SidebarItemIconView(icon: store.sidebarIcon(for: workspace), size: 22)
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A clickable row showing a worktree's current icon. Tapping opens the customization sheet.
private struct WorktreeIconRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel
    let worktree: WorktreeModel

    var body: some View {
        Button {
            store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .worktree(workspaceID: workspace.id, worktreePath: worktree.path.path)
            )
        } label: {
            HStack(spacing: 10) {
                SidebarItemIconView(icon: store.sidebarIcon(for: worktree, in: workspace), size: 18)
                    .padding(.leading, 12)
                Text(worktree.branch ?? worktree.path.lastPathComponent)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
```

**Step 2: Update the subtitle for `.sidebarIcons`**

In `SettingsSheet.swift` line 44, change:

```swift
case .sidebarIcons: return String(localized: "Default icons for workspaces and worktrees")
```

to:

```swift
case .sidebarIcons: return String(localized: "Customize icons for workspaces and worktrees")
```

**Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: rebuild Sidebar Icons settings as instance-level icon manager"
```

---

### Task 7: Update tests for the model changes

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`
- Modify: `TreemuxTests/PersistenceTests.swift`

**Step 1: Update `testRemoteWorkspaceRecordCodable` to test migration**

In `TreemuxTests/WorkspaceModelsTests.swift`, replace `testRemoteWorkspaceRecordCodable` (lines 31-53):

```swift
func testRemoteWorkspaceRecordCodable() throws {
    let target = SSHTarget(
        host: "server1", port: 22, user: "user1",
        identityFile: nil, displayName: "server1", remotePath: "/home/user1/proj"
    )
    let record = WorkspaceRecord(
        id: UUID(),
        kind: .repository,
        name: "proj",
        repositoryPath: nil,
        isPinned: false,
        isArchived: false,
        sshTarget: target,
        worktreeStates: [],
        worktreeOrder: nil,
        workspaceIcon: nil,
        worktreeIconOverrides: nil
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
    XCTAssertEqual(decoded.kind, .repository)
    XCTAssertEqual(decoded.sshTarget?.host, "server1")
}

func testLegacyRemoteKindDecodesToRepository() throws {
    // Simulate old JSON with "remote" kind
    let json = """
    {"id":"00000000-0000-0000-0000-000000000001","kind":"remote","name":"proj","isPinned":false,"isArchived":false,"sshTarget":{"host":"server1","port":22,"user":"user1","displayName":"server1"},"worktreeStates":[]}
    """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
    XCTAssertEqual(decoded.kind, .repository)
    XCTAssertEqual(decoded.sshTarget?.host, "server1")
}
```

**Step 2: Update `testAppSettingsDefaultValues` in `PersistenceTests.swift`**

In `TreemuxTests/PersistenceTests.swift`, the `testAppSettingsDefaultValues` test references fields that no longer exist. Update it:

```swift
func testAppSettingsDefaultValues() {
    let settings = AppSettings()
    XCTAssertEqual(settings.language, "system")
    XCTAssertEqual(settings.activeThemeID, "treemux-dark")
    XCTAssertTrue(settings.startup.restoreLastSession)
    XCTAssertEqual(settings.defaultLocalTerminalIcon, .localTerminalDefault)
}
```

**Step 3: Run all tests**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -40`

Expected: All tests pass.

**Step 4: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift TreemuxTests/PersistenceTests.swift
git commit -m "test: update tests for remote→repository migration and AppSettings changes"
```

---

### Task 8: Build and verify

**Step 1: Full build**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

**Step 2: Run all tests**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`

Expected: All tests pass.

**Step 3: Identify the DerivedData path for manual testing**

Run: `ls ~/Library/Developer/Xcode/DerivedData/ | grep Treemux`

Tell the user to run: `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<number>/Build/Products/Debug/Treemux.app`

**Manual verification checklist:**
- Open a local repository → sidebar shows a deterministic random icon (not the old blue branch icon)
- Open Settings → Sidebar Icons tab shows "Default" section with Terminal, plus per-repo sections with worktrees
- Click a repo icon row → customization sheet opens
- Click a worktree icon row → customization sheet opens
- Reset a workspace icon → returns to deterministic random
- Open a remote SSH project → it shows in sidebar as a repository with SSH grouping
