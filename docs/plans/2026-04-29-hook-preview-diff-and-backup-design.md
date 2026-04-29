# Hook Preview Diff Highlighting & Manual Backup — Design

**Date:** 2026-04-29
**Status:** Approved (brainstorming complete)
**Branch:** `feat/hook-preview-diff-and-backup`

## Goal

Enhance the AI-hook install preview sheet (`HookPreviewSheet`) so users can:

1. **See exactly which lines change.** Today the sheet shows raw before/after
   columns with no visual diff cues. Highlight removed lines red and added lines
   green so the change is immediate and obvious.
2. **Manually preserve their old config files** before applying the install,
   per file, with clear success/failure feedback.

Together this lowers the cognitive cost of trusting the install action: users
can review the actual delta, and if a file is precious, capture a snapshot
before overwriting it.

## Non-Goals (v1)

- Word/character-level diff highlighting (line-level only).
- Unified-diff view (we keep the existing side-by-side layout).
- Aligned line correspondence between the two columns (each column scrolls
  independently; no synthetic blank rows to line up additions and removals).
- Auto-backup: backup is strictly user-initiated.
- Restore UI inside the app. Backups are written to a known path; users restore
  via Finder / shell themselves.
- Backup retention or pruning. Every click writes a new timestamped file; old
  backups are never deleted automatically.
- Backups for newly created files (`current == nil`). Nothing to back up.

## User-Visible Behavior

The sheet still opens from the AI Activity settings group when a user clicks
**Install / Reinstall / Update / Repair** for any provider × target. The shape
of the sheet is unchanged, but each `HookInstallChange` block now:

- Renders before/after with line-level red/green backgrounds.
- Shows a `Backup` button in the change block's header row, on the right.
  - `current == nil` → button disabled with tooltip "Nothing to back up (new file)".
  - Click → button enters `Backing up…`, then resolves to:
    - **Success:** `Backed up ✓` (disabled) plus a `Show in Finder` link button
      that reveals the saved file via `NSWorkspace.activateFileViewerSelecting`.
    - **Failure:** button returns to `Backup`; a red error line shows beneath
      it (`Backup failed: <message>`).
- The sheet's bottom bar (Cancel / Apply) is unchanged. Backup never blocks
  Apply; sequencing the two is the user's responsibility.

## Architecture

### Data flow

```
AIActivityHintsSettingsView
  └─ presents HookPreviewSheet(model: HookPreviewModel)
       ├─ HookDiff.compute(current:proposed:) → ([DiffLine], [DiffLine])
       │      (used per change to render highlighted columns)
       └─ Backup button → HookBackupService.backup(change:target:provider:)
              writes ~/.treemux/backups/<targetID>/<providerKind>/<basename>.<timestamp>
              returns HookBackupResult(localPath:timestamp:)
```

### New / modified files

| File | Type | Responsibility |
|---|---|---|
| `Treemux/UI/Sheets/HookDiff.swift` | new | Line-level diff producing `[DiffLine]` arrays for each side |
| `Treemux/Services/AITool/HookBackupService.swift` | new | Backs up a single change's `current` text to local backup directory |
| `Treemux/UI/Sheets/HookPreviewSheet.swift` | modified | Diff rendering + per-change backup state and button |
| `Treemux/Localizable.xcstrings` | modified | New strings + zh-Hans translations |
| `TreemuxTests/HookDiffTests.swift` | new | Unit tests for diff algorithm |
| `TreemuxTests/HookBackupServiceTests.swift` | new | Unit tests for backup writes |

`HookInstallChange`, `AIHookProvider`, `AIHookFileSystem`, and the per-provider
implementations are **not** modified. We only consume `HookInstallChange` data
already produced by `dryRunInstall`.

## Component Detail

### `HookDiff`

```swift
enum DiffMark {
    case unchanged
    case removed   // present in current, absent in proposed
    case added     // present in proposed, absent in current
}

struct DiffLine: Identifiable {
    let id: Int          // index within its side (used as SwiftUI ForEach id)
    let text: String
    let mark: DiffMark
}

enum HookDiff {
    /// Returns one array per side. Before contains only `.unchanged` and
    /// `.removed`; after contains only `.unchanged` and `.added`.
    static func compute(current: String?, proposed: String) -> (before: [DiffLine], after: [DiffLine])
}
```

**Algorithm.** Split both strings on `\n` (preserving empty trailing lines via
`omittingEmptySubsequences: false`). Use `newLines.difference(from: oldLines)`
from the standard library (Myers under the hood). Build:

- `removedIndices = Set(diff.removals.map { case .remove(let offset, _, _) in offset })`
- `insertedIndices = Set(diff.insertions.map { case .insert(let offset, _, _) in offset })`

Then walk each side once to assign marks by index.

**Edge cases.**

- `current == nil`: emit a single before-line `(file does not exist)` with
  mark `.unchanged` (it is a UI placeholder, not a diff entry); after lines
  are all `.added`.
