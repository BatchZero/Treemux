# UI 主题统一(Phase B)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 DESIGN.md 的非颜色视觉语言 —— 字体/间距/圆角 token、pill/utility 按钮、hairline、扁平化(去 chrome 阴影)、单一 accent、工具栏/对话框重塑,清理 `.white.opacity`/系统色遗留。

**Architecture:** 先建设计系统基座(B1:`Spacing`/`Radius`/`DesignFonts` chrome 角色/`ButtonStyles`/`Hairline`/`ThemeManager.onAccentColor`),再逐表面套用(B2)。颜色仍由 YAML 主题驱动(Phase A 已定),Phase B 只改「形」不改「色映射」。

**Tech Stack:** Swift / SwiftUI / AppKit、XcodeGen(`project.yml`)、XCTest。

## Global Constraints

- 部署目标 macOS 15.0;Swift 5;`project.yml` 由 XcodeGen 生成,**新增/删除源文件后必须 `xcodegen generate` 并提交重生成的 `Treemux.xcodeproj`**。
- 非交互 `xcodebuild` 必须加 `-skipPackagePluginValidation`。
- 规范命令(`<Class>` 替换为具体测试类):
  ```bash
  cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+ui-theme-unification-phase-b
  xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>
  ```
  全量回归:`-only-testing:TreemuxTests`。构建:`xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation`。
- **只动「形」,不动「色映射」。** 颜色仍来自 `ThemeManager` 派生访问器;不改 Phase A 的颜色映射。
- **字体哲学:** 数据层(文件名/tab/树行/终端)保持等宽(`DesignFonts.dataLayer`);chrome(对话框/设置/工具栏/按钮)用 SF Pro(`DesignFonts.chrome` 及新增角色)。DESIGN.md SF Pro 紧排负字距只用于 chrome 标题。
- **token 原值(DESIGN.md):** Spacing `4/8/12/17/24/32/48/80`;Radius `xs5/sm8/md11/lg18/pill9999`。
- **按钮:** pill 仅对话框主 CTA;utility 用于工具栏/次要/Cancel。
- **`SwiftUI.Color` 相等性:** 同一 hex 经 `Color(hex:)` 构造的两个 Color 视为相等(沿用 Phase A 约定)。`Font` 经 `.system(size:weight:design:)` 同参构造视为相等。
- 提交信息用英文;已在 worktree `.worktrees/feat+ui-theme-unification-phase-b/` 内工作,主目录留在 `main`。
- 新增可见静态字符串须 `LocalizedStringKey` + `Treemux/Localizable.xcstrings` 补 `zh-Hans`(本阶段预期极少)。

---

## File Structure

**新建:**
- `Treemux/UI/Theme/DesignSystem.swift` — `enum Spacing` + `enum Radius`。
- `Treemux/UI/Components/ButtonStyles.swift` — `PillButtonStyle` + `UtilityButtonStyle`。
- `Treemux/UI/Components/Hairline.swift` — `.hairline(_:)` ViewModifier。
- 测试:`TreemuxTests/DesignSystemTests.swift`、`TreemuxTests/DesignFontsTests.swift`、`TreemuxTests/ButtonStylesTests.swift`、`TreemuxTests/ThemeManagerOnAccentTests.swift`。

**修改:**
- `Treemux/UI/Theme/DesignFonts.swift` — 新增 chrome 语义角色 + eyebrow。
- `Treemux/UI/Theme/ThemeManager.swift` — 新增 `onAccentColor`。
- `Treemux/UI/Components/PhosphorUnderline.swift` → 改名 `TabAccentIndicator.swift`(去 shadow,扁平)。
- `Treemux/UI/Workspace/WorkspaceTabBarView.swift` — 单一 accent、token 化、改名调用点。
- `Treemux/UI/FileBrowser/FileSubTabBarView.swift` — 去 `.white.opacity`、主题化、用共享指示条。
- `Treemux/UI/MainWindowView.swift` — 工具栏项目名 + utility 按钮。
- `Treemux/UI/Workspace/SplitDivider.swift`、`Treemux/UI/Sidebar/SidebarItemIconView.swift`、`Treemux/UI/FileBrowser/FileViewerPanelView.swift`、`Treemux/UI/FileBrowser/ImagePreviewView.swift` — 系统色 → 主题。
- `Treemux/UI/Sidebar/SidebarNodeRow.swift`(及关联行视图) — 字体 token + 行距/hairline。
- 对话框 ×7:`OpenProjectSheet.swift`、`SSHServerEditSheet.swift`、`SettingsSheet.swift`、`SSHRawConfigSheet.swift`、`RemoteDirectoryBrowser.swift`、`SidebarIconCustomizationSheet.swift`、`BatchUnsavedChangesSheet.swift`。

---

## Task 1: Spacing / Radius token(DesignSystem.swift)

**Files:**
- Create: `Treemux/UI/Theme/DesignSystem.swift`
- Test: `TreemuxTests/DesignSystemTests.swift`

