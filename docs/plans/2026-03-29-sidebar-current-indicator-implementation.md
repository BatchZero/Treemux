# Sidebar Icon Activity Indicator & "Current" Logic Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the sidebar icon system to a three-state activity indicator (none/current/working) with Liney-aligned layout, replacing the current `isActive` green dot and selection-based "current" badge.

**Architecture:** Incremental refactor on the existing SwiftUI List + SidebarNodeRow architecture. Add `SidebarIconActivityIndicator` enum and `SidebarIconActivityBadge` animation view to `SidebarItemIconView.swift`. Add `hasRunningSessions(forWorktreePath:)` to `WorkspaceModel`. Create new `SidebarInfoBadge` component. Update row views to use `activeWorktreePath` instead of `isSelected` for "current" semantics.

**Tech Stack:** SwiftUI, AppKit (NSOutlineView integration), SF Symbols

---

### Task 1: Add `hasRunningSessions(forWorktreePath:)` to WorkspaceModel

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:197` (near `tabControllers`)

**Step 1: Add the method**

In `WorkspaceModels.swift`, add the following method to `WorkspaceModel` after line 217 (after `sessionController(forWorktreePath:)`):

```swift
/// Returns true if the given worktree path has any active tab controllers (running sessions).
func hasRunningSessions(forWorktreePath path: String) -> Bool {
    guard let controllers = tabControllers[path] else { return false }
    return !controllers.isEmpty
}

