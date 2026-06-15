# P1b-A — Visual Surfaces (apply foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Apply the P1a "Phosphor Instrument" foundation to three existing surfaces — hover-reveal the worktree file-browser button (feature 1), group/visually-distinguish tabs with phosphor underlines (feature 5), and resize/restyle the file tree per the density setting (feature 7).

**Architecture:** Pure SwiftUI changes that consume the already-shipped P1a foundation (`DesignTokens`, `DesignFonts`, `FileTreeSettings.density`, `phosphorUnderline`). One small new pure helper (`TabGrouping`) is unit-tested; the rest is view code verified by build + the full regression suite + a manual checklist. The file-tree **icons** are intentionally left on SF Symbols here — feature 2 (the icon catalog) is a separate plan, P1b-B.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest, XcodeGen, `xcodebuild`. Spec: `docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md` (§1, §5, §7; P1b row).

**Conventions:**
- Worktree `/.worktrees/feat+p1b-visual-surfaces/` on branch `feat/p1b-visual-surfaces`. Run all commands from that root.
- New `.swift` files → run `xcodegen generate` before build/test; commit the regenerated `Treemux.xcodeproj/project.pbxproj`. (project.yml is already at 0.0.13; regeneration must not change version.)
- Build/test need `-skipPackagePluginValidation` (SwiftLint plugin) and a long timeout (≤600000 ms).
  - Build: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet`
  - Test: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/<Class> -skipPackagePluginValidation -quiet`
- New user-visible strings → `LocalizedStringKey` + `zh-Hans` in `Treemux/Localizable.xcstrings`.
- Foundation already available: `DesignTokens` (ink/panel/surface/line/text/muted/faint, shell/files, accent*, `tabAccent(for:)`), `DesignFonts.dataLayer(size:weight:)`, `TreeDensity.rowHeight`/`.fontSize`, `AppSettings.fileTree.density`, `View.phosphorUnderline(_:active:)`.
- The worktree's live SourceKit index is unreliable (false "cannot find <same-module-type>" errors) — trust xcodebuild.

---

## File Structure

| File | Create / Modify | Responsibility |
|------|-----------------|----------------|
| `Treemux/UI/Sidebar/SidebarNodeRow.swift` | Modify | Worktree row's file-browser button → hidden until row hover (feature 1) |
| `Treemux/UI/Workspace/TabGrouping.swift` | Create | Pure helper: partition tabs into file/shell groups preserving order |
| `TreemuxTests/TabGroupingTests.swift` | Create | Unit tests for `TabGrouping.partition` |
| `Treemux/UI/Workspace/WorkspaceTabBarView.swift` | Modify | Files/Shell grouping + eyebrows + divider; phosphor underline by kind (feature 5) |
| `Treemux/UI/FileBrowser/FileTreePanelView.swift` | Modify | Density sizing, monospace names, indent guides, selected-row marker, Phosphor colors (feature 7) |
| `Treemux/Localizable.xcstrings` | Modify | zh-Hans for "Files" / "Shell" eyebrows |

---

## Task 1: Hover-reveal the worktree file-browser button (feature 1)

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift` (`WorktreeRowContent`, the button at lines ~151-161)

> Visual-only one-line change; verified by build + manual check. The **workspace (project) row stays unchanged** (its button keeps the 0.5↔1.0 fade).

- [ ] **Step 1: Change the worktree button opacity**

In `Treemux/UI/Sidebar/SidebarNodeRow.swift`, inside `WorktreeRowContent`, find the file-browser `Button`'s label (currently line ~157):
```swift
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.5))
```
Change the opacity so the icon is fully hidden until the row is hovered:
```swift
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0))
```
Do NOT change `WorkspaceRowContent` (the project row at lines ~90-101) — it keeps `0.5`.

The button still occupies layout width (it's in the HStack before `.padding(.trailing, 2)`), so rows don't reflow on hover. The 0-opacity button remains clickable; that's acceptable here (a precise hover-only hit target is not required).

- [ ] **Step 2: Build to verify it compiles**

Run the build command. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat(sidebar): hide worktree file-browser button until row hover"
```

---

## Task 2: Tab grouping + phosphor underline (feature 5)

**Files:**
- Create: `Treemux/UI/Workspace/TabGrouping.swift`
- Test: `TreemuxTests/TabGroupingTests.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`
- Modify: `Treemux/Localizable.xcstrings`

- [ ] **Step 1: Write the failing test for the grouping helper**

