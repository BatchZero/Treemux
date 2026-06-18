# UI 主题统一(Phase A)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把文件浏览相关的硬编码深色 "Phosphor" 调色板(`DesignTokens` 枚举)全部改为主题驱动,修复浅色主题下的"深色孤岛"与侧栏选中色 bug,所有颜色最终来自 YAML 主题(`ui:` + `terminal.ansi:`)。

**Architecture:** 方案 1 —— 复用已注入的可观察 `ThemeManager`。视图(文件树/tab/markdown)用 `@EnvironmentObject ThemeManager` 读派生访问器,SwiftUI 在主题变化时自动重渲染。结构色映射到现有 `ui` 字段,语义色派生自 `terminal.ansi` + `ui.accent`。唯一非视图链路(markdown 代码高亮)由视图层构造时注入主题色。完成后删除 `DesignTokens` 枚举。

**Tech Stack:** Swift / SwiftUI / AppKit、MarkdownUI、SwiftTreeSitter / CodeEditLanguages、XcodeGen(`project.yml`)、XCTest。

## Global Constraints

- 部署目标 macOS 15.0;Swift 5;`project.yml` 由 XcodeGen 生成,新增/删除源文件后必须 `xcodegen generate` 并提交重生成的 `Treemux.xcodeproj`。
- 非交互 `xcodebuild` 必须加 `-skipPackagePluginValidation`。
- 规范测试命令(本计划统一引用,`<Class>` 替换为具体测试类):
  ```bash
  cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+ui-theme-unification-phase-a
  xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>
  ```
  全量回归:`-only-testing:TreemuxTests`。构建:`xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation`。
- 颜色映射(权威,ansi 索引为 0-based,取自主题 `terminal.ansi`,共 16 个):
  - 结构色:`panel→ui.pane`、`surface/选中行→ui.selection`、`line→ui.hairline`、`text→ui.textPrimary`、`muted→ui.textSecondary`、`faint→ui.textMuted`、文件强调/files→`ui.accent`。
  - 语义色:shell→`ansi[2]`;代码高亮 keyword/operator→`ansi[5]`、string→`ansi[2]`、number/constant/boolean→`ansi[3]`、function→`ansi[4]`、type/attribute→`ansi[6]`、label→`ansi[3]`、tag→`ansi[5]`、comment→`ui.textMuted`、variable/property→`ui.textPrimary`、punctuation→`ui.textSecondary`;文件图标 folder→`ui.accent`、muted(symlink/默认)→`ui.textSecondary`。
- 只做 Phase A(正确性)。不引入 `DesignSystem`(字体/间距/圆角)、不做 pill/utility 按钮、不收敛单一 accent、不重排间距/排版。保持三栏主架构、交互逻辑、文件名/类型判定不变。
- 不新增用户可见字符串(纯改色),无需 i18n。
- `SwiftUI.Color` 相等性:对同一 hex 字符串经 `Color(hex:)` 构造的两个 Color 视为相等(组件一致);测试据此断言。若某环境下相等性不稳,改为比较 `NSColor(color).usingColorSpace(.sRGB)` 的 RGBA 分量。
- 提交信息用英文;已在 worktree `.worktrees/feat+ui-theme-unification-phase-a/` 内工作。

---

## File Structure

修改:
- `Treemux/UI/Theme/ThemeManager.swift` — 新增派生访问器(`ansiColor`/`shellAccent`/`fileIconTint`)+ `FileIconTintRole` 枚举。
- `Treemux/Services/Rendering/CodeHighlightTheme.swift` — 静态表 → 主题工厂(`resolvedHex`/`table`/`match`/`color(forCapture:in:)`)。
- `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift` — 注入 `captureColors`。
- `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift` — 去静态单例,构造时注入颜色+字体。
- `Treemux/UI/FileBrowser/RenderedMarkdownView.swift` — `@EnvironmentObject theme`,背景/文字/高亮主题化。
- `Treemux/UI/Theme/FileIconCatalog.swift` — `Icon.tint: Color?` → `tintRole: FileIconTintRole?`。
- `Treemux/UI/FileBrowser/FileTreePanelView.swift` — 全量主题化(面板/行/图标/缩进线)。
- `Treemux/UI/Workspace/WorkspaceTabBarView.swift` — tab 栏主题化。
- `Treemux/UI/Components/PhosphorUnderline.swift` — 更新 `#Preview`(去 DesignTokens)。
- `Treemux/UI/Sidebar/SidebarRowView.swift` + `Treemux/UI/Sidebar/SidebarCoordinator.swift` — 选中色随主题刷新(修浅色 navy bug)。

