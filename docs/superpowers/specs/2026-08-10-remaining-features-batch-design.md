# Remaining Features Batch Design

## Overview

This batch completes four independent Treemux capabilities:

1. Reset or reconnect one terminal pane and reattach its detected tmux session.
2. Drag remote server group headers to persist a user-defined sidebar order.
3. Recursively upload Finder files and folders, and recursively download remote files and folders.
4. Expand symlink directories consistently for local, system-SSH, and password-authenticated SFTP sources while preventing cycles.

Each capability ships from its own branch and worktree so it can be tested, reviewed, merged, or reverted independently. The implementation order is symlink directory support, recursive file transfer, terminal reconnect, then server group ordering. Symlink resolution lands first because recursive transfer reuses its target classification and cycle detection.

## Global Constraints

- The primary repository checkout remains on `main`; every implementation uses a new branch and a worktree under `.worktrees/`.
- All code comments are written in English.
- Every user-visible string uses the existing localization mechanisms and receives a `zh-Hans` entry in `Treemux/Localizable.xcstrings`.
- All visible colors use theme tokens. Font sizes, spacing, and radii use the existing design constants.
- Existing local workspace ordering, worktree ordering, file editing, terminal split layout, and remote authentication behavior must not regress.
- Long-running remote operations remain asynchronous and do not block the main actor.
- New operations expose deterministic seams so their decision logic can be unit tested without a real SSH server.

## Delivery Structure

| Order | Branch | Deliverable |
|---|---|---|
| 1 | `codex/feat/symlink-directory-support` | Uniform symlink directory metadata and cycle-safe expansion |
| 2 | `codex/feat/recursive-file-transfer` | Recursive drag upload and right-click download |
| 3 | `codex/feat/terminal-reconnect-tmux` | Per-pane reset/reconnect with tmux reattachment |
| 4 | `codex/feat/server-group-reordering` | Persistent drag ordering for remote server headers |

The recursive transfer branch starts from a `main` that already contains the symlink-directory work. The terminal and server-order branches have no dependency on the file work and may be implemented independently after their own worktrees are created.

## Feature 10: Symlink Directory Reading

### Goal

Local, key-authenticated system SSH, and password-authenticated Citadel SFTP file trees all classify symlinks to directories as expandable. Expansion terminates safely for broken, inaccessible, or cyclic links.

### Model

`FileNode` continues to represent a symlink with `.symlink(target:)`, but symlink metadata must carry both target classification and a canonical identity suitable for cycle checks. The persisted tree snapshot remains backward compatible: missing new symlink metadata decodes to a non-expandable, unresolved link and is refreshed from the source.

The source layer returns these outcomes for a symlink:

- directory target with a canonical target identity;
- non-directory target;
- broken target;
- inaccessible target;
- unresolved target when the remote server cannot provide enough metadata.

Only the first outcome is expandable. Broken, inaccessible, and unresolved links remain visible with their link icon and expose a localized error when the user tries to expand them.

### Source-specific resolution

- Local filesystem resolution uses URL resource values and the standardized, resolved target URL.
- System SSH retains the existing bulk `[ -d ]` probe and adds a canonical target probe for symlinks that resolve to directories. The listing exit status must remain authoritative and cannot be masked by the probe.
- Citadel SFTP resolves symlink entries with bounded concurrent metadata requests. It uses SFTP link/stat facilities when available and must not launch an unbounded request per row.

### Cycle prevention

Expansion passes an ancestry set of canonical directory identities. Before listing a symlink directory, the controller resolves its canonical identity and rejects the expansion when that identity already occurs in the current ancestry. This detects direct self-links and multi-directory cycles without globally banning valid aliases elsewhere in the tree.

Cycle detection is path-local rather than global: two different branches may expand the same target when neither ancestry contains it. A cycle produces a localized row-level error, leaves the link visible, and does not mutate cached children with an infinite or partial traversal.

### Errors and performance

- Broken link: show that the target no longer exists.
- Permission failure: show that the target cannot be read.
- Cycle: show that expansion stopped because the link points to an ancestor.
- Metadata timeout or unsupported server behavior: retain the link as non-expandable and show the underlying failure on attempted expansion.
- Citadel metadata lookups use a small fixed concurrency limit and support cancellation when the containing tree refresh becomes stale.

### Tests

Tests cover local absolute and relative links, system-SSH probe parsing, Citadel metadata resolution, file links, directory links, broken links, inaccessible links, a self-cycle, a two-directory cycle, a non-cyclic alias, stale async results, snapshot migration, and request concurrency bounds.

### Acceptance criteria

