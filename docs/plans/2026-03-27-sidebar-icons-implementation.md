# Sidebar Icons Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port Liney's complete sidebar icon system to Treemux — 69 symbols, 40 color palettes, semantic profiling, deduplication, and full user customization UI.

**Architecture:** Four new files (data types, catalog/algorithms, rendering view, customization sheet) plus modifications to five existing files (models, settings, store, sidebar view, settings sheet). All data changes are backward-compatible via optional fields and defaults.

**Tech Stack:** SwiftUI, SF Symbols, Codable persistence

---

### Task 1: Create SidebarIcon.swift — Data Types

**Files:**
- Create: `Treemux/Domain/SidebarIcon.swift`

**Step 1: Create the file with all icon data types**

Port from Liney's `AppSettings.swift` (lines 12-192) and `WorkspaceSidebarView.swift` (lines 1460-1793). Create the file with:

1. `SidebarIconFillStyle` enum (solid, gradient)
2. `SidebarIconPalette` enum (40 cases with `title` property)
3. `SidebarIconPaletteDescriptor` struct (5 Color fields)
4. `SidebarItemIcon` struct (symbolName, palette, fillStyle)
5. Static defaults: `.repositoryDefault`, `.localTerminalDefault`, `.remoteDefault`, `.worktreeDefault`
6. `SidebarIconPalette.descriptor` computed property with all 40 palette RGB definitions

