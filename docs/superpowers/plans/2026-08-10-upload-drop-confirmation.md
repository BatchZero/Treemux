# Upload Drop Highlight and Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add theme-aware upload drop highlighting and require one destination-only confirmation before any recursive upload begins.

**Architecture:** `FileBrowserTabController` owns a single pending upload request so row re-rendering cannot lose the dropped URLs. SwiftUI drop targets only stage that request and use targeted-state callbacks for visual feedback; the panel-level alert consumes or cancels it, while the existing `beginUpload` method remains the only transfer starter.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, Xcode 17, macOS 15+

## Global Constraints

- Work only in `.worktrees/codex+fix+upload-drop-confirmation` on `codex/fix/upload-drop-confirmation`; the repository root remains on `main`.
- Show one confirmation per drag operation, show the target directory, and do not show an item count.
- Cancelling or dismissing the confirmation must perform no remote write and must not create a transfer coordinator.
- Use existing `ThemeManager` colors only; do not add hard-coded visible colors or new theme tokens.
- Add English source keys and `zh-Hans` translations for every new user-visible string.
- Preserve existing recursive transfer, conflict, progress, retry, cancellation, and summary behavior after confirmation.
- Perform the final Finder-to-Treemux acceptance test only on the DELL display.

---

### Task 1: Upload-drop acceptance policy

**Files:**
- Modify: `Treemux/Services/FileTransfer/FileTransferModels.swift:94`
- Test: `TreemuxTests/FileTransferPresentationTests.swift`

**Interfaces:**
- Consumes: `FileTransferPresentation` and the controller's `isRemote`, `isTransferActive`, and pending-request state.
- Produces: `FileTransferPresentation.canAcceptUploadDrop(isRemote:isTransferActive:hasPendingUpload:) -> Bool`.

- [ ] **Step 1: Write the failing policy test**

Add this test to `FileTransferPresentationTests`:

```swift
func testUploadDropAcceptanceRequiresIdleRemoteTabWithoutPendingConfirmation() {
    XCTAssertTrue(FileTransferPresentation.canAcceptUploadDrop(
        isRemote: true,
        isTransferActive: false,
        hasPendingUpload: false
    ))
    XCTAssertFalse(FileTransferPresentation.canAcceptUploadDrop(
        isRemote: false,
        isTransferActive: false,
        hasPendingUpload: false
    ))
    XCTAssertFalse(FileTransferPresentation.canAcceptUploadDrop(
        isRemote: true,
        isTransferActive: true,
        hasPendingUpload: false
    ))
    XCTAssertFalse(FileTransferPresentation.canAcceptUploadDrop(
        isRemote: true,
        isTransferActive: false,
        hasPendingUpload: true
    ))
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileTransferPresentationTests/testUploadDropAcceptanceRequiresIdleRemoteTabWithoutPendingConfirmation
```

Expected: compilation fails because `canAcceptUploadDrop` does not exist.

- [ ] **Step 3: Add the minimal policy implementation**

Add to `FileTransferPresentation`:

```swift
static func canAcceptUploadDrop(
    isRemote: Bool,
    isTransferActive: Bool,
    hasPendingUpload: Bool
) -> Bool {
    isRemote && !isTransferActive && !hasPendingUpload
}
```

- [ ] **Step 4: Run the focused presentation tests and verify GREEN**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileTransferPresentationTests
```

Expected: 3 tests pass with 0 failures and exit code 0.

- [ ] **Step 5: Commit the policy**

```bash
git add Treemux/Services/FileTransfer/FileTransferModels.swift \
        TreemuxTests/FileTransferPresentationTests.swift
git commit -m "test: define upload drop acceptance policy"
```

---

### Task 2: Pending upload request lifecycle

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:125-150,733-750`
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Interfaces:**
- Consumes: `FileTransferPresentation.canAcceptUploadDrop(isRemote:isTransferActive:hasPendingUpload:)` from Task 1.
- Produces: `PendingUploadRequest`, `pendingUpload`, `canAcceptUploadDrop`, `stageUpload(urls:destination:)`, `cancelPendingUpload()`, `consumePendingUpload()`, and `confirmPendingUpload()`.

- [ ] **Step 1: Add failing lifecycle tests and a remote-controller helper**

Inside `FileBrowserTabControllerTests`, add:

