# 主题引擎(Theme Engine)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用基于 YAML 的主题系统替换现有 JSON 主题,自带浅/深两套默认主题、支持用户自定义 YAML 的增删切换,并让主题统一驱动 App UI 颜色与 Ghostty 终端配色(切换即热重载)。

**Architecture:** 方案 1(Token 解析器 + 语义色板)。一个 `.yaml` = 一套主题(元数据 + `ui` 语义色 + `terminal` 终端色)。`ThemeLoader` 用 Yams 从 `~/.treemux/themes/` 解析校验;内置两套以嵌入式字符串常量为权威来源,首启写盘、可删可恢复。`ThemeManager` 发布当前 `Theme` 并保持既有计算色访问器(`sidebarBackground` 等)名称不变,视图层不动。`TreemuxGhosttyRuntime` 读 `terminal` 段映射成 ghostty config 并在 `.themeDidChange` 时热重载。

**Tech Stack:** Swift / SwiftUI / AppKit、Yams(新增 SPM 依赖)、GhosttyKit(libghostty)、XcodeGen(`project.yml`)、XCTest。

## Global Constraints

- 部署目标 macOS 15.0;Swift 5;`project.yml` 由 XcodeGen 生成工程,改后必须 `xcodegen generate`。
- 状态目录:DEBUG 构建为 `~/.treemux-debug/`,Release 为 `~/.treemux/`(由 `treemuxStateDirectoryURL()` 决定)。主题目录 = 状态目录下的 `themes/` 子目录。
- 非交互 `xcodebuild` 必须加 `-skipPackagePluginValidation`(SwiftLint 插件)。
- 规范测试/构建命令(本计划统一引用):
  ```bash
  cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+theme-system-and-ui-refactor
  xcodegen generate
  xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -only-testing:TreemuxTests
  ```
  单测某个类:追加 `/<TestClassName>`,如 `-only-testing:TreemuxTests/ThemeLoaderTests`。
- 所有用户可见字符串用 `LocalizedStringKey`,并在 `Treemux/Localizable.xcstrings` 补 `zh-Hans`。
- 颜色 hex 合法格式:`#RGB` / `#RRGGBB` / `#RRGGBBAA`(大小写不敏感,`#` 可选)。终端色按不透明处理(送 ghostty 前归一为 `#RRGGBB`)。
- 提交信息用英文;遵循 worktree 规则(已在 `.worktrees/feat+theme-system-and-ui-refactor/` 内工作)。
- 此计划只做主题引擎(spec 的 P1–P3);UI 重构(P4–P5)在独立的计划二完成。计划一不得引入 `DesignSystem`(字体/间距/圆角)或改动现有 `DesignTokens`(Phosphor)/`CodeHighlightTheme`。

---

## File Structure

新建:
- `Treemux/Domain/Theme.swift` — `Theme` / `ThemeUIColors` / `ThemeTerminalColors` 值类型 + 校验。
- `Treemux/Domain/ThemeLoader.swift` — 从目录加载 + Yams 解析 + 校验 + 错误收集。
- `Treemux/Domain/BuiltInThemes.swift` — 内置两套 YAML 字符串常量 + 写盘/恢复。
- `Treemux/Services/Terminal/Ghostty/GhosttyTerminalConfig.swift` — `ThemeTerminalColors` → ghostty config 文本(纯函数,可测)。
- `TreemuxTests/ThemeLoaderTests.swift`、`TreemuxTests/BuiltInThemesTests.swift`、`TreemuxTests/GhosttyTerminalConfigTests.swift`。

修改:
- `project.yml` — 加 Yams 包 + 依赖。
- `Treemux/Support/Color+Hex.swift` — 支持 3 位 hex。
- `Treemux/UI/Theme/ThemeManager.swift` — 改用 `Theme` + `ThemeLoader`,新增 import/delete/reset,保留计算色访问器名。
- `Treemux/Support/Notifications.swift` — 加 `.themeDidChange`。
- `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift` — 注入终端配色 + 监听 `.themeDidChange` 热重载。
- `Treemux/UI/Settings/SettingsSheet.swift` — 主题管理 UI(列表/导入/删除/恢复/错误)。
- `Treemux/Localizable.xcstrings` — 新增中文翻译。
- `TreemuxTests/ThemeTests.swift` — 迁移到新模型。
- 删除 `Treemux/Domain/ThemeDefinition.swift`。
- `.claude/CLAUDE.md` — 新增「UI 设计规范」小节。

---

## Task 1: 引入 Yams 依赖

**Files:**
- Modify: `project.yml`(`packages:` 与 `targets.Treemux.dependencies`)
- Test: `TreemuxTests/ThemeLoaderTests.swift`(本任务先建一个最小冒烟测试)

**Interfaces:**
- Produces: 项目可 `import Yams`,可用 `YAMLDecoder().decode(_:from:)`。

- [ ] **Step 1: 在 `project.yml` 的 `packages:` 块末尾追加 Yams**

在 `MarkdownUI:` 条目之后追加:
```yaml
  Yams:
    url: https://github.com/jpsim/Yams
    from: "5.1.0"
```

- [ ] **Step 2: 在 `targets.Treemux.dependencies` 末尾追加 Yams 产品**

在 `- package: MarkdownUI` / `product: MarkdownUI` 之后追加:
```yaml
      - package: Yams
        product: Yams
```

- [ ] **Step 3: 写最小冒烟测试**

新建 `TreemuxTests/ThemeLoaderTests.swift`:
```swift
//
//  ThemeLoaderTests.swift
//  TreemuxTests
//

import XCTest
import Yams
@testable import Treemux

final class ThemeLoaderTests: XCTestCase {

    func testYamsDependencyIsLinked() throws {
        struct Probe: Decodable { let a: Int }
        let decoded = try YAMLDecoder().decode(Probe.self, from: "a: 7\n")
        XCTAssertEqual(decoded.a, 7)
    }
}
```