删除:
- `Treemux/UI/Theme/DesignTokens.swift`(所有消费者迁移后)。

测试新增:
- `TreemuxTests/CodeHighlightThemeThemingTests.swift`、`TreemuxTests/FileIconCatalogTests.swift`、`TreemuxTests/ThemeManagerDerivedColorTests.swift`。
- 既有 `TreemuxTests/CodeHighlightThemeTests.swift` 若断言旧静态 API,需在 Task 2 同步更新。

---

## Task 1: ThemeManager 派生访问器 + FileIconTintRole

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift`
- Test: `TreemuxTests/ThemeManagerDerivedColorTests.swift`

**Interfaces:**
- Consumes: `ThemeManager.activeTheme`(`Theme` with `terminal.ansi: [String]`, `ui: ThemeUIColors`)、`Color(hex:)`。
- Produces:
  - `enum FileIconTintRole: Equatable { case folder, muted }`(模块级)
  - `ThemeManager.ansiColor(_ index: Int) -> Color`(越界回退 `textPrimary`)
  - `ThemeManager.shellAccent: Color`(= `ansiColor(2)`)
  - `ThemeManager.fileIconTint(_ role: FileIconTintRole) -> Color`(`.folder`→`accentColor`,`.muted`→`textSecondary`)

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/ThemeManagerDerivedColorTests.swift`:
```swift
//
//  ThemeManagerDerivedColorTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ThemeManagerDerivedColorTests: XCTestCase {

    @MainActor
    func testShellAccentIsAnsiIndex2() {
        let manager = ThemeManager()  // defaults to treemux-dark
        XCTAssertEqual(manager.shellAccent, manager.ansiColor(2))
    }

    @MainActor
    func testAnsiColorMatchesThemePalette() {
        let manager = ThemeManager()
        let hex = manager.activeTheme.terminal.ansi[2]
        XCTAssertEqual(manager.ansiColor(2), Color(hex: hex))
    }

    @MainActor
    func testAnsiColorOutOfBoundsFallsBackToTextPrimary() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.ansiColor(999), manager.textPrimary)
        XCTAssertEqual(manager.ansiColor(-1), manager.textPrimary)
    }

    @MainActor
    func testFileIconTintRoles() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.fileIconTint(.folder), manager.accentColor)
        XCTAssertEqual(manager.fileIconTint(.muted), manager.textSecondary)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ThemeManagerDerivedColorTests`
Expected: 编译失败(`FileIconTintRole`/`ansiColor`/`shellAccent`/`fileIconTint` 未定义)。

- [ ] **Step 3: 实现**

在 `Treemux/UI/Theme/ThemeManager.swift` 文件顶部(`import` 之后、`ThemeManager` 之前)新增:
```swift
/// Tint role for monochrome (template) file-tree icons. Resolved to a theme
/// color by `ThemeManager.fileIconTint(_:)`. Colorful asset icons carry no role.
enum FileIconTintRole: Equatable {
    case folder
    case muted
}
```

在 `ThemeManager` 类内,`// MARK: - Resolved SwiftUI Colors` 区块末尾(`dangerColor` 之后)新增:
```swift
    // MARK: - Derived palette (file browser / syntax)

    /// A color from the active theme's 16-entry ANSI palette, bounds-safe.
    func ansiColor(_ index: Int) -> Color {
        let ansi = activeTheme.terminal.ansi
        guard ansi.indices.contains(index) else { return textPrimary }
        return Color(hex: ansi[index])
    }

    /// Accent for terminal/shell affordances (ANSI green slot).
    var shellAccent: Color { ansiColor(2) }

    /// Resolves a file-tree icon tint role to a theme color.
    func fileIconTint(_ role: FileIconTintRole) -> Color {
        switch role {
        case .folder: return accentColor
        case .muted: return textSecondary
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ThemeManagerDerivedColorTests`
Expected: 4 个测试 PASS。

- [ ] **Step 5: 重新生成工程并提交**

```bash
xcodegen generate
git add Treemux/UI/Theme/ThemeManager.swift TreemuxTests/ThemeManagerDerivedColorTests.swift Treemux.xcodeproj
git commit -m "feat: ThemeManager derived palette accessors (ansiColor/shellAccent/fileIconTint)"
```

---

## Task 2: CodeHighlightTheme 主题工厂 + markdown 高亮链

