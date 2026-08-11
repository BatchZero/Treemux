# Upload Drop Highlight and Confirmation Design

Date: 2026-08-10
Branch: `codex/fix/upload-drop-confirmation`

## Context

Recursive upload currently begins immediately from both `dropDestination` closures in `FileTreePanelView`. The closures do not retain an `isTargeted` state, so a valid remote directory does not provide visible feedback while a local item is held over it. Releasing the drag calls `beginUpload` directly, so the user cannot verify the destination or cancel before remote writes begin.

## Goals

- Highlight a valid remote directory while a local file-system drag is hovering over it.
- Highlight the remote root drop area when the user targets empty tree space.
- After release, show one confirmation for the whole drag operation before any upload begins.
- Show the target directory in the confirmation without showing an item count.
- Guarantee that cancelling the confirmation performs no remote transfer.
- Preserve the existing recursive transfer, conflict, progress, retry, cancellation, and summary behavior after confirmation.

## Non-goals

- Per-file or per-directory confirmation inside a recursive batch.
- Changes to download confirmation or download destination selection.
- New theme color tokens or hard-coded colors.
- Changes to the transfer coordinator's copy and recovery semantics.

## Interaction Design

### Hover feedback

A valid directory row uses the active theme's accent color for both:

- a low-opacity rounded background fill; and
- a clearly visible rounded border.

The highlight is shown only while the dragged payload is over a valid upload destination. It disappears immediately when the pointer leaves or the drag ends. The selected-row indicator remains visible, with the drop highlight taking visual priority during the hover.

Dragging over empty tree space targets the remote root and applies the same themed fill and border to the tree's scroll region. File rows, local-browser rows, and all targets while another transfer is active do not present themselves as valid upload targets.

### Confirmation

Releasing a valid local file-system drag stages a pending upload request instead of starting the transfer. One alert is shown for the entire drag operation:

- title: `Confirm Upload`
- message: `Upload to: <destination path>`
- primary action: `Upload`
- cancel action: `Cancel`

The alert does not show an item count. Choosing `Cancel`, dismissing the alert, or replacing the view clears the pending request without creating a transfer coordinator or writing remote data. Choosing `Upload` consumes the pending request exactly once and starts the existing upload flow.

## State and Data Flow

`FileBrowserTabController` owns one optional `PendingUploadRequest`. The request contains the filtered local file URLs and normalized destination path. Central ownership keeps the request alive if a row re-renders and ensures that only one confirmation can exist for the tab.

The flow is:

1. SwiftUI validates the hovered destination and reflects `isTargeted` in local visual state.
2. A successful drop passes file URLs and the destination to `stageUpload`.
3. `stageUpload` rejects local tabs, empty payloads, and active transfers, then stores a pending request. It does not construct a coordinator.
4. The panel alert observes the pending request.
5. `cancelPendingUpload` clears it without side effects.
6. `confirmPendingUpload` clears it first, then calls the existing asynchronous `beginUpload` once.

Clearing before awaiting prevents a duplicate alert action from starting the same request twice.

## Components

### `FileBrowserTabController`

- Adds the pending upload request state.
- Adds staging, cancellation, and consume/confirmation operations.
- Exposes whether a destination can currently accept a local upload.
- Leaves `beginUpload` as the sole entry point that constructs and starts a transfer coordinator.

### `FileTreePanelView`

- Uses the `dropDestination` targeted-state callback for the root drop area.
- Presents the upload confirmation alert.
- Starts the controller confirmation task only from the alert's `Upload` action.

### `FileTreeRow`

- Tracks row-local targeted state supplied by `dropDestination`.
- Applies theme-derived fill and border only for a valid directory target.
- Stages the request on release instead of starting the upload.

## Error and Concurrency Handling

- A new drop is rejected while a transfer is active or another upload is awaiting confirmation.
- Invalid or non-file URLs are filtered before staging; an empty result is rejected.
- Cancelling never creates a `FileTransferCoordinator`.
- Errors after confirmation continue through the existing progress, retryable-error, conflict, and summary UI.
- If the tab disappears while confirmation is pending, the request is cleared and no upload starts.

## Theme and Localization

Hover colors use `ThemeManager.accentColor` and existing theme background tokens with opacity; no literal color values are introduced.

All new user-visible strings are English source keys in `Treemux/Localizable.xcstrings` with `zh-Hans` translations:

- `Confirm Upload` → `确认上传`
- `Upload` → `上传`
- `Upload to: %@` → `上传到：%@`

The existing localized `Cancel` key is reused.

## Automated Testing

Controller-focused regression tests will prove:

- staging a valid drop creates a pending request and does not create a transfer coordinator;
- cancelling clears the request and leaves the coordinator absent;
- confirming consumes the request and begins one upload;
- invalid, local, active-transfer, and duplicate-pending cases are rejected;
- the staged destination matches the directory row or root target.

Presentation tests will continue to prove that only directories and the empty root area resolve to upload destinations. Tests are written and observed failing before production changes, then rerun after the minimal implementation.

## DELL Screen Acceptance Test

The built app and Finder are placed only on the DELL display. Using a fresh remote target directory:

1. Drag a local nested directory over a remote directory and hold without releasing.
2. Verify the target row visibly shows accent fill and border.
3. Move away and verify the highlight disappears; move back and release.
4. Verify the confirmation appears once, contains the exact target directory, and shows no item count.
5. Choose `Cancel` and verify the remote destination remains empty.
6. Repeat the drag, choose `Upload`, and verify recursive files plus empty directories arrive with byte-identical file contents.
7. Verify the existing transfer summary appears and the tree refreshes.

## Completion Criteria

The change is complete only when targeted controller and presentation tests pass, the full relevant transfer test suite passes, a Debug build succeeds, localization and theme checks pass, and every DELL-screen acceptance step above is observed in the built application.
