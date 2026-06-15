# P1b-B — File-Type Icon System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the file tree's hard-coded SF Symbols with a license-clean, colorful-per-language icon system (feature 2): MDI (Apache-2.0, monochrome, template-tinted) for folders/symlink/default, and Material Icon Theme (MIT, colorful) for per-language file icons.

**Architecture:** A reproducible shell script downloads a curated set of SVGs into `Assets.xcassets` imagesets (Xcode 26 renders SVG natively with Preserve Vector Data; MDI imagesets are template-rendering, Material ones original-color). A pure `FileIconCatalog` maps a file's extension/name/kind to an asset + render mode + optional tint; `NodeRow` renders it. Builds on P1b-A's tree styling.

**Tech Stack:** Swift 5 / SwiftUI, XCTest, XcodeGen, `xcodebuild`, `curl`. Icon sources: `@mdi/svg@7.4.47` (Apache-2.0), `material-extensions/vscode-material-icon-theme` (MIT). Spec: `docs/superpowers/specs/2026-06-15-file-browser-experience-overhaul-design.md` §2 + Licensing/Security Watch-List.

**Conventions:**
- Worktree `/.worktrees/feat+p1b-visual-surfaces/` on branch `feat/p1b-visual-surfaces`. Run all commands from that root.
- Adding imagesets INSIDE `Assets.xcassets` does NOT need `xcodegen generate` (the catalog compiles wholesale). Adding a new `.swift` file DOES → run `xcodegen generate` + commit `project.pbxproj`.
- Build/test need `-skipPackagePluginValidation` + long timeout (≤600000 ms). project.yml is at 0.0.13; regeneration must not change version.
- Live SourceKit index is unreliable (false "cannot find <type>") — trust xcodebuild.
- Foundation available: `DesignTokens` (`.files`, `.muted`, type accents), `TreeDensity.fontSize`. P1b-A already restyled `NodeRow`.

**Trademark/licensing:** Material Icon Theme ships some brand/language logos (MIT covers copyright, not trademark). Used only as in-tree file-type labels (nominative use). Task 4 adds a third-party notice doc.

---

## File Structure

| File | Create / Modify | Responsibility |
|------|-----------------|----------------|
| `scripts/fetch_file_icons.sh` | Create | Reproducible downloader → builds `Assets.xcassets` imagesets for the curated icon set |
| `Treemux/Assets.xcassets/<name>.imageset/…` | Create (generated) | ~28 SVG imagesets (MDI template + Material color) |
| `Treemux/Domain/FileIconCatalog.swift` | Create | Pure map: file → (asset, isTemplate, tint) |
| `TreemuxTests/FileIconCatalogTests.swift` | Create | Unit tests for the mapping |
| `Treemux/UI/FileBrowser/FileTreePanelView.swift` | Modify | `NodeRow` renders catalog icon; remove old `iconName` |
| `docs/THIRD_PARTY_ICONS.md` | Create | License + trademark notice for bundled icon sets |

**Curated icon set** (asset name = source file name, kept identical for traceability):
- **MDI (Apache-2.0, template-rendering):** `folder`, `folder-open`, `link-variant`, `file-document-outline`
- **Material Icon Theme (MIT, original color):** `swift`, `typescript`, `react`, `javascript`, `python`, `rust`, `go`, `json`, `markdown`, `html`, `css`, `vue`, `nodejs`, `docker`, `git`, `toml`, `lock`, `zip`, `pdf`, `image`, `audio`, `video`, `font`, `prisma`

---

## Task 1: Asset-generation script + generate imagesets

**Files:**
- Create: `scripts/fetch_file_icons.sh`
- Generates: imagesets under `Treemux/Assets.xcassets/`

- [ ] **Step 1: Create the generator script**

Create `scripts/fetch_file_icons.sh` (make it executable: `chmod +x`):