**Files:**
- Modify: `Treemux/Services/Rendering/CodeHighlightTheme.swift`(整体重写)
- Modify: `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift`
- Modify: `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift`
- Modify: `Treemux/UI/FileBrowser/RenderedMarkdownView.swift`
- Test: `TreemuxTests/CodeHighlightThemeThemingTests.swift`;同步更新既有 `TreemuxTests/CodeHighlightThemeTests.swift`

**Interfaces:**
- Consumes: `Theme.terminal.ansi: [String]`、`ThemeUIColors`(字段 `textPrimary/textSecondary/textMuted`)、`ThemeManager.activeTheme`、`Color(hex:)`、`DesignFonts.dataLayer(size:)`。
- Produces:
  - `CodeHighlightTheme.resolvedHex(ansi: [String], ui: ThemeUIColors) -> [String: String]`
  - `CodeHighlightTheme.table(ansi: [String], ui: ThemeUIColors) -> [String: Color]`
  - `CodeHighlightTheme.match<V>(capture: String, in table: [String: V]) -> V?`(最长前缀匹配)
  - `CodeHighlightTheme.color(forCapture name: String, in table: [String: Color]) -> Color?`
  - `TreeSitterCodeHighlighter(captureColors: [String: Color])`
  - `MarkdownCodeSyntaxHighlighter(captureColors: [String: Color], font: Font)`

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/CodeHighlightThemeThemingTests.swift`:
```swift
//
//  CodeHighlightThemeThemingTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class CodeHighlightThemeThemingTests: XCTestCase {

    // 16 distinct ansi hexes so each index is identifiable by value.
    private let ansi = [
        "#000000", "#010101", "#020202", "#030303",
        "#040404", "#050505", "#060606", "#070707",
        "#080808", "#090909", "#0A0A0A", "#0B0B0B",
        "#0C0C0C", "#0D0D0D", "#0E0E0E", "#0F0F0F"
    ]
    private let ui = ThemeUIColors(
        accent: "#AA0000", accentOnDark: "#AA0001", onAccent: "#FFFFFF",
        window: "#111111", sidebar: "#121212", pane: "#131313",
        paneHeader: "#141414", tabBar: "#151515", statusBar: "#161616",
        selection: "#171717", selectionStroke: nil, hairline: "#181818",
        textPrimary: "#AAAAAA", textSecondary: "#BBBBBB", textMuted: "#CCCCCC",
        success: "#00AA00", warning: "#AAAA00", danger: "#AA0000")

    func testResolvedHexMapsRolesToAnsiAndUI() {
        let map = CodeHighlightTheme.resolvedHex(ansi: ansi, ui: ui)
        XCTAssertEqual(map["keyword"], ansi[5])
        XCTAssertEqual(map["operator"], ansi[5])
        XCTAssertEqual(map["string"], ansi[2])
        XCTAssertEqual(map["number"], ansi[3])
        XCTAssertEqual(map["constant"], ansi[3])
        XCTAssertEqual(map["boolean"], ansi[3])
        XCTAssertEqual(map["function"], ansi[4])
        XCTAssertEqual(map["type"], ansi[6])
        XCTAssertEqual(map["attribute"], ansi[6])
        XCTAssertEqual(map["label"], ansi[3])
        XCTAssertEqual(map["tag"], ansi[5])
        XCTAssertEqual(map["comment"], ui.textMuted)
        XCTAssertEqual(map["variable"], ui.textPrimary)
        XCTAssertEqual(map["property"], ui.textPrimary)
        XCTAssertEqual(map["punctuation"], ui.textSecondary)
    }

    func testMatchLongestPrefix() {
        let table = ["keyword": "K", "keyword.function": "KF"]
        XCTAssertEqual(CodeHighlightTheme.match(capture: "keyword.function", in: table), "KF")
        XCTAssertEqual(CodeHighlightTheme.match(capture: "keyword.return", in: table), "K")
        XCTAssertEqual(CodeHighlightTheme.match(capture: "string", in: table), nil)
    }

    func testTableProducesColorsForKnownCaptures() {
        let table = CodeHighlightTheme.table(ansi: ansi, ui: ui)
        XCTAssertEqual(table["keyword"], Color(hex: ansi[5]))
        XCTAssertNotNil(CodeHighlightTheme.color(forCapture: "string.special", in: table))
    }
}
```
> 文件顶部需 `import SwiftUI`(用到 `Color`)。

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/CodeHighlightThemeThemingTests`
Expected: 编译失败(新 API 未定义)。

- [ ] **Step 3: 重写 CodeHighlightTheme.swift**

