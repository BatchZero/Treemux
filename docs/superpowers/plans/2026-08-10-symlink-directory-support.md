# Symlink Directory Support Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make local, system-SSH, and Citadel SFTP symlinks expose consistent target metadata, expand directory targets, and stop self/ancestor cycles with localized row-level errors.

**Architecture:** Extend `FileNode` with a Codable symlink-resolution value that carries target classification and canonical directory identity while retaining the legacy Boolean decoding path. Each data source resolves that value using its native facilities: Foundation URLs locally, a bulk shell probe for system SSH, and a bounded async metadata resolver for Citadel. `FileBrowserTabController` owns path-local ancestry checks and stale-load tokens so source metadata stays transport-focused and aliases remain legal outside their own ancestry.

**Tech Stack:** Swift 6, SwiftUI Observation, Foundation file APIs, Citadel SFTP, XCTest, Xcode 26.

---

### Task 1: Add the rich symlink model and snapshot migration

**Files:**
- Modify: `Treemux/Domain/FileNode.swift`
- Modify: `Treemux/Services/SFTP/SFTPDirectoryEntry.swift`
- Test: `TreemuxTests/FileNodeSymlinkTests.swift`

- [ ] **Step 1: Write failing model and migration tests**

Add coverage for directory, file, broken, inaccessible, and unresolved target outcomes; require directory metadata to carry a canonical identity; decode both a new snapshot and a legacy snapshot containing only `symlinkTargetIsDirectory`; verify a missing field becomes unresolved and non-expandable.

- [ ] **Step 2: Run the focused tests and confirm the new expectations fail**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileNodeSymlinkTests
```

Expected: failures because `SymlinkTargetResolution` and canonical identity do not exist.

- [ ] **Step 3: Implement the smallest backward-compatible model**

In `FileNode.swift`, add a `Codable`, `Equatable`, `Sendable` resolution enum with cases equivalent to:

```swift
enum SymlinkTargetResolution: Equatable, Codable, Sendable {
    case directory(canonicalIdentity: String)
    case file
    case broken
    case inaccessible
    case unresolved(reason: String?)
}
```

Store it on `FileNode`, derive `symlinkTargetIsDirectory` and `isExpandableDirectory` from it, and custom-decode legacy Boolean snapshots. Keep a compatibility initializer argument so existing call sites compile during the migration. Mirror the value in `SFTPRichEntry` and `SFTPRichStat`.

- [ ] **Step 4: Run focused tests until green**

- [ ] **Step 5: Commit the model checkpoint**

```bash
git add Treemux/Domain/FileNode.swift Treemux/Services/SFTP/SFTPDirectoryEntry.swift TreemuxTests/FileNodeSymlinkTests.swift
git commit -m 'feat: model resolved symlink targets'
```

### Task 2: Resolve local absolute, relative, broken, and inaccessible links

**Files:**
- Modify: `Treemux/Services/FileBrowser/FileBrowserDataSource.swift`
- Modify: `Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift`
- Test: `TreemuxTests/LocalFileBrowserDataSourceTests.swift`

- [ ] **Step 1: Write failing local-resolution tests**

Create temporary absolute and relative directory links, a file link, and a broken link. Assert that both `listDirectory` and `searchNames` return identical resolution metadata and that directory identities equal standardized resolved paths. Add an injected/helper-level inaccessible-target test so it remains deterministic outside macOS privacy controls.

- [ ] **Step 2: Run the focused tests and confirm failure**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests
```

- [ ] **Step 3: Add a source-level canonical identity contract**

Add `canonicalDirectoryIdentity(_:) async throws -> String` to `FileBrowserDataSource`. Supply a default standardized-path implementation for test doubles and override it in local and remote sources. Add typed symlink failures to `FileBrowserError` where the controller needs to distinguish broken, unreadable, and unsupported outcomes.

- [ ] **Step 4: Implement one local resolver shared by listing and search**

