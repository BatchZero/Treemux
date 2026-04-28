# Default Terminal Always-Visible Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Promote the virtual `~` workspace into a built-in persistent workspace that remains visible after the user adds projects, can be toggled in Settings, supports drag-reordering, and falls back to always-visible when no other workspace exists.

**Architecture:** Add a fixed-UUID built-in entry to the persisted `workspaces` array tagged via `isBuiltInDefaultTerminal: Bool`. A new `AppSettings.showDefaultTerminal` toggle filters it from the sidebar; an emptiness fallback overrides the filter. Drag/drop and persistence reuse existing machinery unchanged. Defensive guards block rename/remove of the built-in entry.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSOutlineView` for sidebar drag/drop), XCTest, Xcode `Localizable.xcstrings`.

**Reference design:** `docs/plans/2026-04-28-default-terminal-always-visible-design.md`

---

## Task 1: Add `isBuiltInDefaultTerminal` to `WorkspaceRecord` and `WorkspaceModel`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift`
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

This task adds the new persisted field, the fixed-UUID constant, and a custom `Codable` decoder so legacy JSON without the field decodes as `false`. Tests are written first.

**Step 1: Write the failing tests**

Open `TreemuxTests/WorkspaceModelsTests.swift` and append two tests at the end of the class (just before the closing `}`):

```swift
    // MARK: - Built-in Default Terminal Tests

    func testWorkspaceRecordBuiltInFlagRoundTrip() throws {
        let record = WorkspaceRecord(
            id: WorkspaceModel.builtInDefaultTerminalID,
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertTrue(decoded.isBuiltInDefaultTerminal)
        XCTAssertEqual(decoded.id, WorkspaceModel.builtInDefaultTerminalID)
    }

    func testWorkspaceRecordLegacyDecodingDefaultsBuiltInFalse() throws {
        // Old JSON without isBuiltInDefaultTerminal field
        let json = """
        {"id":"00000000-0000-0000-0000-000000000099","kind":"repository","name":"proj","isPinned":false,"isArchived":false,"worktreeStates":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertFalse(decoded.isBuiltInDefaultTerminal)
    }
```

**Step 2: Run tests to verify they fail**

Run from the worktree root:

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests/testWorkspaceRecordBuiltInFlagRoundTrip 2>&1 | tail -30
```

Expected: build error referencing missing `isBuiltInDefaultTerminal` argument and missing `WorkspaceModel.builtInDefaultTerminalID`.

**Step 3: Add the constant and the field**

In `Treemux/Domain/WorkspaceModels.swift`:

a. Add a fixed UUID constant on `WorkspaceModel`. Find the line that opens the class:

```
@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    let id: UUID
    let kind: WorkspaceKindRecord
```

Insert just below the `final class WorkspaceModel...` opening line (around line 173):

```swift
    /// Stable UUID for the single built-in `~` (home directory) terminal entry.
    /// Persisted alongside user-created workspaces so its sidebar order survives launches.
    static let builtInDefaultTerminalID = UUID(uuidString: "00000000-0000-0000-0000-00000000007E")!