- Identical inputs: every line is `.unchanged` on both sides.
- Empty proposed (degenerate, shouldn't occur): every current line is `.removed`,
  after side empty.

### `HookPreviewSheet` rendering

The change block layout becomes:

```
┌─ <change.path>             [Backup] [Show in Finder]? ┐
│  Before                    After                      │
│  ┌──────────────────┐      ┌──────────────────┐       │
│  │ unchanged line   │      │ unchanged line   │       │
│  │ - removed line   │ red  │ + added line     │ green │
│  └──────────────────┘      └──────────────────┘       │
│  Backup failed: ...                                    │  (only on failure)
└────────────────────────────────────────────────────────┘
```

Per-line styling:

| Mark | Background | Foreground | Prefix |
|---|---|---|---|
| `.unchanged` | clear | `.primary` | none |
| `.removed` | `Color.red.opacity(0.18)` | `Color.red` | `-` |
| `.added` | `Color.green.opacity(0.18)` | `Color.green` | `+` |

Each line renders as monospaced caption text inside a `LazyVStack` (so very
long files don't stall the sheet). The whole column sits inside the existing
`ScrollView` background. We do not add line numbers; the focus is on what
changed, not navigation.

Backup state (per change) lives on the sheet:

```swift
@State private var backupStates: [String: BackupState] = [:]   // keyed by change.path

enum BackupState {
    case idle
    case inProgress
    case success(URL)
    case failure(String)
}
```

Multiple clicks for the same change replace the state with the newest result;
prior backup files on disk are not removed.

### `HookBackupService`

```swift
struct HookBackupResult {
    let localPath: URL
    let timestamp: Date
}

@MainActor
final class HookBackupService {
    init(now: @escaping () -> Date = Date.init,
         home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         fm: FileManager = .default)

    func backup(
        change: HookInstallChange,
        target: HookTarget,
        provider: AIHookProvider
    ) async throws -> HookBackupResult
}
```

**Behavior.**

- Throws `HookInstallError.ioError("Nothing to back up")` when `change.current == nil`.
  (The UI path normally disables the button in this case; this is a defensive
  guard, not a primary flow.)
- Computes destination:
  ```
  <home>/.treemux/backups/<sanitizedTargetID>/<provider.kind.rawValue>/
                                       <basename>.<yyyyMMdd-HHmmss>
  ```
  - `sanitizedTargetID` = `target.id` with `:` replaced by `_`
    (`remote:user@host` → `remote_user@host`). Macs technically allow `:` in
    POSIX paths, but Finder remaps it to `/`.
  - `basename` = last path component of `change.path` (`settings.json`,
    `notify.sh`, etc.).
  - Timestamp formatted with `DateFormatter` `yyyyMMdd-HHmmss` in user's local
    timezone.
- Creates intermediate directories with `withIntermediateDirectories: true`.
- Writes `change.current!` atomically.
- Returns `HookBackupResult(localPath: …, timestamp: …)`.
- Wraps `FileManager` errors as `HookInstallError.ioError(...)` to match the
  rest of the install pipeline's error vocabulary.

The service is `@MainActor` for parity with `AIHookInstaller`; the file IO
itself is fast and synchronous, so we don't bother off-main.

### Remote targets

Remote `HookInstallChange.current` is already populated by `dryRunInstall`
(reading the remote file via `RemoteHookFileSystem`). Backup just persists
that captured string locally; **no additional SSH round-trip happens at
backup time**. This makes the user-visible Backup latency essentially
constant regardless of target.

### Testing

`HookDiffTests`:
- Identical inputs → all `.unchanged`, no `.removed` or `.added`.
- Pure additions → before all `.unchanged`, after has `.added` lines.
- Pure removals → before has `.removed`, after all `.unchanged`.
- Mixed insert + delete in middle.
- `current == nil` → before is the placeholder, after all `.added`.
- Trailing blank line preserved.

`HookBackupServiceTests`:
- Local target writes to `<home>/.treemux/backups/local/<kind>/<basename>.<ts>`.
- Remote target with `host = user@example.com` writes under
  `remote_user@example.com/<kind>/...`.
- Two backups in quick succession produce two distinct timestamped files
  (resolution: seconds).
- Throws when `current == nil`.
- Creates parent directories that didn't exist before.

UI is verified via Xcode Previews (sample changes covering pure add, pure
delete, mixed) and manual QA per the project's existing AI activity QA
checklist (`docs/plans/2026-04-28-sidebar-ai-attention-qa-checklist.md`
pattern).

## Localization

New `LocalizedStringKey`s, all required to ship with `zh-Hans`:

| English | 中文 |
|---|---|
| `Backup` | 备份 |
| `Backing up…` | 正在备份… |
| `Backed up ✓` | 已备份 ✓ |
| `Show in Finder` | 在 Finder 中显示 |
| `Backup failed: %@` | 备份失败：%@ |
| `Nothing to back up (new file)` | 无需备份（新文件） |

`(file does not exist)` already exists in the strings catalog and is reused.

## Open Questions

None. All design decisions resolved during brainstorming on 2026-04-29.

## Out-of-Scope Follow-Ups

These were considered and explicitly deferred:

- Word-level highlighting inside changed lines (current scope: line-level only).
- Synthetic blank-line padding to align corresponding lines across columns.
- A "Backup all" button that backs up every applicable change at once.
- A backups listing pane in Settings with `Restore` actions.
- Auto-backup-before-Apply with an opt-out toggle.