整体替换 `Treemux/Services/Rendering/CodeHighlightTheme.swift`:
```swift
import SwiftUI

/// Builds a tree-sitter capture → color map from the active theme.
/// Structural roles come from `ui`; syntax accents from the 16-entry `ansi`.
/// Matching is longest-prefix on dot-separated capture components
/// (e.g. "keyword.function" -> "keyword" if no exact entry exists).
enum CodeHighlightTheme {

    /// Role → hex map resolved from a theme's ansi palette + ui colors.
    static func resolvedHex(ansi: [String], ui: ThemeUIColors) -> [String: String] {
        func a(_ i: Int) -> String { ansi.indices.contains(i) ? ansi[i] : ui.textPrimary }
        return [
            "keyword": a(5),
            "operator": a(5),
            "string": a(2),
            "number": a(3),
            "constant": a(3),
            "boolean": a(3),
            "comment": ui.textMuted,
            "function": a(4),
            "type": a(6),
            "attribute": a(6),
            "variable": ui.textPrimary,
            "property": ui.textPrimary,
            "punctuation": ui.textSecondary,
            "label": a(3),
            "tag": a(5)
        ]
    }

    /// Capture → Color table for the highlighter.
    static func table(ansi: [String], ui: ThemeUIColors) -> [String: Color] {
        resolvedHex(ansi: ansi, ui: ui).mapValues { Color(hex: $0) }
    }

    /// Longest-prefix match on dot-separated capture components.
    static func match<V>(capture name: String, in table: [String: V]) -> V? {
        var components = name.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let value = table[components.joined(separator: ".")] {
                return value
            }
            components.removeLast()
        }
        return nil
    }

    static func color(forCapture name: String, in table: [String: Color]) -> Color? {
        match(capture: name, in: table)
    }
}
```

- [ ] **Step 4: 注入 TreeSitterCodeHighlighter**

在 `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift`:

4a. 在 `private var queryCache: [String: Query] = [:]` 上方新增存储与初始化:
```swift
    /// Capture → color table built from the active theme (injected at construction).
    private let captureColors: [String: Color]

    init(captureColors: [String: Color]) {
        self.captureColors = captureColors
    }
```

4b. 把 `attributed` 内的
```swift
            guard let color = CodeHighlightTheme.color(forCapture: named.name) else { continue }
```
改为
```swift
            guard let color = CodeHighlightTheme.color(forCapture: named.name, in: captureColors) else { continue }
```
> 顶部已 `import SwiftUI`(`Color` 可用)。

- [ ] **Step 5: 改 MarkdownCodeSyntaxHighlighter(去静态单例,注入颜色+字体)**

整体替换 `Treemux/Services/Rendering/MarkdownCodeSyntaxHighlighter.swift`:
```swift
import SwiftUI
import MarkdownUI

/// Bridges our tree-sitter highlighter into MarkdownUI's code-block rendering.
/// Constructed per render with the active theme's capture colors + code font.
struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let highlighter: TreeSitterCodeHighlighter
    private let font: Font

    init(captureColors: [String: Color], font: Font) {
        self.highlighter = TreeSitterCodeHighlighter(captureColors: captureColors)
        self.font = font
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        // Strip a single trailing newline MarkdownUI appends to fenced blocks.
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let attributed = highlighter.attributed(code: trimmed, languageName: language)
        return Text(attributed).font(font)
    }
}
```

- [ ] **Step 6: 改 RenderedMarkdownView(主题化背景/文字/高亮)**

在 `Treemux/UI/FileBrowser/RenderedMarkdownView.swift` 的 `struct RenderedMarkdownView`:

6a. 在 `let content: String` 上方新增:
```swift
    @EnvironmentObject private var theme: ThemeManager
```

6b. 把 body 内的 markdown 链替换。原:
```swift
                .markdownCodeSyntaxHighlighter(MarkdownCodeSyntaxHighlighter.treeSitter)
                .markdownTextStyle {
                    ForegroundColor(DesignTokens.text)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.panel)
```
改为:
```swift
                .markdownCodeSyntaxHighlighter(MarkdownCodeSyntaxHighlighter(
                    captureColors: CodeHighlightTheme.table(
                        ansi: theme.activeTheme.terminal.ansi,
                        ui: theme.activeTheme.ui),
                    font: DesignFonts.dataLayer(size: 12)))
                .markdownTextStyle {
                    ForegroundColor(theme.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.paneBackground)
```

- [ ] **Step 7: 更新既有 CodeHighlightThemeTests.swift**

