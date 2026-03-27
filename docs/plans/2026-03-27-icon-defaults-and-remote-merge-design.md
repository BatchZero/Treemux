# Icon Defaults Removal & Remote → Repository Merge

**Date:** 2026-03-27
**Status:** Approved

## Problem

The current icon system has global default icons for Repository, Terminal, Remote, and Worktree. This creates unnecessary rigidity — repositories and worktrees already have a sophisticated deterministic random generation system that produces visually distinct, semantically meaningful icons. The global defaults override this.

Additionally, "Remote" as a separate workspace kind is a false distinction — a remote SSH connection that opens a repository is still a repository. The model should reflect this.

## Design

### Part 1: Model Refactoring — Merge Remote into Repository

**`WorkspaceKindRecord`**: Remove `.remote`, keep `.repository` and `.localTerminal`.

```swift
enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal
}
```

Distinguish local vs remote repositories via the existing `sshTarget: SSHTarget?` property:
- `kind == .repository && sshTarget == nil` → local repo
- `kind == .repository && sshTarget != nil` → remote repo

**Data migration**: When reading `workspacestate.json`, map `"remote"` kind to `.repository` automatically. The `sshTarget` field is already present and requires no migration.

**Sidebar grouping**: `remoteWorkspaceGroups` filter changes from `kind == .remote` to `kind == .repository && sshTarget != nil`.

### Part 2: Icon Default Logic

**`AppSettings`**: Remove 3 fields, keep only `defaultLocalTerminalIcon`.

```swift
struct AppSettings: Codable, Equatable {
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
}
```

**Static defaults cleanup**: Remove `.repositoryDefault`, `.remoteDefault`, `.worktreeDefault` as global defaults. Retain internal fallback values within the generation algorithm as needed.

**Workspace icon resolution (`sidebarIcon(for:)`):**
1. Per-workspace override → use it
2. `kind == .localTerminal` → use `settings.defaultLocalTerminalIcon`
3. `kind == .repository` → deterministic random generation (seeded by repo name, avoiding existing icons)

**Worktree icon resolution (`sidebarIcon(for:in:)`):**
1. Per-worktree override → use it
2. Deterministic random generation (remove the global default interception at line 383-385)

**`SidebarIconCustomizationTarget`**: Remove `.appDefaultRepository`, `.appDefaultRemote`, `.appDefaultWorktree`. Keep `.appDefaultLocalTerminal`, `.workspace(UUID)`, `.worktree(workspaceID:worktreePath:)`.

### Part 3: Settings Panel — Sidebar Icons Tab

**Layout:**

```
┌─ Default ──────────────────────────────┐
│  Terminal    [icon preview]        ✏️  │
└────────────────────────────────────────┘

┌─ {repo name} ──────────────────────────┐
│  {repo}      [icon preview]        ✏️  │
│  ├─ {branch} [icon preview]        ✏️  │
│  └─ {branch} [icon preview]        ✏️  │
└────────────────────────────────────────┘
```

- One section per repository, with worktrees nested underneath
- Click any icon row → opens `SidebarIconCustomizationSheet`
- Save creates a per-workspace or per-worktree override
- Reset clears the override, returning to deterministic random generation
- Data source: `WorkspaceStore.workspaces` (non-archived, repository kind only)
- `.localTerminal` workspaces do not appear in the instance list
- Empty state: if no repositories are open, only the Default section with Terminal is shown

## Files Affected

| File | Changes |
|------|---------|
| `Domain/WorkspaceModels.swift` | Remove `.remote` from `WorkspaceKindRecord` |
| `Domain/AppSettings.swift` | Remove 3 default icon fields |
| `Domain/SidebarIcon.swift` | Remove `.repositoryDefault`, `.remoteDefault`, `.worktreeDefault` as public defaults |
| `App/WorkspaceStore.swift` | Update icon resolution, remote grouping filter, customization targets |
| `UI/Settings/SettingsSheet.swift` | Rebuild Sidebar Icons tab with instance-level icon manager |
| `UI/Sheets/SidebarIconCustomizationSheet.swift` | Remove app-default-related targets |
| `UI/Sidebar/WorkspaceSidebarView.swift` | Update any `.remote` references |
| `UI/Sheets/OpenProjectSheet.swift` | Update workspace creation to use `.repository` for remote |
| `Persistence/AppSettingsPersistence.swift` | Handle migration of removed fields |
| `Persistence/WorkspaceStatePersistence.swift` | Handle `"remote"` → `.repository` migration |