```

b. Add `isBuiltInDefaultTerminal` to `WorkspaceRecord` (struct around line 31). Replace the existing struct definition with:

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
    /// Persisted display order of worktrees (paths). Nil means default git order.
    let worktreeOrder: [String]?
    /// User-customized sidebar icon for this workspace.
    let workspaceIcon: SidebarItemIcon?
    /// Per-worktree icon overrides, keyed by worktree path.
    let worktreeIconOverrides: [String: SidebarItemIcon]?
    /// True for the single built-in home-directory terminal entry. Defaults to false for
    /// every user-created workspace and decodes as false when absent in legacy JSON.
    let isBuiltInDefaultTerminal: Bool

    init(
        id: UUID,
        kind: WorkspaceKindRecord,
        name: String,
        repositoryPath: String?,
        isPinned: Bool,
        isArchived: Bool,
        sshTarget: SSHTarget?,
        worktreeStates: [WorktreeSessionStateRecord],
        worktreeOrder: [String]?,
        workspaceIcon: SidebarItemIcon?,
        worktreeIconOverrides: [String: SidebarItemIcon]?,
        isBuiltInDefaultTerminal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.repositoryPath = repositoryPath
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sshTarget = sshTarget
        self.worktreeStates = worktreeStates
        self.worktreeOrder = worktreeOrder
        self.workspaceIcon = workspaceIcon
        self.worktreeIconOverrides = worktreeIconOverrides
        self.isBuiltInDefaultTerminal = isBuiltInDefaultTerminal
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, repositoryPath, isPinned, isArchived, sshTarget,
             worktreeStates, worktreeOrder, workspaceIcon, worktreeIconOverrides,
             isBuiltInDefaultTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(WorkspaceKindRecord.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        repositoryPath = try c.decodeIfPresent(String.self, forKey: .repositoryPath)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        sshTarget = try c.decodeIfPresent(SSHTarget.self, forKey: .sshTarget)
        worktreeStates = try c.decodeIfPresent([WorktreeSessionStateRecord].self, forKey: .worktreeStates) ?? []
        worktreeOrder = try c.decodeIfPresent([String].self, forKey: .worktreeOrder)
        workspaceIcon = try c.decodeIfPresent(SidebarItemIcon.self, forKey: .workspaceIcon)
        worktreeIconOverrides = try c.decodeIfPresent([String: SidebarItemIcon].self, forKey: .worktreeIconOverrides)
        isBuiltInDefaultTerminal = try c.decodeIfPresent(Bool.self, forKey: .isBuiltInDefaultTerminal) ?? false
    }
}
```

c. Add `isBuiltInDefaultTerminal` to the runtime `WorkspaceModel` and propagate through both initializers and `toRecord()`.

In the `@Published` block (around line 190), add after `worktreeIconOverrides`:

```swift
    /// True for the single built-in home-directory terminal entry. Read-only at runtime — set during init.
    let isBuiltInDefaultTerminal: Bool
```

In the designated `init(...)` (around line 233), append a parameter before the closing `)` and initialize:

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
        workspaceIcon: SidebarItemIcon? = nil,
        worktreeIconOverrides: [String: SidebarItemIcon] = [:],
        isBuiltInDefaultTerminal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.repositoryRoot = repositoryRoot
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sshTarget = sshTarget
        self.worktreeOrder = worktreeOrder
        self.workspaceIcon = workspaceIcon
        self.worktreeIconOverrides = worktreeIconOverrides
        self.isBuiltInDefaultTerminal = isBuiltInDefaultTerminal
        // ... existing body (workingDirectory, default tab) unchanged
```

In the convenience `init(from record:)` (around line 265), pass it through:

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
            worktreeIconOverrides: record.worktreeIconOverrides ?? [:],
            isBuiltInDefaultTerminal: record.isBuiltInDefaultTerminal
        )
        restoreTabState(from: record.worktreeStates)
    }
```

In `toRecord()` (around line 525), add the field to the returned record:

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
            worktreeIconOverrides: worktreeIconOverrides.isEmpty ? nil : worktreeIconOverrides,
            isBuiltInDefaultTerminal: isBuiltInDefaultTerminal
        )