- [ ] **Step 4: 重新生成工程并运行测试**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+theme-system-and-ui-refactor
xcodegen generate
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeLoaderTests
```
Expected: 解析依赖、构建成功、`testYamsDependencyIsLinked` PASS。

- [ ] **Step 5: 提交**

```bash
git add project.yml Treemux.xcodeproj TreemuxTests/ThemeLoaderTests.swift
git commit -m "build: add Yams YAML dependency"
```

---

## Task 2: 主题颜色模型 + 校验

**Files:**
- Create: `Treemux/Domain/Theme.swift`
- Modify: `Treemux/Support/Color+Hex.swift`(支持 3 位)
- Test: `TreemuxTests/ThemeModelTests.swift`

**Interfaces:**
- Produces:
  - `struct Theme: Codable, Identifiable, Equatable { let id, name: String; let author: String?; let appearance: String; let ui: ThemeUIColors; let terminal: ThemeTerminalColors }`
  - `struct ThemeUIColors: Codable, Equatable { accent, accentOnDark, onAccent, window, sidebar, pane, paneHeader, tabBar, statusBar, selection, hairline, textPrimary, textSecondary, textMuted, success, warning, danger: String; selectionStroke: String? }`
  - `struct ThemeTerminalColors: Codable, Equatable { foreground, background, cursor, selection: String; cursorText, selectionText: String?; ansi: [String] }`
  - `enum ThemeValidationError: Error, Equatable { case badHex(field: String, value: String); case wrongAnsiCount(Int) }`
  - `func Theme.validate() throws`
  - `enum HexColor { static func isValid(_ s: String) -> Bool }`

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/ThemeModelTests.swift`:
```swift
//
//  ThemeModelTests.swift
//  TreemuxTests
//

import XCTest
import Yams
@testable import Treemux

final class ThemeModelTests: XCTestCase {

    private let validYAML = """
    id: sample
    name: Sample
    author: tester
    appearance: dark
    ui:
      accent: "#418ADE"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#0F1114"
      sidebar: "#0F1114"
      pane: "#111317"
      paneHeader: "#151820"
      tabBar: "#0F1114"
      statusBar: "#0F1114"
      selection: "#1A2A42"
      selectionStroke: "#418ADE"
      hairline: "#FFFFFF1A"
      textPrimary: "#F0F0F2"
      textSecondary: "#C5C8C6"
      textMuted: "#7A7A7A"
      success: "#B5BD68"
      warning: "#F0C674"
      danger: "#CC6666"
    terminal:
      foreground: "#C5C8C6"
      background: "#111317"
      cursor: "#C5C8C6"
      selection: "#373B41"
      ansi:
        - "#1D1F21"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#C5C8C6"
        - "#969896"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#FFFFFF"
    """

    func testDecodeValidTheme() throws {
        let theme = try YAMLDecoder().decode(Theme.self, from: validYAML)
        XCTAssertEqual(theme.id, "sample")
        XCTAssertEqual(theme.ui.accent, "#418ADE")
        XCTAssertNil(theme.terminal.cursorText)
        XCTAssertEqual(theme.terminal.ansi.count, 16)
        XCTAssertNoThrow(try theme.validate())
    }

    func testValidateRejectsWrongAnsiCount() throws {
        let shortYAML = validYAML.replacingOccurrences(
            of: "      - \"#FFFFFF\"", with: "")  // remove last ansi entry -> 15
        let theme = try YAMLDecoder().decode(Theme.self, from: shortYAML)
        XCTAssertThrowsError(try theme.validate()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .wrongAnsiCount(15))
        }
    }

    func testValidateRejectsBadHex() throws {
        let badYAML = validYAML.replacingOccurrences(
            of: "accent: \"#418ADE\"", with: "accent: \"not-a-color\"")
        let theme = try YAMLDecoder().decode(Theme.self, from: badYAML)
        XCTAssertThrowsError(try theme.validate()) { error in
            XCTAssertEqual(error as? ThemeValidationError, .badHex(field: "ui.accent", value: "not-a-color"))
        }
    }

    func testHexValidatorAcceptsThreeSixEight() {
        XCTAssertTrue(HexColor.isValid("#FFF"))
        XCTAssertTrue(HexColor.isValid("#FFFFFF"))
        XCTAssertTrue(HexColor.isValid("#FFFFFF1A"))
        XCTAssertTrue(HexColor.isValid("418ADE"))
        XCTAssertFalse(HexColor.isValid("#GG0000"))
        XCTAssertFalse(HexColor.isValid("#FF"))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeModelTests
```
Expected: 编译失败(`Theme`/`HexColor` 未定义)。

- [ ] **Step 3: 实现模型**

新建 `Treemux/Domain/Theme.swift`:
```swift
//
//  Theme.swift
//  Treemux
//

import Foundation

// MARK: - Hex color validation

/// Validates hex color strings in #RGB / #RRGGBB / #RRGGBBAA form (# optional).
enum HexColor {
    static func isValid(_ raw: String) -> Bool {
        let s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard s.count == 3 || s.count == 6 || s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Theme value types

/// App UI semantic colors. Field names follow DESIGN.md vocabulary.
struct ThemeUIColors: Codable, Equatable {
    let accent: String
    let accentOnDark: String
    let onAccent: String
    let window: String
    let sidebar: String
    let pane: String
    let paneHeader: String
    let tabBar: String
    let statusBar: String
    let selection: String
    let selectionStroke: String?   // optional -> falls back to accent
    let hairline: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let success: String
    let warning: String
    let danger: String
}

/// Terminal colors consumed by Ghostty.
struct ThemeTerminalColors: Codable, Equatable {
    let foreground: String
    let background: String
    let cursor: String
    let cursorText: String?     // optional
    let selection: String
    let selectionText: String?  // optional
    let ansi: [String]          // exactly 16
}

/// A complete theme: metadata + UI colors + terminal colors.
struct Theme: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let author: String?
    let appearance: String      // "dark" | "light"
    let ui: ThemeUIColors
    let terminal: ThemeTerminalColors
}

// MARK: - Validation

enum ThemeValidationError: Error, Equatable {
    case badHex(field: String, value: String)
    case wrongAnsiCount(Int)
}

extension Theme {
    /// Validates every color field and the ansi count. Throws on first problem.
    func validate() throws {
        let uiFields: [(String, String)] = [
            ("ui.accent", ui.accent),
            ("ui.accentOnDark", ui.accentOnDark),
            ("ui.onAccent", ui.onAccent),
            ("ui.window", ui.window),
            ("ui.sidebar", ui.sidebar),
            ("ui.pane", ui.pane),
            ("ui.paneHeader", ui.paneHeader),
            ("ui.tabBar", ui.tabBar),
            ("ui.statusBar", ui.statusBar),
            ("ui.selection", ui.selection),
            ("ui.hairline", ui.hairline),
            ("ui.textPrimary", ui.textPrimary),
            ("ui.textSecondary", ui.textSecondary),
            ("ui.textMuted", ui.textMuted),
            ("ui.success", ui.success),
            ("ui.warning", ui.warning),
            ("ui.danger", ui.danger)
        ]
        for (field, value) in uiFields where !HexColor.isValid(value) {
            throw ThemeValidationError.badHex(field: field, value: value)
        }
        if let stroke = ui.selectionStroke, !HexColor.isValid(stroke) {
            throw ThemeValidationError.badHex(field: "ui.selectionStroke", value: stroke)
        }

        guard terminal.ansi.count == 16 else {
            throw ThemeValidationError.wrongAnsiCount(terminal.ansi.count)
        }
        var termFields: [(String, String)] = [
            ("terminal.foreground", terminal.foreground),
            ("terminal.background", terminal.background),
            ("terminal.cursor", terminal.cursor),
            ("terminal.selection", terminal.selection)
        ]
        if let c = terminal.cursorText { termFields.append(("terminal.cursorText", c)) }
        if let s = terminal.selectionText { termFields.append(("terminal.selectionText", s)) }
        for (i, hex) in terminal.ansi.enumerated() {
            termFields.append(("terminal.ansi[\(i)]", hex))
        }
        for (field, value) in termFields where !HexColor.isValid(value) {
            throw ThemeValidationError.badHex(field: field, value: value)
        }
    }
}
```