Use `destinationOfSymbolicLink`, resolve relative destinations against the link parent, standardize and resolve the target URL, then obtain target resource values. Map missing targets to `.broken`, permission failures to `.inaccessible`, directories to `.directory(canonicalIdentity:)`, regular files to `.file`, and other failures to `.unresolved(reason:)`. Do not drop a link merely because target metadata fails.

- [ ] **Step 5: Run local and model tests until green**

- [ ] **Step 6: Commit the local checkpoint**

```bash
git add Treemux/Services/FileBrowser/FileBrowserDataSource.swift Treemux/Services/FileBrowser/LocalFileBrowserDataSource.swift TreemuxTests/LocalFileBrowserDataSourceTests.swift
git commit -m 'feat: resolve local symlink targets'
```

### Task 3: Extend the system-SSH bulk probe without masking listing failures

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Modify: `Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift`
- Test: `TreemuxTests/SFTPServiceTests.swift`
- Test: `TreemuxTests/SFTPRecursiveListingTests.swift`

- [ ] **Step 1: Write failing parser/probe tests**

Cover directory links with canonical targets, file links, broken links, inaccessible/unresolved links, paths containing spaces, and recursive listings. Add a command-construction assertion proving the primary `ls`/`find` exit code is captured before the optional symlink probe.

- [ ] **Step 2: Run SSH parser tests and confirm failure**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests -only-testing:TreemuxTests/SFTPRecursiveListingTests
```

- [ ] **Step 3: Emit and parse a structured probe section**

After the authoritative listing succeeds, probe each symlink with `[ -d ]`, `[ -e ]`, `[ -r ]`, and a portable canonical-path fallback (`realpath` first, then resolved physical parent plus basename). Encode fields safely for arbitrary names and parse them into a path-to-resolution map. Preserve the listing command status independently so probe failures cannot turn a failed listing into success.

- [ ] **Step 4: Map remote entries and canonical identity**

Have `RemoteFileBrowserDataSource` transfer the rich resolution into `FileNode`, and expose an `SFTPService` canonical directory lookup used when a regular ancestor lacks embedded symlink metadata.

- [ ] **Step 5: Run SSH tests until green**

- [ ] **Step 6: Commit the SSH checkpoint**

```bash
git add Treemux/Services/SFTP/SFTPService.swift Treemux/Services/FileBrowser/RemoteFileBrowserDataSource.swift TreemuxTests/SFTPServiceTests.swift TreemuxTests/SFTPRecursiveListingTests.swift
git commit -m 'feat: resolve system ssh symlink targets'
```

### Task 4: Add bounded, cancellable Citadel metadata resolution

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift`
- Test: `TreemuxTests/SFTPServiceTests.swift`

- [ ] **Step 1: Write failing resolver tests around an injectable async closure**

Test directory/file/broken/permission/unsupported results, a fixed maximum in-flight count, preservation of input order, and prompt cancellation. The seam accepts a path and returns canonical path plus stat attributes so no real server is required.

- [ ] **Step 2: Run the focused resolver tests and confirm failure**

- [ ] **Step 3: Implement bounded resolution**

For Citadel directory listings, identify symlink rows from `listDirectory`, resolve only those rows through a helper capped at four concurrent requests, and check cancellation before scheduling and applying every result. Use `getRealPath(atPath:)` for canonical identity and `getAttributes(at:)` for target classification. Map `SFTPError.errorStatus(.noSuchFile)` to broken and `.permissionDenied` to inaccessible; retain other failures as unresolved without failing the parent listing.

- [ ] **Step 4: Reuse the resolver in single-directory and recursive Citadel paths**

Keep `BFSTreeLister` traversal restricted to real directories; symlink directories remain lazily expandable so recursive prefetch cannot walk a cycle.

- [ ] **Step 5: Run SFTP tests until green**

- [ ] **Step 6: Commit the Citadel checkpoint**

```bash
git add Treemux/Services/SFTP/SFTPService.swift TreemuxTests/SFTPServiceTests.swift
git commit -m 'feat: bound citadel symlink metadata lookups'
```

