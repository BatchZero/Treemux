# P1a — Design-System Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the "Phosphor Instrument" design-system foundation — color tokens, data-layer typography, the file-tree density setting, and the phosphor-underline primitive — that P1b's visual surfaces consume.

**Architecture:** Add pure, testable foundation types: a `DesignTokens` color namespace and `DesignFonts` typography helper (new files under `Treemux/UI/Theme/`), a `TreeDensity`/`FileTreeSettings` settings group wired into the existing `AppSettings` Codable struct, and a reusable `PhosphorUnderline` SwiftUI modifier (under `Treemux/UI/Components/`). The only user-visible change this phase is a File-Tree Density picker in Settings → General; everything else is foundation that P1b applies to the tab bar and file tree.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest, XcodeGen (project regeneration), `xcodebuild` (build + test). Spec: `docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md` (§0, and the P1a row of the Phasing table).

**Conventions for this plan:**
- Work happens in the worktree `/.worktrees/feat+p1a-design-system/` on branch `feat/p1a-design-system`. Run all commands from that worktree root.
- **New `.swift` files are folder-globbed by `project.yml`, so after creating any new file run `xcodegen generate` before building/testing**, and include the regenerated `Treemux.xcodeproj/project.pbxproj` in the commit.
- Test command shape: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/<Class> -quiet`
- All new user-visible strings use `LocalizedStringKey` and get a `zh-Hans` entry in `Treemux/Localizable.xcstrings` (per CLAUDE.md i18n rule).

---

## File Structure

| File | Create / Modify | Responsibility |
|------|-----------------|----------------|
| `Treemux/Domain/AppSettings.swift` | Modify | Add `TreeDensity` enum + `FileTreeSettings` struct + `fileTree` field (Codable, backward-compatible) |
| `Treemux/UI/Theme/DesignTokens.swift` | Create | Phosphor color palette (hex source of truth + SwiftUI Colors) + semantic `tabAccent` mapping |
| `Treemux/UI/Theme/DesignFonts.swift` | Create | Data-layer (monospaced) vs chrome (system) font helpers |
| `Treemux/UI/Components/PhosphorUnderline.swift` | Create | Reusable glowing-underline `ViewModifier` + `View.phosphorUnderline(_:active:)` |
| `Treemux/UI/Settings/SettingsSheet.swift` | Modify | File-Tree Density picker in `GeneralSettingsView` |
| `Treemux/Localizable.xcstrings` | Modify | `zh-Hans` for the new settings strings |
| `TreemuxTests/FileTreeSettingsTests.swift` | Create | Density defaults, sizing maps, Codable round-trip + backward-compat |
| `TreemuxTests/DesignTokensTests.swift` | Create | Palette hex values + `tabAccent` mapping |

---

## Task 1: TreeDensity + FileTreeSettings (domain + AppSettings integration)

**Files:**
- Test: `TreemuxTests/FileTreeSettingsTests.swift` (create)
- Modify: `Treemux/Domain/AppSettings.swift`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/FileTreeSettingsTests.swift`:

```swift
//
//  FileTreeSettingsTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileTreeSettingsTests: XCTestCase {

    func testDefaultDensityIsComfortable() {
        XCTAssertEqual(FileTreeSettings().density, .comfortable)
        XCTAssertEqual(AppSettings().fileTree.density, .comfortable)
    }

    func testRowHeightMapping() {
        XCTAssertEqual(TreeDensity.compact.rowHeight, 28)
        XCTAssertEqual(TreeDensity.comfortable.rowHeight, 32)
        XCTAssertEqual(TreeDensity.spacious.rowHeight, 38)
    }

    func testFontSizeMapping() {
        XCTAssertEqual(TreeDensity.compact.fontSize, 12)
        XCTAssertEqual(TreeDensity.comfortable.fontSize, 13)
        XCTAssertEqual(TreeDensity.spacious.fontSize, 15)
    }

    func testAllCasesCount() {
        XCTAssertEqual(TreeDensity.allCases.count, 3)
    }

    func testAppSettingsCodableRoundTripIncludesFileTree() throws {
        var settings = AppSettings()
        settings.fileTree.density = .spacious
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.fileTree.density, .spacious)
    }

    func testBackwardCompatDecodeMissingFileTree() throws {
        // Legacy persisted JSON without the fileTree key must decode to the default.
        let legacy = Data("{\"version\":1}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.fileTree.density, .comfortable)
    }
}
```

