# Recursive File Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add recursive Finder-to-remote upload and remote-to-local download with chunked I/O, explicit conflicts, progress, cancellation, cleanup, and focused tree refresh.

**Architecture:** `FileTransferCoordinator` owns a single batch and operates only through two `FileTransferEndpoint` values, which makes traversal and lifecycle deterministic in tests. Local and file-browser endpoints adapt `FileManager` and `FileBrowserDataSource`; the controller owns one coordinator and maps its observable state to SwiftUI drop, chooser, conflict, and summary presentation.

**Tech Stack:** Swift 5, Swift concurrency, Observation, SwiftUI/AppKit drag-and-drop, XCTest, XcodeGen, `xcodebuild`.

## Global Constraints

- The primary checkout remains on `main`; implementation is isolated in `codex/feat/recursive-file-transfer`.
- User-visible strings use localization and include `zh-Hans` translations.
- Visible colors use theme tokens; code comments are English.
- Remote work stays asynchronous and transfer decisions are testable without SSH.
- Files are transferred in 256 KiB chunks and no general transfer calls `downloadForQuickLook`.
- Temporary files end in `.treemux-transfer-part` and are removed on failure or cancellation.

---

### Task 1: Transfer domain and recursive coordinator

**Files:**
- Create: `Treemux/Services/FileTransfer/FileTransferModels.swift`
- Create: `Treemux/Services/FileTransfer/FileTransferCoordinator.swift`
- Create: `TreemuxTests/FileTransferCoordinatorTests.swift`
- Modify: `Treemux.xcodeproj/project.pbxproj` (regenerate with `xcodegen generate`)

**Interfaces:**
- Produces: `FileTransferEndpoint` with `metadata(at:)`, `children(at:)`, `readChunk(at:offset:length:)`, `createDirectory(at:)`, `createTemporaryFile(at:)`, `writeChunk(_:to:offset:)`, `replaceItem(at:withTemporaryItemAt:)`, and `removeItem(at:)`.
- Produces: `@MainActor @Observable final class FileTransferCoordinator` with `start(direction:sources:destinationRoot:)`, `resolveConflict(_:)`, and `cancel()`.
- Produces: `FileTransferSnapshot`, `FileTransferConflict`, `FileTransferSummary`, and `FileTransferFailure` values consumed by UI.

- [ ] **Step 1: Write failing coordinator tests**

Create fake in-memory endpoints and tests named `testNestedFolderCopiesFilesAndEmptyDirectory`, `testLargeFileUsesMultipleChunks`, `testConflictWaitsForOverwriteSkipOrCancelAll`, `testCancellationRemovesTemporaryFile`, `testSiblingFailureDoesNotAbortBatch`, `testProgressAggregatesBytesAndCounts`, and `testSymlinkCycleIsReportedWithoutAbortingSibling`.

- [ ] **Step 2: Verify RED**

Run `xcodegen generate && xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-transfer-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileTransferCoordinatorTests` and confirm the new types are missing.

- [ ] **Step 3: Implement minimal coordinator**

Use incremental depth-first discovery, a path-local `Set<String>` of canonical directory identities, cooperative `Task.checkCancellation()` between every chunk, and a checked continuation for each explicit conflict. Write each file to `destination + ".treemux-transfer-part"`, then call `replaceItem` only after the final chunk.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused suite, then commit `test: add recursive transfer coordinator` and `feat: add recursive transfer coordinator` after their respective red/green checkpoints.

### Task 2: Concrete chunked endpoints

**Files:**
- Create: `Treemux/Services/FileTransfer/LocalFileTransferEndpoint.swift`
- Create: `Treemux/Services/FileTransfer/FileBrowserTransferEndpoint.swift`
- Modify: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Create: `TreemuxTests/FileTransferEndpointTests.swift`

**Interfaces:**
- Consumes: `FileTransferEndpoint` from Task 1.
- Produces: chunked local `FileHandle` reads/writes and remote `SFTPService` chunk methods for both system SSH and Citadel modes.

- [ ] **Step 1: Write failing endpoint tests**

Test local offset reads/writes and atomic replacement, SSH command generation for offset reads/writes and cleanup, and data-source forwarding without invoking `downloadForQuickLook`.

- [ ] **Step 2: Verify RED**

Run `xcodebuild test ... -only-testing:TreemuxTests/FileTransferEndpointTests` and confirm missing endpoint APIs.

- [ ] **Step 3: Implement minimal adapters**

For system SSH, use binary-safe base64 around bounded `dd` reads and offset writes; for Citadel use `SFTPFile.read(from:length:)` and `write(_:at:)`. Add rename/remove helpers for temporary replacement. Local replacement uses `FileManager.replaceItemAt` or move for a new destination.

- [ ] **Step 4: Verify GREEN and commit**

Run endpoint and existing SFTP/data-source suites, then commit `feat: add chunked transfer endpoints`.

### Task 3: Controller lifecycle and focused refresh

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Create: `TreemuxTests/FileBrowserTransferControllerTests.swift`

**Interfaces:**
- Consumes: coordinator snapshots and conflict decisions.
- Produces: `beginUpload(urls:destination:)`, `beginDownload(node:destinationURL:)`, `resolveTransferConflict(_:)`, `cancelTransfer()`, and `dismissTransferSummary()`.

- [ ] **Step 1: Write failing controller tests**

Assert drop target routing to a directory/root, context download source routing, duplicate-batch suppression, and refresh of only affected expanded directories after completion.

- [ ] **Step 2: Verify RED, implement, and verify GREEN**

Run `xcodebuild test ... -only-testing:TreemuxTests/FileBrowserTransferControllerTests`; add the minimal controller state and actions; rerun until green.

- [ ] **Step 3: Commit**

Commit `feat: connect transfers to file browser controller`.

### Task 4: Drag/drop, download chooser, progress, conflicts, and summary UI

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Modify: `Treemux/Localizable.xcstrings`
- Create: `TreemuxTests/FileTransferPresentationTests.swift`

**Interfaces:**
- Consumes: controller transfer actions/state.
- Produces: Finder file URL drop on rows and empty root area, localized `Download…`, directory chooser handoff, progress/cancel sheet, conflict alert, and persistent summary sheet.

- [ ] **Step 1: Write failing presentation seam tests**

Test the pure drop target resolver and download menu availability for both file and expandable directory nodes.

- [ ] **Step 2: Verify RED, implement, and verify GREEN**

Add `UTType.fileURL` drop destinations and an `NSOpenPanel` configured for one directory. Present `Overwrite`, `Skip`, and `Cancel All`; show byte/item progress with themed controls; expose the final counts and failures until dismissal.

- [ ] **Step 3: Verify localization**

Confirm every new key has `zh-Hans`, including `Download…`, transfer state labels, conflict actions, summary labels, and failure copy.

- [ ] **Step 4: Commit**

Commit `feat: add recursive transfer interactions`.

### Task 5: Branch verification

- [ ] Run all transfer, SFTP, file-browser controller, and tree-row suites.
- [ ] Run the full `TreemuxTests` suite with `-skipPackagePluginValidation`.
- [ ] Run `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation`.
- [ ] Inspect `git diff --check`, localized keys, and confirm `downloadForQuickLook` has no transfer caller.
- [ ] Commit any verification-only project regeneration as `chore: finalize recursive transfer project`.