- [ ] **Step 4: 扩展 `Color+Hex.swift` 支持 3 位**

在 `Treemux/Support/Color+Hex.swift` 的 `switch cleaned.count {` 中,在 `case 6:` 之前插入:
```swift
        case 3:
            r = Double((rgba >> 8) & 0xF) / 15.0
            g = Double((rgba >> 4) & 0xF) / 15.0
            b = Double(rgba & 0xF) / 15.0
            a = 1.0
```

- [ ] **Step 5: 运行测试确认通过**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeModelTests
```
Expected: 4 个测试全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add Treemux/Domain/Theme.swift Treemux/Support/Color+Hex.swift TreemuxTests/ThemeModelTests.swift
git commit -m "feat: YAML theme color model with validation"
```

---

## Task 3: ThemeLoader(目录加载 + 校验 + 错误收集)

**Files:**
- Create: `Treemux/Domain/ThemeLoader.swift`
- Test: `TreemuxTests/ThemeLoaderTests.swift`(扩展 Task 1 的文件)

**Interfaces:**
- Consumes: `Theme`、`Theme.validate()`、`YAMLDecoder`。
- Produces:
  - `struct ThemeLoadError: Equatable { let fileName: String; let message: String }`
  - `struct ThemeLoadResult: Equatable { let themes: [Theme]; let errors: [ThemeLoadError] }`
  - `enum ThemeLoader { static func load(from directory: URL, fileManager: FileManager = .default) -> ThemeLoadResult }`
  - 加载规则:遍历目录下 `.yaml`/`.yml`,解码+校验;失败计入 `errors` 且跳过;同 `id` 重复时保留先遇到的、其余计入 errors;`themes` 按 `name` 升序(`treemux-` 内置不特殊排序,纯 name 排序)。

- [ ] **Step 1: 写失败测试(追加到 ThemeLoaderTests.swift)**

在 `ThemeLoaderTests` 类内追加方法,并在文件顶部已 `import Yams`:
```swift
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("themeloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, named name: String, to dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func minimalThemeYAML(id: String, name: String) -> String {
        """
        id: \(id)
        name: \(name)
        appearance: dark
        ui:
          accent: "#418ADE"
          accentOnDark: "#2997FF"
          onAccent: "#FFFFFF"
          window: "#0F1114"
          sidebar: "#0F1114"
          pane: "#111317"
          paneHeader: "#151820"
          tabBar: "#0F1114"
          statusBar: "#0F1114"
          selection: "#1A2A42"
          hairline: "#FFFFFF1A"
          textPrimary: "#F0F0F2"
          textSecondary: "#C5C8C6"
          textMuted: "#7A7A7A"
          success: "#B5BD68"
          warning: "#F0C674"
          danger: "#CC6666"
        terminal:
          foreground: "#C5C8C6"
          background: "#111317"
          cursor: "#C5C8C6"
          selection: "#373B41"
          ansi: ["#1D1F21","#CC6666","#B5BD68","#F0C674","#81A2BE","#B294BB","#8ABEB7","#C5C8C6","#969896","#CC6666","#B5BD68","#F0C674","#81A2BE","#B294BB","#8ABEB7","#FFFFFF"]
        """
    }

    func testLoadsValidThemesSortedByName() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "b-theme", name: "Bravo"), named: "b.yaml", to: dir)
        try write(minimalThemeYAML(id: "a-theme", name: "Alpha"), named: "a.yml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.map(\.name), ["Alpha", "Bravo"])
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testInvalidYAMLIsCollectedAsError() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "ok", name: "OK"), named: "ok.yaml", to: dir)
        try write("id: broken\nthis is: : not valid", named: "broken.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.map(\.id), ["ok"])
        XCTAssertEqual(result.errors.map(\.fileName), ["broken.yaml"])
    }

    func testWrongAnsiCountIsCollectedAsError() throws {
        let dir = try makeTempDir()
        let bad = minimalThemeYAML(id: "bad", name: "Bad")
            .replacingOccurrences(of: ",\"#FFFFFF\"]", with: "]")  // 15 entries
        try write(bad, named: "bad.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].message.contains("ansi"))
    }

    func testDuplicateIDKeepsFirstAndReportsError() throws {
        let dir = try makeTempDir()
        try write(minimalThemeYAML(id: "dup", name: "AAA First"), named: "a-first.yaml", to: dir)
        try write(minimalThemeYAML(id: "dup", name: "ZZZ Second"), named: "z-second.yaml", to: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes[0].id, "dup")
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].message.contains("duplicate"))
    }

    func testMissingDirectoryReturnsEmpty() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeLoaderTests
```
Expected: 编译失败(`ThemeLoader` 未定义)。

- [ ] **Step 3: 实现 ThemeLoader**

新建 `Treemux/Domain/ThemeLoader.swift`:
```swift
//
//  ThemeLoader.swift
//  Treemux
//

import Foundation
import Yams

/// One failed theme file, surfaced in the settings UI.
struct ThemeLoadError: Equatable {
    let fileName: String
    let message: String
}

/// Result of scanning a themes directory.
struct ThemeLoadResult: Equatable {
    let themes: [Theme]
    let errors: [ThemeLoadError]
}

/// Loads and validates `.yaml`/`.yml` theme files from a directory.
enum ThemeLoader {
    static func load(from directory: URL, fileManager: FileManager = .default) -> ThemeLoadResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return ThemeLoadResult(themes: [], errors: [])
        }

        let files = entries
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = YAMLDecoder()
        var themes: [Theme] = []
        var errors: [ThemeLoadError] = []
        var seenIDs = Set<String>()

        for file in files {
            let name = file.lastPathComponent
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let theme = try decoder.decode(Theme.self, from: text)
                try theme.validate()
                if seenIDs.contains(theme.id) {
                    errors.append(ThemeLoadError(
                        fileName: name,
                        message: "duplicate theme id '\(theme.id)' — skipped"))
                    continue
                }
                seenIDs.insert(theme.id)
                themes.append(theme)
            } catch let validation as ThemeValidationError {
                errors.append(ThemeLoadError(fileName: name, message: describe(validation)))
            } catch {
                errors.append(ThemeLoadError(fileName: name, message: error.localizedDescription))
            }
        }

        themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ThemeLoadResult(themes: themes, errors: errors)
    }

    private static func describe(_ error: ThemeValidationError) -> String {
        switch error {
        case let .badHex(field, value):
            return "invalid hex color in \(field): '\(value)'"
        case let .wrongAnsiCount(count):
            return "terminal.ansi must have exactly 16 entries (found \(count))"
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeLoaderTests
```
Expected: 全部 PASS(含 Task 1 的冒烟测试)。

