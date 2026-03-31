# Sidebar Sections & Drag-Drop Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix broken workspace drag-drop reordering and add collapsible section headers to group local vs remote repositories in the sidebar.

**Architecture:** Add `.section` node type to `SidebarNodeItem`, restructure `SidebarCoordinator.buildNodes()` to wrap workspaces in section containers when remote repos exist, add section-aware drag-drop validation, persist collapsed state in `PersistedWorkspaceState`, and render section headers as custom SwiftUI views hosted in `NSHostingView`.

**Tech Stack:** Swift, AppKit (NSOutlineView), SwiftUI, Codable persistence

---

### Task 1: Add `SidebarSection` enum and extend `SidebarNodeItem`

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeItem.swift`

**Step 1: Add `SidebarSection` enum and `.section` case**

```swift
// Add above the SidebarNodeItem class:
enum SidebarSection: Hashable {
    case local
    case remote(groupKey: String, displayTitle: String)

    var persistenceKey: String {
        switch self {
        case .local: return "local"
        case .remote(let groupKey, _): return groupKey
        }
    }
}
```

Update `SidebarNodeItem.Kind`:
```swift
enum Kind {
    case section(SidebarSection)
    case workspace(WorkspaceModel)
    case worktree(WorkspaceModel, WorktreeModel)
}
```

**Step 2: Update computed properties for the new case**

Update `nodeID`:
```swift
var nodeID: String {
    switch kind {
    case .section(let section): return "section:\(section.persistenceKey)"
    case .workspace(let ws): return ws.id.uuidString
    case .worktree(_, let wt): return wt.id.uuidString
    }
}
```

Update `workspace`:
```swift
var workspace: WorkspaceModel? {
    switch kind {
    case .section: return nil
    case .workspace(let ws): return ws
    case .worktree(let ws, _): return ws
    }
}
```

Update `worktree`:
```swift
var worktree: WorktreeModel? {
    switch kind {
    case .section: return nil
    case .workspace: return nil
    case .worktree(_, let wt): return wt
    }
}
```

**Step 3: Build and verify no compile errors**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (with possible warnings from other files referencing `.section` in switch — fix any exhaustive switch errors in the next task)

**Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeItem.swift
git commit -m "feat: add SidebarSection enum and .section case to SidebarNodeItem"
```

---

### Task 2: Add `collapsedSections` to persistence and `moveRemoteWorkspace` to WorkspaceStore

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift` (lines 134-138, `PersistedWorkspaceState`)
- Modify: `Treemux/App/WorkspaceStore.swift` (add `moveRemoteWorkspace`, update `saveWorkspaceState`, add `collapsedSections` state)

**Step 1: Add `collapsedSections` to `PersistedWorkspaceState`**

In `Treemux/Domain/WorkspaceModels.swift`, change:
```swift
struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
}
```
to:
```swift
struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
    var collapsedSections: [String]?
}
```

**Step 2: Add `collapsedSections` state and `moveRemoteWorkspace` to WorkspaceStore**

In `Treemux/App/WorkspaceStore.swift`, add a published property near other state:
```swift
@Published var collapsedSections: Set<String> = []
```

Add a helper to generate the display title for a remote group (used by both the coordinator and the store):
```swift
/// Display title for a remote workspace group, e.g. "my-server (root@192.168.1.100)".
static func remoteGroupDisplayTitle(for target: SSHTarget) -> String {
    if let user = target.user, !user.isEmpty {
        return "\(target.displayName) (\(user)@\(target.host))"
    }
    return "\(target.displayName) (\(target.host))"
}
```

Add the `moveRemoteWorkspace` method after `moveLocalWorkspace`:
```swift
/// Moves remote workspaces within a specific server group.
func moveRemoteWorkspace(groupKey: String, from source: IndexSet, to destination: Int) {
    let remotes = workspaces.filter { !$0.isArchived && $0.sshTarget != nil }
    var group = remotes.filter { ws in
        guard let target = ws.sshTarget else { return false }
        let user = target.user ?? ""
        return "\(target.displayName)|\(user)" == groupKey
    }
    group.move(fromOffsets: source, toOffset: destination)
    let movedIDs = Set(group.map { $0.id })
    // Rebuild workspaces: keep everything not in this group in place, replace group items in order
    var result: [WorkspaceModel] = []
    var groupIterator = group.makeIterator()
    for ws in workspaces {
        if movedIDs.contains(ws.id) {
            if let next = groupIterator.next() {
                result.append(next)
            }
        } else {
            result.append(ws)
        }
    }
    workspaces = result
    saveWorkspaceState()
}
```

**Step 3: Update `saveWorkspaceState` to persist collapsed sections**

In `saveWorkspaceState()`, change:
```swift
let state = PersistedWorkspaceState(
    version: 1,
    selectedWorkspaceID: persistedSelectedID,
    workspaces: workspaces.map { $0.toRecord() }
)
```
to:
```swift
let state = PersistedWorkspaceState(
    version: 1,
    selectedWorkspaceID: persistedSelectedID,
    workspaces: workspaces.map { $0.toRecord() },
    collapsedSections: collapsedSections.isEmpty ? nil : Array(collapsedSections)
)
```

**Step 4: Load collapsed sections in `loadWorkspaceState`**

In `loadWorkspaceState()`, after loading state, add:
```swift
collapsedSections = Set(state.collapsedSections ?? [])
```

**Step 5: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Treemux/App/WorkspaceStore.swift
git commit -m "feat: add collapsedSections persistence and moveRemoteWorkspace method"
```