- [ ] **Step 2: Regenerate project, run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileTreeSettingsTests -quiet
```
Expected: BUILD/TEST FAILURE — "cannot find 'FileTreeSettings' / 'TreeDensity' in scope" and `AppSettings` has no member `fileTree`.

- [ ] **Step 3: Implement TreeDensity + FileTreeSettings**

In `Treemux/Domain/AppSettings.swift`, add these two types just below the `import Foundation` line's section (e.g. after `struct SSHSettings` near the bottom, before `struct UpdateSettings`, or at the end of the file — anywhere at top level in the file):

```swift
/// File-tree row sizing density. Pure value type so the size maps are unit-testable.
enum TreeDensity: String, Codable, CaseIterable, Identifiable, Equatable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    /// Row height in points.
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .comfortable: return 32
        case .spacious: return 38
        }
    }

    /// File-name font size in points.
    var fontSize: CGFloat {
        switch self {
        case .compact: return 12
        case .comfortable: return 13
        case .spacious: return 15
        }
    }
}

/// File-browser appearance settings. Distinct from the top-level
/// `AppSettings.appearance` (system/dark/light) selector.
struct FileTreeSettings: Codable, Equatable {
    var density: TreeDensity = .comfortable
}
```

Then wire it into `AppSettings` in the same file with three edits:

1. Add the stored property after `var enableCodeCompletion: Bool = true` (line ~30):
```swift
    /// File-browser tree appearance (row density). See `FileTreeSettings`.
    var fileTree: FileTreeSettings = FileTreeSettings()
```

2. Add `fileTree` to the `CodingKeys` enum (currently ends `...showDefaultTerminal, enableCodeCompletion`):
```swift
    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal,
             enableCodeCompletion, fileTree
    }
```

3. Add a backward-compatible decode line at the end of `init(from:)` after the `enableCodeCompletion` line:
```swift
        fileTree = try container.decodeIfPresent(FileTreeSettings.self, forKey: .fileTree) ?? FileTreeSettings()
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileTreeSettingsTests -quiet
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/AppSettings.swift TreemuxTests/FileTreeSettingsTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(settings): add file-tree density (TreeDensity + FileTreeSettings)"
```

---

## Task 2: DesignTokens color palette + DesignFonts typography

**Files:**
- Test: `TreemuxTests/DesignTokensTests.swift` (create)
- Create: `Treemux/UI/Theme/DesignTokens.swift`
- Create: `Treemux/UI/Theme/DesignFonts.swift`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/DesignTokensTests.swift`:

```swift
//
//  DesignTokensTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class DesignTokensTests: XCTestCase {

    func testCorePaletteHex() {
        XCTAssertEqual(DesignTokens.Hex.ink, "#13161D")
        XCTAssertEqual(DesignTokens.Hex.panel, "#191D26")
        XCTAssertEqual(DesignTokens.Hex.surface, "#232936")
        XCTAssertEqual(DesignTokens.Hex.line, "#2C333F")
    }

    func testTextRampHex() {
        XCTAssertEqual(DesignTokens.Hex.text, "#D7DCE4")
        XCTAssertEqual(DesignTokens.Hex.muted, "#7C8694")
        XCTAssertEqual(DesignTokens.Hex.faint, "#525B69")
    }

    func testSemanticAccentsHex() {
        XCTAssertEqual(DesignTokens.Hex.shell, "#54D38B")
        XCTAssertEqual(DesignTokens.Hex.files, "#5BA6F2")
    }

    func testTabAccentMapping() {
        XCTAssertEqual(DesignTokens.tabAccentHex(for: .fileBrowser), DesignTokens.Hex.files)
        XCTAssertEqual(DesignTokens.tabAccentHex(for: .terminal), DesignTokens.Hex.shell)
    }
}
```

- [ ] **Step 2: Regenerate project, run test to verify it fails**

Run:
```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/DesignTokensTests -quiet
```
Expected: BUILD/TEST FAILURE — "cannot find 'DesignTokens' in scope".

- [ ] **Step 3: Implement DesignTokens and DesignFonts**

Create `Treemux/UI/Theme/DesignTokens.swift`:

```swift
//
//  DesignTokens.swift
//  Treemux
//
//  "Phosphor Instrument" design-system color tokens — the shared palette every
//  file-browser visual surface derives from. Tuned for the dark theme (the app's
//  primary appearance); light-theme variants are intentionally out of scope for
//  this foundation phase.
//

import SwiftUI

enum DesignTokens {

    /// Raw hex strings — the single source of truth (asserted in tests).
    enum Hex {
        static let ink = "#13161D"      // app base (blue-charcoal)
        static let panel = "#191D26"    // sidebar / tree / tab-bar background
        static let surface = "#232936"  // active tab, hover, selected row
        static let line = "#2C333F"     // hairlines, dividers, indent guides
        static let text = "#D7DCE4"
        static let muted = "#7C8694"
        static let faint = "#525B69"

        // Semantic accents
        static let shell = "#54D38B"    // terminal / shell (phosphor green)
        static let files = "#5BA6F2"    // files (azure)

        // Type-accent palette (mapped to file types in P1b's FileIconCatalog)
        static let accentOrange = "#E8865A"
        static let accentAmber = "#E2A55C"
        static let accentGreen = "#5FC98A"
        static let accentViolet = "#A98BFA"
    }

    static let ink = Color(hex: Hex.ink)
    static let panel = Color(hex: Hex.panel)
    static let surface = Color(hex: Hex.surface)
    static let line = Color(hex: Hex.line)
    static let text = Color(hex: Hex.text)
    static let muted = Color(hex: Hex.muted)
    static let faint = Color(hex: Hex.faint)

    static let shell = Color(hex: Hex.shell)
    static let files = Color(hex: Hex.files)

    static let accentOrange = Color(hex: Hex.accentOrange)
    static let accentAmber = Color(hex: Hex.accentAmber)
    static let accentGreen = Color(hex: Hex.accentGreen)
    static let accentViolet = Color(hex: Hex.accentViolet)

    /// Hex of the accent that identifies a workspace tab's kind (testable).
    static func tabAccentHex(for kind: WorkspaceTabKind) -> String {
        switch kind {
        case .fileBrowser: return Hex.files
        case .terminal: return Hex.shell
        }
    }

    /// The accent color that identifies a workspace tab's kind.
    static func tabAccent(for kind: WorkspaceTabKind) -> Color {
        Color(hex: tabAccentHex(for: kind))
    }
}
```

Create `Treemux/UI/Theme/DesignFonts.swift`:

```swift
//
//  DesignFonts.swift
//  Treemux
//
//  Typography roles for the "Phosphor Instrument" language. The data layer
//  (file names, tab titles, tree rows, eyebrow labels) is monospaced — reusing
//  the terminal's monospaced feel; chrome (menus, settings, dialogs) stays on
//  the system font.
//

import SwiftUI

enum DesignFonts {
    /// Monospaced font for the data layer.
    static func dataLayer(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// System font for chrome.
    static func chrome(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/DesignTokensTests -quiet
```
Expected: PASS (4 tests). (`DesignFonts` has no unit test — it is verified by successful compilation here and used in P1b.)

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Theme/DesignTokens.swift Treemux/UI/Theme/DesignFonts.swift TreemuxTests/DesignTokensTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(theme): add Phosphor Instrument design tokens + typography helpers"
```

---

## Task 3: PhosphorUnderline primitive

**Files:**
- Create: `Treemux/UI/Components/PhosphorUnderline.swift`

> This is a pure SwiftUI view modifier with no value output, so it is verified by
> compilation + an Xcode preview rather than XCTest.

- [ ] **Step 1: Create the primitive with a preview**

Create `Treemux/UI/Components/PhosphorUnderline.swift`:

```swift
//
//  PhosphorUnderline.swift
//  Treemux
//
//  The "Phosphor Instrument" signature: a glowing accent underline marking the
//  selected tab. Color is supplied by the caller (e.g. DesignTokens.tabAccent);
//  inactive tabs draw nothing. Reuses the existing CodeEdit-style bottom stripe.
//

import SwiftUI

struct PhosphorUnderline: ViewModifier {
    let color: Color
    let isActive: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 2)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .padding(.horizontal, 8)
            }
        }
    }
}

extension View {
    /// Applies the phosphor underline signature when `active` is true.
    func phosphorUnderline(_ color: Color, active: Bool) -> some View {
        modifier(PhosphorUnderline(color: color, isActive: active))
    }
}