打开 `TreemuxTests/CodeHighlightThemeTests.swift`。它断言的是旧静态 API(`CodeHighlightTheme.color(forCapture:)` 单参版)。把每个调用改为基于新 `table` 的两参版,构造一个测试用 table:
```swift
// 在每个测试方法内,或作为属性:
private let ansi = Array(repeating: "#123456", count: 16)
private let ui = ThemeUIColors(
    accent: "#AA0000", accentOnDark: "#AA0001", onAccent: "#FFFFFF",
    window: "#111111", sidebar: "#121212", pane: "#131313",
    paneHeader: "#141414", tabBar: "#151515", statusBar: "#161616",
    selection: "#171717", selectionStroke: nil, hairline: "#181818",
    textPrimary: "#AAAAAA", textSecondary: "#BBBBBB", textMuted: "#CCCCCC",
    success: "#00AA00", warning: "#AAAA00", danger: "#AA0000")
private var table: [String: Color] { CodeHighlightTheme.table(ansi: ansi, ui: ui) }
```
把形如 `CodeHighlightTheme.color(forCapture: "keyword.function")` 的调用改为 `CodeHighlightTheme.color(forCapture: "keyword.function", in: table)`。保留原本验证"最长前缀匹配 / 未知 capture 返回 nil"的断言意图(前缀逻辑未变)。删除任何断言具体旧 Phosphor 颜色值(如 `== DesignTokens.accentViolet`)的行——改为断言"非 nil"或与 `table["keyword"]` 比较。
> 若该文件全部断言都已无意义,可整体改写为针对前缀匹配 + 已知 capture 非 nil 的若干用例。

- [ ] **Step 8: 运行测试确认通过**

Run:
```bash
xcodebuild test ... -only-testing:TreemuxTests/CodeHighlightThemeThemingTests -only-testing:TreemuxTests/CodeHighlightThemeTests
```
Expected: 全部 PASS。

- [ ] **Step 9: 全量构建(确保 markdown 链编译)+ 提交**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
git add -A
git commit -m "feat: theme-driven markdown code highlighting (CodeHighlightTheme factory + injected colors)"
```
Expected: BUILD SUCCEEDED。

---

## Task 3: FileTreePanelView + FileIconCatalog 主题化

**Files:**
- Modify: `Treemux/UI/Theme/FileIconCatalog.swift`
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift`
- Test: `TreemuxTests/FileIconCatalogTests.swift`