---

### Task 3: Add `SectionHeaderRow` SwiftUI view

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift` (add `SectionHeaderRow` and update `SidebarNodeRow` switch)

**Step 1: Add the `.section` case to `SidebarNodeRow`**

In `SidebarNodeRow.body`, add the new case:
```swift
var body: some View {
    switch node.kind {
    case .section(let section):
        SectionHeaderRow(section: section, theme: theme)
    case .workspace(let ws):
        WorkspaceRowContent(
            workspace: ws,
            store: store,
            theme: theme,
            isSelected: isSelected
        )
    case .worktree(let ws, let wt):
        WorktreeRowContent(
            workspace: ws,
            worktree: wt,
            store: store,
            theme: theme,
            isSelected: isSelected
        )
    }
}
```

**Step 2: Create `SectionHeaderRow` view in the same file**

Add after `WorktreeRowContent`:
```swift
// MARK: - SectionHeaderRow

/// Displays a section header for grouping local/remote workspaces.
struct SectionHeaderRow: View {
    let section: SidebarSection
    let theme: ThemeManager

    private var title: String {
        switch section {
        case .local:
            return String(localized: "Local")
        case .remote(_, let displayTitle):
            return displayTitle
        }
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }
}
```

**Step 3: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat: add SectionHeaderRow view for sidebar section headers"
```

---