### Task 5: Reject ancestry cycles and stale expansion results

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`
- Modify: `Treemux/UI/FileBrowser/FileTreeRowModel.swift`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`
- Test: `TreemuxTests/FileBrowserTabControllerStaleLoadTests.swift`
- Test: `TreemuxTests/FileTreeRowModelTests.swift`

- [ ] **Step 1: Write failing controller tests**

Build deterministic fake trees for a self-link, a two-directory cycle, and two non-cyclic aliases to the same target. Assert cycle expansion never calls `listDirectory`, leaves the link visible/collapsed, and attaches a row error. Delay a metadata/list request, refresh or collapse the tree, then prove the stale result does not mutate children or expansion state.

- [ ] **Step 2: Run focused controller tests and confirm failure**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests -only-testing:TreemuxTests/FileBrowserTabControllerStaleLoadTests -only-testing:TreemuxTests/FileTreeRowModelTests
```

- [ ] **Step 3: Implement path-local ancestry validation**

Track canonical identities by displayed path. Before expanding a symlink directory, gather only its visible ancestors from the root, resolve/cache their canonical identities, and reject the link when its identity is already present. Clear the error on a later successful attempt. Do not use a global visited set, because aliases in separate branches are valid.

- [ ] **Step 4: Add per-path expansion tokens**

Issue a request token for each load. Invalidate it on collapse, refresh, root change, and a newer request; verify it after every await before writing `rawChildren`, `children`, `expandedPaths`, caches, or errors.

- [ ] **Step 5: Expose row-level symlink failures**

Add an optional error message to `FileTreeRowModel`. For broken, inaccessible, and unresolved non-expandable symlinks, route activation to a controller method that records the appropriate localized row error instead of trying to read the link as a regular file.

- [ ] **Step 6: Run controller/model tests until green**

- [ ] **Step 7: Commit the controller checkpoint**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift Treemux/UI/FileBrowser/FileTreeRowModel.swift TreemuxTests/FileBrowserTabControllerTests.swift TreemuxTests/FileBrowserTabControllerStaleLoadTests.swift TreemuxTests/FileTreeRowModelTests.swift
git commit -m 'feat: stop symlink expansion cycles'
```

### Task 6: Render localized row errors and verify the complete feature

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Modify: `Treemux/Localizable.xcstrings`
- Test: relevant existing suites under `TreemuxTests/`

- [ ] **Step 1: Add localized strings**

Add English keys and `zh-Hans` translations for broken target, unreadable target, ancestor cycle, and unresolved/unsupported metadata. Keep dynamic paths in `String(localized:)` interpolation and use no hard-coded visible text.

- [ ] **Step 2: Render the row-level state**

Show a warning icon with the existing theme danger token and `.help(errorMessage)`. Keep the symlink icon and row present. Make the disclosure action available only for resolved directory targets and send other symlink activation to the error-reporting path.

- [ ] **Step 3: Run all symlink-focused suites**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileNodeSymlinkTests \
  -only-testing:TreemuxTests/LocalFileBrowserDataSourceTests \
  -only-testing:TreemuxTests/SFTPServiceTests \
  -only-testing:TreemuxTests/SFTPRecursiveListingTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerStaleLoadTests \
  -only-testing:TreemuxTests/FileTreeRowModelTests
```

Expected: all focused suites pass.

- [ ] **Step 4: Run the complete test suite**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -derivedDataPath /tmp/treemux-symlink-dd -skipPackagePluginValidation
```

Expected: all product tests pass; if the known sandbox-only `WorkspaceStoreRemoteRefreshTests.test_refreshRemoteWorkspacesConcurrently_visitsEveryIDOnce` failure recurs, record it separately with its `~/.treemux-debug` permission evidence.

- [ ] **Step 5: Build the debug app in the standard DerivedData location**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation
```

- [ ] **Step 6: Review the diff and localization coverage**

Check for hard-coded visible strings/colors, accidental traversal of symlink directories in bulk BFS, unbounded task creation, and edits outside the feature worktree.

- [ ] **Step 7: Commit the completed feature**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m 'feat: surface symlink resolution errors'
```