- A symlink directory expands through every supported authentication path.
- Direct and indirect cycles stop without a hang or unbounded tree growth.
- A broken or unreadable link stays visible and reports a useful localized error.
- Existing regular directory listing and recursive search behavior remains unchanged.

## Feature 9: Recursive Upload and Download

### Goal

Users can drag one or more Finder files or folders into a remote file tree and can right-click any remote file or folder to download it to a chosen local directory. Transfers support recursion, bounded concurrency, progress, cancellation, and explicit conflict decisions.

### Transfer model

A dedicated transfer coordinator owns one user-initiated transfer batch. It converts source selections into transfer items, walks directories incrementally, limits concurrent file operations, aggregates progress, and publishes a summary. Upload and download share the same conflict and lifecycle model but use direction-specific readers and writers.

Transfer state includes:

- current item and direction;
- known total bytes and completed bytes;
- discovered, completed, skipped, and failed item counts;
- running, waiting-for-conflict, cancelling, completed, and failed states;
- per-item failures for the final summary.

Files are copied in chunks. The implementation must not call the existing whole-file Quick Look download path for general downloads and must not buffer an entire large file before writing it.

### Upload interaction

- The file tree accepts Finder file URLs on a directory row or on the empty area of the tree.
- Dropping on a directory uploads into that directory. Dropping on empty space uploads into the browser root.
- Multiple files and folders form one batch.
- An invalid drop target shows the standard prohibited operation and does not start a transfer.
- When a batch finishes, the affected remote directories refresh without rebuilding unrelated file-browser state.

### Download interaction

- Remote file and folder rows add a localized `Download…` context-menu command.
- A macOS directory chooser selects the destination directory.
- Multiple selected rows are not introduced in this scope; one context-menu invocation downloads the clicked node, recursively when it is a directory.
- On success, the destination is revealed in Finder when practical, and the transfer summary remains available until dismissed.

### Conflicts

Every destination collision pauses the affected decision point and presents `Overwrite`, `Skip`, and `Cancel All`:

- Overwriting a file writes to a temporary sibling and atomically replaces the destination after success.
- Overwriting a directory merges its contents. Descendant conflicts are requested individually.
- A file/directory type mismatch is replaced only after an explicit `Overwrite` decision.
- `Skip` records the item as skipped and continues the batch.
- `Cancel All` cancels queued and active operations, removes temporary partial files, and preserves previously completed items.

There is no implicit overwrite and no apply-to-all option in this scope.

### Symlink behavior

Recursive transfers follow a selected symlink directory and symlink directories encountered beneath a selected folder. They reuse Feature 10's canonical ancestry cycle detection. A detected cycle is recorded as a failed/skipped entry in the summary and does not abort unrelated transfer items.

### Failures, cancellation, and cleanup

- One item failure does not stop independent siblings.
- Authentication or connection loss pauses new work and surfaces a retryable batch error.
- Cancellation is cooperative between chunks and directory discoveries.
- Temporary destination files use a Treemux-specific suffix and are removed on failure or cancellation.
- Empty directories are created explicitly.
- The final sheet reports successful, skipped, failed, and cancelled counts and lists actionable failures.

### Tests

Pure coordinator tests use fake local and remote transfer endpoints. Coverage includes a single file, multiple files, nested folders, empty folders, large chunked files, bounded concurrency, all three conflict choices, file/directory type mismatch, mid-file cancellation, partial batch failure, connection retry, temporary-file cleanup, progress aggregation, symlink aliases, and symlink cycles. UI tests or focused representable tests cover drop-target routing, the directory chooser handoff, and context-menu availability.

### Acceptance criteria

- Finder files and folders upload recursively to the intended remote directory.
- A remote file or folder downloads recursively to the directory selected by the user.
- No large transfer requires whole-file buffering.
- Every collision waits for an explicit overwrite, skip, or cancel-all decision.
- Progress, cancellation, cleanup, and final failure reporting work for partially completed batches.

## Feature 4: Terminal Reconnect and tmux Restore

### Goal

Every terminal pane has a reset/reconnect control. It restarts only that pane, preserves the surrounding tab and split layout, reconnects SSH when applicable, and reattaches a detected tmux session instead of starting an unrelated shell.

### Reconnect decision

A pure resolver derives the reconnect backend from the pane's original backend, SSH target, and current detected tmux session:

- local shell without detected tmux returns the original local shell backend;
- SSH without detected tmux returns the original SSH backend;
- local shell with a real detected tmux name returns a local tmux-attach backend;
- SSH with a real detected tmux name returns a remote tmux-attach backend using the original SSH target;
- an existing tmux-attach backend remains a tmux-attach backend.