/// Returns true if any worktree path in this workspace has running sessions.
var hasAnyRunningSessions: Bool {
    tabControllers.values.contains { !$0.isEmpty }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: add hasRunningSessions methods to WorkspaceModel"
```

---

### Task 2: Rewrite SidebarItemIconView with activity indicator support

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarItemIconView.swift`

**Step 1: Replace the entire file content**

Replace the full contents of `SidebarItemIconView.swift` with:

```swift
//
//  SidebarItemIconView.swift
//  Treemux
//

import SwiftUI

// MARK: - Activity Indicator State

/// Three-state activity indicator for sidebar icons.
enum SidebarIconActivityIndicator {
    case none
    case current   // Static dot — this worktree is the active working directory
    case working   // Animated pulse — terminal sessions are running
}

// MARK: - Icon View

/// Renders a sidebar icon as a rounded-rectangle (or circular) tile with an SF Symbol
/// and an optional activity indicator badge at the bottom-right corner.
struct SidebarItemIconView: View {
    let icon: SidebarItemIcon
    let size: CGFloat
    var usesCircularShape: Bool = false
    var activityIndicator: SidebarIconActivityIndicator = .none
    var activityPalette: SidebarIconPalette = .amber
    var isEmphasized: Bool = false

    private var palette: SidebarIconPaletteDescriptor {
        icon.palette.descriptor
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(
            cornerRadius: usesCircularShape ? size / 2 : max(7, size * 0.34),
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon.symbolName)
                .font(.system(size: max(9, size * 0.48), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay(
                    backgroundShape
                        .strokeBorder(palette.border, lineWidth: 1)
                )

            if activityIndicator != .none {
                SidebarIconActivityBadge(
                    kind: activityIndicator,
                    size: size,
                    palette: activityPalette,
                    isEmphasized: isEmphasized
                )
                .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }

    @ViewBuilder
    private var background: some View {
        switch icon.fillStyle {
        case .solid:
            backgroundShape.fill(palette.solidBackground)
        case .gradient:
            backgroundShape.fill(
                LinearGradient(
                    colors: [palette.gradientStart, palette.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

// MARK: - Activity Badge

/// Animated or static badge shown at the bottom-right of a sidebar icon.
struct SidebarIconActivityBadge: View {
    let kind: SidebarIconActivityIndicator
    let size: CGFloat
    let palette: SidebarIconPalette
    let isEmphasized: Bool
    @State private var isAnimating = false

    private var activityColor: Color {
        palette.descriptor.gradientEnd
    }

    private var badgeSize: CGFloat {
        switch kind {
        case .working:
            return max(7, size * 0.34)
        case .current, .none:
            return max(6, size * 0.28)
        }
    }

    private var pulseLineWidth: CGFloat {
        isEmphasized ? 1.4 : 1.15
    }

    private var pulseOpacity: Double {
        isEmphasized ? 0.8 : 0.5
    }

    private var pulseScale: CGFloat {
        isEmphasized ? 2.15 : 1.85
    }

    private var pulseDuration: Double {
        isEmphasized ? 0.95 : 1.15
    }

    private var coreScale: CGFloat {
        guard kind == .working else { return 1 }
        return isAnimating ? 1.18 : 0.9
    }

    private var coreOpacity: Double {
        guard kind == .working else { return 1 }
        return isAnimating ? 1 : 0.82
    }

    private var glowRadius: CGFloat {
        guard kind == .working else { return 0 }
        return isEmphasized ? 6 : 4
    }

    var body: some View {
        ZStack {
            if kind == .working {
                Circle()
                    .fill(activityColor.opacity(isAnimating ? 0.18 : 0.06))
                    .frame(width: badgeSize, height: badgeSize)
                    .scaleEffect(isAnimating ? pulseScale * 0.9 : 1.0)
                    .blur(radius: isEmphasized ? 1.2 : 0.8)

                Circle()
                    .stroke(activityColor.opacity(pulseOpacity), lineWidth: pulseLineWidth)
                    .frame(width: badgeSize, height: badgeSize)
                    .scaleEffect(isAnimating ? pulseScale : 1.0)
                    .opacity(isAnimating ? 0 : pulseOpacity)
            }

            Circle()
                .fill(activityColor)
                .frame(width: badgeSize, height: badgeSize)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                .scaleEffect(coreScale)
                .opacity(coreOpacity)
                .shadow(color: activityColor.opacity(kind == .working ? 0.9 : 0), radius: glowRadius)
        }
        .onAppear {
            updateAnimationState()
        }
        .onChange(of: kind) { _, _ in
            updateAnimationState()
        }
    }

    private func updateAnimationState() {
        guard kind == .working else {
            isAnimating = false
            return
        }
        isAnimating = false
        withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (call sites that used `isActive:` will fail — we fix those in Task 4)

Note: If build fails due to `isActive` references in `SidebarNodeRow.swift` and `WorkspaceSidebarView.swift`, that's expected. Continue to Task 3 and Task 4 which fix those call sites.

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarItemIconView.swift
git commit -m "feat: rewrite SidebarItemIconView with activity indicator support"
```

---

### Task 3: Create SidebarInfoBadge component

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarInfoBadge.swift`

**Step 1: Create the file**

Create `Treemux/UI/Sidebar/SidebarInfoBadge.swift`:

```swift
//
//  SidebarInfoBadge.swift
//  Treemux
//

import SwiftUI

/// A reusable capsule-shaped badge for sidebar row metadata.
struct SidebarInfoBadge: View {
    enum Tone {
        case neutral
        case accent
        case success
        case subtleSuccess
        case warning
    }

    let text: String
    let tone: Tone

    private var foreground: Color {
        switch tone {
        case .neutral:
            return .secondary
        case .accent:
            return .accentColor
        case .success:
            return .green
        case .subtleSuccess:
            return .green.opacity(0.82)
        case .warning:
            return .orange
        }
    }

    private var background: Color {
        switch tone {
        case .subtleSuccess:
            return .green.opacity(0.08)
        default:
            return Color.gray.opacity(0.15)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}
```

**Step 2: Add to Xcode project**

The file is in the `Treemux/UI/Sidebar/` directory, which is already included in the Xcode project's folder reference. It should be picked up automatically.

**Step 3: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (or expected failures from Task 2's `isActive` removal — resolved in Task 4)

**Step 4: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarInfoBadge.swift
git commit -m "feat: add SidebarInfoBadge reusable badge component"
```

---

### Task 4: Update SidebarNodeRow with new layout and current logic

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift`

**Step 1: Replace the entire file content**

Replace `SidebarNodeRow.swift` with:

```swift
//
//  SidebarNodeRow.swift
//  Treemux

import SwiftUI

/// Dispatches rendering to workspace or worktree row content
/// based on the SidebarNodeItem kind.
/// All dependencies are passed as parameters — no @EnvironmentObject usage.
struct SidebarNodeRow: View {
    let node: SidebarNodeItem
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    var body: some View {
        switch node.kind {
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
}

// MARK: - WorkspaceRowContent

/// Displays workspace icon, name, optional branch, and current badge.
struct WorkspaceRowContent: View {
    let workspace: WorkspaceModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasAnyRunningSessions {
            return .working
        }
        if workspace.activeWorktreePath == workspace.repositoryRoot?.path {
            return .current
        }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: workspace),
                size: 22,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if activityIndicator == .current {
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isSelected ? theme.sidebarSelection.opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - WorktreeRowContent

/// Displays worktree icon, branch name, and current badge.
struct WorktreeRowContent: View {
    let workspace: WorkspaceModel
    let worktree: WorktreeModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasRunningSessions(forWorktreePath: worktree.path.path) {
            return .working
        }
        if workspace.activeWorktreePath == worktree.path.path {
            return .current
        }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 16,
                usesCircularShape: true,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected
            )
            .frame(width: 24, alignment: .leading)
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.sidebarForeground)
                .lineLimit(1)
            Spacer()
            if activityIndicator == .current {
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isSelected ? theme.sidebarSelection.opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
```

**Step 2: Build to verify compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: May still fail if `WorkspaceSidebarView.swift` references old `isActive` — resolved in Task 5.

**Step 3: Commit**

```bash
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat: update SidebarNodeRow with activity indicators and Liney-aligned layout"
```

---

### Task 5: Update WorkspaceSidebarView with new current logic and layout

**Files:**
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`

**Step 1: Update ProjectLabel**

In `WorkspaceSidebarView.swift`, replace `ProjectLabel` (lines 319–341) with:

```swift
/// Displays a project icon, name, and optional "current" badge.
struct ProjectLabel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasAnyRunningSessions {
            return .working
        }
        if workspace.activeWorktreePath == workspace.repositoryRoot?.path {
            return .current
        }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: workspace),
                size: 22,
                activityIndicator: activityIndicator
            )
            Text(workspace.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if activityIndicator == .current {
                Spacer()
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
        }
    }
}
```

**Step 2: Update WorktreeRow**

Replace `WorktreeRow` (lines 346–395) with:

```swift
/// A single worktree row shown inside a disclosure group.
struct WorktreeRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var workspace: WorkspaceModel
    let worktree: WorktreeModel
    @Binding var hoveredID: UUID?

    private var isSelected: Bool {
        store.selectedWorkspaceID == worktree.id
    }

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasRunningSessions(forWorktreePath: worktree.path.path) {
            return .working
        }
        if workspace.activeWorktreePath == worktree.path.path {
            return .current
        }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 16,
                usesCircularShape: true,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected
            )
            .frame(width: 24, alignment: .leading)
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer()
            if activityIndicator == .current {
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
        }
        .onHover { isHovering in
            if isHovering { hoveredID = worktree.id }
            else if hoveredID == worktree.id { hoveredID = nil }
        }
        .contextMenu {
            Button {
                store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                    target: .worktree(workspaceID: workspace.id, worktreePath: worktree.path.path)
                )
            } label: {
                Label(String(localized: "Change Icon…"), systemImage: "paintpalette")
            }
        }
        .listRowBackground(sidebarRowBackground(
            isSelected: isSelected,
            isHovered: hoveredID == worktree.id
        ))
    }
}
```

**Step 3: Update WorkspaceRowGroup**

In `WorkspaceRowGroup`, remove `showCurrent: isWorkspaceSelected` from `ProjectLabel` calls (lines 273–276 and 291–294). The `showCurrent` parameter no longer exists — `ProjectLabel` now determines current state internally.

Replace:
```swift
ProjectLabel(
    workspace: workspace,
    showCurrent: isWorkspaceSelected
)
```

With:
```swift
ProjectLabel(workspace: workspace)
```

There are two occurrences: one inside the DisclosureGroup label (line ~273) and one in the single-worktree VStack (line ~291).

Also update the single-worktree branch text font to match Liney:

Replace:
```swift
if let branch = workspace.currentBranch {
    Text(branch)
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        .padding(.leading, 20)
}
```

With:
```swift
if let branch = workspace.currentBranch {
    Text(branch)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        .padding(.leading, 24)
}
```

**Step 4: Build to verify full compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Treemux/UI/Sidebar/WorkspaceSidebarView.swift
git commit -m "feat: update WorkspaceSidebarView with activity indicators and Liney-aligned layout"
```

---

### Task 6: Fix remaining call sites (Settings, Icon Customization)

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:384,410`
- Modify: `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift:21`

These files use `SidebarItemIconView` but only for display purposes (no activity indicator needed). Verify they still compile since the `isActive` parameter was removed (it had a default value of `false`, and the new parameters all have defaults too).

**Step 1: Check compilation**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED — these call sites only use `icon:` and `size:`, which are unchanged.

If any call site still passes `isActive:`, remove that argument.

**Step 2: Commit (only if changes needed)**

```bash
git add -u
git commit -m "fix: update remaining SidebarItemIconView call sites"
```

---

### Task 7: Visual verification

**Step 1: Build and run**

Run: `cd /Users/yanu/Documents/code/Terminal/treemux && xcodebuild -scheme Treemux -destination 'platform=macOS' build 2>&1 | tail -5`

Then run the app: `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`

**Step 2: Verify visually**

Check:
1. Workspace icons are 22pt rounded rectangles (unchanged shape)
2. Worktree icons are 16pt circles in 24pt columns
3. Font sizes: workspace 12pt semibold, worktree 10pt medium, branch 10pt monospaced
4. HStack spacing is 8pt (wider than before)
5. "current" badge appears on the worktree matching `activeWorktreePath`, NOT based on sidebar selection
6. Activity indicator amber dot appears at icon bottom-right for the current worktree
7. If a worktree has running sessions, the pulsing animation shows instead of static dot
8. "current" text badge uses subtle green capsule styling

**Step 3: Final commit if any tweaks needed**

```bash
git add -u
git commit -m "fix: visual refinements for sidebar activity indicators"
```