Key adaptations from Liney:
- Remove `nonisolated` markers (not needed in Treemux's architecture)
- Add `Identifiable` conformance to both enums (for SwiftUI ForEach)
- Add `.remoteDefault` (new for Treemux): `SidebarItemIcon(symbolName: "globe", palette: .orange, fillStyle: .gradient)`
- Use Treemux's existing `nilIfEmpty` from `String+Helpers.swift` in `SidebarItemIcon.init`
- Place `SidebarIconPaletteDescriptor` in this file (Liney has it in its sidebar view file)
- Place the `SidebarIconPalette.descriptor` extension in this file alongside the enum

Source reference — copy exact RGB values from Liney:
- `Liney/Domain/AppSettings.swift:12-192` — enums, struct, defaults
- `Liney/UI/Sidebar/WorkspaceSidebarView.swift:1460-1793` — PaletteDescriptor + 40 descriptor cases

**Step 2: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/SidebarIcon.swift
git commit -m "feat: add sidebar icon data types with 40 color palettes"
```

---

### Task 2: Create SidebarIconCatalog.swift — Symbol Catalog & Algorithms

**Files:**
- Create: `Treemux/Domain/SidebarIconCatalog.swift`

**Step 1: Create the file with full catalog and algorithms**

Direct port from `Liney/Domain/SidebarIconCatalog.swift` (all 449 lines). The file contains:

1. `SidebarIconCatalog` enum with:
   - `Symbol` struct (title, systemName)
   - `symbols` array (69 SF Symbols — copy exact list from Liney lines 18-82)
   - `repositorySymbolNames` (filtered list excluding terminal.fill, circle.fill, square.fill)

2. `SidebarItemIcon` extension with generation methods:
   - `random()` — fully random icon
   - `randomRepository()` — random repo-appropriate icon
   - `randomRepository(avoiding:)` — with deduplication
   - `randomRepository(preferredSeed:avoiding:)` — seed-based with dedup
   - `generatedWorktreeIcons(seedSourcesByID:overrides:)` — batch generation

3. `SidebarIconCatalog` extension with algorithm types:
   - `RepositorySemanticProfile` struct
   - `RepositoryUsage` struct (frequency tracking)
   - `RepositoryStylePreferences` struct (seed-based preferences)
   - `repositoryCandidates` static property
   - `repositoryScore(for:usage:preferences:)` — scoring algorithm
   - `seededCandidateRank(for:seed:)` — deterministic tiebreaker
   - `seededSymbolNames(seed:)` — seeded symbol ordering
   - `seededPalettes(seed:)` — seeded palette ordering
   - `semanticProfile(for:)` — keyword-based category matching (6 categories)
   - `stableHash(_:)` — FNV-1a hash
   - `mix64(_:)` — MurmurHash3-style mixing

4. Private `repositoryPairKey` extension on `SidebarItemIcon`

Key adaptations:
- Remove all `nonisolated` markers
- Use Treemux's existing `nilIfEmpty` (already in `String+Helpers.swift`)

Source reference — copy exact code from Liney:
- `Liney/Domain/SidebarIconCatalog.swift:1-449` — entire file

**Step 2: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/SidebarIconCatalog.swift
git commit -m "feat: add sidebar icon catalog with semantic profiling and dedup"
```

---

### Task 3: Create SidebarItemIconView.swift — Rendering Component

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarItemIconView.swift`

**Step 1: Create the icon rendering view**

Port from `Liney/UI/Sidebar/WorkspaceSidebarView.swift` lines 1406-1458.

```swift
import SwiftUI

/// Renders a sidebar icon as a rounded-rectangle tile with an SF Symbol.
struct SidebarItemIconView: View {
    let icon: SidebarItemIcon
    let size: CGFloat
    var isActive: Bool = false

    private var palette: SidebarIconPaletteDescriptor {
        icon.palette.descriptor
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: max(7, size * 0.34), style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon.symbolName)
                .font(.system(size: max(9, size * 0.48), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay(
                    backgroundShape
                        .strokeBorder(palette.border, lineWidth: 1)
                )

            if isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: max(6, size * 0.28), height: max(6, size * 0.28))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }

    @ViewBuilder
    private var background: some View {
        switch icon.fillStyle {
        case .solid:
            backgroundShape.fill(palette.solidBackground)
        case .gradient:
            backgroundShape.fill(
                LinearGradient(
                    colors: [palette.gradientStart, palette.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}
```

Key adaptations from Liney:
- Replace `LineyTheme.success` with `Color.green`
- Replace `LineyTheme.sidebarBackground` with `Color(nsColor: .windowBackgroundColor)`

**Step 2: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarItemIconView.swift
git commit -m "feat: add SidebarItemIconView rendering component"
```

---

### Task 4: Update Data Models — WorkspaceRecord & WorkspaceModel

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`

**Step 1: Add icon fields to WorkspaceRecord**

Add two new optional fields to `WorkspaceRecord`:

```swift
struct WorkspaceRecord: Codable {
    let id: UUID
    let kind: WorkspaceKindRecord
    let name: String
    let repositoryPath: String?
    let isPinned: Bool
    let isArchived: Bool
    let sshTarget: SSHTarget?
    let worktreeStates: [WorktreeSessionStateRecord]
    let worktreeOrder: [String]?
    let workspaceIcon: SidebarItemIcon?                   // NEW
    let worktreeIconOverrides: [String: SidebarItemIcon]? // NEW
}
```

**Step 2: Add @Published properties to WorkspaceModel**

Add after the existing `worktreeOrder` property:

```swift
@Published var workspaceIcon: SidebarItemIcon?
@Published var worktreeIconOverrides: [String: SidebarItemIcon] = [:]
```

**Step 3: Update WorkspaceModel.init**

Add parameters:

```swift
init(
    id: UUID = UUID(),
    name: String,
    kind: WorkspaceKindRecord,
    repositoryRoot: URL? = nil,
    isPinned: Bool = false,
    isArchived: Bool = false,
    sshTarget: SSHTarget? = nil,
    worktreeOrder: [String] = [],
    workspaceIcon: SidebarItemIcon? = nil,              // NEW
    worktreeIconOverrides: [String: SidebarItemIcon] = [:] // NEW
) {
    // ... existing assignments ...
    self.workspaceIcon = workspaceIcon
    self.worktreeIconOverrides = worktreeIconOverrides
}
```

**Step 4: Update convenience init(from record:)**

Pass through the new fields:

```swift
convenience init(from record: WorkspaceRecord) {
    self.init(
        id: record.id,
        name: record.name,
        kind: record.kind,
        repositoryRoot: record.repositoryPath.map { URL(fileURLWithPath: $0) },
        isPinned: record.isPinned,
        isArchived: record.isArchived,
        sshTarget: record.sshTarget,
        worktreeOrder: record.worktreeOrder ?? [],
        workspaceIcon: record.workspaceIcon,
        worktreeIconOverrides: record.worktreeIconOverrides ?? [:]
    )
    restoreTabState(from: record.worktreeStates)
}
```

**Step 5: Update toRecord()**

Add the new fields to the returned `WorkspaceRecord`:

```swift
return WorkspaceRecord(
    id: id,
    kind: kind,
    name: name,
    repositoryPath: repositoryRoot?.path,
    isPinned: isPinned,
    isArchived: isArchived,
    sshTarget: sshTarget,
    worktreeStates: allWorktreeStates,
    worktreeOrder: worktreeOrder.isEmpty ? nil : worktreeOrder,
    workspaceIcon: workspaceIcon,
    worktreeIconOverrides: worktreeIconOverrides.isEmpty ? nil : worktreeIconOverrides
)
```

**Step 6: Handle backward compatibility in WorkspaceRecord decoding**

`WorkspaceRecord` currently uses auto-synthesized `Codable`. Since the new fields are `Optional`, Swift's auto-synthesized decoder already handles missing keys by defaulting to `nil`. No custom `init(from decoder:)` is needed.

**Step 7: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: add icon fields to WorkspaceRecord and WorkspaceModel"
```

---

### Task 5: Update AppSettings — Default Icon Fields

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift`

**Step 1: Add default icon fields to AppSettings**

```swift
struct AppSettings: Codable, Equatable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var appearance: String = "system"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var aiTools: AIToolSettings = AIToolSettings()
    var shortcutOverrides: [String: ShortcutOverride] = [:]
    var defaultRepositoryIcon: SidebarItemIcon = .repositoryDefault     // NEW
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault // NEW
    var defaultRemoteIcon: SidebarItemIcon = .remoteDefault             // NEW
    var defaultWorktreeIcon: SidebarItemIcon = .worktreeDefault         // NEW
}
```

These fields have defaults, so old JSON missing these keys will decode fine.

**Step 2: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/AppSettings.swift
git commit -m "feat: add default sidebar icon settings to AppSettings"
```

---

### Task 6: Add Icon Logic to WorkspaceStore

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`

**Step 1: Add customization request state**

Add near the top of `WorkspaceStore`, after the existing `@Published` properties:

```swift
@Published var sidebarIconCustomizationRequest: SidebarIconCustomizationRequest?
```

**Step 2: Add the customization target model**

Add at the bottom of the file (outside `WorkspaceStore`):

```swift
// MARK: - Sidebar Icon Customization

enum SidebarIconCustomizationTarget {
    case workspace(UUID)
    case worktree(workspaceID: UUID, worktreePath: String)
    case appDefaultRepository
    case appDefaultLocalTerminal
    case appDefaultRemote
    case appDefaultWorktree
}

struct SidebarIconCustomizationRequest: Identifiable {
    let id = UUID()
    let target: SidebarIconCustomizationTarget
}
```

**Step 3: Add icon retrieval methods to WorkspaceStore**

Add a new `// MARK: - Sidebar Icons` section:

```swift
// MARK: - Sidebar Icons

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

private func worktreeIconSeed(for worktree: WorktreeModel, in workspace: WorkspaceModel) -> String {
    let repositoryName = workspace.repositoryRoot.map { $0.lastPathComponent } ?? workspace.name
    let displayName = worktree.branch ?? worktree.path.lastPathComponent
    return "\(repositoryName)|\(displayName)|\(worktree.path.path)"
}
```

**Step 4: Add icon update/reset methods**

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

**Step 5: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat: add sidebar icon retrieval, update, and reset logic to store"
```

---

### Task 7: Update WorkspaceSidebarView — Replace Fixed Icons

**Files:**
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`

**Step 1: Update ProjectLabel to use SidebarItemIconView**

Replace the existing `ProjectLabel` (lines 300-347) with:

```swift
struct ProjectLabel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel
    var showCurrent: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            SidebarItemIconView(icon: store.sidebarIcon(for: workspace), size: 22)
            Text(workspace.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if showCurrent {
                Spacer()
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
    }
}
```

Key changes:
- Add `@EnvironmentObject private var store: WorkspaceStore`
- Replace `Image(systemName: workspaceIcon)` with `SidebarItemIconView(icon: store.sidebarIcon(for: workspace), size: 22)`
- Remove the `workspaceIcon` and `iconColor` computed properties

**Step 2: Update WorktreeRow to use SidebarItemIconView**

Replace the worktree icon in `WorktreeRow` (line 364):

```swift
// Replace:
Image(systemName: "arrow.triangle.branch")
    .foregroundStyle(theme.textMuted)
    .font(.system(size: 11))

// With:
SidebarItemIconView(
    icon: store.sidebarIcon(for: worktree, in: workspace),
    size: 18,
    isActive: isSelected
)
```

This requires adding a `workspace` parameter to `WorktreeRow`. Update the struct:

```swift
struct WorktreeRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    let workspace: WorkspaceModel  // NEW
    let worktree: WorktreeModel
    @Binding var hoveredID: UUID?
    // ... rest unchanged
}
```

Update the call site in `WorkspaceRowGroup` (line 247):

```swift
WorktreeRow(workspace: workspace, worktree: worktree, hoveredID: $hoveredID)
```

**Step 3: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/WorkspaceSidebarView.swift
git commit -m "feat: replace fixed sidebar icons with SidebarItemIconView"
```

---

### Task 8: Create SidebarIconCustomizationSheet

**Files:**
- Create: `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift`

**Step 1: Create the sheet with editor card**

Port from `Liney/UI/Sheets/SettingsSheet.swift` lines 813-886 and 1089-1161.

The file should contain:

1. `SidebarIconEditorCard` — reusable editor component:
   - Icon preview (26pt) + title + subtitle + Random button
   - Symbol picker dropdown (69 symbols with icons)
   - Fill style segmented control (Solid / Gradient)
   - Palette grid (LazyVGrid, 34x24pt gradient swatches)

2. `SidebarIconCustomizationSheet` — modal sheet:
   - Title: "Customize Sidebar Icon"
   - Subtitle: workspace/worktree name from `store.sidebarIconRequestTitle(request)`
   - SidebarIconEditorCard
   - Reset / Cancel / Save buttons
   - `.task` loads current icon via `store.sidebarIconSelection(for:)`
   - Save calls `store.updateSidebarIcon(_:for:)`
   - Reset calls `store.resetSidebarIcon(for:)`

Key adaptations from Liney:
- Use Treemux's `ThemeManager` for background colors instead of `LineyTheme`
- The randomizer function should return `.randomRepository()` for workspace/worktree/repo targets and `.random()` for terminal targets

**Step 2: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift
git commit -m "feat: add sidebar icon customization sheet with editor card"
```

---

### Task 9: Wire Up Right-Click Menus & Sheet Presentation

**Files:**
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`

**Step 1: Add "Change Icon..." to workspace context menus**

In the local projects section context menu (around line 38), add before the existing Rename button:

```swift
Button {
    store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
        target: .workspace(workspace.id)
    )
} label: {
    Label(String(localized: "Change Icon..."), systemImage: "paintpalette")
}
```

Do the same for the remote workspace context menu (around line 71).

**Step 2: Add context menu to WorktreeRow**

In `WorktreeRow`, add a `.contextMenu` modifier:

```swift
.contextMenu {
    Button {
        store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
            target: .worktree(workspaceID: workspace.id, worktreePath: worktree.path.path)
        )
    } label: {
        Label(String(localized: "Change Icon..."), systemImage: "paintpalette")
    }
}
```

Note: Need to find the parent workspace ID. Since `WorktreeRow` now has a `workspace` parameter (added in Task 7), use `workspace.id`.

**Step 3: Add sheet presentation to WorkspaceSidebarView**

Add a `.sheet(item:)` modifier to the root `VStack` in `WorkspaceSidebarView.body`, after the existing `.sheet(isPresented: $showOpenProjectSheet)`:

```swift
.sheet(item: $store.sidebarIconCustomizationRequest) { request in
    SidebarIconCustomizationSheet(request: request)
        .environmentObject(store)
        .environmentObject(theme)
}
```

**Step 4: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/WorkspaceSidebarView.swift
git commit -m "feat: add icon customization context menus and sheet binding"
```

---

### Task 10: Add Sidebar Icons Section to SettingsSheet

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`

**Step 1: Add sidebarIcons case to SettingsSection enum**

Add `case sidebarIcons` to the enum, between `theme` and `aiTools`:

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, terminal, theme, sidebarIcons, aiTools, ssh, shortcuts
    // ...
}
```

Add the corresponding `title`, `subtitle`, and `icon`:

```swift
case .sidebarIcons: return String(localized: "Sidebar Icons")
// subtitle:
case .sidebarIcons: return String(localized: "Default icons for workspaces and worktrees")
// icon:
case .sidebarIcons: return "paintpalette"
```

**Step 2: Add SidebarIconsSettingsView**

Create a new private view below the existing settings views:

```swift
private struct SidebarIconsSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section(String(localized: "Default Icons")) {
                SidebarIconEditorCard(
                    title: String(localized: "Repository"),
                    subtitle: String(localized: "Default icon for git repositories"),
                    icon: $settings.defaultRepositoryIcon,
                    randomizer: SidebarItemIcon.randomRepository
                )

                SidebarIconEditorCard(
                    title: String(localized: "Terminal"),
                    subtitle: String(localized: "Default icon for local terminals"),
                    icon: $settings.defaultLocalTerminalIcon,
                    randomizer: SidebarItemIcon.random
                )

                SidebarIconEditorCard(
                    title: String(localized: "Remote"),
                    subtitle: String(localized: "Default icon for remote connections"),
                    icon: $settings.defaultRemoteIcon,
                    randomizer: SidebarItemIcon.randomRepository
                )

                SidebarIconEditorCard(
                    title: String(localized: "Worktree"),
                    subtitle: String(localized: "Default icon for git worktrees"),
                    icon: $settings.defaultWorktreeIcon,
                    randomizer: SidebarItemIcon.randomRepository
                )
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 3: Wire into settingsContent**

Add the case to the switch in `settingsContent(for:)`:

```swift
case .sidebarIcons:
    SidebarIconsSettingsView(settings: $draft)
```

**Step 4: Build to verify**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat: add Sidebar Icons section to settings sheet"
```

---

### Task 11: Final Build & Visual Verification

**Step 1: Full clean build**

Run: `xcodebuild clean build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 2: Launch and verify visually**

Run: `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<hash>/Build/Products/Debug/Treemux.app`

Visual verification checklist:
- [ ] Sidebar shows colored icon tiles instead of flat SF Symbols
- [ ] Workspace icons are 22pt with gradient/solid backgrounds
- [ ] Worktree icons are 18pt, auto-generated with different colors
- [ ] Right-click a workspace → "Change Icon..." shows customization sheet
- [ ] Right-click a worktree → "Change Icon..." shows customization sheet
- [ ] Sheet: symbol picker works, style toggle works, palette grid works
- [ ] Sheet: Random button generates new icon
- [ ] Sheet: Save persists, Cancel discards, Reset clears override
- [ ] Settings → Sidebar Icons shows 4 default icon editors
- [ ] Quit and relaunch → icons are persisted correctly

**Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address visual issues from sidebar icons integration"
```