The generic fallback value `tmux` is not considered a restorable session name. The reconnect resolver does not mutate the persisted original backend merely because a transient tmux session was detected.

### Session lifecycle

The pane asks for confirmation before reset because the current foreground process will be terminated. After confirmation it:

1. rejects a duplicate request while a reconnect is active;
2. records the reconnect backend;
3. detaches or terminates the current managed terminal process;
4. clears stale PID, exit code, reported working directory, title, detected runtime tmux value, and surface status;
5. updates the managed surface launch configuration;
6. starts the replacement process in the same pane;
7. restores focus if the pane was focused.

The pane ID, split layout, zoom state, tab identity, and neighboring sessions remain unchanged.

### UI

The terminal pane header places a themed reset/reconnect button next to the close button. The button has localized help and an accessibility label. While reconnecting, it is disabled and shows a progress animation. The confirmation explains that a normal foreground process will terminate and that tmux programs remain alive while Treemux disconnects and reattaches.

### tmux failure behavior

If the saved tmux session no longer exists, Treemux does not create a replacement session with the same name. The pane surfaces a localized failure action with:

- `Retry`, which retries the same attach backend;
- `Start Shell`, which starts the pane's original non-tmux local or SSH backend.

Choosing `Start Shell` affects the current reconnect only and does not erase unrelated saved pane state.

### Tests

Resolver tests cover local shell, SSH, local tmux, remote tmux, existing attach backends, and the generic tmux fallback. Session tests use a fake managed surface to verify call order, state clearing, focus preservation, duplicate-click suppression, tmux attach failure, retry, and start-shell fallback. UI-level tests cover the button's enabled, reconnecting, and error states.

### Acceptance criteria

- Resetting one pane never restarts another pane or changes the layout.
- Local and SSH panes restart with their original connection behavior.
- A detected real tmux session reattaches locally or remotely as appropriate.
- Repeated clicks cannot create concurrent replacement processes.
- A missing tmux session offers retry or a normal shell without silently creating a session.

## Feature 5: Remote Server Group Header Reordering

### Goal

Remote server group headers in the sidebar can be dragged before or after other remote server groups, and the chosen order survives application restarts. Local workspace ordering and project-row dragging remain unchanged.

### Persistence

`PersistedWorkspaceState` gains an optional remote group order array. Each entry is the existing remote group key used for grouping. Decoding old state without this field yields the legacy alphabetical order.

When building remote groups:

1. include existing keys that occur in the saved order;
2. append newly discovered keys not present in the saved order;
3. preserve alphabetical ordering only for the initial legacy state and among multiple newly discovered groups in the same refresh;
4. remove keys that no longer correspond to a remote group on the next persisted save.

Changing connection information so that the group key changes creates a new group at the end. It does not inherit an unrelated stale position.

### Drag interaction

Server header rows use a dedicated pasteboard type separate from workspace-row dragging. A remote server header may be dropped before or after another remote server header whether either group is expanded or collapsed.

The local section remains fixed above all remote server groups and is not draggable. A remote group cannot be dropped above the local section. Project rows retain the current restriction that they can only reorder within their existing section; cross-server project moves are outside this scope.

After a successful header drop, the store updates the remote group order, invalidates the derived group cache, refreshes the outline view while preserving selection and collapse state, and schedules persistence.

### Tests

Tests cover legacy alphabetical order, explicit persisted order, moving a group forward and backward, collapsed-group dragging, restart round-trip, appending new groups, removing stale keys, changed group identity, local-section pinning, and non-regression of project-row dragging.

### Acceptance criteria

- Remote server group headers drag before or after each other.
- The local section remains fixed at the top.
- The chosen order survives restart and does not disturb group collapse or selected project state.
- New groups append predictably and removed groups do not leave permanent stale state.
- Existing within-group project sorting continues to work.

## Cross-feature Verification

Each feature branch runs its focused tests and the full `TreemuxTests` suite with package plugin validation enabled or explicitly skipped in environments where Xcode has not trusted the SwiftLint plugin. Manual verification uses local and remote test fixtures and confirms English and Simplified Chinese UI strings.

The known baseline environment can fail `WorkspaceStoreRemoteRefreshTests.test_refreshRemoteWorkspacesConcurrently_visitsEveryIDOnce` when the test runner lacks permission to remove `~/.treemux-debug`. That environmental failure is not changed or suppressed by these feature branches; feature verification must report it separately if it recurs.

## Out of Scope

- Moving projects between server groups.
- Dragging the local section or placing a remote group above it.
- Apply-to-all conflict decisions for file transfer.
- Background transfer persistence across application restarts.
- Silent creation of a missing tmux session.
- Redesigning the entire sidebar, terminal header, or file browser.