**Interfaces:**
- Produces: `enum Spacing { static let xxs/xs/sm/md/lg/xl/xxl/section: CGFloat }`、`enum Radius { static let xs/sm/md/lg/pill: CGFloat }`。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/DesignSystemTests.swift`:
```swift
//
//  DesignSystemTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class DesignSystemTests: XCTestCase {
    func testSpacingScaleMatchesDesignMd() {
        XCTAssertEqual(Spacing.xxs, 4)
        XCTAssertEqual(Spacing.xs, 8)
        XCTAssertEqual(Spacing.sm, 12)
        XCTAssertEqual(Spacing.md, 17)
        XCTAssertEqual(Spacing.lg, 24)
        XCTAssertEqual(Spacing.xl, 32)
        XCTAssertEqual(Spacing.xxl, 48)
        XCTAssertEqual(Spacing.section, 80)
    }

    func testRadiusScaleMatchesDesignMd() {
        XCTAssertEqual(Radius.xs, 5)
        XCTAssertEqual(Radius.sm, 8)
        XCTAssertEqual(Radius.md, 11)
        XCTAssertEqual(Radius.lg, 18)
        XCTAssertEqual(Radius.pill, 9999)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DesignSystemTests`
Expected: 编译失败(`Spacing`/`Radius` 未定义)。

- [ ] **Step 3: 实现**

新建 `Treemux/UI/Theme/DesignSystem.swift`:
```swift
//
//  DesignSystem.swift
//  Treemux
//
//  Fixed, theme-independent layout tokens from .claude/DESIGN.md.
//  Colors come from the YAML theme (ThemeManager); these do not.
//

import CoreGraphics

/// Spacing scale (DESIGN.md). Base unit 8; md=17 is the body line rhythm.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 17
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let section: CGFloat = 80
}