- [ ] **Step 5: 提交**

```bash
git add Treemux/Domain/ThemeLoader.swift TreemuxTests/ThemeLoaderTests.swift
git commit -m "feat: ThemeLoader parses and validates YAML theme directory"
```

---

## Task 4: 内置主题 YAML 常量 + 写盘/恢复

**Files:**
- Create: `Treemux/Domain/BuiltInThemes.swift`
- Test: `TreemuxTests/BuiltInThemesTests.swift`

**Interfaces:**
- Consumes: `ThemeLoader`、`Theme`。
- Produces:
  - `enum BuiltInThemes { static let darkYAML: String; static let lightYAML: String; static let ids: [String] /* ["treemux-dark","treemux-light"] */; static let fileNames: [String: String] /* id -> "<id>.yaml" */ }`
  - `static func ensureInstalled(in directory: URL, fileManager: FileManager = .default) throws` — 缺失的内置文件才写;不覆盖已存在文件。
  - `static func restore(in directory: URL, fileManager: FileManager = .default) throws` — 强制把两套内置写回(覆盖)。
  - `static func fallbackDark() -> Theme` — 直接解析 `darkYAML`(用于磁盘上无任何有效主题时的兜底)。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/BuiltInThemesTests.swift`:
```swift
//
//  BuiltInThemesTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class BuiltInThemesTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBuiltInYAMLParsesAndValidates() throws {
        for yaml in [BuiltInThemes.darkYAML, BuiltInThemes.lightYAML] {
            let theme = try Yams.YAMLDecoder().decode(Theme.self, from: yaml)
            XCTAssertNoThrow(try theme.validate())
        }
    }

    func testEnsureInstalledWritesBothThenLoaderFindsThem() throws {
        let dir = try makeTempDir()
        try BuiltInThemes.ensureInstalled(in: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertEqual(Set(result.themes.map(\.id)), Set(["treemux-dark", "treemux-light"]))
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testEnsureInstalledDoesNotOverwriteExisting() throws {
        let dir = try makeTempDir()
        let darkFile = dir.appendingPathComponent("treemux-dark.yaml")
        try "id: treemux-dark\n# user edited".write(to: darkFile, atomically: true, encoding: .utf8)
        try BuiltInThemes.ensureInstalled(in: dir)
        let contents = try String(contentsOf: darkFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("user edited"))
    }

    func testRestoreOverwrites() throws {
        let dir = try makeTempDir()
        let darkFile = dir.appendingPathComponent("treemux-dark.yaml")
        try "garbage".write(to: darkFile, atomically: true, encoding: .utf8)
        try BuiltInThemes.restore(in: dir)
        let result = ThemeLoader.load(from: dir)
        XCTAssertTrue(result.themes.contains(where: { $0.id == "treemux-dark" }))
    }

    func testFallbackDarkParses() {
        XCTAssertEqual(BuiltInThemes.fallbackDark().id, "treemux-dark")
    }
}
```
> 注:测试需 `import Yams`。在文件顶部加 `import Yams`。

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/BuiltInThemesTests
```
Expected: 编译失败(`BuiltInThemes` 未定义)。

- [ ] **Step 3: 实现 BuiltInThemes**

新建 `Treemux/Domain/BuiltInThemes.swift`:
```swift
//
//  BuiltInThemes.swift
//  Treemux
//

import Foundation
import Yams

/// The two shipped themes. The YAML literals are the authoritative source;
/// they are written to the user's themes directory on first run and can be
/// restored after deletion/edit.
enum BuiltInThemes {

    static let ids = ["treemux-dark", "treemux-light"]

    static let fileNames: [String: String] = [
        "treemux-dark": "treemux-dark.yaml",
        "treemux-light": "treemux-light.yaml"
    ]

    static let darkYAML = """
    id: treemux-dark
    name: Treemux Dark
    author: BatchZero
    appearance: dark
    ui:
      accent: "#418ADE"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#0F1114"
      sidebar: "#0F1114"
      pane: "#111317"
      paneHeader: "#151820"
      tabBar: "#0F1114"
      statusBar: "#0F1114"
      selection: "#1A2A42"
      selectionStroke: "#418ADE"
      hairline: "#FFFFFF1A"
      textPrimary: "#F0F0F2"
      textSecondary: "#C5C8C6"
      textMuted: "#7A7A7A"
      success: "#B5BD68"
      warning: "#F0C674"
      danger: "#CC6666"
    terminal:
      foreground: "#C5C8C6"
      background: "#111317"
      cursor: "#C5C8C6"
      cursorText: "#111317"
      selection: "#373B41"
      selectionText: "#C5C8C6"
      ansi:
        - "#1D1F21"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#C5C8C6"
        - "#969896"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#FFFFFF"
    """

    static let lightYAML = """
    id: treemux-light
    name: Treemux Light
    author: BatchZero
    appearance: light
    ui:
      accent: "#0066CC"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#FFFFFF"
      sidebar: "#F5F5F7"
      pane: "#FFFFFF"
      paneHeader: "#FAFAFC"
      tabBar: "#F5F5F7"
      statusBar: "#F5F5F7"
      selection: "#D2E3FB"
      selectionStroke: "#0066CC"
      hairline: "#1D1D1F14"
      textPrimary: "#1D1D1F"
      textSecondary: "#333333"
      textMuted: "#7A7A7A"
      success: "#248A3D"
      warning: "#B25000"
      danger: "#D70015"
    terminal:
      foreground: "#1D1D1F"
      background: "#FFFFFF"
      cursor: "#0066CC"
      cursorText: "#FFFFFF"
      selection: "#D2E3FB"
      selectionText: "#1D1D1F"
      ansi:
        - "#1D1D1F"
        - "#D70015"
        - "#248A3D"
        - "#B25000"
        - "#0066CC"
        - "#8944AB"
        - "#0071A4"
        - "#6E6E73"
        - "#7A7A7A"
        - "#E5484D"
        - "#30A46C"
        - "#D9822B"
        - "#2997FF"
        - "#A450CF"
        - "#0091C2"
        - "#1D1D1F"
    """

    private static func yaml(forID id: String) -> String {
        id == "treemux-light" ? lightYAML : darkYAML
    }

    /// Writes any missing built-in files without overwriting existing ones.
    static func ensureInstalled(in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ids {
            let url = directory.appendingPathComponent(fileNames[id]!)
            if !fileManager.fileExists(atPath: url.path) {
                try yaml(forID: id).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Force-rewrites both built-in files (overwriting edits/corruption).
    static func restore(in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ids {
            let url = directory.appendingPathComponent(fileNames[id]!)
            try yaml(forID: id).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// In-memory dark theme for when no valid theme exists on disk.
    static func fallbackDark() -> Theme {
        // The literal is validated by tests; force-try is safe here.
        // swiftlint:disable:next force_try
        try! YAMLDecoder().decode(Theme.self, from: darkYAML)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/BuiltInThemesTests
```
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add Treemux/Domain/BuiltInThemes.swift TreemuxTests/BuiltInThemesTests.swift
git commit -m "feat: built-in dark/light theme YAML with install + restore"
```

---

## Task 5: ThemeManager 改造(YAML 驱动 + 增删恢复 + 保留访问器)

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift`(整体重写)
- Modify: `Treemux/Support/Notifications.swift`(加 `.themeDidChange`)
- Delete: `Treemux/Domain/ThemeDefinition.swift`
- Modify: `TreemuxTests/ThemeTests.swift`(迁移到新模型)

**Interfaces:**
- Consumes: `Theme`、`ThemeLoader`、`BuiltInThemes`、`treemuxStateDirectoryURL()`、`Color(hex:)`。
- Produces(`ThemeManager` 公开成员,供视图与 Ghostty 复用):
  - `@Published private(set) var activeTheme: Theme`
  - `@Published private(set) var availableThemes: [Theme]`
  - `@Published private(set) var loadErrors: [ThemeLoadError]`
  - `init(activeThemeID: String = "treemux-dark")`
  - `func setActiveTheme(_ id: String)` — 切换 + 发 `.themeDidChange`(object = 新 `Theme`)
  - `func reloadThemes()`
  - `func importTheme(from url: URL) throws` — 校验后复制进主题目录,刷新
  - `func deleteTheme(_ id: String) throws` — 删除对应文件,刷新;若删的是 active 则回退
  - `func resetBuiltIns()` — `BuiltInThemes.restore` + 刷新
  - `func ensureBuiltInThemesExist()` — `BuiltInThemes.ensureInstalled`(保留旧名,`WindowContext` 在调用)
  - 计算色访问器(名称与现状一致,视图无需改):`sidebarBackground/sidebarForeground/sidebarSelection/tabBarBackground/paneBackground/paneHeaderBackground/dividerColor/accentColor/statusBarBackground/textPrimary/textSecondary/textMuted/successColor/warningColor/dangerColor`、`sidebarSelectionFillNS/sidebarSelectionStrokeNS`、`windowAppearance/nsWindowBackgroundColor`
  - `var themesDirectory: URL`(`~/.treemux/themes`)

- [ ] **Step 1: 加通知名**

在 `Treemux/Support/Notifications.swift` 的 `extension Notification.Name {` 内追加:
```swift
    /// Posted when the active theme changes. `object` is the new `Theme`.
    static let themeDidChange = Notification.Name("treemux.themeDidChange")
```

- [ ] **Step 2: 重写 ThemeTests.swift(新模型)**

整体替换 `TreemuxTests/ThemeTests.swift`:
```swift
//
//  ThemeTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ThemeTests: XCTestCase {

    @MainActor
    func testDefaultsToDark() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }

    @MainActor
    func testSwitchTheme() {
        let manager = ThemeManager()
        manager.setActiveTheme("treemux-light")
        XCTAssertEqual(manager.activeTheme.id, "treemux-light")
    }

    @MainActor
    func testFallbackForUnknownID() {
        let manager = ThemeManager(activeThemeID: "nonexistent")
        XCTAssertEqual(manager.activeTheme.id, "treemux-dark")
    }

    @MainActor
    func testAvailableThemesIncludeBuiltIns() {
        let manager = ThemeManager()
        XCTAssertTrue(manager.availableThemes.contains(where: { $0.id == "treemux-dark" }))
        XCTAssertTrue(manager.availableThemes.contains(where: { $0.id == "treemux-light" }))
    }

    @MainActor
    func testSetActiveThemePostsNotification() {
        let manager = ThemeManager()
        let expectation = expectation(forNotification: .themeDidChange, object: nil)
        manager.setActiveTheme("treemux-light")
        wait(for: [expectation], timeout: 1.0)
    }
}
```
> 注:这些测试会读写真实的 `~/.treemux-debug/themes/`(DEBUG)。`ensureInstalled` 不覆盖已存在文件,安全。

- [ ] **Step 3: 运行测试确认失败**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeTests
```
Expected: 编译失败(旧 `ThemeManager` API/类型不匹配,`ThemeDefinition` 仍在)。

- [ ] **Step 4: 整体重写 ThemeManager.swift**

替换 `Treemux/UI/Theme/ThemeManager.swift` 全文:
```swift
//
//  ThemeManager.swift
//  Treemux
//

import AppKit
import Foundation
import SwiftUI

/// Manages YAML theme loading, selection, and color publishing for the app.
@MainActor
final class ThemeManager: ObservableObject {

    @Published private(set) var activeTheme: Theme
    @Published private(set) var availableThemes: [Theme] = []
    @Published private(set) var loadErrors: [ThemeLoadError] = []

    /// Directory holding all theme `.yaml` files.
    let themesDirectory: URL

    init(activeThemeID: String = "treemux-dark") {
        self.themesDirectory = treemuxStateDirectoryURL()
            .appendingPathComponent("themes", isDirectory: true)

        // Make sure built-ins exist on disk, then load.
        try? BuiltInThemes.ensureInstalled(in: themesDirectory)
        let result = ThemeLoader.load(from: themesDirectory)
        self.availableThemes = result.themes
        self.loadErrors = result.errors

        self.activeTheme = ThemeManager.resolve(
            id: activeThemeID, in: result.themes)
    }

    // MARK: - Loading

    private static func resolve(id: String, in themes: [Theme]) -> Theme {
        if let match = themes.first(where: { $0.id == id }) { return match }
        if let dark = themes.first(where: { $0.id == "treemux-dark" }) { return dark }
        if let first = themes.first { return first }
        return BuiltInThemes.fallbackDark()
    }

    func reloadThemes() {
        let result = ThemeLoader.load(from: themesDirectory)
        availableThemes = result.themes
        loadErrors = result.errors
        // Re-resolve active theme (it may have been deleted/edited).
        activeTheme = ThemeManager.resolve(id: activeTheme.id, in: result.themes)
    }

    func ensureBuiltInThemesExist() {
        try? BuiltInThemes.ensureInstalled(in: themesDirectory)
    }

    // MARK: - Switching

    func setActiveTheme(_ id: String) {
        let resolved = ThemeManager.resolve(id: id, in: availableThemes)
        activeTheme = resolved
        NotificationCenter.default.post(name: .themeDidChange, object: resolved)
    }

    // MARK: - Management

    func importTheme(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let theme = try YAMLDecoderShim.decode(text)   // throws on parse/validation
        let destination = themesDirectory
            .appendingPathComponent("\(theme.id).yaml")
        try FileManager.default.createDirectory(
            at: themesDirectory, withIntermediateDirectories: true)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        reloadThemes()
    }

    func deleteTheme(_ id: String) throws {
        // Delete every file in the directory that declares this id
        // (file names are not guaranteed to equal the theme id).
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: themesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in entries where ["yaml", "yml"].contains(file.pathExtension.lowercased()) {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let theme = try? YAMLDecoderShim.decodeWithoutValidation(text),
               theme.id == id {
                try FileManager.default.removeItem(at: file)
            }
        }
        reloadThemes()
    }

    func resetBuiltIns() {
        try? BuiltInThemes.restore(in: themesDirectory)
        reloadThemes()
    }

    // MARK: - Resolved SwiftUI Colors (accessor names kept stable for views)

    var sidebarBackground: Color { Color(hex: activeTheme.ui.sidebar) }
    var sidebarForeground: Color { Color(hex: activeTheme.ui.textPrimary) }
    var sidebarSelection: Color { Color(hex: activeTheme.ui.selection) }
    var tabBarBackground: Color { Color(hex: activeTheme.ui.tabBar) }
    var paneBackground: Color { Color(hex: activeTheme.ui.pane) }
    var paneHeaderBackground: Color { Color(hex: activeTheme.ui.paneHeader) }
    var dividerColor: Color { Color(hex: activeTheme.ui.hairline) }
    var accentColor: Color { Color(hex: activeTheme.ui.accent) }
    var statusBarBackground: Color { Color(hex: activeTheme.ui.statusBar) }
    var textPrimary: Color { Color(hex: activeTheme.ui.textPrimary) }
    var textSecondary: Color { Color(hex: activeTheme.ui.textSecondary) }
    var textMuted: Color { Color(hex: activeTheme.ui.textMuted) }
    var successColor: Color { Color(hex: activeTheme.ui.success) }
    var warningColor: Color { Color(hex: activeTheme.ui.warning) }
    var dangerColor: Color { Color(hex: activeTheme.ui.danger) }

    // MARK: - Resolved AppKit Colors (NSOutlineView sidebar)

    var sidebarSelectionFillNS: NSColor { NSColor(sidebarSelection) }
    var sidebarSelectionStrokeNS: NSColor {
        if let hex = activeTheme.ui.selectionStroke {
            return NSColor(Color(hex: hex)).withAlphaComponent(0.9)
        }
        return NSColor(accentColor).withAlphaComponent(0.9)
    }

    // MARK: - Window appearance

    var windowAppearance: NSAppearance? {
        switch activeTheme.appearance {
        case "light": return NSAppearance(named: .aqua)
        default: return NSAppearance(named: .darkAqua)
        }
    }

    var nsWindowBackgroundColor: NSColor {
        NSColor(Color(hex: activeTheme.ui.window))
    }
}

/// Small wrapper so ThemeManager doesn't import Yams directly at call sites.
private enum YAMLDecoderShim {
    static func decode(_ text: String) throws -> Theme {
        let theme = try decodeWithoutValidation(text)
        try theme.validate()
        return theme
    }
    static func decodeWithoutValidation(_ text: String) throws -> Theme {
        try Yams.YAMLDecoder().decode(Theme.self, from: text)
    }
}
```
> 在文件顶部 `import` 处加 `import Yams`(YAMLDecoderShim 需要)。

- [ ] **Step 5: 删除 ThemeDefinition.swift**

```bash
git rm Treemux/Domain/ThemeDefinition.swift
```

- [ ] **Step 6: 重新生成工程并运行测试**

> 删除文件后需重生成,确保 pbxproj 不再引用 `ThemeDefinition.swift`。

Run:
```bash
xcodegen generate
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/ThemeTests
```
Expected: `ThemeTests` 5 个全部 PASS;整体编译成功(`SettingsSheet` 仍用 `availableThemes`/`name`/`id`,与新 `Theme` 兼容)。

- [ ] **Step 7: 全量回归(确认没有别处引用旧类型)**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests
```
Expected: 全测试套件 PASS。若有文件引用了 `ThemeDefinition`/旧 `UIColors`/`TerminalColors`,在此修复(预期仅 `ThemeManager`/`ThemeTests`,已处理)。

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat: YAML-driven ThemeManager with import/delete/reset; remove JSON ThemeDefinition"
```

---

## Task 6: Ghostty 终端配色接通 + 热切换

**Files:**
- Create: `Treemux/Services/Terminal/Ghostty/GhosttyTerminalConfig.swift`
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift`
- Test: `TreemuxTests/GhosttyTerminalConfigTests.swift`

**Interfaces:**
- Consumes: `ThemeTerminalColors`、`Theme`、`ThemeLoader`、`AppSettingsPersistence`、`BuiltInThemes`、`.themeDidChange`、`TerminalSettings`。
- Produces:
  - `enum GhosttyHex { static func normalize(_ raw: String) -> String /* -> "#RRGGBB" */ }`
  - `enum GhosttyTerminalConfig { static func lines(for colors: ThemeTerminalColors, cursorStyle: String) -> [String] }`
  - `TreemuxGhosttyRuntime` 在 init 时解析当前主题终端色注入初始 config;监听 `.themeDidChange` → `reloadGhosttyConfig`。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/GhosttyTerminalConfigTests.swift`:
```swift
//
//  GhosttyTerminalConfigTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class GhosttyTerminalConfigTests: XCTestCase {

    private func sampleColors() -> ThemeTerminalColors {
        ThemeTerminalColors(
            foreground: "#C5C8C6",
            background: "#111317",
            cursor: "#C5C8C6",
            cursorText: "#111317",
            selection: "#373B41",
            selectionText: "#C5C8C6",
            ansi: (0..<16).map { _ in "#1D1F21" })
    }

    func testNormalizeExpandsThreeDigit() {
        XCTAssertEqual(GhosttyHex.normalize("#FFF"), "#FFFFFF")
    }

    func testNormalizeStripsAlpha() {
        XCTAssertEqual(GhosttyHex.normalize("#11223344"), "#112233")
    }

    func testNormalizeAddsHash() {
        XCTAssertEqual(GhosttyHex.normalize("418ADE"), "#418ADE")
    }

    func testLinesContainCoreColors() {
        let lines = GhosttyTerminalConfig.lines(for: sampleColors(), cursorStyle: "bar")
        XCTAssertTrue(lines.contains("background = #111317"))
        XCTAssertTrue(lines.contains("foreground = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-color = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-text = #111317"))
        XCTAssertTrue(lines.contains("selection-background = #373B41"))
        XCTAssertTrue(lines.contains("selection-foreground = #C5C8C6"))
        XCTAssertTrue(lines.contains("cursor-style = bar"))
    }

    func testLinesContainSixteenPaletteEntries() {
        let lines = GhosttyTerminalConfig.lines(for: sampleColors(), cursorStyle: "bar")
        for i in 0..<16 {
            XCTAssertTrue(lines.contains("palette = \(i)=#1D1F21"),
                          "missing palette entry \(i)")
        }
    }

    func testOptionalColorsOmittedWhenNil() {
        let colors = ThemeTerminalColors(
            foreground: "#FFFFFF", background: "#000000", cursor: "#FFFFFF",
            cursorText: nil, selection: "#222222", selectionText: nil,
            ansi: (0..<16).map { _ in "#FFFFFF" })
        let lines = GhosttyTerminalConfig.lines(for: colors, cursorStyle: "block")
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("cursor-text") }))
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("selection-foreground") }))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/GhosttyTerminalConfigTests
```
Expected: 编译失败(`GhosttyTerminalConfig`/`GhosttyHex` 未定义)。

- [ ] **Step 3: 实现 GhosttyTerminalConfig**

新建 `Treemux/Services/Terminal/Ghostty/GhosttyTerminalConfig.swift`:
```swift
//
//  GhosttyTerminalConfig.swift
//  Treemux
//