### Task 4: Refactor `SidebarCoordinator.buildNodes()` to support sections

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift`
- Modify: `Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift`

**Step 1: Update `WorkspaceOutlineSidebar.updateNSView` to pass structured data**

In `WorkspaceOutlineSidebar.updateNSView`, change:
```swift
let workspaces = store.localWorkspaces + store.remoteWorkspaceGroups.flatMap(\.targets)
coordinator.apply(
    workspaces: workspaces,
    selectedWorkspaceID: store.selectedWorkspaceID,
    theme: theme
)
```
to:
```swift
coordinator.apply(
    store: store,
    selectedWorkspaceID: store.selectedWorkspaceID,
    theme: theme
)
```

**Step 2: Update `SidebarCoordinator.apply` signature**

Change the `apply` method to accept the store directly instead of a flat workspace array:
```swift
func apply(
    store: WorkspaceStore,
    selectedWorkspaceID: UUID?,
    theme: ThemeManager
) {
    self.theme = theme
    let localWorkspaces = store.localWorkspaces
    let remoteGroups = store.remoteWorkspaceGroups
    let allWorkspaces = localWorkspaces + remoteGroups.flatMap(\.targets)
    let fingerprint = dataFingerprint(workspaces: allWorkspaces)
    let dataChanged = fingerprint != lastDataFingerprint

    if dataChanged {
        lastDataFingerprint = fingerprint
        rootNodes = buildNodes(
            localWorkspaces: localWorkspaces,
            remoteGroups: remoteGroups
        )
        container?.reloadOutlineData()

        guard let outlineView = container?.outlineView else { return }
        // Expand all nodes by default, then collapse persisted sections.
        for node in rootNodes {
            outlineView.expandItem(node)
            // Expand workspace children (worktrees)
            for child in node.children {
                if child.isExpandable {
                    outlineView.expandItem(child)
                }
            }
        }
        // Apply persisted collapsed state
        for node in rootNodes {
            if case .section(let section) = node.kind,
               store.collapsedSections.contains(section.persistenceKey) {
                outlineView.collapseItem(node)
            }
        }
        synchronizeSelection(on: outlineView, selectedWorkspaceID: selectedWorkspaceID)
    } else {
        guard let outlineView = container?.outlineView else { return }
        synchronizeSelection(on: outlineView, selectedWorkspaceID: selectedWorkspaceID)
    }
}
```

**Step 3: Refactor `buildNodes` to support sections**

Replace the existing `buildNodes(from:)` method:
```swift
private func buildNodes(
    localWorkspaces: [WorkspaceModel],
    remoteGroups: [(key: String, targets: [WorkspaceModel])]
) -> [SidebarNodeItem] {
    let hasRemote = !remoteGroups.isEmpty

    if !hasRemote {
        // No sections — flat list like before
        return localWorkspaces.map { makeWorkspaceNode($0) }
    }

    // Build sectioned tree
    var sections: [SidebarNodeItem] = []

    // Local section
    if !localWorkspaces.isEmpty {
        let localChildren = localWorkspaces.map { makeWorkspaceNode($0) }
        sections.append(SidebarNodeItem(
            kind: .section(.local),
            children: localChildren
        ))
    }

    // Remote sections
    for group in remoteGroups {
        let displayTitle: String
        if let firstTarget = group.targets.first?.sshTarget {
            displayTitle = WorkspaceStore.remoteGroupDisplayTitle(for: firstTarget)
        } else {
            displayTitle = group.key
        }
        let remoteChildren = group.targets.map { makeWorkspaceNode($0) }
        sections.append(SidebarNodeItem(
            kind: .section(.remote(groupKey: group.key, displayTitle: displayTitle)),
            children: remoteChildren
        ))
    }

    return sections
}

private func makeWorkspaceNode(_ workspace: WorkspaceModel) -> SidebarNodeItem {
    let children: [SidebarNodeItem]
    if workspace.worktrees.count > 1 {
        children = workspace.worktrees.map { worktree in
            SidebarNodeItem(kind: .worktree(workspace, worktree))
        }
    } else {
        children = []
    }
    return SidebarNodeItem(kind: .workspace(workspace), children: children)
}
```

**Step 4: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift
git commit -m "feat: refactor buildNodes to support section grouping with smart display"
```

---

### Task 5: Update delegate methods for section nodes

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift`

**Step 1: Update `heightOfRowByItem` for sections**

```swift
func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    guard let node = item as? SidebarNodeItem else { return 36 }
    switch node.kind {
    case .section: return 24
    case .workspace: return 36
    case .worktree: return 28
    }
}
```

**Step 2: Add `shouldSelectItem` to prevent section selection**

```swift
func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    guard let node = item as? SidebarNodeItem else { return false }
    switch node.kind {
    case .section: return false
    case .workspace, .worktree: return true
    }
}
```

**Step 3: Track collapse/expand for persistence**

Add two delegate methods:
```swift
func outlineViewItemDidCollapse(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? SidebarNodeItem,
          case .section(let section) = node.kind else { return }
    store?.collapsedSections.insert(section.persistenceKey)
    store?.saveWorkspaceState()
}