/// Corner-radius scale (DESIGN.md).
enum Radius {
    static let xs: CGFloat = 5
    static let sm: CGFloat = 8
    static let md: CGFloat = 11
    static let lg: CGFloat = 18
    static let pill: CGFloat = 9999
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DesignSystemTests`
Expected: 2 个测试 PASS。

- [ ] **Step 5: 重新生成工程并提交**

```bash
xcodegen generate
git add Treemux/UI/Theme/DesignSystem.swift TreemuxTests/DesignSystemTests.swift Treemux.xcodeproj
git commit -m "feat: DESIGN.md spacing/radius tokens (DesignSystem)"
```

---

## Task 2: DesignFonts chrome 语义角色

**Files:**
- Modify: `Treemux/UI/Theme/DesignFonts.swift`
- Test: `TreemuxTests/DesignFontsTests.swift`

**Interfaces:**
- Consumes: 现有 `DesignFonts.chrome(size:weight:)`、`DesignFonts.dataLayer(size:weight:)`。
- Produces: `DesignFonts.dialogTitle/sectionTitle/chromeBody/chromeStrong/chromeCaption/eyebrow: Font`、`DesignFonts.dialogTitleTracking: CGFloat`。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/DesignFontsTests.swift`:
```swift
//
//  DesignFontsTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class DesignFontsTests: XCTestCase {
    func testChromeRolesMapToSystemFont() {
        XCTAssertEqual(DesignFonts.dialogTitle, .system(size: 20, weight: .semibold))
        XCTAssertEqual(DesignFonts.sectionTitle, .system(size: 13, weight: .semibold))
        XCTAssertEqual(DesignFonts.chromeBody, .system(size: 13, weight: .regular))
        XCTAssertEqual(DesignFonts.chromeStrong, .system(size: 11, weight: .semibold))
        XCTAssertEqual(DesignFonts.chromeCaption, .system(size: 11, weight: .regular))
    }

    func testEyebrowIsMonospaced() {
        XCTAssertEqual(DesignFonts.eyebrow, .system(size: 9, weight: .semibold, design: .monospaced))
    }

    func testDialogTitleTracking() {
        XCTAssertEqual(DesignFonts.dialogTitleTracking, -0.4)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DesignFontsTests`
Expected: 编译失败(新角色未定义)。

- [ ] **Step 3: 实现**

在 `Treemux/UI/Theme/DesignFonts.swift` 末尾(`enum DesignFonts { ... }` 闭合之后)新增扩展:
```swift
extension DesignFonts {
    // MARK: - Chrome semantic roles (SF Pro, IDE-scaled)
    //
    // DESIGN.md's 56/40px marketing display sizes don't apply to IDE chrome.
    // Titles keep the SF Pro tight-tracking signature; body/caption land at
    // macOS-standard 13/11 so dialogs read as native, not oversized.

    /// Dialog / toolbar title — the only place DESIGN.md tight tracking applies.
    /// SwiftUI Font has no letterSpacing; apply `.tracking(dialogTitleTracking)`
    /// on the title Text.
    static let dialogTitle: Font = chrome(size: 20, weight: .semibold)
    static let dialogTitleTracking: CGFloat = -0.4

    /// Section / group heading inside dialogs and the sidebar.
    static let sectionTitle: Font = chrome(size: 13, weight: .semibold)
    /// Default chrome body copy.
    static let chromeBody: Font = chrome(size: 13, weight: .regular)
    /// Emphasized small chrome label (file-name header, etc.).
    static let chromeStrong: Font = chrome(size: 11, weight: .semibold)
    /// Secondary chrome caption.
    static let chromeCaption: Font = chrome(size: 11, weight: .regular)

    // MARK: - Data layer semantic role (mono)

    /// Tab-group eyebrow ("Files"/"Shell") — small mono label.
    static let eyebrow: Font = dataLayer(size: 9, weight: .semibold)
}
```
> 顶部已 `import SwiftUI`。`chrome`/`dataLayer` 现有函数返回 `.system(size:weight:design:)`,故上面相等断言成立。

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test ... -only-testing:TreemuxTests/DesignFontsTests`
Expected: 3 个测试 PASS。

- [ ] **Step 5: 重新生成工程并提交**

```bash
xcodegen generate
git add Treemux/UI/Theme/DesignFonts.swift TreemuxTests/DesignFontsTests.swift Treemux.xcodeproj
git commit -m "feat: DesignFonts chrome semantic roles (SF Pro, IDE-scaled) + eyebrow"
```

---

## Task 3: ThemeManager.onAccentColor

**Files:**
- Modify: `Treemux/UI/Theme/ThemeManager.swift`
- Test: `TreemuxTests/ThemeManagerOnAccentTests.swift`

**Interfaces:**
- Consumes: `activeTheme.ui.onAccent: String`、`Color(hex:)`。
- Produces: `ThemeManager.onAccentColor: Color`。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/ThemeManagerOnAccentTests.swift`:
```swift
//
//  ThemeManagerOnAccentTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ThemeManagerOnAccentTests: XCTestCase {
    @MainActor
    func testOnAccentColorMatchesThemeUI() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.onAccentColor, Color(hex: manager.activeTheme.ui.onAccent))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ThemeManagerOnAccentTests`
Expected: 编译失败(`onAccentColor` 未定义)。

- [ ] **Step 3: 实现**

在 `Treemux/UI/Theme/ThemeManager.swift` 的 `// MARK: - Resolved SwiftUI Colors` 区块内,`accentColor` 之后新增:
```swift
    var onAccentColor: Color { Color(hex: activeTheme.ui.onAccent) }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ThemeManagerOnAccentTests`
Expected: PASS。

- [ ] **Step 5: 重新生成工程并提交**

```bash
xcodegen generate
git add Treemux/UI/Theme/ThemeManager.swift TreemuxTests/ThemeManagerOnAccentTests.swift Treemux.xcodeproj
git commit -m "feat: ThemeManager.onAccentColor (accent text color)"
```

---

## Task 4: ButtonStyles(Pill / Utility)

**Files:**
- Create: `Treemux/UI/Components/ButtonStyles.swift`
- Test: `TreemuxTests/ButtonStylesTests.swift`

**Interfaces:**
- Consumes: `Spacing`/`Radius`(Task 1)、`ThemeManager.accentColor/onAccentColor/dividerColor/textSecondary`(调用点注入)。
- Produces:
  - `struct PillButtonStyle: ButtonStyle { let accent: Color; let onAccent: Color }`
  - `struct UtilityButtonStyle: ButtonStyle { let tint: Color; let activeTint: Color; let border: Color; var isActive: Bool = false }`

> `ButtonStyle` 内不能用 `@EnvironmentObject`,故颜色在调用点显式注入(`theme.*`),保证主题切换实时生效。

- [ ] **Step 1: 写失败测试**

新建 `TreemuxTests/ButtonStylesTests.swift`:
```swift
//
//  ButtonStylesTests.swift
//  TreemuxTests
//

import SwiftUI
import XCTest
@testable import Treemux

final class ButtonStylesTests: XCTestCase {
    func testPillStoresColors() {
        let style = PillButtonStyle(accent: Color(hex: "#0066CC"), onAccent: Color(hex: "#FFFFFF"))
        XCTAssertEqual(style.accent, Color(hex: "#0066CC"))
        XCTAssertEqual(style.onAccent, Color(hex: "#FFFFFF"))
    }

    func testUtilityStoresColorsAndActiveDefaultsFalse() {
        let style = UtilityButtonStyle(
            tint: Color(hex: "#C5C8C6"),
            activeTint: Color(hex: "#0066CC"),
            border: Color(hex: "#FFFFFF1A"))
        XCTAssertEqual(style.tint, Color(hex: "#C5C8C6"))
        XCTAssertEqual(style.activeTint, Color(hex: "#0066CC"))
        XCTAssertFalse(style.isActive)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ButtonStylesTests`
Expected: 编译失败(样式未定义)。

- [ ] **Step 3: 实现**

新建 `Treemux/UI/Components/ButtonStyles.swift`:
```swift
//
//  ButtonStyles.swift
//  Treemux
//
//  The two DESIGN.md button grammars. Colors are injected at the call site
//  (from ThemeManager) because ButtonStyle can't read @EnvironmentObject.
//

import SwiftUI

/// Primary call-to-action: full-pill accent fill, press shrinks to 0.95.
/// Use ONLY for the single primary action in a dialog (Save/Open/Connect).
struct PillButtonStyle: ButtonStyle {
    let accent: Color
    let onAccent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(onAccent)
            .padding(.vertical, 11)
            .padding(.horizontal, 22)
            .background(accent, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Compact utility action: Radius.sm, transparent fill, hairline border.
/// `isActive` (or press) lifts the tint to `activeTint` (accent).
/// Use for toolbar buttons, secondary actions, and Cancel.
struct UtilityButtonStyle: ButtonStyle {
    let tint: Color
    let activeTint: Color
    let border: Color
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(isActive || configuration.isPressed ? activeTint : tint)
            .padding(.vertical, 8)
            .padding(.horizontal, 15)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test ... -only-testing:TreemuxTests/ButtonStylesTests`
Expected: PASS。

- [ ] **Step 5: 重新生成工程并提交**

```bash
xcodegen generate
git add Treemux/UI/Components/ButtonStyles.swift TreemuxTests/ButtonStylesTests.swift Treemux.xcodeproj
git commit -m "feat: PillButtonStyle + UtilityButtonStyle (DESIGN.md button grammars)"
```

---

## Task 5: Hairline 修饰符

**Files:**
- Create: `Treemux/UI/Components/Hairline.swift`

**Interfaces:**
- Consumes: `ThemeManager.dividerColor`(`@EnvironmentObject`)。
- Produces: `View.hairline(_ edge: Edge) -> some View`。

> 本任务无独立单测(纯视图修饰,渲染层人工验证);它的正确性在后续表面任务编译 + 人工验证时一并覆盖。

- [ ] **Step 1: 实现**

新建 `Treemux/UI/Components/Hairline.swift`:
```swift
//
//  Hairline.swift
//  Treemux
//
//  1px theme-driven hairline replacing heavy Divider()/Rectangle separators.
//  DESIGN.md: hairlines replace heavy dividers; color from theme.dividerColor.
//

import SwiftUI

private struct HairlineModifier: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let edge: Edge

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            Rectangle()
                .fill(theme.dividerColor)
                .frame(
                    width: edge == .leading || edge == .trailing ? 1 : nil,
                    height: edge == .top || edge == .bottom ? 1 : nil
                )
        }
    }

    private var alignment: Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

extension View {
    /// Overlays a 1px theme hairline on the given edge.
    func hairline(_ edge: Edge) -> some View {
        modifier(HairlineModifier(edge: edge))
    }
}
```

- [ ] **Step 2: 构建确认编译**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 提交**

```bash
git add Treemux/UI/Components/Hairline.swift Treemux.xcodeproj
git commit -m "feat: theme-driven .hairline(_:) view modifier"
```

---

## Task 6: PhosphorUnderline → TabAccentIndicator(去阴影 + 扁平)

**Files:**
- Rename + Modify: `Treemux/UI/Components/PhosphorUnderline.swift` → `Treemux/UI/Components/TabAccentIndicator.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`(调用点)

**Interfaces:**
- Produces: `struct TabAccentIndicator: ViewModifier`、`View.tabAccentIndicator(_ color: Color, active: Bool, inset: CGFloat = 8) -> some View`。
- 移除:`PhosphorUnderline`、`View.phosphorUnderline(...)`。

- [ ] **Step 1: git mv 重命名文件**

```bash
git mv Treemux/UI/Components/PhosphorUnderline.swift Treemux/UI/Components/TabAccentIndicator.swift
```

- [ ] **Step 2: 重写文件内容(去 shadow,扁平 2px accent 条)**

整体替换 `Treemux/UI/Components/TabAccentIndicator.swift`:
```swift
//
//  TabAccentIndicator.swift
//  Treemux
//
//  Flat 2px accent bar marking the selected tab. DESIGN.md: chrome carries no
//  shadow; the active-tab indicator is a solid accent bar. Color is supplied by
//  the caller (theme.accentColor); inactive tabs draw nothing.
//

import SwiftUI

struct TabAccentIndicator: ViewModifier {
    let color: Color
    let isActive: Bool
    var inset: CGFloat = Spacing.xs

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, inset)
            }
        }
    }
}

extension View {
    /// Applies the flat tab accent indicator when `active` is true.
    func tabAccentIndicator(_ color: Color, active: Bool, inset: CGFloat = Spacing.xs) -> some View {
        modifier(TabAccentIndicator(color: color, isActive: active, inset: inset))
    }
}

#Preview {
    HStack(spacing: 6) {
        Text("README.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: true)
        Text("zsh")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: true)
        Text("other.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: false)
    }
    .padding(24)
    .background(Color(hex: "#191D26"))
}
```
> 注:预览三条都用蓝(单一 accent),不再蓝/绿分色。

- [ ] **Step 3: 更新 WorkspaceTabBarView 调用点**

在 `Treemux/UI/Workspace/WorkspaceTabBarView.swift` 第 195 行,把
```swift
            .phosphorUnderline(tab.kind == .fileBrowser ? theme.accentColor : theme.shellAccent, active: isSelected)
```
改为(收敛为单一 accent):
```swift
            .tabAccentIndicator(theme.accentColor, active: isSelected)
```

- [ ] **Step 4: 构建确认编译**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED(`phosphorUnderline` 已无残留引用 —— FileSubTabBarView 用的是自有 overlay,Task 8 处理)。

- [ ] **Step 5: 确认无残留引用**

```bash
grep -rn "phosphorUnderline\|PhosphorUnderline" --include="*.swift" Treemux TreemuxTests
```
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "refactor: PhosphorUnderline -> flat TabAccentIndicator (no chrome shadow)"
```

---

## Task 7: WorkspaceTabBarView 单一 accent + token 化

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Interfaces:**
- Consumes: `theme.accentColor/dividerColor`(已注入)、`Spacing`、`DesignFonts.eyebrow`。Task 6 已改 underline 调用点。

- [ ] **Step 1: Files/Shell eyebrow 收敛为单一 accent**

在 body 内,把第 36 行
```swift
                        TabGroupEyebrow(title: "Shell", color: theme.shellAccent)
```
改为
```swift
                        TabGroupEyebrow(title: "Shell", color: theme.accentColor)
```
> 第 26 行 Files 已是 `theme.accentColor`,保持不变。区分靠 eyebrow 文字 + 组间分隔条。

- [ ] **Step 2: eyebrow 字体走 token**

把 `TabGroupEyebrow` 内(第 232 行)
```swift
            .font(DesignFonts.dataLayer(size: 9, weight: .semibold))
```
改为
```swift
            .font(DesignFonts.eyebrow)
```

- [ ] **Step 3: 组间分隔条 + 底边线用 token 间距**

把第 33 行 `.padding(.horizontal, 5)` 改为 `.padding(.horizontal, Spacing.xxs)`;把第 40 行 `.padding(.horizontal, 8)` 改为 `.padding(.horizontal, Spacing.xs)`;把第 55 行 `.padding(.trailing, 8)` 改为 `.padding(.trailing, Spacing.xs)`。
> 两处 `Rectangle().fill(theme.dividerColor)`(组间 18 高、底边 1 高)颜色已是主题色,保留。

- [ ] **Step 4: 构建确认编译**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor: workspace tab bar single accent + spacing tokens"
```

---

## Task 8: FileSubTabBarView 去 .white.opacity + 主题化

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileSubTabBarView.swift`

**Interfaces:**
- Consumes: `ThemeManager`(`sidebarSelection/textPrimary/accentColor/tabBarBackground`)、`Spacing`/`Radius`、`View.tabAccentIndicator`(Task 6)。
- `SubTabButton` 当前无 theme,需加 `@EnvironmentObject`(环境已由 `MainWindowView` 注入)。

- [ ] **Step 1: 给两个结构体注入 theme**

在 `struct FileSubTabBarView` 的 `@ObservedObject var controller` 上方新增:
```swift
    @EnvironmentObject private var theme: ThemeManager
```
在 `private struct SubTabButton` 的 `let tab: SubTabRuntime` 上方新增:
```swift
    @EnvironmentObject private var theme: ThemeManager
```

- [ ] **Step 2: 背景材质 → 主题色 + token 间距**

把第 47 行 `.padding(.horizontal, 6)` 改为 `.padding(.horizontal, Spacing.xs)`;把第 50 行
```swift
        .background(.thickMaterial)
```
改为
```swift
        .background(theme.tabBarBackground)
```

- [ ] **Step 3: 去 .white.opacity,改主题 token**

把 `SubTabButton.body` 内第 141–147 行:
```swift
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(.white.opacity(0.12))
                : isHovered ? AnyShapeStyle(.white.opacity(0.06))
                : AnyShapeStyle(Color.clear)
            )