import Foundation

/// Normalizes theme hex strings into the `#RRGGBB` form ghostty expects.
enum GhosttyHex {
    static func normalize(_ raw: String) -> String {
        var s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()   // RGB -> RRGGBB
        } else if s.count == 8 {
            s = String(s.prefix(6))               // drop alpha
        }
        return "#\(s.uppercased())"
    }
}

/// Builds ghostty config lines from a theme's terminal colors.
enum GhosttyTerminalConfig {
    static func lines(for colors: ThemeTerminalColors, cursorStyle: String) -> [String] {
        var lines: [String] = []
        lines.append("background = \(GhosttyHex.normalize(colors.background))")
        lines.append("foreground = \(GhosttyHex.normalize(colors.foreground))")
        lines.append("cursor-color = \(GhosttyHex.normalize(colors.cursor))")
        if let cursorText = colors.cursorText {
            lines.append("cursor-text = \(GhosttyHex.normalize(cursorText))")
        }
        lines.append("selection-background = \(GhosttyHex.normalize(colors.selection))")
        if let selectionText = colors.selectionText {
            lines.append("selection-foreground = \(GhosttyHex.normalize(selectionText))")
        }
        for (i, hex) in colors.ansi.enumerated() {
            lines.append("palette = \(i)=\(GhosttyHex.normalize(hex))")
        }
        lines.append("cursor-style = \(cursorStyle)")
        return lines
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/GhosttyTerminalConfigTests
```
Expected: 全部 PASS。

- [ ] **Step 5: 接入 TreemuxGhosttyRuntime —— 注入颜色**

在 `TreemuxGhosttyRuntime.swift` 中改 `writeTemporaryGhosttyConfig`,让它带上当前主题终端色。

5a. 新增一个解析当前主题终端色的辅助(放在 `TreemuxGhosttyRuntime` 类内,`writeTemporaryGhosttyConfig` 上方):
```swift
    /// Resolves the active theme's terminal colors from disk + persisted id.
    /// Falls back to the built-in dark theme if nothing valid is found.
    private func resolveActiveTerminalColors() -> ThemeTerminalColors {
        let themesDir = treemuxStateDirectoryURL()
            .appendingPathComponent("themes", isDirectory: true)
        try? BuiltInThemes.ensureInstalled(in: themesDir)
        let activeID = AppSettingsPersistence().load().activeThemeID
        let themes = ThemeLoader.load(from: themesDir).themes
        if let match = themes.first(where: { $0.id == activeID }) { return match.terminal }
        if let dark = themes.first(where: { $0.id == "treemux-dark" }) { return dark.terminal }
        return BuiltInThemes.fallbackDark().terminal
    }
```

5b. 替换 `writeTemporaryGhosttyConfig(for:)` 的 `lines` 构造,改为合并终端色 + cursorStyle。把:
```swift
        let lines = [
            "cursor-style = \(terminal.cursorStyle)"
        ]
```
替换为:
```swift
        let colors = resolveActiveTerminalColors()
        let lines = GhosttyTerminalConfig.lines(for: colors, cursorStyle: terminal.cursorStyle)
```

- [ ] **Step 6: 接入 —— 监听 `.themeDidChange` 热重载**

6a. 在 `installObservers()` 末尾追加一个观察者:
```swift
        center.addObserver(
            self,
            selector: #selector(themeDidChange(_:)),
            name: .themeDidChange,
            object: nil
        )
```

6b. 在 `terminalSettingsDidChange(_:)` 方法旁新增:
```swift
    @objc private func themeDidChange(_ notification: Notification) {
        // Reuse the existing reload path with the current terminal settings;
        // the new theme colors are picked up via resolveActiveTerminalColors().
        let terminal = AppSettingsPersistence().load().terminal
        reloadGhosttyConfig(with: terminal)
    }
```

> 说明:`reloadGhosttyConfig(with:)` 内部调用 `writeTemporaryGhosttyConfig(for:)`,后者现在会带上最新主题色;`ghostty_app_update_config` 是 app 级热重载,所有已开 surface 同步变色。

- [ ] **Step 7: 重新生成工程并构建(含全量测试回归)**

Run:
```bash
xcodegen generate
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests
```
Expected: 编译成功;全测试 PASS。

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat: drive Ghostty terminal colors from active theme + live reload on theme change"
```

---

## Task 7: 设置页主题管理 UI

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`(`ThemeSettingsView`)
- Modify: `Treemux/Localizable.xcstrings`
- Test: 逻辑已由 Task 5 覆盖;UI 走人工验证。

**Interfaces:**
- Consumes: `ThemeManager.availableThemes/activeTheme/loadErrors/setActiveTheme/importTheme/deleteTheme/resetBuiltIns`、`BuiltInThemes.ids`、`AppSettings.activeThemeID`。

- [ ] **Step 1: 重写 ThemeSettingsView**

把 `SettingsSheet.swift` 中 `private struct ThemeSettingsView` 整体替换为:
```swift
private struct ThemeSettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var themeManager: ThemeManager

    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                ForEach(themeManager.availableThemes) { theme in
                    HStack {
                        Image(systemName: settings.activeThemeID == theme.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.activeThemeID == theme.id
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                            if let author = theme.author {
                                Text(author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !BuiltInThemes.ids.contains(theme.id) {
                            Button(role: .destructive) {
                                try? themeManager.deleteTheme(theme.id)
                                settings.activeThemeID = themeManager.activeTheme.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete theme")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.activeThemeID = theme.id
                        themeManager.setActiveTheme(theme.id)
                    }
                }
            } header: {
                Text("Themes")
            }

            Section {
                Button("Import Theme…") { importTheme() }
                Button("Restore Built-in Themes") {
                    themeManager.resetBuiltIns()
                    settings.activeThemeID = themeManager.activeTheme.id
                }
                Text("Theme files are stored as YAML in ~/.treemux/themes/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !themeManager.loadErrors.isEmpty {
                Section {
                    ForEach(themeManager.loadErrors, id: \.fileName) { err in
                        Label("\(err.fileName): \(err.message)",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                } header: {
                    Text("Theme Load Errors")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try themeManager.importTheme(from: url)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}
```
> `.yaml` UTType:在 `SettingsSheet.swift` 顶部确保 `import UniformTypeIdentifiers`。`UTType.yaml` 在 macOS 15 可用。

- [ ] **Step 2: 移除旧的「revert theme preview」对 JSON 的隐含依赖检查**

确认 `SettingsSheet.swift` 中(约第 106 行)的 revert 逻辑仍成立(`setActiveTheme(originalSettings.activeThemeID)`)——无需改动,新 `setActiveTheme` 兼容。仅复核,不改代码。

- [ ] **Step 3: 补 i18n 翻译**

在 `Treemux/Localizable.xcstrings` 为以下新键添加 `zh-Hans`:
- `"Themes"` → `"主题"`
- `"Import Theme…"` → `"导入主题…"`
- `"Restore Built-in Themes"` → `"恢复内置主题"`
- `"Theme files are stored as YAML in ~/.treemux/themes/"` → `"主题文件以 YAML 形式存放在 ~/.treemux/themes/"`
- `"Theme Load Errors"` → `"主题加载错误"`
- `"Delete theme"` → `"删除主题"`

> 用 Xcode 打开 `Localizable.xcstrings` 添加,或按现有 JSON 结构手工追加条目(参考文件中已有键的格式)。

- [ ] **Step 4: 重新生成工程并构建**

Run:
```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation
```
Expected: 编译成功。

- [ ] **Step 5: 人工验证(卡皮巴拉运行)**

编译后运行(DerivedData 编号以实际为准,先列出):
```bash
ls ~/Library/Developer/Xcode/DerivedData/ | grep -i Treemux
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app
```
验证清单:
- 设置 → Theme:看到 Dark/Light 两套;点选即时切换;**终端颜色同步变化**。
- Import Theme…:选一个自定义 `.yaml` → 出现在列表;非法 YAML → 红色错误提示。
- 删除自定义主题:trash 按钮可删;内置无 trash 按钮。
- Restore Built-in Themes:删掉内置文件后点恢复 → 重新出现。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: theme management UI (list/import/delete/restore/errors) + zh-Hans"
```

---

## Task 8: CLAUDE.md 记录 UI 设计规范

**Files:**
- Modify: `.claude/CLAUDE.md`

**Interfaces:** 无代码;纯文档。

- [ ] **Step 1: 在 CLAUDE.md 追加「UI 设计规范」小节**

在 `.claude/CLAUDE.md` 的「多语言 (i18n) 规则」小节之后插入:
```markdown
## UI 设计规范

- 今后所有 UI 设计 / 重构以 `.claude/DESIGN.md`(Apple 风格设计语言)为唯一依据。
- 核心原则:单一强调色(accent)承载所有交互;SF Pro 紧排标题(显示级负字距);两种按钮语法(pill 主操作 / sm 工具操作);发丝线(hairline)取代重分隔;阴影只留给"产品图",chrome 不用;间距与圆角走固定 token;浅/深表面节奏。
- 颜色由主题 YAML 驱动(`~/.treemux/themes/*.yaml`,见 `Theme`/`ThemeLoader`/`ThemeManager`);字体、间距、圆角等非颜色 token 固化在代码(后续 `DesignSystem`),不随主题变。
- 主题同时驱动 App UI 与 Ghostty 终端配色;新增可见颜色一律走主题 token,禁止硬编码。
```

- [ ] **Step 2: 提交**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: record DESIGN.md as the UI design source of truth in CLAUDE.md"
```

---

## Self-Review

**Spec coverage(对照 spec 各节):**
- §1 YAML Schema → Task 2(模型)+ Task 4(内置文件按 schema 书写)。✔
- §2 架构与组件:Yams(T1)、ThemeLoader(T3)、ThemeManager(T5)、Ghostty 接通(T6)、管理操作 import/delete/reset(T5+T7)、持久化 activeThemeID(沿用 `AppSettings`,T5/T7 写回 `settings.activeThemeID`)、首启写盘(T4/T5 `ensureInstalled`)、`.themeDidChange`(T5)。✔
- §3 两套默认主题(dark/light 精确配色)→ Task 4 字符串常量。✔
- §4 UI 重构 → **不在本计划**(计划二);本计划仅保证 ThemeManager 访问器稳定,UI 层不动。已在 Global Constraints 标注。✔(有意延后)
- §5 CLAUDE.md(T8)、迁移/移除 JSON(T5 删除 ThemeDefinition、T7 文案改 YAML)、错误处理(T3 收集 + T5 fallback + T7 展示)、测试(各 Task)、i18n(T7)、Worktree(已在 worktree)。✔
- §6 分阶段:P1=T1–T4+T8、P2=T5–T6、P3=T7。✔

**Placeholder scan:** 无 TBD/TODO;每个改代码的 step 都给了完整代码或精确替换点。✔

**Type consistency:** `Theme`/`ThemeUIColors`/`ThemeTerminalColors`/`ThemeValidationError`/`HexColor`(T2)在 T3/T4/T5/T6 一致使用;`ThemeLoadResult`/`ThemeLoadError`(T3)在 T5/T6 一致;`GhosttyHex`/`GhosttyTerminalConfig`(T6)签名一致;`BuiltInThemes.ids/ensureInstalled/restore/fallbackDark`(T4)在 T5/T6/T7 一致;`ThemeManager` 访问器名与现有视图一致(`successColor` 等沿用旧名)。✔

**已知风险/留意点(实现者注意):**
- `UTType.yaml` 若在目标 SDK 不可用,改用 `UTType(filenameExtension: "yaml")!`。
- `deleteTheme` 通过逐文件读取 id 匹配删除(因文件名不保证等于 id),已在 T5 实现中处理。