Create `TreemuxTests/TabGroupingTests.swift`:

```swift
//
//  TabGroupingTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class TabGroupingTests: XCTestCase {

    private struct Item { let id: Int; let kind: WorkspaceTabKind }

    func testPartitionSplitsByKindPreservingOrder() {
        let items = [
            Item(id: 1, kind: .terminal),
            Item(id: 2, kind: .fileBrowser),
            Item(id: 3, kind: .terminal),
            Item(id: 4, kind: .fileBrowser),
        ]
        let groups = TabGrouping.partition(items) { $0.kind }
        XCTAssertEqual(groups.files.map(\.id), [2, 4])
        XCTAssertEqual(groups.shell.map(\.id), [1, 3])
    }

    func testPartitionEmpty() {
        let groups = TabGrouping.partition([Item]()) { $0.kind }
        XCTAssertTrue(groups.files.isEmpty)
        XCTAssertTrue(groups.shell.isEmpty)
    }

    func testPartitionAllOneKind() {
        let items = [Item(id: 1, kind: .fileBrowser), Item(id: 2, kind: .fileBrowser)]
        let groups = TabGrouping.partition(items) { $0.kind }
        XCTAssertEqual(groups.files.map(\.id), [1, 2])
        XCTAssertTrue(groups.shell.isEmpty)
    }
}
```

- [ ] **Step 2: Regenerate, run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/TabGroupingTests -skipPackagePluginValidation -quiet
```
Expected: FAIL — "cannot find 'TabGrouping' in scope".

- [ ] **Step 3: Create the grouping helper**

Create `Treemux/UI/Workspace/TabGrouping.swift`:

```swift
//
//  TabGrouping.swift
//  Treemux
//
//  Pure helper that partitions tabs into file-browser and terminal groups for
//  the grouped tab bar, preserving each group's relative order.
//

import Foundation

enum TabGrouping {
    /// Splits `items` into (files, shell) by kind, preserving input order within
    /// each group. Generic over the element so it is unit-testable without
    /// constructing full tab records.
    static func partition<T>(_ items: [T], kindOf: (T) -> WorkspaceTabKind) -> (files: [T], shell: [T]) {
        var files: [T] = []
        var shell: [T] = []
        for item in items {
            switch kindOf(item) {
            case .fileBrowser: files.append(item)
            case .terminal: shell.append(item)
            }
        }
        return (files, shell)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/TabGroupingTests -skipPackagePluginValidation -quiet
```
Expected: PASS (3 tests).

- [ ] **Step 5: Restructure WorkspaceTabBarView to grouped layout**

In `Treemux/UI/Workspace/WorkspaceTabBarView.swift`:

(a) Add a computed `groups` property on `WorkspaceTabBarView` (after the `@State` declarations, before `var body`):
```swift
    private var groups: (files: [WorkspaceTabStateRecord], shell: [WorkspaceTabStateRecord]) {
        TabGrouping.partition(workspace.tabs) { $0.kind }
    }
```

(b) Replace the inner `HStack(spacing: 1) { ForEach(workspace.tabs) { tab in ... } }` (currently lines ~19-62) with grouped rendering that calls a per-tab `@ViewBuilder`:
```swift
                HStack(spacing: 1) {
                    if !groups.files.isEmpty {
                        TabGroupEyebrow(title: "Files", color: DesignTokens.files)
                        ForEach(groups.files) { tab in tabView(tab) }
                    }
                    if !groups.files.isEmpty && !groups.shell.isEmpty {
                        Rectangle()
                            .fill(DesignTokens.line)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 5)
                    }
                    if !groups.shell.isEmpty {
                        TabGroupEyebrow(title: "Shell", color: DesignTokens.shell)
                        ForEach(groups.shell) { tab in tabView(tab) }
                    }
                }
                .padding(.horizontal, 8)
```

(c) Extract the existing per-tab rendering (rename field vs TabButton with the `.onHover`/`.onDrag`/`.onDrop` modifiers) into a `@ViewBuilder` method on `WorkspaceTabBarView`. Paste the EXACT body that was previously inside the `ForEach`:
```swift
    @ViewBuilder
    private func tabView(_ tab: WorkspaceTabStateRecord) -> some View {
        if renamingTabID == tab.id {
            TabRenameField(
                text: $renameText,
                onCommit: {
                    workspace.renameTab(tab.id, title: renameText)
                    renamingTabID = nil
                },
                onCancel: {
                    renamingTabID = nil
                }
            )
            .frame(width: TreemuxTabSizing.width(for: renameText.isEmpty ? "Tab name" : renameText, paneCount: paneCount(for: tab)))
        } else {
            TabButton(
                tab: tab,
                isSelected: tab.id == workspace.activeTabID,
                isHovered: hoveredTabID == tab.id,
                paneCount: paneCount(for: tab),
                isDirty: dirtyState(for: tab),
                dotKind: dotKind(for: tab),
                onSelect: { workspace.selectTab(tab.id) },
                onClose: { workspace.requestCloseTab(tab.id) },
                onRename: {
                    renameText = tab.title
                    renamingTabID = tab.id
                }
            )
            .onHover { isHovered in
                hoveredTabID = isHovered ? tab.id : nil
            }
            .onDrag {
                draggedTabID = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(
                targetTabID: tab.id,
                workspace: workspace,
                draggedTabID: $draggedTabID
            ))
        }
    }
```
(Drag-reorder is unchanged. Within-kind drags reorder correctly; a cross-kind drag is harmless because the bar always re-groups by kind on render — noted in the spec as acceptable.)

(d) Add the eyebrow view at the bottom of the file (near `TabActivityDot`):
```swift
// MARK: - Group Eyebrow

/// Tiny uppercase monospace label marking a tab-kind group ("Files" / "Shell").
private struct TabGroupEyebrow: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(DesignFonts.dataLayer(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.trailing, 2)
    }
}
```

- [ ] **Step 6: Replace the selected stripe with the phosphor underline**

In `TabButton.body`, replace the existing selected-stripe overlay (currently lines ~173-180):
```swift
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                }
            }