func outlineViewItemDidExpand(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? SidebarNodeItem,
          case .section(let section) = node.kind else { return }
    store?.collapsedSections.remove(section.persistenceKey)
    store?.saveWorkspaceState()
}
```

**Step 4: Update `synchronizeSelection` to handle section layer**

The existing `synchronizeSelection` uses `rootNodes.flatMap { $0.flattened() }` which already traverses children recursively. Verify this works with sections by checking `flattened()` returns section → workspace → worktree nodes. The existing implementation already handles this since `.section` nodes have children and `flattened()` recurses through `children`.

No code change needed here — just verify.

**Step 5: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift
git commit -m "feat: add section delegate behavior (height, selection, collapse persistence)"
```

---

### Task 6: Fix drag-and-drop with section-aware logic

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift` (drag & drop methods)

**Step 1: Update `pasteboardWriterForItem` — sections not draggable**

No change needed — current code already only writes pasteboard for `.workspace` nodes.

**Step 2: Rewrite `validateDrop` with section awareness**

Replace the existing `validateDrop`:
```swift
func outlineView(
    _ outlineView: NSOutlineView,
    validateDrop info: NSDraggingInfo,
    proposedItem item: Any?,
    proposedChildIndex index: Int
) -> NSDragOperation {
    guard let payload = info.draggingPasteboard.string(forType: Self.workspaceDragType),
          let draggedID = UUID(uuidString: payload) else { return [] }

    let hasSections = rootNodes.contains { if case .section = $0.kind { return true }; return false }

    if hasSections {
        // Must drop into a section node
        guard let targetNode = item as? SidebarNodeItem,
              case .section(let targetSection) = targetNode.kind else { return [] }

        // Find which section the dragged workspace belongs to
        guard let sourceSection = findSection(forWorkspaceID: draggedID) else { return [] }

        // Only allow drop within the same section
        return sourceSection.persistenceKey == targetSection.persistenceKey ? .move : []
    } else {
        // No sections — flat mode, drop at root level only
        guard item == nil else { return [] }
        return .move
    }
}
```

**Step 3: Add helper to find the section a workspace belongs to**

```swift
private func findSection(forWorkspaceID id: UUID) -> SidebarSection? {
    for node in rootNodes {
        if case .section(let section) = node.kind {
            if node.children.contains(where: {
                if case .workspace(let ws) = $0.kind { return ws.id == id }
                return false
            }) {
                return section
            }
        }
    }
    return nil
}
```

**Step 4: Rewrite `acceptDrop` with section-local indexing**

Replace the existing `acceptDrop`:
```swift
func outlineView(
    _ outlineView: NSOutlineView,
    acceptDrop info: NSDraggingInfo,
    item: Any?,
    childIndex index: Int
) -> Bool {
    guard let payload = info.draggingPasteboard.string(forType: Self.workspaceDragType),
          let draggedID = UUID(uuidString: payload) else { return false }

    let hasSections = rootNodes.contains { if case .section = $0.kind { return true }; return false }

    if hasSections {
        guard let sectionNode = item as? SidebarNodeItem,
              case .section(let section) = sectionNode.kind else { return false }

        let children = sectionNode.children
        guard let sourceIndex = children.firstIndex(where: {
            if case .workspace(let ws) = $0.kind { return ws.id == draggedID }
            return false
        }) else { return false }

        let destination = index == -1 ? children.count : index

        switch section {
        case .local:
            store?.moveLocalWorkspace(from: IndexSet(integer: sourceIndex), to: destination)
        case .remote(let groupKey, _):
            store?.moveRemoteWorkspace(groupKey: groupKey, from: IndexSet(integer: sourceIndex), to: destination)
        }
        return true
    } else {
        // Flat mode — local only
        guard item == nil else { return false }
        guard let sourceIndex = rootNodes.firstIndex(where: {
            if case .workspace(let ws) = $0.kind { return ws.id == draggedID }
            return false
        }) else { return false }

        let destination = index == -1 ? rootNodes.count : index
        store?.moveLocalWorkspace(from: IndexSet(integer: sourceIndex), to: destination)
        return true
    }
}
```

**Step 5: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift
git commit -m "fix: section-aware drag-drop with correct local indexing"
```