```
改为:
```swift
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(
                isActive ? AnyShapeStyle(theme.sidebarSelection)
                : isHovered ? AnyShapeStyle(theme.textPrimary.opacity(0.06))
                : AnyShapeStyle(Color.clear)
            )
```

- [ ] **Step 4: 指示条改用共享 TabAccentIndicator**

把第 148–156 行:
```swift
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
```
改为:
```swift
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
            .tabAccentIndicator(theme.accentColor, active: isActive, inset: Spacing.xxs)
```

- [ ] **Step 5: dirty 标记 accent 主题化**

把第 126 行 `.fill(Color.accentColor)` 改为 `.fill(theme.accentColor)`。

- [ ] **Step 6: 构建 + 确认无 .white.opacity 残留**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
grep -n "\.white\.opacity\|Color\.accentColor\|thickMaterial" Treemux/UI/FileBrowser/FileSubTabBarView.swift
```
Expected: BUILD SUCCEEDED;grep 无输出。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor: theme-driven file sub-tab bar (drop .white.opacity, shared accent indicator)"
```

---

## Task 9: 工具栏重塑(项目名 + utility 按钮)

**Files:**
- Modify: `Treemux/UI/MainWindowView.swift`

**Interfaces:**
- Consumes: `ThemeManager`(`textSecondary/accentColor/dividerColor`)、`UtilityButtonStyle`(Task 4)、`DesignFonts.dialogTitle/dialogTitleTracking`、`WorkspaceStore.selectedWorkspace`。
- `MainWindowView` 当前无 `theme`,需加 `@EnvironmentObject`。

> **取标题来源**:`store.selectedWorkspace` 暴露项目/连接名的属性。实现前先确认属性名:
> ```bash
> grep -n "var name\|var title\|var displayName\|var projectName\|worktreePath" Treemux/**/WorkspaceModel*.swift Treemux/**/WorkspaceStore*.swift
> ```
> 用其返回的项目显示名(下方以 `store.selectedWorkspace?.name` 占位,按实际属性名替换;若无现成显示名,用 `URL(fileURLWithPath: store.selectedWorkspace?.worktreePath ?? "").lastPathComponent`)。该值是动态数据,非可本地化字符串。

- [ ] **Step 1: 注入 theme**

在 `struct MainWindowView` 的 `@EnvironmentObject private var store` 上方新增:
```swift
    @EnvironmentObject private var theme: ThemeManager