```swift
private func makeRemoteController(rootPath: String = "/remote") -> FileBrowserTabController {
    let target = SSHTarget(
        host: "127.0.0.1",
        port: 1,
        user: "test",
        identityFile: nil,
        displayName: "test",
        remotePath: rootPath
    )
    return FileBrowserTabController(
        initial: FileBrowserTabState(rootPath: rootPath, rootKind: .project),
        dataSource: RemoteFileBrowserDataSource(sshTarget: target)
    )
}

func testStageUploadStoresOnePendingRequestWithoutStartingTransfer() throws {
    let controller = makeRemoteController()
    let urls = [URL(fileURLWithPath: "/tmp/local-folder")]

    XCTAssertTrue(controller.stageUpload(urls: urls, destination: "/remote/target"))

    let request = try XCTUnwrap(controller.pendingUpload)
    XCTAssertEqual(request.urls, urls)
    XCTAssertEqual(request.destination, "/remote/target")
    XCTAssertNil(controller.transferCoordinator)
    XCTAssertFalse(controller.canAcceptUploadDrop)
}

func testCancelPendingUploadClearsRequestWithoutStartingTransfer() {
    let controller = makeRemoteController()
    XCTAssertTrue(controller.stageUpload(
        urls: [URL(fileURLWithPath: "/tmp/local-folder")],
        destination: "/remote/target"
    ))

    controller.cancelPendingUpload()

    XCTAssertNil(controller.pendingUpload)
    XCTAssertNil(controller.transferCoordinator)
    XCTAssertTrue(controller.canAcceptUploadDrop)
}

func testConsumePendingUploadReturnsRequestOnlyOnce() throws {
    let controller = makeRemoteController()
    XCTAssertTrue(controller.stageUpload(
        urls: [URL(fileURLWithPath: "/tmp/local-folder")],
        destination: "/remote/target"
    ))

    let request = try XCTUnwrap(controller.consumePendingUpload())

    XCTAssertEqual(request.destination, "/remote/target")
    XCTAssertNil(controller.consumePendingUpload())
    XCTAssertNil(controller.pendingUpload)
}

func testStageUploadRejectsNonFileEmptyLocalAndDuplicateRequests() {
    let remote = makeRemoteController()
    XCTAssertFalse(remote.stageUpload(urls: [], destination: "/remote"))
    XCTAssertFalse(remote.stageUpload(
        urls: [URL(string: "https://example.com/file")!],
        destination: "/remote"
    ))
    XCTAssertTrue(remote.stageUpload(
        urls: [URL(fileURLWithPath: "/tmp/first")],
        destination: "/remote"
    ))
    XCTAssertFalse(remote.stageUpload(
        urls: [URL(fileURLWithPath: "/tmp/second")],
        destination: "/remote"
    ))

    let local = FileBrowserTabController(
        initial: FileBrowserTabState(rootPath: "/tmp", rootKind: .project),
        dataSource: MockFileBrowserDataSource()
    )
    XCTAssertFalse(local.stageUpload(
        urls: [URL(fileURLWithPath: "/tmp/first")],
        destination: "/tmp"
    ))
}
```

- [ ] **Step 2: Run the lifecycle tests and verify RED**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests/testStageUploadStoresOnePendingRequestWithoutStartingTransfer \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests/testCancelPendingUploadClearsRequestWithoutStartingTransfer \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests/testConsumePendingUploadReturnsRequestOnlyOnce \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests/testStageUploadRejectsNonFileEmptyLocalAndDuplicateRequests
```

Expected: compilation fails because the pending-upload API does not exist.

- [ ] **Step 3: Implement the pending-request state and lifecycle**

Add above `FileBrowserTabController`:

```swift
struct PendingUploadRequest: Equatable {
    let urls: [URL]
    let destination: String
}
```

Add controller state and acceptance policy:

```swift
private(set) var pendingUpload: PendingUploadRequest?

var canAcceptUploadDrop: Bool {
    FileTransferPresentation.canAcceptUploadDrop(
        isRemote: isRemote,
        isTransferActive: isTransferActive,
        hasPendingUpload: pendingUpload != nil
    )
}
```

Add the lifecycle methods beside the existing transfer methods:

```swift
@discardableResult
func stageUpload(urls: [URL], destination: String) -> Bool {
    guard canAcceptUploadDrop else { return false }
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else { return false }
    pendingUpload = PendingUploadRequest(urls: fileURLs, destination: destination)
    return true
}

func cancelPendingUpload() {
    pendingUpload = nil
}

func consumePendingUpload() -> PendingUploadRequest? {
    defer { pendingUpload = nil }
    return pendingUpload
}