---

### Task 7: Add i18n for "Local" section header

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add "Local" translation entry**

In `Treemux/Localizable.xcstrings`, add a new entry in the `strings` object:
```json
"Local" : {
  "localizations" : {
    "zh-Hans" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "本地"
      }
    }
  }
}
```

**Step 2: Build and verify**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: add Chinese translation for Local section header"
```

---

### Task 8: Write tests for section building and reordering

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Add test for `PersistedWorkspaceState` with `collapsedSections`**

```swift
func testPersistedWorkspaceStateWithCollapsedSections() throws {
    let state = PersistedWorkspaceState(
        version: 1,
        selectedWorkspaceID: nil,
        workspaces: [],
        collapsedSections: ["local", "myserver|root"]
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    XCTAssertEqual(decoded.collapsedSections, ["local", "myserver|root"])
}

func testPersistedWorkspaceStateNilCollapsedSections() throws {
    let state = PersistedWorkspaceState(
        version: 1,
        selectedWorkspaceID: nil,
        workspaces: [],
        collapsedSections: nil
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    XCTAssertNil(decoded.collapsedSections)
}

func testPersistedWorkspaceStateBackwardsCompatibility() throws {
    // Old JSON without collapsedSections field should decode fine
    let json = """
    {"version":1,"selectedWorkspaceID":null,"workspaces":[]}
    """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    XCTAssertNil(decoded.collapsedSections)
}
```

**Step 2: Add test for `SidebarSection.persistenceKey`**

```swift
func testSidebarSectionPersistenceKey() {
    let local = SidebarSection.local
    XCTAssertEqual(local.persistenceKey, "local")

    let remote = SidebarSection.remote(groupKey: "server1|root", displayTitle: "server1 (root@10.0.0.1)")
    XCTAssertEqual(remote.persistenceKey, "server1|root")
}
```

**Step 3: Add test for `WorkspaceStore.remoteGroupDisplayTitle`**

```swift
func testRemoteGroupDisplayTitle() {
    let targetWithUser = SSHTarget(
        host: "192.168.1.100", port: 22, user: "root",
        identityFile: nil, displayName: "my-server", remotePath: nil
    )
    XCTAssertEqual(
        WorkspaceStore.remoteGroupDisplayTitle(for: targetWithUser),
        "my-server (root@192.168.1.100)"
    )

    let targetWithoutUser = SSHTarget(
        host: "192.168.1.100", port: 22, user: nil,
        identityFile: nil, displayName: "my-server", remotePath: nil
    )
    XCTAssertEqual(
        WorkspaceStore.remoteGroupDisplayTitle(for: targetWithoutUser),
        "my-server (192.168.1.100)"
    )
}
```

**Step 4: Run tests**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild test -scheme Treemux -configuration Debug -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add TreemuxTests/WorkspaceModelsTests.swift
git commit -m "test: add tests for section persistence and remote group display title"
```

---

### Task 9: Manual QA & edge case verification

**No code changes — manual testing checklist.**

1. **Local only (no SSH repos):** Sidebar shows flat list with no section headers. Drag reorder works.
2. **Local + remote:** Sidebar shows "本地" and "server (user@host)" sections with disclosure arrows. Both sections expand/collapse.
3. **Collapse persistence:** Collapse a section → quit app → reopen → section stays collapsed.
4. **Drag within local section:** Works, order persists after restart.
5. **Drag within remote section:** Works, order persists after restart.
6. **Drag across sections:** Forbidden cursor, drop rejected.
7. **Section not selectable:** Clicking section header does not change selection.
8. **Add new remote repo:** New section appears. If it's the first remote, "本地" header appears too.
9. **Remove all remote repos:** Section headers disappear, returns to flat layout.

Run: `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`