```

- [ ] **Step 2: 工具栏加项目名(principal placement)**

在 `.toolbar { ... }` 内,`ToolbarItem(placement: .navigation)` 之后新增:
```swift
            ToolbarItem(placement: .principal) {
                if let name = store.selectedWorkspace?.name {   // 按实际属性名替换
                    Text(name)
                        .font(DesignFonts.dialogTitle)
                        .tracking(DesignFonts.dialogTitleTracking)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
```

- [ ] **Step 3: 4 个图标按钮 utility 化**

把 `ToolbarItemGroup(placement: .primaryAction)` 内 4 个 `Button { ... } label: { Image(systemName: ...) }` 各自追加 `.buttonStyle(...)`。统一用 utility 语法(平时 `textSecondary`,按下/激活上 accent;设置按钮在 `store.showSettings` 时 active):
- Split Down / Split Right / New Terminal 三个按钮各加:
  ```swift
                .buttonStyle(UtilityButtonStyle(
                    tint: theme.textSecondary,
                    activeTint: theme.accentColor,
                    border: .clear))
  ```
- Settings 按钮加(激活态绑定 sheet 显隐):
  ```swift
                .buttonStyle(UtilityButtonStyle(
                    tint: theme.textSecondary,
                    activeTint: theme.accentColor,
                    border: .clear,
                    isActive: store.showSettings))
  ```
> `border: .clear` 让工具栏按钮无边、退隐;只有图标着色变化。`.help(...)` 保留。

- [ ] **Step 4: 构建确认编译**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。若 `store.selectedWorkspace?.name` 报错,按 Step 0 的 grep 结果改成实际属性。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "refactor: toolbar project title + utility-styled actions"
```

---

## Task 10: 系统色 → 主题 token 清理

**Files:**
- Modify: `Treemux/UI/Workspace/SplitDivider.swift`
- Modify: `Treemux/UI/Sidebar/SidebarItemIconView.swift`
- Modify: `Treemux/UI/FileBrowser/FileViewerPanelView.swift`
- Modify: `Treemux/UI/FileBrowser/ImagePreviewView.swift`

**Interfaces:**
- Consumes: `ThemeManager`(`dividerColor/sidebarBackground/paneBackground`)。各结构体如无 `theme` 需加 `@EnvironmentObject`(环境已注入)。

- [ ] **Step 1: SplitDivider 用主题 dividerColor**

`SplitDivider` 加 `@EnvironmentObject private var theme: ThemeManager`(在 `let axis` 上方)。把第 28 行 `.fill(Color(nsColor: .separatorColor).opacity(0.4))` 改为 `.fill(theme.dividerColor.opacity(0.4))`;把第 36 行 `.fill(Color(nsColor: .separatorColor))` 改为 `.fill(theme.dividerColor)`。

- [ ] **Step 2: 其余三处系统色 → 主题表面色**

先读各文件确认上下文,再按映射替换:
```bash
grep -n "windowBackgroundColor" Treemux/UI/Sidebar/SidebarItemIconView.swift
grep -n "textBackgroundColor" Treemux/UI/FileBrowser/FileViewerPanelView.swift
grep -n "black.opacity" Treemux/UI/FileBrowser/ImagePreviewView.swift
```
- `SidebarItemIconView`:`Color(nsColor: .windowBackgroundColor)` → `theme.sidebarBackground`(需加 `@EnvironmentObject theme`)。
- `FileViewerPanelView`:`Color(nsColor: .textBackgroundColor)` → `theme.paneBackground`(需加 `@EnvironmentObject theme`)。
- `ImagePreviewView`:`Color.black.opacity(0.05)` → `theme.paneBackground`(需加 `@EnvironmentObject theme`)。

> 若某文件是非视图类型(无法用 `@EnvironmentObject`),则该文件改由调用方传入颜色;实现时读文件确认。预期三者均为 SwiftUI `View`。

- [ ] **Step 3: 构建 + 确认无残留系统色**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
grep -rn "separatorColor\|windowBackgroundColor\|textBackgroundColor" --include="*.swift" Treemux/UI/Workspace/SplitDivider.swift Treemux/UI/Sidebar/SidebarItemIconView.swift Treemux/UI/FileBrowser/FileViewerPanelView.swift
```
Expected: BUILD SUCCEEDED;grep 无输出。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor: replace AppKit system colors with theme tokens (divider/surfaces)"
```

---

## Task 11: AppKit 侧边栏字体 token + 行距/hairline

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarNodeRow.swift`(及行内引用的关联行视图)

**Interfaces:**
- Consumes: `DesignFonts`(`chromeBody/chromeStrong/chromeCaption/sectionTitle`)、`Spacing`、`ThemeManager.dividerColor`。

> 本任务前**先读** `Treemux/UI/Sidebar/SidebarNodeRow.swift` 全文(及 `SidebarCellView.swift`/`SidebarInfoBadge.swift` 若被引用),定位全部硬编码 `.system(size:)`、`.padding`、分组分隔线。AppKit `NSView` 子类用 `NSFont`,SwiftUI 行用 `Font`;按下方规则迁移。

- [ ] **Step 1: 硬编码字体 → token**

把 SidebarNodeRow 内的硬编码字体按语义替换:
- 主标题/项目名 `.system(size: 12/13, weight: .semibold)` → SwiftUI 行用 `DesignFonts.sectionTitle`;若是 `NSFont`,用 `NSFont.systemFont(ofSize: 13, weight: .semibold)`(与 token 同参,保持一致)。
- 普通行文字 `.system(size: 12)` → `DesignFonts.chromeBody`(SwiftUI)或 `NSFont.systemFont(ofSize: 13)`。
- 次要/徽标小字 `.system(size: 10/9/11)` → `DesignFonts.chromeCaption`(SwiftUI)或 `NSFont.systemFont(ofSize: 11)`。
> 字号统一对齐到 token 的 13/11(原 12/10 微调到 13/11),实现「字体走 token」。

- [ ] **Step 2: 行距加大 + 分组 hairline 色**

把行内 `.padding(.vertical, N)` / 行高常量按 `Spacing` 调整(行垂直内边距用 `Spacing.xs`(8)取代原较小值,实现「行距加大」);分组分隔线颜色改为 `theme.dividerColor`(SwiftUI 行)或对应 `NSColor(theme.dividerColor)`(AppKit 行)。
> 具体常量以读到的现状为准,目标:行更松、分隔更轻。改动限于字体/间距/分隔色,不动行的数据/交互逻辑。

- [ ] **Step 3: 构建确认编译**

```bash
xcodegen generate
xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "refactor: sidebar row typography tokens + roomier spacing/hairline"
```

---

## Task 12: 对话框 ×7 重塑(pill / utility / hairline / token)

**Files:**
- Modify: `Treemux/UI/Sheets/OpenProjectSheet.swift`
- Modify: `Treemux/UI/Sheets/SSHServerEditSheet.swift`
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`
- Modify: `Treemux/UI/Sheets/SSHRawConfigSheet.swift`
- Modify: `Treemux/UI/Sheets/RemoteDirectoryBrowser.swift`
- Modify: `Treemux/UI/Sheets/SidebarIconCustomizationSheet.swift`
- Modify: `Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift`

**Interfaces:**
- Consumes: `PillButtonStyle`/`UtilityButtonStyle`(Task 4)、`View.hairline(_:)`(Task 5)、`Spacing`/`Radius`、`DesignFonts` chrome 角色、`ThemeManager`(`accentColor/onAccentColor/textSecondary/dividerColor`)。

**统一转换规则(对每个对话框逐一施用):**
1. 加 `@EnvironmentObject private var theme: ThemeManager`(若无)。
2. **主 CTA**(Save/Open/Connect/Confirm 等唯一主动作):`.buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))`,去掉原 `.borderedProminent`。
3. **次要 / Cancel / Reset**:`.buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))`。
4. **分隔**:`Divider()` → 容器上 `.hairline(.top/.bottom)`(按原 Divider 位置选边)。
5. **内边距**:外层 `.padding(20)` → `.padding(Spacing.lg)`(24);其余散落 `8/10/12/18` → 最近的 `Spacing` token。
6. **圆角**:卡片/输入容器 `cornerRadius: 10/8` → `Radius.md`(11)/`Radius.sm`(8);卡片容器用 `Radius.lg`(18)。
7. **字体**:对话框标题 `.font(.system(size: 20))` → `DesignFonts.dialogTitle` + `.tracking(DesignFonts.dialogTitleTracking)`;小节标题 → `DesignFonts.sectionTitle`;正文 → `DesignFonts.chromeBody`;说明小字 → `DesignFonts.chromeCaption`。
8. **遗留色**:`.white.opacity(...)` / `Color.white` / `Color(nsColor: ...)` → 主题 token(`SidebarIconCustomizationSheet` 的 `.white.opacity(0.9)`/`.white.opacity(0.035)` → `theme.dividerColor`/`theme.sidebarSelection.opacity(...)` 等就近主题色)。

> **不改**:每个对话框的字段、校验、交互逻辑、布局骨架(VStack/Grid/Form 结构保留),只换字体/间距/圆角/按钮/分隔/颜色语法。

- [ ] **Step 1: OpenProjectSheet**

读 `Treemux/UI/Sheets/OpenProjectSheet.swift` 全文,按统一规则施用:主 CTA "Open" 用 pill,Cancel/Choose… 用 utility,`.padding(20)`→`Spacing.lg`,folder 输入容器 `.quaternary` 背景保留但圆角对齐 `Radius.sm`,标题字体 token 化。构建:
```bash
xcodegen generate && xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 2: SSHServerEditSheet**

读全文,Grid 表单骨架保留;Save→pill,Cancel→utility;Grid `spacing: 12`→`Spacing.sm`;标题/字段标签字体 token 化。构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 3: SettingsSheet**

读全文,3 处 `Divider()`→`.hairline`(header 下/list 下/footer 上);footer 主按钮(Save/Done)→pill,其余→utility;sidebar List 行字体 token 化;header `.font(.system(size: 20))`→`dialogTitle`+tracking;`.padding` 对齐 token。**注意 Settings 含 Theme 管理页(Phase A/前期已有),只改字体/间距/按钮,不动主题列表逻辑。** 构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 4: SSHRawConfigSheet**

读全文,`.padding(20)`→`Spacing.lg`;TextEditor 边框 `.quaternary` 圆角对齐 `Radius.sm`;主按钮→pill,Cancel→utility;TextEditor 保持 `.monospaced`(数据层等宽,符合字体哲学)。构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 5: RemoteDirectoryBrowser**

读全文,4 处 `Divider()`→`.hairline`;Connect 主按钮→pill,Cancel→utility;path TextField `.roundedBorder` 保留;各段 padding 对齐 token。构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 6: SidebarIconCustomizationSheet**

读全文,卡片 `RoundedRectangle(cornerRadius: 10)`→`Radius.md`;`.white.opacity(0.035)` 卡片底→`theme.sidebarSelection.opacity(0.5)`(或就近主题表面色),`.white.opacity(0.9)` 选中边→`theme.accentColor`;Save→pill,Reset/Cancel→utility;字体 token 化。构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 7: BatchUnsavedChangesSheet**

读全文,确认 / Save All 主按钮→pill,Discard/Cancel→utility;`Divider()`→`.hairline`;padding/字体 token 化。构建同上 Expected BUILD SUCCEEDED。

- [ ] **Step 8: 确认对话框无遗留 .white.opacity / borderedProminent**

```bash
grep -rn "\.white\.opacity\|borderedProminent" --include="*.swift" \
  Treemux/UI/Sheets Treemux/UI/Settings Treemux/UI/FileBrowser/BatchUnsavedChangesSheet.swift
```
Expected: 无输出(或仅剩有意保留项,需在提交信息说明)。

- [ ] **Step 9: 提交**

```bash
git add -A
git commit -m "refactor: reshape 7 dialogs — pill/utility buttons, hairline, spacing/radius/font tokens"
```

---

## Task 13: 全量回归 + 阴影/字面量清扫 + 人工验证

**Files:** 无新增(清扫 + 验证)。

- [ ] **Step 1: 确认全 UI 无 chrome 阴影残留**

```bash
grep -rn "\.shadow(" --include="*.swift" Treemux/UI
```
Expected: 无输出(PhosphorUnderline 辉光已在 Task 6 移除;若有其他,逐一评估是否 chrome —— 产品图/内容阴影才允许,本 app 无)。

- [ ] **Step 2: 确认无散落 .white.opacity / 系统背景色残留(全 UI)**

```bash
grep -rn "\.white\.opacity\|\.black\.opacity\|separatorColor\|windowBackgroundColor\|textBackgroundColor" --include="*.swift" Treemux/UI
```
Expected: 仅剩 `CommandPaletteView` 的模态遮罩 `Color.black.opacity(0.35)`(有意保留)。其余应已清除。

- [ ] **Step 3: 全量测试**

```bash
xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:TreemuxTests
```
Expected: 全部 PASS(含 Phase A 既有 + 本阶段新增 DesignSystem/DesignFonts/ButtonStyles/ThemeManagerOnAccent)。

- [ ] **Step 4: 提交(若有清扫改动)**

```bash
git add -A
git commit -m "chore: Phase B sweep — confirm no chrome shadows / stray literal colors"
```

- [ ] **Step 5: 人工验证(卡皮巴拉运行)**

```bash
ls ~/Library/Developer/Xcode/DerivedData/ | grep -i Treemux
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app
```
验证清单(切换浅/深主题):
- 工具栏:左侧项目名(SF Pro 紧排),4 个按钮平时退隐(textSecondary)、悬停/激活上 accent,设置打开时高亮。
- Workspace tab 栏:Files/Shell 指示条均单一 accent,靠 eyebrow + 组间分隔区分;指示条扁平无辉光;底边 hairline。
- File 子 tab 栏:激活/hover 背景跟随主题(不再 .white.opacity);指示条与上方一致;背景为主题色(不再 thickMaterial)。
- AppKit 侧边栏:行字体统一、行距更松、分隔更轻。
- 7 个对话框:主 CTA 为 accent pill(按下缩放),次要/Cancel 为 utility;分隔为 hairline;内边距 24;标题紧排。
- 全局:无 chrome 阴影;分屏分隔条/各表面背景跟随主题。

---

## Self-Review

**Spec coverage(对照 spec §1–6):**
- §1.1 Spacing/Radius → Task 1。✔
- §1.2 DesignFonts chrome 角色 → Task 2。✔
- §1.3 ButtonStyles(Pill/Utility,显式注入色) + §1.3 注 onAccentColor → Task 3 + Task 4。✔
- §1.4 Hairline → Task 5。✔
- §2 工具栏 → Task 9;Workspace tab → Task 7;File 子 tab → Task 8;tab 指示条扁平改名 → Task 6;AppKit 侧边栏 → Task 11;对话框 ×7 → Task 12;文件面板头 → Task 12(FileViewerPanelView 头)+ Task 10(textBackgroundColor)。✔
- §3 阴影移除 → Task 6 + Task 13 Step 1;系统色 → Task 10;间距/圆角字面量 → Tasks 7/8/11/12 各自 token 化 + Task 13 清扫。✔
- §4 范围边界:命令面板仅保留 scrim(Task 13 Step 2 确认),不重构;主架构/内核/颜色映射不动。✔
- §5 分两段(B1=Tasks 1–5,B2=Tasks 6–13)、测试、i18n、worktree。✔
- §6 组件边界:各 token/样式被多表面消费,职责单一。✔

**Placeholder scan:** 基座任务(1–5)给完整代码;机械表面(6–10)给精确 before/after。Tasks 11/12 是「读文件 + 按精确规则转换」型(字体/间距/按钮/分隔有明确目标 API 与映射),非含糊指令 —— 这是 token 铺开的标准做法,实现者按规则逐文件施用。✔

**Type consistency:**
- `Spacing`/`Radius`(T1)在 T4/T6/T7/T8/T11/T12 一致引用。✔
- `DesignFonts.dialogTitle/sectionTitle/chromeBody/chromeStrong/chromeCaption/eyebrow/dialogTitleTracking`(T2)在 T7/T9/T11/T12 一致。✔
- `ThemeManager.onAccentColor`(T3)在 T4 调用点、T9、T12 一致。✔
- `PillButtonStyle(accent:onAccent:)` / `UtilityButtonStyle(tint:activeTint:border:isActive:)`(T4)在 T9/T12 一致。✔
- `View.hairline(_:)`(T5)在 T12 一致;`View.tabAccentIndicator(_:active:inset:)`(T6)在 T6 调用点(WorkspaceTabBar)、T8(FileSubTabBar)一致。✔

**实现者注意:**
- Task 9 的项目名属性、Task 11 的侧边栏现状、Task 12 的各对话框结构,均要求**先读文件再改**;计划给出目标 API 与映射规则,不臆造未确认的属性名。
- `@EnvironmentObject ThemeManager` 仅在 `MainWindowView` 注入的视图树内可用;本阶段所有改动表面都在该树内。新加 `@EnvironmentObject` 的私有子结构体(TabButton/SubTabButton/SplitDivider 等)同属该树,安全。
- `Color`/`Font` 相等断言若在 CI 不稳,改比较 `NSColor(color).usingColorSpace(.sRGB)` 分量(沿用 Phase A 约定)。