func confirmPendingUpload() async {
    guard let request = consumePendingUpload() else { return }
    await beginUpload(urls: request.urls, destination: request.destination)
}
```

- [ ] **Step 4: Run focused controller and presentation suites and verify GREEN**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileTransferPresentationTests
```

Expected: all selected tests pass with 0 failures and exit code 0.

- [ ] **Step 5: Commit the request lifecycle**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift \
        TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat: stage uploads before confirmation"
```

---

### Task 3: Targeted highlight and confirmation UI

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift:8-190,373-540`
- Modify: `Treemux/Localizable.xcstrings`

**Interfaces:**
- Consumes: the controller APIs produced by Task 2 and `ThemeManager.accentColor`, `sidebarSelection`, and `paneBackground`.
- Produces: themed row/root hover feedback and one panel-level confirmation alert.

- [ ] **Step 1: Replace direct root upload with staging and targeted state**

Add `@State private var isRootUploadTargeted = false` to `FileTreePanelView`. Change the root drop modifier to:

```swift
.dropDestination(for: URL.self) { urls, _ in
    controller.stageUpload(urls: urls, destination: controller.rootPath)
} isTargeted: { targeted in
    isRootUploadTargeted = targeted && controller.canAcceptUploadDrop
}
.background(
    RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isRootUploadTargeted ? theme.accentColor.opacity(0.10) : Color.clear)
)
.overlay {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
            isRootUploadTargeted ? theme.accentColor : Color.clear,
            lineWidth: isRootUploadTargeted ? 1.5 : 0
        )
}
```

Apply these modifiers to the `ScrollView`, not the entire panel, so toolbar and error UI do not flash.

- [ ] **Step 2: Add directory-row targeted state and highlight**

Add `@State private var isUploadTargeted = false` to `FileTreeRow`. Give the existing rounded background drop priority and add a themed border:

```swift
.background(
    RoundedRectangle(cornerRadius: 4)
        .fill(
            isUploadTargeted ? theme.accentColor.opacity(0.16)
            : row.isSelected ? theme.sidebarSelection
            : isHovered ? theme.textPrimary.opacity(0.06)
            : Color.clear
        )
)
.overlay {
    RoundedRectangle(cornerRadius: 4)
        .stroke(
            isUploadTargeted ? theme.accentColor : Color.clear,
            lineWidth: isUploadTargeted ? 1.5 : 0
        )
}
```

Replace the row's direct upload closure with:

```swift
.dropDestination(for: URL.self) { urls, _ in
    guard let destination = FileTransferPresentation.dropDestination(
        for: node,
        rootPath: controller.rootPath
    ) else { return false }
    return controller.stageUpload(urls: urls, destination: destination)
} isTargeted: { targeted in
    isUploadTargeted = targeted
        && controller.canAcceptUploadDrop
        && FileTransferPresentation.dropDestination(
            for: node,
            rootPath: controller.rootPath
        ) != nil
}
```

- [ ] **Step 3: Add the panel-level upload confirmation**

Chain this alert on `FileTreePanelView` before the existing conflict alert:

```swift
.alert(
    LocalizedStringKey("Confirm Upload"),
    isPresented: Binding(
        get: { controller.pendingUpload != nil },
        set: { presented in
            if !presented { controller.cancelPendingUpload() }
        }
    )
) {
    Button(LocalizedStringKey("Upload")) {
        Task { await controller.confirmPendingUpload() }
    }
    Button(LocalizedStringKey("Cancel"), role: .cancel) {
        controller.cancelPendingUpload()
    }
} message: {
    if let request = controller.pendingUpload {
        Text(String.localizedStringWithFormat(
            String(localized: "Upload to: %@"),
            request.destination
        ))
    }
}
.onDisappear {
    controller.cancelPendingUpload()
}
```

Keep the existing conflict and summary presentations unchanged.

- [ ] **Step 4: Add localized strings**

Add `zh-Hans` translated entries in `Treemux/Localizable.xcstrings`:

```json
"Confirm Upload": {
  "localizations": {
    "zh-Hans": {
      "stringUnit": { "state": "translated", "value": "确认上传" }
    }
  }
},
"Upload": {
  "localizations": {
    "zh-Hans": {
      "stringUnit": { "state": "translated", "value": "上传" }
    }
  }
},
"Upload to: %@": {
  "localizations": {
    "zh-Hans": {
      "stringUnit": { "state": "translated", "value": "上传到：%@" }
    }
  }
}
```

