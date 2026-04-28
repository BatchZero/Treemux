# Default Terminal Workspace — Always-Visible Design

## Problem

The built-in `~` (home directory) workspace currently appears only when no real
workspaces exist. As soon as the user adds their first project, the `~` entry
disappears, and reappears once all real workspaces are removed. This violates
user expectations: users want a permanent, always-available local terminal
entry, regardless of how many projects they have.

## Goals

- Keep the `~` workspace visible after the user creates real workspaces.
- Let the user toggle its visibility via a settings switch (default on).
- Allow the user to drag-reorder `~` among other local workspaces, with the
  position persisted across launches.
- Always show `~` as a fallback when the user has hidden it via the setting
  but has no other workspace, so the sidebar is never empty.

## Non-Goals

- Renaming `~`. Its display name remains the literal `~`.
- Customizing `~` icon beyond the existing `defaultLocalTerminalIcon` setting.
- Adding multiple built-in terminals. Exactly one.

## Approach

Promote `~` from a virtual, ephemeral object into a real, persisted workspace
that lives in the `workspaces` array alongside user-created entries, but is
flagged as built-in so it cannot be deleted, renamed, or archived. A settings
toggle filters it out of the sidebar; an empty-fallback rule overrides that
filter when no other workspace exists.

This approach was chosen over two alternatives:

- **Keep virtual + standalone sort index in settings**: simpler data model,
  but drag/drop logic must reconcile two data sources, and integer indices
  drift when other workspaces are added or removed.
- **Keep virtual + neighbor anchor**: more stable position, but adds
  fallback complexity when the anchor workspace is deleted, and offers no
  meaningful gain over the chosen approach.

Promoting to a real workspace lets the existing drag/drop, persistence,
and ordering machinery apply to `~` with zero modifications.

## Data Model Changes

### `WorkspaceModel`

Add:

- `static let builtInDefaultTerminalID: UUID` — fixed constant
  (e.g. `00000000-0000-0000-0000-00000000007E`).
- `var isBuiltInDefaultTerminal: Bool` — defaults to `false`. `Codable`
  decoding treats missing key as `false`.

### `AppSettings`

Add:

- `var showDefaultTerminal: Bool` — defaults to `true`. `Codable` decoding
  treats missing key as `true` so existing users see `~` after upgrade.

### `WorkspaceStore` removals

Remove the virtual scaffolding now that `~` is real:

- Property `defaultTerminalWorkspace`
- Method `ensureDefaultTerminal()`
- Fallback branches in `selectedWorkspace`, `sidebarWorkspaces`,
  `localWorkspaces`, and `removeWorkspace(_:)` that return the virtual
  workspace.

## Startup Migration (`WorkspaceStore.init()`)

After loading persisted state and before scheduling watchers:

1. Find all entries in `workspaces` with `isBuiltInDefaultTerminal == true`.
2. If zero, append a new built-in `~` workspace at the end of `workspaces`
   (UUID = `builtInDefaultTerminalID`, `kind = .localTerminal`,
   `repositoryRoot = NSHomeDirectory()`, `name = "~"`,
   `isBuiltInDefaultTerminal = true`).
3. If more than one, keep the first by array position and remove the rest.
4. Force `isArchived = false` and overwrite `repositoryRoot` with the current
   home directory (defends against cross-machine state sync where the home
   path differs).
5. Persist if any of the above mutated state.

## Sidebar Filtering Logic

`localWorkspaces` (and analogous adjustment in `sidebarWorkspaces`):

```
let real = workspaces.filter { !$0.isArchived && $0.sshTarget == nil }
guard !settings.showDefaultTerminal else { return real }
let withoutBuiltin = real.filter { !$0.isBuiltInDefaultTerminal }
return withoutBuiltin.isEmpty ? real : withoutBuiltin
```

Remote sections are unaffected — `~` is local-only.

## Selection Behavior on Toggle

When `showDefaultTerminal` transitions from `true` to `false` and
`selectedWorkspaceID == builtInDefaultTerminalID`:

- If at least one non-builtin workspace exists, switch selection to the
  first such entry in `workspaces`.
- Otherwise, leave selection unchanged. The fallback rule will keep `~`
  visible in the sidebar, so the UI remains consistent.

## Drag & Drop

No code changes. `~` participates in `localWorkspaces` like any other entry,
so the existing `SidebarCoordinator` `pasteboardWriterForItem` /
`validateDrop` / `acceptDrop` path covers it. `moveLocalWorkspace` reorders
the underlying `workspaces` array, and the array's order is the persistence
mechanism — order survives restarts automatically.

## Defensive Operation Guards

- `removeWorkspace(_:)`: early return if the id matches a built-in entry.
- `renameWorkspace(_:, to:)`: early return for built-in entries.
- Built-in entries skip git metadata watching (already implicit because
  `kind == .localTerminal` and `repositoryRoot` is not a git repo, but the
  guard in `startWatching` should be reviewed to confirm).

## Settings UI

Add a toggle to the existing settings panel (placed in the General /
Appearance section that best fits current layout):

- Toggle label: `Show Default Terminal (~)` (zh-Hans: `显示默认终端 (~)`)
- Footer hint: `Always shown when no other workspace exists.`
  (zh-Hans: `当不存在其他 workspace 时始终显示。`)

Both strings must be added to `Treemux/Localizable.xcstrings`.

## Persistence Compatibility

- Old JSON state without `isBuiltInDefaultTerminal` decodes existing entries
  as non-builtin and the migration appends a fresh built-in.
- Old `AppSettings` JSON without `showDefaultTerminal` decodes as `true`,
  preserving the always-visible default.
- Built-in entries serialize alongside other workspaces in the same array;
  no schema version bump required.

## Error Handling Summary

| Scenario | Behavior |
|---|---|
| Old JSON without builtin | Migration appends one |
| Multiple builtin entries (corrupt state) | Keep first, drop the rest |
| Builtin marked archived | Reset to `isArchived = false` |
| `removeWorkspace(builtin)` | Silent early return |
| `renameWorkspace(builtin, …)` | Silent early return |
| Toggle off, builtin selected, no real ws | Keep selection (fallback shows `~`) |
| Toggle off, builtin selected, real ws exists | Switch to first real ws |
| Cross-machine sync, different `$HOME` | Overwrite `repositoryRoot` on launch |

## Testing

### Unit (XCTest)

`WorkspaceModelsTests`:

- `isBuiltInDefaultTerminal` round-trip via `Codable`.
- Decoding legacy JSON without the field yields `false`.

`PersistenceTests`:

- Loading state without builtin → after `WorkspaceStore.init`, exactly one
  builtin appears in `workspaces`.
- Loading state with two builtins → after init, exactly one remains
  (the first).

`WorkspaceStore` tests:

- `showDefaultTerminal == true`, real ws present → `localWorkspaces`
  includes builtin.
- `showDefaultTerminal == false`, real ws present → builtin filtered out.
- `showDefaultTerminal == false`, no real ws → fallback retains builtin.
- Toggling off while builtin selected and real ws exists → selection moves.
- `removeWorkspace(builtinID)` is a no-op.
- `renameWorkspace(builtinID, …)` is a no-op.
- `moveLocalWorkspace` repositions builtin and order survives encode →
  decode round-trip.

### Manual Verification

1. Fresh launch (no state) → `~` visible.
2. Add a project → `~` still in sidebar.
3. Toggle off in settings → `~` disappears, selection moves if needed.
4. Remove all real projects → `~` reappears via fallback.
5. Restart app → `~` retains its drag-reordered position.
6. Drag `~` between two real projects → position persists across restart.
7. Switch language between en and zh-Hans → settings copy is correct.

## Out-of-Scope / Follow-ups

- Multi-instance built-in terminals (e.g. one per disk volume).
- Per-workspace `cwd` override for the built-in terminal.
- Hover tooltip explaining the fallback rule (deferred — the footer hint
  is judged sufficient).