```

**Step 4: Update existing test call sites that construct `WorkspaceRecord`**

Search for all `WorkspaceRecord(` occurrences in the test target:

```bash
grep -n "WorkspaceRecord(" TreemuxTests/*.swift
```

Each existing call already passes positional arguments through `worktreeIconOverrides: nil`. Because we added `isBuiltInDefaultTerminal` with a default value of `false` in the struct's `init`, existing call sites keep compiling. No edits required there.

**Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20
```

Expected: all `WorkspaceModelsTests` pass, including the two new built-in tests.

**Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: add isBuiltInDefaultTerminal field to workspace record/model"
```

---

## Task 2: Add `showDefaultTerminal` setting to `AppSettings`

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift`
- Modify: `TreemuxTests/PersistenceTests.swift`

**Step 1: Write the failing tests**

Append to `TreemuxTests/PersistenceTests.swift`, before the final `}`:

```swift
    func testAppSettingsShowDefaultTerminalDefaultsTrue() {
        let settings = AppSettings()
        XCTAssertTrue(settings.showDefaultTerminal)
    }

    func testAppSettingsShowDefaultTerminalLegacyJSONDefaultsTrue() throws {
        // Old settings JSON without showDefaultTerminal must decode with showDefaultTerminal == true
        let json = """
        {"version":1,"language":"system","activeThemeID":"treemux-dark","appearance":"system","terminal":{"defaultShell":"/bin/zsh","fontSize":14,"cursorStyle":"bar"},"startup":{"restoreLastSession":true},"ssh":{"configPaths":["~/.ssh/config"]},"shortcutOverrides":{},"defaultLocalTerminalIcon":{"kind":"localTerminalDefault"},"updates":{"automaticallyChecksForUpdates":true,"automaticallyDownloadsUpdates":false}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.showDefaultTerminal)
    }
```

> Note: the exact JSON shape of `defaultLocalTerminalIcon` may differ. If the legacy decode fails on the icon shape rather than the new field, copy the icon JSON from `~/.treemux-debug/settings.json` after a fresh launch and substitute it into the test. The point of the test is: legacy JSON without `showDefaultTerminal` decodes with `showDefaultTerminal == true`.

**Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/PersistenceTests/testAppSettingsShowDefaultTerminalDefaultsTrue 2>&1 | tail -10
```

Expected: build error — `showDefaultTerminal` not a member of `AppSettings`.

**Step 3: Implement the field**

In `Treemux/Domain/AppSettings.swift`, modify `AppSettings`:

```swift
struct AppSettings: Codable, Equatable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var appearance: String = "system"  // "system", "dark", "light"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var shortcutOverrides: [String: ShortcutOverride] = [:]
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
    var updates: UpdateSettings = UpdateSettings()
    /// Controls whether the built-in `~` terminal workspace appears in the sidebar.
    /// True by default. When false and at least one other workspace exists, `~` is filtered out.
    /// When false and no other workspace exists, the filter is overridden as a fallback so the sidebar is never empty.
    var showDefaultTerminal: Bool = true

    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "system"
        activeThemeID = try c.decodeIfPresent(String.self, forKey: .activeThemeID) ?? "treemux-dark"
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        terminal = try c.decodeIfPresent(TerminalSettings.self, forKey: .terminal) ?? TerminalSettings()
        startup = try c.decodeIfPresent(StartupSettings.self, forKey: .startup) ?? StartupSettings()
        ssh = try c.decodeIfPresent(SSHSettings.self, forKey: .ssh) ?? SSHSettings()
        shortcutOverrides = try c.decodeIfPresent([String: ShortcutOverride].self, forKey: .shortcutOverrides) ?? [:]
        defaultLocalTerminalIcon = try c.decodeIfPresent(SidebarItemIcon.self, forKey: .defaultLocalTerminalIcon) ?? .localTerminalDefault
        updates = try c.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? UpdateSettings()
        showDefaultTerminal = try c.decodeIfPresent(Bool.self, forKey: .showDefaultTerminal) ?? true
    }
}
```

> Why explicit `CodingKeys` + `init(from:)`: previously the struct used Swift's synthesized `Codable`, which fails when *any* required key is missing. By making decode explicit and using `decodeIfPresent ?? defaultValue` for every field, legacy JSON without the new key still decodes cleanly. The synthesized encoder is still fine — Swift will continue to synthesize `encode(to:)` against `CodingKeys`.

**Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/PersistenceTests 2>&1 | tail -20
```

Expected: every `PersistenceTests` test passes including the two new ones.

**Step 5: Commit**

```bash
git add Treemux/Domain/AppSettings.swift TreemuxTests/PersistenceTests.swift
git commit -m "feat: add showDefaultTerminal setting (default true) with legacy decode fallback"
```

---

## Task 3: WorkspaceStore — startup migration & remove virtual scaffolding

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `TreemuxTests/PersistenceTests.swift` (or a new test file `TreemuxTests/WorkspaceStoreBuiltInTests.swift`)

This task replaces the virtual `defaultTerminalWorkspace` with a real entry inserted into `workspaces` at startup.

**Step 1: Write the failing tests**

Create `TreemuxTests/WorkspaceStoreBuiltInTests.swift`:

```swift
//
//  WorkspaceStoreBuiltInTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

@MainActor
final class WorkspaceStoreBuiltInTests: XCTestCase {

    /// Helper: writes a state JSON file before WorkspaceStore.init reads it.
    private func writeState(_ state: PersistedWorkspaceState) throws {
        let dir = treemuxStateDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace-state.json")
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func clearState() throws {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    override func setUp() async throws {
        try clearState()
    }

    override func tearDown() async throws {
        try clearState()
    }

    func testInitInsertsBuiltInWhenAbsent() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].id, WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertTrue(store.workspaces[0].isBuiltInDefaultTerminal)
        XCTAssertEqual(store.workspaces[0].name, "~")
    }

    func testInitDeduplicatesBuiltInEntries() async throws {
        // Two built-in entries in persisted state — should deduplicate to one.
        let builtinA = WorkspaceRecord(
            id: WorkspaceModel.builtInDefaultTerminalID,
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        // Second copy with a different UUID but still flagged
        let builtinB = WorkspaceRecord(
            id: UUID(),
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [builtinA, builtinB]))
        let store = WorkspaceStore()
        let builtins = store.workspaces.filter { $0.isBuiltInDefaultTerminal }
        XCTAssertEqual(builtins.count, 1)
    }

    func testInitForcesBuiltInUnarchived() async throws {
        let archived = WorkspaceRecord(
            id: WorkspaceModel.builtInDefaultTerminalID,
            kind: .localTerminal,
            name: "~",
            repositoryPath: NSHomeDirectory(),
            isPinned: false,
            isArchived: true, // erroneously archived
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: true
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [archived]))
        let store = WorkspaceStore()
        let builtin = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })
        XCTAssertNotNil(builtin)
        XCTAssertFalse(builtin?.isArchived ?? true)
    }

    func testLocalWorkspacesIncludesBuiltInWhenToggleOn() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = true
        XCTAssertTrue(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
    }

    func testLocalWorkspacesFiltersBuiltInWhenToggleOffAndRealExists() async throws {
        let real = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "real",
            repositoryPath: "/tmp/real",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: false
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [real]))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = false
        XCTAssertFalse(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
        XCTAssertTrue(store.localWorkspaces.contains { $0.name == "real" })
    }

    func testLocalWorkspacesFallbackKeepsBuiltInWhenToggleOffAndNoOtherWorkspace() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.settings.showDefaultTerminal = false
        // Only the built-in exists → fallback rule keeps it visible.
        XCTAssertTrue(store.localWorkspaces.contains { $0.isBuiltInDefaultTerminal })
    }
}
```

> Note on test isolation: these tests touch the real state directory on disk (debug builds use `~/.treemux-debug`). The setUp/tearDown wipe-and-rewrite pattern keeps tests deterministic. If the existing test suite has a different convention for state isolation, follow that; otherwise the above is the simplest reliable approach.

**Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreBuiltInTests 2>&1 | tail -30
```

Expected: tests compile but most fail because the migration logic doesn't exist yet (e.g. `workspaces.count == 0` rather than `1` for the empty-state case).

**Step 3: Add the migration logic to `WorkspaceStore.init()`**

In `Treemux/App/WorkspaceStore.swift`:

a. Replace the property at line 67-69:

```
    /// Virtual "Terminal" workspace shown when no real projects exist.
    /// This workspace is never persisted to disk.
    private var defaultTerminalWorkspace: WorkspaceModel?
```

with: *(remove these lines entirely — no replacement)*

b. Replace the `selectedWorkspace` computed property block (lines 74-88):

```swift
    /// The currently selected workspace, if any.
    /// Resolves both workspace-level and worktree-level selection.
    var selectedWorkspace: WorkspaceModel? {
        if let ws = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return ws
        }
        // Check if selection is a worktree ID within any workspace
        if let ws = workspaces.first(where: { ws in
            ws.worktrees.contains { $0.id == self.selectedWorkspaceID }
        }) {
            return ws
        }
        return nil
    }
```

c. Replace `sidebarWorkspaces` (lines 113-119) and `localWorkspaces` (lines 122-128) with:

```swift
    /// Workspaces visible in the sidebar (non-archived).
    /// Honors `settings.showDefaultTerminal`. When the toggle is off and at least
    /// one non-builtin workspace exists, the built-in `~` is hidden. When the toggle
    /// is off and no other workspace exists, the toggle is overridden so the sidebar
    /// is never empty.
    var sidebarWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived }
        return applyDefaultTerminalFilter(to: real)
    }

    /// Local workspaces (repositories and local terminals, non-archived).
    /// Same filtering rules as `sidebarWorkspaces`.
    var localWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived && $0.sshTarget == nil }
        return applyDefaultTerminalFilter(to: real)
    }

    /// Applies the `showDefaultTerminal` filter with empty-fallback override.
    private func applyDefaultTerminalFilter(to list: [WorkspaceModel]) -> [WorkspaceModel] {
        if settings.showDefaultTerminal { return list }
        let withoutBuiltin = list.filter { !$0.isBuiltInDefaultTerminal }
        return withoutBuiltin.isEmpty ? list : withoutBuiltin
    }
```

d. Replace `init()` (line 141-146) with:

```swift
    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
        ensureBuiltInDefaultTerminal()
        startRemoteWorkspaceRefreshScheduler()
    }
```

e. Replace `ensureDefaultTerminal()` (lines 148-166) with the new migration logic:

```swift
    /// Ensures exactly one built-in `~` workspace exists in `workspaces`. Inserts one if absent,
    /// deduplicates if multiple exist (keeping the first), and resets defensive state
    /// (archived flag, repositoryRoot) on the surviving entry. Persists if any mutation occurred.
    private func ensureBuiltInDefaultTerminal() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let builtins = workspaces.filter { $0.isBuiltInDefaultTerminal }
        var mutated = false

        if builtins.isEmpty {
            let builtin = WorkspaceModel(
                id: WorkspaceModel.builtInDefaultTerminalID,
                name: "~",
                kind: .localTerminal,
                repositoryRoot: homeURL,
                isBuiltInDefaultTerminal: true
            )
            workspaces.append(builtin)
            mutated = true
        } else if builtins.count > 1 {
            // Keep the first; drop the rest.
            let firstBuiltinID = builtins[0].id
            workspaces.removeAll { $0.isBuiltInDefaultTerminal && $0.id != firstBuiltinID }
            mutated = true
        }

        // Defensive state reset on the surviving built-in.
        if let builtin = workspaces.first(where: { $0.isBuiltInDefaultTerminal }) {
            if builtin.isArchived {
                builtin.isArchived = false
                mutated = true
            }
            if builtin.repositoryRoot != homeURL {
                builtin.repositoryRoot = homeURL
                mutated = true
            }
            if builtin.name != "~" {
                builtin.name = "~"
                mutated = true
            }
        }

        if mutated {
            saveWorkspaceState()
        }
    }
```

f. Update `removeWorkspace` (lines 304-323) to drop the obsolete `defaultTerminalWorkspace` references and the `ensureDefaultTerminal()` call. Replace it entirely with:

```swift
    func removeWorkspace(_ id: UUID) {
        // Defensive: never remove the built-in. Silent early return.
        if id == WorkspaceModel.builtInDefaultTerminalID { return }

        metadataWatcher.stopWatching(workspaceID: id)
        // Clear selection if it points to a worktree within this workspace
        if let ws = workspaces.first(where: { $0.id == id }),
           ws.worktrees.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = nil
        }
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id || selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        saveWorkspaceState()
    }
```

g. Update `saveWorkspaceState()` (lines 503-522). Remove the line that excluded the virtual workspace:

```
        // Exclude the default terminal workspace from persistence — it is virtual.
        let persistedSelectedID = resolvedID == defaultTerminalWorkspace?.id ? nil : resolvedID
```

Replace with:

```swift
        let persistedSelectedID = resolvedID
```

**Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreBuiltInTests 2>&1 | tail -30
```

Expected: all six new tests pass.

**Step 5: Run the full test suite to confirm no regressions**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: zero failures.

**Step 6: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift TreemuxTests/WorkspaceStoreBuiltInTests.swift
git commit -m "feat: persist built-in ~ terminal workspace and add visibility filter"
```

---

## Task 4: Defensive guards on rename + selection switching when toggle flips off

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `TreemuxTests/WorkspaceStoreBuiltInTests.swift`

**Step 1: Write the failing tests**

Append to `WorkspaceStoreBuiltInTests`:

```swift
    func testRenameBuiltInIsNoOp() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        let originalName = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })?.name
        store.renameWorkspace(WorkspaceModel.builtInDefaultTerminalID, to: "renamed")
        let after = store.workspaces.first(where: { $0.isBuiltInDefaultTerminal })?.name
        XCTAssertEqual(after, originalName)
        XCTAssertEqual(after, "~")
    }

    func testRemoveBuiltInIsNoOp() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        XCTAssertTrue(store.workspaces.contains { $0.isBuiltInDefaultTerminal })
        store.removeWorkspace(WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertTrue(store.workspaces.contains { $0.isBuiltInDefaultTerminal })
    }

    func testTogglingOffMovesSelectionAwayFromBuiltInWhenRealExists() async throws {
        let real = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "real",
            repositoryPath: "/tmp/real",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil,
            isBuiltInDefaultTerminal: false
        )
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [real]))
        let store = WorkspaceStore()
        store.selectedWorkspaceID = WorkspaceModel.builtInDefaultTerminalID

        // Flip the toggle via updateSettings (mirrors what SettingsSheet does)
        var newSettings = store.settings
        newSettings.showDefaultTerminal = false
        store.updateSettings(newSettings)

        XCTAssertNotEqual(store.selectedWorkspaceID, WorkspaceModel.builtInDefaultTerminalID)
        XCTAssertEqual(store.selectedWorkspaceID, real.id)
    }

    func testTogglingOffKeepsBuiltInSelectionWhenNoRealExists() async throws {
        try writeState(PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: []))
        let store = WorkspaceStore()
        store.selectedWorkspaceID = WorkspaceModel.builtInDefaultTerminalID

        var newSettings = store.settings
        newSettings.showDefaultTerminal = false
        store.updateSettings(newSettings)

        // No real workspace → selection unchanged; fallback shows ~ in sidebar.
        XCTAssertEqual(store.selectedWorkspaceID, WorkspaceModel.builtInDefaultTerminalID)
    }
```

**Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreBuiltInTests 2>&1 | tail -30
```

Expected: rename guard test fails (no current early return), the toggle-flip tests fail (no selection-handling code).

**Step 3: Add rename guard**

In `Treemux/App/WorkspaceStore.swift`, replace `renameWorkspace` (lines 239-244):

```swift
    func renameWorkspace(_ id: UUID, to newName: String) {
        // Defensive: built-in `~` is not renameable. Silent early return.
        if id == WorkspaceModel.builtInDefaultTerminalID { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        workspace.name = newName
        saveWorkspaceState()
    }
```

**Step 4: Add selection-switching to `updateSettings`**

Modify `updateSettings` (lines 31-38):

```swift
    /// Applies a new settings snapshot (used by SettingsSheet Save).
    func updateSettings(_ newSettings: AppSettings) {
        let terminalChanged = settings.terminal != newSettings.terminal
        let toggledOff = settings.showDefaultTerminal && !newSettings.showDefaultTerminal
        settings = newSettings
        if terminalChanged {
            NotificationCenter.default.post(name: .treemuxTerminalSettingsDidChange, object: newSettings.terminal)
        }
        if toggledOff && selectedWorkspaceID == WorkspaceModel.builtInDefaultTerminalID {
            // Switch to the first non-builtin workspace if any exists. If none, leave selection alone —
            // the empty-fallback rule will keep `~` visible in the sidebar so the UI stays consistent.
            if let firstReal = workspaces.first(where: { !$0.isBuiltInDefaultTerminal && !$0.isArchived }) {
                selectedWorkspaceID = firstReal.id
            }
        }
    }
```

**Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceStoreBuiltInTests 2>&1 | tail -20
```

Expected: all `WorkspaceStoreBuiltInTests` pass.

**Step 6: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift TreemuxTests/WorkspaceStoreBuiltInTests.swift
git commit -m "feat: guard built-in ~ from rename/remove and switch selection on toggle off"
```

---

## Task 5: Settings UI — toggle in General section + localization

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add toggle to `GeneralSettingsView`**

In `Treemux/UI/Settings/SettingsSheet.swift`, replace `GeneralSettingsView` (lines 158-176):

```swift
private struct GeneralSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Picker("Language", selection: $settings.language) {
                Text("Follow System").tag("system")
                Text("English").tag("en")
                Text("中文").tag("zh-Hans")
            }

            Picker("On Startup", selection: $settings.startup.restoreLastSession) {
                Text("Restore Last Session").tag(true)
                Text("Blank Window").tag(false)
            }

            Section {
                Toggle("Show Default Terminal (~)", isOn: $settings.showDefaultTerminal)
            } footer: {
                Text("Always shown when no other workspace exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 2: Add localization entries**

In `Treemux/Localizable.xcstrings`, find the `"Default Terminal Icon"` entry (around line 824) and insert two new entries before or after it (the file is JSON — add as siblings of existing string entries inside `"strings"` object). Append:

```json
    "Show Default Terminal (~)" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "显示默认终端 (~)"
          }
        }
      }
    },
    "Always shown when no other workspace exists." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "当不存在其他 workspace 时始终显示。"
          }
        }
      }
    },
```

> Place them anywhere inside the `"strings"` object. The Xcode string catalog editor will sort them alphabetically next time it opens; that's fine.

**Step 3: Build to ensure no syntax errors**

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

**Step 4: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift Treemux/Localizable.xcstrings
git commit -m "feat: add Show Default Terminal toggle to General settings"
```

---

## Task 6: Manual verification

After Task 5 completes, build and verify the feature end-to-end. Get the current DerivedData folder number first:

```bash
ls -td ~/Library/Developer/Xcode/DerivedData/Treemux-* | head -1
```

Take note of the suffix (e.g. `Treemux-abc123def456`). Then build and run:

```bash
xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5
rm -rf ~/.treemux-debug/
open ~/Library/Developer/Xcode/DerivedData/Treemux-<suffix>/Build/Products/Debug/Treemux.app
```

**Verify each of the following manually:**

1. ☐ Fresh launch (no state) shows `~` in the sidebar.
2. ☐ Add a project via `Add Workspace…` — both `~` and the new project remain visible.
3. ☐ Open Settings → General → toggle `Show Default Terminal (~)` off → click Save. `~` disappears. If `~` was selected, selection moved to the project.
4. ☐ Remove the project (right-click → Remove). `~` reappears (fallback override).
5. ☐ Re-add the project. `~` is hidden again (toggle is still off).
6. ☐ Toggle setting back on. `~` reappears.
7. ☐ Quit app, relaunch — toggle state and `~` visibility match what you left.
8. ☐ Drag `~` between two real local workspaces. Quit and relaunch — `~` retains its dragged position.
9. ☐ Right-click `~`: "Remove" / "Rename" actions either are unavailable or are no-ops (sidebar contents unchanged after attempting them).
10. ☐ Switch language: Settings → General → Language → 中文 → Save. The toggle label reads `显示默认终端 (~)` and the footer reads `当不存在其他 workspace 时始终显示。`

**If any check fails, revert the build artifact, identify the broken task, fix it, run the full test suite, and re-verify the failing checks.**

---

## Out-of-Scope Reminders

- No multi-instance built-in terminals.
- No tooltip on the toggle explaining the fallback (footer text suffices).
- No icon change for `~` — existing `defaultLocalTerminalIcon` setting still works.
- No DB / schema version bump — the new fields decode safely from legacy JSON.

## Final Step: Mark complete

After all six tasks pass and manual verification is clean:

```bash
git log --oneline feat/default-terminal-always-visible
```

Confirm there are exactly 5 implementation commits + 1 design-doc commit on the branch (Tasks 1, 2, 3, 4, 5). Task 6 is verification only and produces no commits.