```bash
#!/usr/bin/env bash
# Downloads a curated, license-clean icon set into Assets.xcassets imagesets.
# Re-runnable. MDI (Apache-2.0) icons are template-rendering (tinted in code);
# Material Icon Theme (MIT) icons keep their original color.
set -euo pipefail

ASSETS="$(cd "$(dirname "$0")/.." && pwd)/Treemux/Assets.xcassets"
MDI="https://cdn.jsdelivr.net/npm/@mdi/svg@7.4.47/svg"
MAT="https://cdn.jsdelivr.net/gh/material-extensions/vscode-material-icon-theme@main/icons"

# name list per source
MDI_ICONS="folder folder-open link-variant file-document-outline"
MAT_ICONS="swift typescript react javascript python rust go json markdown html css vue nodejs docker git toml lock zip pdf image audio video font prisma"

emit_imageset() { # $1 = name, $2 = base url, $3 = template(true/false)
  local name="$1" base="$2" template="$3"
  local dir="$ASSETS/$name.imageset"
  mkdir -p "$dir"
  curl -fsSL "$base/$name.svg" -o "$dir/$name.svg"
  local props='"preserves-vector-representation" : true'
  if [ "$template" = "true" ]; then
    props="$props, \"template-rendering-intent\" : \"template\""
  fi
  cat > "$dir/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "$name.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : { $props }
}
EOF
  echo "  + $name ($([ "$template" = true ] && echo template || echo color))"
}

echo "MDI (template):"
for n in $MDI_ICONS; do emit_imageset "$n" "$MDI" true; done
echo "Material Icon Theme (color):"
for n in $MAT_ICONS; do emit_imageset "$n" "$MAT" false; done
echo "Done. $(echo $MDI_ICONS $MAT_ICONS | wc -w) imagesets in $ASSETS"
```

- [ ] **Step 2: Run it and verify the assets generated**

```bash
chmod +x scripts/fetch_file_icons.sh
bash scripts/fetch_file_icons.sh
ls Treemux/Assets.xcassets | grep imageset | wc -l   # expect 28
# sanity: a template one and a color one
cat Treemux/Assets.xcassets/folder.imageset/Contents.json
head -c 120 Treemux/Assets.xcassets/swift.imageset/swift.svg; echo
```
Expected: 28 imagesets; `folder` Contents.json has `"template-rendering-intent" : "template"`; `swift.svg` is a real SVG (`<svg ...`). If any `curl` 404s (a Material name changed), note which and either find the correct name on the source repo or drop that extension from the catalog map in Task 2.