- [ ] **Step 5: Compile and run focused tests**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileTransferPresentationTests
```

Expected: build succeeds, all selected tests pass, and exit code is 0.

- [ ] **Step 6: Validate localization and theme usage**

Run:

```bash
plutil -lint Treemux/Localizable.xcstrings
jq -e '.strings["Confirm Upload"].localizations["zh-Hans"].stringUnit.value == "确认上传"' Treemux/Localizable.xcstrings
jq -e '.strings["Upload"].localizations["zh-Hans"].stringUnit.value == "上传"' Treemux/Localizable.xcstrings
jq -e '.strings["Upload to: %@"].localizations["zh-Hans"].stringUnit.value == "上传到：%@"' Treemux/Localizable.xcstrings
git diff -- Treemux/UI/FileBrowser/FileTreePanelView.swift | rg 'Color\((red|white|black)|#[0-9A-Fa-f]{3,8}' && exit 1 || true
```

Expected: plist and all `jq` checks succeed; the hard-coded-color scan has no matches.

- [ ] **Step 7: Commit the UI**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift Treemux/Localizable.xcstrings
git commit -m "feat: confirm highlighted upload drops"
```

---

### Task 4: Regression, Debug build, and DELL acceptance

**Files:**
- Verify: all files changed by Tasks 1-3
- Verify: `docs/superpowers/specs/2026-08-10-upload-drop-confirmation-design.md`

**Interfaces:**
- Consumes: the complete upload-drop interaction.
- Produces: automated, build, localization, theme, and real-GUI evidence suitable for merging to `main`.

- [ ] **Step 1: Run relevant transfer tests**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileTransferPresentationTests \
  -only-testing:TreemuxTests/FileTransferCoordinatorTests \
  -only-testing:TreemuxTests/FileTransferEndpointTests
```

Expected: all selected tests pass with 0 failures and exit code 0.

- [ ] **Step 2: Build a deterministic Debug app**

Run:

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
  -configuration Debug -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath /Users/yanu/Library/Developer/Xcode/DerivedData/Treemux-upload-drop-confirmation
```

Expected: `BUILD SUCCEEDED`, exit code 0, and app at `/Users/yanu/Library/Developer/Xcode/DerivedData/Treemux-upload-drop-confirmation/Build/Products/Debug/Treemux.app`.

- [ ] **Step 3: Run repository checks**

Run:

```bash
git diff --check
plutil -lint Treemux/Localizable.xcstrings
git status --short
```

Expected: no whitespace errors, localization parses, and only intentional committed files are present.

- [ ] **Step 4: Perform DELL-only cancel-path acceptance**

Place Finder and the new Debug app only on the DELL display. Use a fresh local directory containing `nested/alpha.txt`, `nested/deeper/beta.txt`, and `empty-dir`, plus an empty remote destination.

1. Hold `nested` over the remote destination without releasing.
2. Capture and inspect the screen while held: the destination row has accent fill and a 1.5-point accent border.
3. Move away: the highlight disappears. Move back and release.
4. Confirm one `确认上传` alert appears, its message contains the exact remote destination, and it contains no item count.
5. Click `取消` and verify the remote directory is still empty and no progress UI appears.

- [ ] **Step 5: Perform DELL-only confirm-path acceptance**

1. Drag `nested` and `empty-dir` to the same destination again and release.
2. Click `上传` in the single confirmation.
3. Verify the progress UI starts only after the click.
4. Verify the refreshed tree contains both directories.
5. Compare both remote files byte-for-byte with their local sources and verify `empty-dir` remains empty.
6. Verify the transfer summary reports success.

- [ ] **Step 6: Final commit if acceptance required any test-only correction**

If tracked corrections were required, run:

```bash
git add Treemux TreemuxTests docs/superpowers
git commit -m "fix: finalize upload drop confirmation"
```

If no tracked correction was required, leave the existing commits unchanged.

- [ ] **Step 7: Review and merge locally**

Review the complete branch diff against `main`, rerun any affected focused test after review corrections, then merge from the repository root without changing its branch:

```bash
git -C /Users/yanu/Documents/code/Terminal/treemux merge --no-ff codex/fix/upload-drop-confirmation
```

Expected: repository root remains on `main`, merge succeeds without touching the pre-existing untracked `AGENTS.md`, and the merged Debug app is rebuilt from the resulting `main` commit before the final handoff.