```
with the foundation modifier (color-coded by kind):
```swift
            .phosphorUnderline(DesignTokens.tabAccent(for: tab.kind), active: isSelected)
```
Also change the selected tab background (currently `.white.opacity(0.15)` at line ~168) to the on-design surface token — replace only the selected branch:
```swift
            .background(
                isSelected ? AnyShapeStyle(DesignTokens.surface)
                : isHovered ? AnyShapeStyle(.white.opacity(0.08))
                : AnyShapeStyle(.white.opacity(0.05))
            )
```
Leave the kind icon (line ~121), dirty marker, and pane-count badge as they are.

- [ ] **Step 7: Add zh-Hans for the eyebrows**

In `Treemux/Localizable.xcstrings`, add (matching the file's existing expanded multi-line style — read an existing entry like "Save All" first):
- `"Files"` → `"文件"`
- `"Shell"` → `"终端"`

Then validate: `python3 -m json.tool Treemux/Localizable.xcstrings >/dev/null && echo "xcstrings OK"`.

- [ ] **Step 8: Build to verify everything compiles**

Run the build command. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Treemux/UI/Workspace/TabGrouping.swift TreemuxTests/TabGroupingTests.swift Treemux/UI/Workspace/WorkspaceTabBarView.swift Treemux/Localizable.xcstrings Treemux.xcodeproj/project.pbxproj
git commit -m "feat(tabs): group Files/Shell tabs with phosphor-underline distinction"
```

---

## Task 3: File-tree density, monospace, indent guides, selected marker (feature 7)

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`

> Consumes `store.settings.fileTree.density`. `WorkspaceStore` and `ThemeManager` are available as `@EnvironmentObject` here (injected at `WindowContext`; same pattern as `TextEditorView`). The file-tree **icon** stays an SF Symbol in this task — P1b-B swaps it for the icon catalog. Verified by build + manual; density values themselves are already unit-tested in P1a.

- [ ] **Step 1: Inject the store and pass density into the row tree**

In `FileTreePanelView`, add the environment object and pass `density` to the root `NodeRow`s:
```swift
struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            FileTreeErrorBanner(controller: controller)
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rootChildren, id: \.id) { node in
                        NodeRow(node: node, depth: 0, density: store.settings.fileTree.density, controller: controller)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(DesignTokens.panel)
    }
}
```

- [ ] **Step 2: Add the density parameter to NodeRow and thread it through recursion**

In `NodeRow`, add the stored `density` property and pass it to child rows:
```swift
private struct NodeRow: View {
    let node: FileNode
    let depth: Int
    let density: TreeDensity
    @ObservedObject var controller: FileBrowserTabController
    @State private var isHovered = false