#Preview {
    HStack(spacing: 6) {
        Text("README.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(DesignTokens.surface)
            .phosphorUnderline(DesignTokens.files, active: true)
        Text("zsh")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(DesignTokens.surface)
            .phosphorUnderline(DesignTokens.shell, active: true)
    }
    .padding(24)
    .background(DesignTokens.panel)
}
```

- [ ] **Step 2: Regenerate project and build to verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/Components/PhosphorUnderline.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(ui): add phosphor-underline primitive (signature tab indicator)"
```

---

## Task 4: File-Tree Density picker in Settings → General (+ i18n)

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift` (`GeneralSettingsView`, lines ~158-192)
- Modify: `Treemux/Localizable.xcstrings`

> No new files here, so no `xcodegen generate` is required. Persistence of the
> setting is already covered by Task 1's Codable test; the picker itself is UI,
> verified by build + a manual check.

- [ ] **Step 1: Add the density picker to GeneralSettingsView**

In `Treemux/UI/Settings/SettingsSheet.swift`, inside `GeneralSettingsView.body`'s `Form`, add this `Section` immediately after the existing "Enable code completion" `Section` (before the closing `}` of the `Form`):

```swift
            Section {
                Picker("File Tree Density", selection: $settings.fileTree.density) {
                    ForEach(TreeDensity.allCases) { density in
                        Text(densityTitle(density)).tag(density)
                    }
                }
            } footer: {
                Text("Row height and font size in the file browser tree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Then add this helper method inside the `GeneralSettingsView` struct (after `var body`):

```swift
    private func densityTitle(_ density: TreeDensity) -> LocalizedStringKey {
        switch density {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
```

- [ ] **Step 2: Add zh-Hans translations**

In `Treemux/Localizable.xcstrings`, add these five entries inside the top-level `"strings": { ... }` object (object key order does not matter; Xcode re-sorts on save):

```json
    "File Tree Density" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "文件树密度" }
        }
      }
    },
    "Compact" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "紧凑" }
        }
      }
    },
    "Comfortable" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "舒适" }
        }
      }
    },
    "Spacious" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "宽松" }
        }
      }
    },
    "Row height and font size in the file browser tree." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "文件浏览器树的行高与字号。" }
        }
      }
    },
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Validate the xcstrings JSON is well-formed**

Run:
```bash
python3 -m json.tool Treemux/Localizable.xcstrings >/dev/null && echo "xcstrings OK"
```
Expected: `xcstrings OK` (no JSON error).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift Treemux/Localizable.xcstrings
git commit -m "feat(settings): add File Tree Density picker (General) + zh-Hans"
```

---

## Task 5: Phase verification (full tests + run)

**Files:** none (verification only)

- [ ] **Step 1: Run the full new-test set**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileTreeSettingsTests -only-testing:TreemuxTests/DesignTokensTests -quiet
```
Expected: PASS (10 tests total).

- [ ] **Step 2: Full app build**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Produce the run command for the user**

Find the DerivedData id, then hand the user the launch command (per CLAUDE.md):
```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-* | head -1
```
Then tell 卡皮巴拉 to run (substituting the `<id>` from above):
```bash
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<id>/Build/Products/Debug/Treemux.app
```

- [ ] **Step 4: Manual verification checklist**

Open Settings (⌘,) → **General** → confirm a **File Tree Density** picker shows **Compact / Comfortable / Spacious** (default Comfortable), in Chinese when the app language is 中文 (紧凑 / 舒适 / 宽松). Change it, click **Save**, reopen Settings → the choice persisted. (The tree itself does not yet resize — that lands in P1b.)

---

## Notes for P1b (not in scope here)

P1b consumes these foundation pieces:
- `DesignTokens` (palette + `tabAccent`) → tab grouping/underline colors, file-tree colors, indent guides.
- `DesignFonts.dataLayer` → file names + tab titles in monospace.
- `FileTreeSettings.density` (`.rowHeight` / `.fontSize`) → actual file-tree row sizing.
- `.phosphorUnderline(_:active:)` → applied to the selected tab in `WorkspaceTabBarView`.
- The per-type accent colors (`accentOrange`/`accentAmber`/`accentGreen`/`accentViolet`) → wired to extensions in the new `FileIconCatalog`.
