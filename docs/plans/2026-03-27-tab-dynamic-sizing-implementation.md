# Tab Dynamic Sizing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port Liney's dynamic tab width calculation so each tab has a precise, consistent width based on its title and pane count.

**Architecture:** Add a `TreemuxTabSizing` enum that uses `NSFont` to measure actual rendered text width, then applies a clamped width to each `TabButton`. Single file change in `WorkspaceTabBarView.swift`.

**Tech Stack:** SwiftUI, AppKit (NSFont for text measurement)

---

### Task 1: Add TreemuxTabSizing and apply to TabButton

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`
- Test: `TreemuxTests/TreemuxTabSizingTests.swift` (create)

**Reference:** Liney's implementation at `Liney/UI/Workspace/WorkspaceDetailView.swift:416-427`

**Step 1: Write the failing test**

Create `TreemuxTests/TreemuxTabSizingTests.swift`:

```swift
//
//  TreemuxTabSizingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class TreemuxTabSizingTests: XCTestCase {

    func testMinimumWidth() {
        // Very short title should clamp to minimum
        let width = TreemuxTabSizing.width(for: "T", paneCount: 1)
        XCTAssertEqual(width, 100, "Short title should clamp to minimum 100pt")
    }

    func testMaximumWidth() {
        // Very long title should clamp to maximum
        let longTitle = String(repeating: "A", count: 100)
        let width = TreemuxTabSizing.width(for: longTitle, paneCount: 1)
        XCTAssertEqual(width, 260, "Long title should clamp to maximum 260pt")
    }

    func testBadgeAddsWidth() {
        let title = "Tab 1"
        let withoutBadge = TreemuxTabSizing.width(for: title, paneCount: 1)
        let withBadge = TreemuxTabSizing.width(for: title, paneCount: 3)
        XCTAssertGreaterThan(withBadge, withoutBadge, "Badge should increase tab width")
    }

    func testTypicalTabWidth() {
        let width = TreemuxTabSizing.width(for: "Tab 1", paneCount: 1)
        XCTAssertGreaterThanOrEqual(width, 100)
        XCTAssertLessThanOrEqual(width, 260)
    }

    func testWidthIncreasesWithTitle() {
        let shortWidth = TreemuxTabSizing.width(for: "Tab", paneCount: 1)
        let longWidth = TreemuxTabSizing.width(for: "My Long Tab Name", paneCount: 1)
        XCTAssertGreaterThan(longWidth, shortWidth)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/TreemuxTabSizingTests 2>&1 | tail -20`

Expected: FAIL — `TreemuxTabSizing` not found (cannot find type in scope)

**Step 3: Add TreemuxTabSizing enum**

In `WorkspaceTabBarView.swift`, add before the `TabDropDelegate` section (before line 179):

```swift
// MARK: - Tab Sizing

enum TreemuxTabSizing {
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let countFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)

    /// Calculate tab width based on actual rendered title width.
    /// Always reserves space for the close button to prevent width jumps on hover.
    static func width(for title: String, paneCount: Int) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        // 12 leading + 4 hstack spacing + 16 close button + 12 trailing = 44 base chrome
        var totalWidth = titleWidth + 44
        if paneCount > 1 {
            let countText = "\(paneCount)"
            let countWidth = ceil((countText as NSString).size(withAttributes: [.font: countFont]).width)
            // countWidth + 8 badge horizontal padding + 4 hstack spacing
            totalWidth += countWidth + 12
        }
        return min(max(totalWidth, 100), 260)
    }
}
```

Note: the enum is `internal` (not `private`) so tests can access it.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing TreemuxTests/TreemuxTabSizingTests 2>&1 | tail -20`

Expected: All 5 tests PASS

**Step 5: Apply sizing to TabButton**

In `WorkspaceTabBarView.swift`, modify the `TabButton` view body to:

1. Add `.frame(width:)` to the outer button using `TreemuxTabSizing.width()`
2. Make the title Text fill available space with `.frame(maxWidth: .infinity, alignment: .leading)`
3. Add `.truncationMode(.tail)` to title for long names

Update `TabButton` body (replace lines 103-154):

```swift
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if paneCount > 1 {
                    Text("\(paneCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isSelected ? .secondary : .tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Reserve space for close button to prevent width jumps
                    Color.clear
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(.white.opacity(0.15))
                : isHovered ? AnyShapeStyle(.white.opacity(0.08))
                : AnyShapeStyle(.white.opacity(0.05))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: TreemuxTabSizing.width(for: tab.title, paneCount: paneCount))
        .contextMenu {
            Button("Rename…") { onRename() }
            Divider()
            Button("Close Tab") { onClose() }
        }
    }
```

Key changes from original:
- Added `.frame(maxWidth: .infinity, alignment: .leading)` on title Text
- Added `.truncationMode(.tail)` on title Text
- Added `Color.clear.frame(width: 16, height: 16)` placeholder when close button hidden
- Added `.frame(width: TreemuxTabSizing.width(...))` on outer Button

**Step 6: Also apply width to TabRenameField**

Update the `TabRenameField` (line 159-177) to use the same sizing:

Replace the fixed `.frame(width: 140)` at line 32 with:

```swift
.frame(width: TreemuxTabSizing.width(for: renameText.isEmpty ? "Tab name" : renameText, paneCount: paneCount(for: tab)))
```

**Step 7: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 8: Run all tests**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`

Expected: All tests PASS

**Step 9: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift TreemuxTests/TreemuxTabSizingTests.swift
git commit -m "feat: add dynamic tab width calculation based on Liney's sizing approach"
```