    private var isSelected: Bool { controller.selectedFilePath == node.path }
    private var isExpanded: Bool { controller.expandedDirs.contains(node.path) }
    private var children: [FileNode]? { controller.childrenByPath[node.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, let kids = children {
                ForEach(kids, id: \.id) { child in
                    NodeRow(node: child, depth: depth + 1, density: density, controller: controller)
                }
            }
        }
    }
```

- [ ] **Step 3: Restyle the row (density sizing, mono name, indent guides, Phosphor colors, selected marker)**

Replace the `private var row: some View { ... }` body with:
```swift
    private var row: some View {
        HStack(spacing: 4) {
            // Indent guides — one hairline per depth level (14pt per level).
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(DesignTokens.line)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 13)
            }
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.faint)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            // 4×4 git-status dot (clear placeholder keeps name alignment stable).
            if let status = controller.fileStatusByPath[node.path] {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
            Image(systemName: iconName)
                .font(.system(size: density.fontSize))
                .foregroundStyle(DesignTokens.muted)
                .frame(width: density.fontSize + 2)
            Text(node.name)
                .font(DesignFonts.dataLayer(size: density.fontSize))
                .foregroundStyle(DesignTokens.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(height: density.rowHeight)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? DesignTokens.surface
                      : isHovered ? DesignTokens.text.opacity(0.06)
                      : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DesignTokens.files)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                if !node.isDirectory {
                    Task { await controller.pinFile(node.path) }
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if node.isDirectory {
                    Task { await controller.toggleExpand(node.path) }
                } else {
                    Task { await controller.openInTree(node.path) }
                }
            }
        )
        .contextMenu {
            Button(LocalizedStringKey("Copy Absolute Path")) {
                controller.copyPath(node.path, mode: .absolute)
            }
            Button(LocalizedStringKey("Copy Relative Path")) {
                controller.copyPath(node.path, mode: .relative)
            }
            .disabled(node.path == controller.rootPath)
        }
    }
```
Leave the `iconName` computed property and `color(for:)` exactly as they are (icons change in P1b-B). Note the `.padding(.vertical, 3)` was removed in favor of the fixed `.frame(height: density.rowHeight)`.

- [ ] **Step 4: Build to verify it compiles**

Run the build command. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(filetree): density sizing, monospace names, indent guides, phosphor selection"
```

---

## Task 4: Phase verification

**Files:** none (verification only)

- [ ] **Step 1: Run the new + relevant tests**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/TabGroupingTests -only-testing:TreemuxTests/FileTreeSettingsTests -only-testing:TreemuxTests/DesignTokensTests -skipPackagePluginValidation -quiet
```
Expected: all PASS (TabGrouping 3 + FileTreeSettings 6 + DesignTokens 5 = 14).

- [ ] **Step 2: Full regression suite**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
```
Expected: `** TEST SUCCEEDED **`, no failures. If any fail, report whether they relate to P1b-A surfaces (sidebar/tabs/filetree) or are pre-existing/unrelated.

- [ ] **Step 3: Full Debug build + locate app**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation -quiet
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```
Report the built-app path + the `Treemux-<id>` DerivedData segment.

- [ ] **Step 4: Manual verification checklist**

Launch the app and confirm:
- **Feature 1:** A worktree row's file-browser (`folder.badge.plus`) icon is invisible until you hover that row; the project row's icon stays visible (dimmed) as before.
- **Feature 5:** With both a file tab and a terminal tab open, the tab bar shows a `FILES` eyebrow (azure) over file tabs and a `SHELL` eyebrow (green) over terminal tabs with a divider between; the selected file tab shows an azure phosphor underline, the selected terminal tab a green one. Eyebrows read 文件 / 终端 when the app language is 中文.
- **Feature 7:** The file tree rows are larger (default Comfortable), file names are monospace, depth shows hairline indent guides, and the selected row has an azure left marker on a raised background. Switching Settings → General → File Tree Density between Compact/Comfortable/Spacious changes row height/font size live.

---

## Notes for P1b-B (file icons — separate plan)

P1b-B replaces `NodeRow.iconName` (SF Symbols) with a `FileIconCatalog` driving bundled MDI (abstract, template-tinted via the type-accent palette) + Material Icon Theme (colorful) SVG assets in `Assets.xcassets`. Tooling confirmed available: `curl` + network (jsDelivr), `rsvg-convert`, and Xcode 26 native SVG asset-catalog support (so SVGs can be added directly with "Preserve Vector Data"; PDF conversion optional). The per-type accent colors (`DesignTokens.accent*`) are already defined for the monochrome baseline.