- [ ] **Step 3: Build to confirm the catalog compiles into the app**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
```
Expected `** BUILD SUCCEEDED **`. (No `xcodegen` needed — assets compile wholesale.)

- [ ] **Step 4: Commit**

```bash
git add scripts/fetch_file_icons.sh Treemux/Assets.xcassets
git commit -m "feat(icons): generate MDI + Material Icon Theme file-tree icon assets"
```

---

## Task 2: FileIconCatalog (pure mapping) + tests

**Files:**
- Create: `Treemux/Domain/FileIconCatalog.swift`
- Test: `TreemuxTests/FileIconCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TreemuxTests/FileIconCatalogTests.swift`:

```swift
//
//  FileIconCatalogTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileIconCatalogTests: XCTestCase {

    func testKnownExtensionsMapToColorAssets() {
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "main.swift"), "swift")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "app.tsx"), "react")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "index.ts"), "typescript")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "README.md"), "markdown")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "page.html"), "html")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "data.json"), "json")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "photo.PNG"), "image") // case-insensitive
    }

    func testKnownFilenamesMapByName() {
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "Dockerfile"), "docker")
        XCTAssertEqual(FileIconCatalog.assetForFile(named: ".gitignore"), "git")
    }

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(FileIconCatalog.assetForFile(named: "mystery.qqq"))
        XCTAssertNil(FileIconCatalog.assetForFile(named: "noext"))
    }

    func testDirectoryIconIsTemplateTinted() {
        let closed = FileIconCatalog.directoryIcon(isExpanded: false)
        let open = FileIconCatalog.directoryIcon(isExpanded: true)
        XCTAssertEqual(closed.asset, "folder")
        XCTAssertEqual(open.asset, "folder-open")
        XCTAssertTrue(closed.isTemplate)
        XCTAssertNotNil(closed.tint)
    }

    func testDefaultFileIconIsTemplate() {
        let icon = FileIconCatalog.defaultFileIcon
        XCTAssertEqual(icon.asset, "file-document-outline")
        XCTAssertTrue(icon.isTemplate)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect FAIL**

```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileIconCatalogTests -skipPackagePluginValidation -quiet
```
Expected FAIL — "cannot find 'FileIconCatalog'".

- [ ] **Step 3: Implement the catalog**

Create `Treemux/Domain/FileIconCatalog.swift`:

```swift
//
//  FileIconCatalog.swift
//  Treemux
//
//  Maps a file node to a bundled icon asset. Folders/symlink/default use MDI
//  (monochrome, template-tinted); known file types use Material Icon Theme
//  (colorful, original). Brand/language logos are used only as in-tree
//  file-type labels (nominative use); see docs/THIRD_PARTY_ICONS.md.
//

import SwiftUI

enum FileIconCatalog {

    /// A resolved icon: asset-catalog name + whether to render as a tintable
    /// template + an optional tint (only meaningful when `isTemplate`).
    struct Icon: Equatable {
        let asset: String
        let isTemplate: Bool
        let tint: Color?
    }

    // MARK: Structural (MDI, template)

    static func directoryIcon(isExpanded: Bool) -> Icon {
        Icon(asset: isExpanded ? "folder-open" : "folder", isTemplate: true, tint: DesignTokens.files)
    }

    static let symlinkIcon = Icon(asset: "link-variant", isTemplate: true, tint: DesignTokens.muted)
    static let defaultFileIcon = Icon(asset: "file-document-outline", isTemplate: true, tint: DesignTokens.muted)

    // MARK: Resolution for a node

    static func icon(for node: FileNode, isExpanded: Bool) -> Icon {
        switch node.kind {
        case .directory: return directoryIcon(isExpanded: isExpanded)
        case .symlink: return symlinkIcon
        case .file:
            if let asset = assetForFile(named: node.name) {
                return Icon(asset: asset, isTemplate: false, tint: nil)
            }
            return defaultFileIcon
        }
    }

    // MARK: Colorful per-type (Material Icon Theme) — pure, testable

    /// Returns the Material Icon Theme asset name for a file, or nil if unmapped.
    static func assetForFile(named name: String) -> String? {
        let lower = name.lowercased()
        if let byName = byFilename[lower] { return byName }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return nil }
        let ext = String(lower[lower.index(after: dot)...])
        return byExtension[ext]
    }

    private static let byFilename: [String: String] = [
        "dockerfile": "docker",
        ".gitignore": "git",
        ".gitattributes": "git",
        "package.json": "nodejs",
        "cargo.lock": "lock",
        "package-lock.json": "lock",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "react", "jsx": "react",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python",
        "rs": "rust",
        "go": "go",
        "json": "json",
        "md": "markdown", "markdown": "markdown",
        "html": "html", "htm": "html",
        "css": "css",
        "vue": "vue",
        "toml": "toml",
        "lock": "lock",
        "zip": "zip", "tar": "zip", "gz": "zip", "tgz": "zip",
        "pdf": "pdf",
        "png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
        "webp": "image", "svg": "image", "bmp": "image", "tiff": "image",
        "ico": "image", "heic": "image",
        "mp3": "audio", "wav": "audio", "flac": "audio", "aac": "audio", "m4a": "audio",
        "mp4": "video", "mov": "video", "mkv": "video", "avi": "video", "webm": "video",
        "ttf": "font", "otf": "font", "woff": "font", "woff2": "font",
        "prisma": "prisma",
    ]
}
```

- [ ] **Step 4: Run test, expect PASS**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileIconCatalogTests -skipPackagePluginValidation -quiet
```
Expected PASS (5 tests). If `assetForFile` references an asset that Task 1 failed to download, remove that key.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/FileIconCatalog.swift TreemuxTests/FileIconCatalogTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "feat(icons): add FileIconCatalog extension/name -> asset mapping"
```

---

## Task 3: Render catalog icons in NodeRow

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`

- [ ] **Step 1: Replace the icon Image in `NodeRow.row`**

In `NodeRow.row` (from P1b-A), replace the icon block:
```swift
            Image(systemName: iconName)
                .font(.system(size: density.fontSize))
                .foregroundStyle(DesignTokens.muted)
                .frame(width: density.fontSize + 2)
```
with a catalog-driven icon:
```swift
            iconView
                .frame(width: density.fontSize + 3, height: density.fontSize + 3)
```
And add a computed `iconView` property to `NodeRow` (alongside `row`):
```swift
    @ViewBuilder
    private var iconView: some View {
        let icon = FileIconCatalog.icon(for: node, isExpanded: isExpanded)
        Image(icon.asset)
            .resizable()
            .renderingMode(icon.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(icon.tint ?? DesignTokens.muted)
    }
```

- [ ] **Step 2: Remove the now-unused `iconName` property**

Delete the entire `private var iconName: String { ... }` switch from `NodeRow` (it is fully replaced by `FileIconCatalog`). Leave `color(for:)` (still used by the git-status dot).

- [ ] **Step 3: Build**

```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
```
Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat(filetree): render FileIconCatalog icons (colorful per type)"
```

---

## Task 4: Third-party notice + phase verification

**Files:**
- Create: `docs/THIRD_PARTY_ICONS.md`

- [ ] **Step 1: Add the icon license notice**

Create `docs/THIRD_PARTY_ICONS.md`:
```markdown
# Third-Party Icon Assets

The file-tree icons in `Treemux/Assets.xcassets` are generated by
`scripts/fetch_file_icons.sh` from two open-source sets:

- **Material Design Icons (Pictogrammers)** — Apache License 2.0.
  Used (monochrome, tinted) for folders, symlinks, and the default file icon.
  https://pictogrammers.com/library/mdi/  ·  pinned: `@mdi/svg@7.4.47`
- **Material Icon Theme** (material-extensions) — MIT License.
  Used (original color) for per-language file-type icons.
  https://github.com/material-extensions/vscode-material-icon-theme

These licenses grant copyright permission. Some Material Icon Theme glyphs
depict third-party brand/language trademarks; they are used here solely as
functional in-tree file-type labels (nominative use) and never in app
branding, marketing, or the app icon.
```

- [ ] **Step 2: Run new + relevant tests**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/FileIconCatalogTests -only-testing:TreemuxTests/TabGroupingTests -only-testing:TreemuxTests/FileTreeSettingsTests -only-testing:TreemuxTests/DesignTokensTests -skipPackagePluginValidation -quiet
```
Expected all PASS (FileIconCatalog 5 + TabGrouping 4 + FileTreeSettings 6 + DesignTokens 5 = 20).

- [ ] **Step 3: Full regression + build + locate app**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -quiet
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation -quiet
ls -dt ~/Library/Developer/Xcode/DerivedData/Treemux-*/Build/Products/Debug/Treemux.app | head -1
```
Report regression result, build result, app path + `Treemux-<id>`.

- [ ] **Step 4: Commit + manual checklist**

```bash
git add docs/THIRD_PARTY_ICONS.md
git commit -m "docs: third-party icon license notice"
```
Manual check (launch the app): open a file tree containing varied types — confirm folders show a tinted MDI folder/folder-open, and `.swift`/`.ts`/`.py`/`.json`/`.md`/`.html`/images/etc. show their colorful Material icons; unmapped files show the default document icon. Icons scale with the density setting.

---

## Notes
- Light-theme: the folder/default tints use `DesignTokens` (dark-tuned) — same tracked limitation as P1b-A; colorful Material icons are theme-agnostic.
- To add/adjust icons later: edit the name lists in `scripts/fetch_file_icons.sh` + the maps in `FileIconCatalog.swift`, re-run the script.