**Interfaces:**
- Consumes: `FileIconTintRole`(Task 1)、`ThemeManager`(`paneBackground/sidebarSelection/dividerColor/textPrimary/textMuted/textSecondary/accentColor/fileIconTint`)。
- Produces: `FileIconCatalog.Icon { asset: String; isTemplate: Bool; tintRole: FileIconTintRole? }`(把原 `tint: Color?` 改为 `tintRole`)。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/FileIconCatalogTests.swift`:
```swift
//
//  FileIconCatalogTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class FileIconCatalogTests: XCTestCase {

    func testDirectoryIconUsesFolderRole() {
        XCTAssertEqual(FileIconCatalog.directoryIcon(isExpanded: false).tintRole, .folder)
        XCTAssertEqual(FileIconCatalog.directoryIcon(isExpanded: true).tintRole, .folder)
    }

    func testSymlinkAndDefaultUseMutedRole() {
        XCTAssertEqual(FileIconCatalog.symlinkIcon.tintRole, .muted)
        XCTAssertEqual(FileIconCatalog.defaultFileIcon.tintRole, .muted)
    }

    func testKnownColorfulFileHasNoTintRole() {
        // A mapped extension uses the colorful Material asset (original rendering, no tint).
        XCTAssertEqual(FileIconCatalog.assetForFile(named: "main.swift"), "swift")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/FileIconCatalogTests`
Expected: 编译失败(`Icon` 无 `tintRole`)。

- [ ] **Step 3: 改 FileIconCatalog**

在 `Treemux/UI/Theme/FileIconCatalog.swift`:

3a. 把 `Icon` 结构体的 `tint` 字段换成 `tintRole`:
```swift
    struct Icon: Equatable {
        let asset: String
        let isTemplate: Bool
        let tintRole: FileIconTintRole?
    }
```

3b. 更新三处构造:
```swift
    static func directoryIcon(isExpanded: Bool) -> Icon {
        Icon(asset: isExpanded ? "folder-open" : "folder", isTemplate: true, tintRole: .folder)
    }

    static let symlinkIcon = Icon(asset: "link-variant", isTemplate: true, tintRole: .muted)
    static let defaultFileIcon = Icon(asset: "file-document-outline", isTemplate: true, tintRole: .muted)
```

3c. `icon(for:)` 内 file 分支的彩色资源构造改为 `tintRole: nil`:
```swift
        case .file:
            if let asset = assetForFile(named: node.name) {
                return Icon(asset: asset, isTemplate: false, tintRole: nil)
            }
            return defaultFileIcon
```

- [ ] **Step 4: 主题化 FileTreePanelView**

在 `Treemux/UI/FileBrowser/FileTreePanelView.swift`:

4a. `FileTreePanelView` 加 `@EnvironmentObject private var theme: ThemeManager`(在 `@EnvironmentObject private var store` 旁),并把 `.background(DesignTokens.panel)` → `.background(theme.paneBackground)`。

4b. `NodeRow` 加 `@EnvironmentObject private var theme: ThemeManager`(在 `@State private var isHovered` 旁),替换其 `row` 与 `iconView` 内的 token:
- `Rectangle().fill(DesignTokens.line)` → `.fill(theme.dividerColor)`
- chevron `.foregroundStyle(DesignTokens.faint)` → `.foregroundStyle(theme.textMuted)`
- name `.foregroundStyle(DesignTokens.text)` → `.foregroundStyle(theme.textPrimary)`
- 选中/hover 背景:
  ```swift
          .background(
              RoundedRectangle(cornerRadius: 4)
                  .fill(isSelected ? theme.sidebarSelection
                        : isHovered ? theme.textPrimary.opacity(0.06)
                        : Color.clear)
          )
  ```
- 选中条 overlay `.fill(DesignTokens.files)` → `.fill(theme.accentColor)`
- 删除第 184–185 行那段"这些 Phosphor token 是 dark-tuned..."的注释。
- `iconView` 改为:
  ```swift
      @ViewBuilder
      private var iconView: some View {
          let icon = FileIconCatalog.icon(for: node, isExpanded: isExpanded)
          Image(icon.asset)
              .resizable()
              .renderingMode(icon.isTemplate ? .template : .original)
              .scaledToFit()
              .foregroundStyle(icon.tintRole.map { theme.fileIconTint($0) } ?? theme.textSecondary)
      }
  ```

4c. `LoadMoreRow` 加 `@EnvironmentObject private var theme: ThemeManager`,把其 `Rectangle().fill(DesignTokens.line)` → `.fill(theme.dividerColor)`。

> 这些子结构体都在 `FileTreePanelView` 所处的视图树内,`ThemeManager` 已由 `MainWindowView` 注入到环境,`@EnvironmentObject` 可用。

- [ ] **Step 5: 运行测试 + 构建**

Run:
```bash
xcodegen generate
xcodebuild test ... -only-testing:TreemuxTests/FileIconCatalogTests
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: 测试 PASS;BUILD SUCCEEDED。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: theme-driven file tree panel + icon tint roles"
```

---

## Task 4: WorkspaceTabBarView + PhosphorUnderline 主题化

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`
- Modify: `Treemux/UI/Components/PhosphorUnderline.swift`

**Interfaces:**
- Consumes: `ThemeManager`(`tabBarBackground/dividerColor/accentColor/shellAccent/sidebarSelection/textPrimary`)。无新产出。

- [ ] **Step 1: 主题化 WorkspaceTabBarView**

在 `Treemux/UI/Workspace/WorkspaceTabBarView.swift`:

1a. `WorkspaceTabBarView` 加 `@EnvironmentObject private var theme: ThemeManager`(在 `@ObservedObject var workspace` 旁)。

1b. body 内 eyebrow / 分隔 / 背景 / 底边替换:
- `TabGroupEyebrow(title: "Files", color: DesignTokens.files)` → `TabGroupEyebrow(title: "Files", color: theme.accentColor)`
- `TabGroupEyebrow(title: "Shell", color: DesignTokens.shell)` → `TabGroupEyebrow(title: "Shell", color: theme.shellAccent)`
- 两处 `Rectangle().fill(DesignTokens.line)` → `.fill(theme.dividerColor)`
- `.background(Color(nsColor: .windowBackgroundColor).opacity(0.6))` → `.background(theme.tabBarBackground)`
- 底边 overlay `Rectangle().fill(.white.opacity(0.08))` → `.fill(theme.dividerColor)`

1c. `TabButton` 加 `@EnvironmentObject private var theme: ThemeManager`(在它的存储属性旁),替换其 `.background(...)` 与 underline:
- 背景:
  ```swift
              .background(
                  isSelected ? AnyShapeStyle(theme.sidebarSelection)
                  : isHovered ? AnyShapeStyle(theme.textPrimary.opacity(0.08))
                  : AnyShapeStyle(theme.textPrimary.opacity(0.05))
              )
  ```
- underline:
  ```swift
              .phosphorUnderline(tab.kind == .fileBrowser ? theme.accentColor : theme.shellAccent, active: isSelected)
  ```

> `TabButton` 是 `WorkspaceTabBarView` 的子视图,环境里已有 `ThemeManager`。

- [ ] **Step 2: 更新 PhosphorUnderline 的 #Preview(去 DesignTokens)**

在 `Treemux/UI/Components/PhosphorUnderline.swift`:
- 第 5–6 行注释里 "e.g. DesignTokens.tabAccent" 改为 "e.g. theme.accentColor"。
- `#Preview` 块内把 `DesignTokens.surface/files/shell/panel` 替换为字面 Color(预览不依赖主题):
  ```swift
  #Preview {
      HStack(spacing: 6) {
          Text("README.md")
              .font(DesignFonts.dataLayer(size: 12.5))
              .padding(8)
              .background(Color(hex: "#232936"))
              .phosphorUnderline(Color(hex: "#5BA6F2"), active: true)
          Text("zsh")
              .font(DesignFonts.dataLayer(size: 12.5))
              .padding(8)
              .background(Color(hex: "#232936"))
              .phosphorUnderline(Color(hex: "#54D38B"), active: true)
          Text("other.md")
              .font(DesignFonts.dataLayer(size: 12.5))
              .padding(8)
              .background(Color(hex: "#232936"))
              .phosphorUnderline(Color(hex: "#5BA6F2"), active: false)
      }
      .padding(24)
      .background(Color(hex: "#191D26"))
  }
  ```

- [ ] **Step 3: 构建**

Run:
```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "feat: theme-driven workspace tab bar; de-Phosphor PhosphorUnderline preview"
```

---

## Task 5: 侧栏选中色随主题刷新(修浅色 navy bug)

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarRowView.swift`
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift`

**Interfaces:**
- Consumes: `ThemeManager.sidebarSelectionFillNS / sidebarSelectionStrokeNS`、`.themeDidChange`(object 为 `Theme`)、`SidebarRowView`。无新产出。

- [ ] **Step 1: 去掉 SidebarRowView 的深 navy 默认值**

在 `Treemux/UI/Sidebar/SidebarRowView.swift` 把第 9–10 行默认色改为中性(协调器始终会覆盖;默认仅在极端情况兜底,不应是深 navy):
```swift
    var selectionFillColor: NSColor = .selectedContentBackgroundColor
    var selectionStrokeColor: NSColor = .clear
```

- [ ] **Step 2: 协调器监听 .themeDidChange 刷新行选中色**

在 `Treemux/UI/Sidebar/SidebarCoordinator.swift`:

2a. 在 `attach(...)`(设置 dataSource/delegate 的方法)末尾注册观察者。找到 `attach` 方法体末尾,新增:
```swift
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChangeRefresh(_:)),
            name: .themeDidChange,
            object: nil
        )
```

2b. 在文件内(类作用域)新增刷新方法:
```swift
    @objc private func themeDidChangeRefresh(_ notification: Notification) {
        guard let theme, let outlineView = container?.outlineView else { return }
        let fill = theme.sidebarSelectionFillNS
        let stroke = theme.sidebarSelectionStrokeNS
        outlineView.enumerateAvailableRowViews { rowView, _ in
            guard let row = rowView as? SidebarRowView else { return }
            row.selectionFillColor = fill
            row.selectionStrokeColor = stroke
            row.needsDisplay = true
        }
    }
```
> `theme`(`ThemeManager?`)与 `container`(持有 `outlineView`)都是协调器既有属性(见文件头部)。`enumerateAvailableRowViews` 是 `NSTableView`/`NSOutlineView` API,遍历当前已实例化的行视图。

2c. 若 `SidebarCoordinator` 没有 `deinit` 移除观察者,在类内补一个(避免悬挂观察者):
```swift
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
```
> 若文件已有 `deinit`,把 `removeObserver(self)` 加进去即可,不要重复定义。

- [ ] **Step 3: 构建**

Run:
```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "fix: refresh sidebar selection colors on theme change (light-theme navy bug)"
```

---

## Task 6: 删除 DesignTokens 枚举 + 全量回归

**Files:**
- Delete: `Treemux/UI/Theme/DesignTokens.swift`

**Interfaces:** 无。前置:Tasks 1–5 已移除所有 `DesignTokens.` 引用(消费者:FileTreePanelView、WorkspaceTabBarView、CodeHighlightTheme、RenderedMarkdownView、FileIconCatalog、PhosphorUnderline)。

- [ ] **Step 1: 确认无残留引用**

Run:
```bash
grep -rn "DesignTokens" --include="*.swift" Treemux TreemuxTests | grep -v "Treemux/UI/Theme/DesignTokens.swift"
```
Expected: 无输出。若有,回到对应文件按 Tasks 2–4 的映射表替换为 `theme.*`,再继续。

- [ ] **Step 2: 删除文件并重新生成工程**

```bash
git rm Treemux/UI/Theme/DesignTokens.swift
xcodegen generate
```

- [ ] **Step 3: 全量测试 + 构建**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests
```
Expected: 编译成功(pbxproj 不再引用 DesignTokens.swift);全测试 PASS。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor: remove hardcoded DesignTokens (Phosphor) palette — fully theme-driven"
```

- [ ] **Step 5: 人工验证(卡皮巴拉运行)**

编译后运行(DerivedData 编号以实际为准):
```bash
ls ~/Library/Developer/Xcode/DerivedData/ | grep -i Treemux
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app
```
验证清单(切换浅/深主题):
- 文件列表面板背景跟随主题(浅色下为白,不再深色)。
- 文件树行选中/hover 色、缩进线、文件名、文件夹图标跟随主题。
- tab 栏背景、活动 tab、Files/Shell eyebrow、底边线跟随主题。
- 侧栏选中色:浅色为浅蓝(不再深 navy),且**切换主题时已选中行实时变色**。
- 打开一个 `.md` 文件:markdown 背景/正文/代码块高亮跟随主题(浅色下用浅色 ansi,可读)。

---

## Self-Review

**Spec coverage(对照 spec):**
- §1 颜色映射 → Global Constraints + Task 1(派生访问器)+ Task 2(代码高亮映射)。✔
- §2 逐表面:FileTreePanelView(T3)、WorkspaceTabBarView(T4)、FileIconCatalog(T3)、CodeHighlightTheme(T2)、TreeSitterCodeHighlighter(T2)、RenderedMarkdownView(T2)、PhosphorUnderline(T4)、侧栏选中(T5)、删 DesignTokens(T6)。✔
- §2 highlighter 注入:spec 提"监听 .themeDidChange";本计划因 markdown 高亮唯一消费者是视图(`RenderedMarkdownView`),改为**视图层在重渲染时用当前主题色构造 highlighter**(T2 Step 6)——实现 spec 意图(高亮主题驱动)且更简单,无需通知监听。已记此细化。✔
- §3 测试:CodeHighlightTheme 纯逻辑(T2)、FileIconCatalog 角色(T3)、ThemeManager 派生(T1);渲染层人工验证(T6 Step 5)。✔
- §4 范围边界:不引入 DesignSystem/pill/单一 accent 收敛;保持主架构;无新字符串。✔
- 侧栏选中 bug(§背景/§2)→ T5。✔

**Placeholder scan:** 无 TBD/TODO;每个改代码 step 给了完整代码或精确替换点。✔

**Type consistency:** `FileIconTintRole`(T1 定义,T3 消费)一致;`CodeHighlightTheme.resolvedHex/table/match/color(forCapture:in:)`(T2)签名在测试与 highlighter 中一致;`Icon.tintRole`(T3)替换 `tint` 后,唯一消费点 `FileTreePanelView.iconView`(T3 同任务更新)一致;`ThemeManager.ansiColor/shellAccent/fileIconTint`(T1)在 T3/T4 一致使用;`MarkdownCodeSyntaxHighlighter(captureColors:font:)`(T2)在 `RenderedMarkdownView`(T2)一致。✔

**实现者注意:**
- `RenderedMarkdownView` 现位于编辑器/文档查看视图树内(`MainWindowView` 注入了 `ThemeManager`);若在某处脱离环境使用,`@EnvironmentObject` 会崩——本阶段它仅用于文档查看,环境齐备。
- `SwiftUI.Color` 相等断言若在 CI 不稳,改比较 `NSColor(color).usingColorSpace(.sRGB)` 分量(见 Global Constraints)。
- Task 5 的 `enumerateAvailableRowViews` 只刷新已实例化行;滚动后新行经 `rowViewForItem` 已用当前主题色,二者覆盖完整。
