# UI 主题统一(Phase B)设计文档 — DESIGN.md 视觉重塑

- **日期**: 2026-06-18
- **分支 / worktree**: `feat/ui-theme-unification-phase-b` → `.worktrees/feat+ui-theme-unification-phase-b/`
- **设计依据**: `.claude/DESIGN.md`(Apple 风格设计语言)、`docs/superpowers/specs/2026-06-17-theme-system-and-ui-refactor-design.md` §4、`docs/superpowers/plans/2026-06-18-ui-theme-unification-phase-a.md` §4「范围边界」延后项

## 背景与目标

Phase A 已完成「颜色全主题驱动」:文件浏览/tab/markdown/侧栏的硬编码 Phosphor 调色板全部迁移到 YAML 主题(`ThemeManager`),并修复了浅色主题下的孤岛与选中色 bug。

Phase B 落地 DESIGN.md 的**非颜色视觉语言**:字体 / 间距 / 圆角 token、两种按钮语法(pill / utility)、hairline 发丝线、移除 chrome 阴影、间距排版重排、工具栏 / 对话框重塑、蓝 / 绿 tab 收敛为单一 accent,并清理 `FileSubTabBarView` 等处的 `.white.opacity` 与系统色遗留。

**核心约束:Phase B 只动「形」,不动「色映射」。** 颜色 token 仍来自 YAML 主题(`ThemeManager` 派生访问器),Phase A 定下的颜色映射不变。

## 关键决策(已与用户确认)

1. **字体哲学 = 保留等宽数据层 + chrome 走 SF Pro。** 数据层(文件名 / tab / 树行 / 终端)继续等宽(复用终端质感);chrome(对话框 / 设置 / 工具栏 / 按钮)用 SF Pro。`DesignFonts` 分两族:`dataLayer(mono)` + `chrome(SF Pro)`。DESIGN.md 的 SF Pro 紧排负字距只用在 chrome 标题。**不**把数据层改成 SF Pro(否则与终端等宽产生割裂感)。
2. **按钮语法 = pill 只给对话框主 CTA。** 每个对话框唯一主动作(Save / Open / Connect)用 `PillButtonStyle`(accent 填充 + 按下 `scale(0.95)`);Cancel / 次要动作 / 工具栏按钮用 `UtilityButtonStyle`(`Radius.sm` 紧凑、透明 / hairline、激活态才上 accent)。不滥用 pill。
3. **蓝 / 绿 tab 收敛 = 单一 accent + eyebrow 区分。** Files / Shell 两组指示条统一 `accentColor`;功能区分靠现有「Files」/「Shell」eyebrow 小标签 + 两组之间的 hairline 分隔。`shellAccent`(绿)不再用于 tab 指示。
4. **tab 指示条 = 扫平为纯色 accent 条。** 去掉 `PhosphorUnderline` 的辉光 `shadow`,激活 tab = 底部 2px 纯 `accentColor` 指示条(扁平)。组件改名为 `TabAccentIndicator`。严格符合 DESIGN.md「chrome 不用阴影」+「底部 accent 指示条」。
5. **工具栏 = 加项目名 + 按钮 utility 化。** 工具栏左侧加当前项目 / 连接名(`dialogTitle`,SF Pro 紧排);4 个图标按钮(分屏×2 / 新终端 / 设置)改为 `UtilityButtonStyle`,激活态才上 accent,平时 `textSecondary`。
6. **AppKit 侧边栏纳入。** `SidebarNodeRow` 等硬编码 `.system()` 字体迁到 `DesignFonts` token,行距加大,分组用 hairline,标题用 `tagline / captionStrong`。

### chrome 字体缩放取舍

DESIGN.md 的 17px body 是营销站阅读节奏,放进 macOS 密集对话框会过大、不像原生 Mac app。决策:chrome **标题保留 SF Pro 紧排负字距**这一签名(`dialogTitle` ~20/600 / -0.4),但 body / caption 落在 Mac 标准的 13 / 11,而非照搬 17 / 14。营销站的 hero-display(56px)、display-lg(40px)等大尺寸 token 不进 IDE chrome。

## 1. DesignSystem 基座(新建)

### 1.1 `Treemux/UI/Theme/DesignSystem.swift`(新建)

两组固化 token(不随主题变,源自 DESIGN.md 原值):

```swift
import SwiftUI

/// Fixed spacing scale (DESIGN.md). Theme-independent.
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

/// Fixed corner-radius scale (DESIGN.md). Theme-independent.
enum Radius {
    static let xs: CGFloat = 5
    static let sm: CGFloat = 8
    static let md: CGFloat = 11
    static let lg: CGFloat = 18
    static let pill: CGFloat = 9999
}
```

### 1.2 `Treemux/UI/Theme/DesignFonts.swift`(扩展)

保留现有 `dataLayer(size:weight:)`(mono)与 `chrome(size:weight:)`(SF Pro)两个基础函数**不变**。新增按 IDE 密度缩放的 chrome 语义角色(SF Pro):

```swift
extension DesignFonts {
    // MARK: - Chrome semantic roles (SF Pro, IDE-scaled)

    /// Dialog / toolbar title — the only place DESIGN.md tight tracking applies.
    /// SwiftUI Font 不支持 letterSpacing;负字距通过 .tracking(_:) 在 Text 上施加。
    static let dialogTitle: Font = chrome(size: 20, weight: .semibold)
    static let dialogTitleTracking: CGFloat = -0.4

    static let sectionTitle: Font = chrome(size: 13, weight: .semibold)
    static let chromeBody: Font = chrome(size: 13, weight: .regular)
    static let chromeStrong: Font = chrome(size: 11, weight: .semibold)
    static let chromeCaption: Font = chrome(size: 11, weight: .regular)

    // MARK: - Data layer semantic roles (mono)

    /// Tab-group eyebrow ("Files"/"Shell") — small mono label.
    static let eyebrow: Font = dataLayer(size: 9, weight: .semibold)
}
```

> SwiftUI 的 `Font` 无 letterSpacing 入口;紧排通过在标题 `Text` 上 `.tracking(DesignFonts.dialogTitleTracking)` 施加。提供 `dialogTitleTracking` 常量供调用点统一引用。

### 1.3 `Treemux/UI/Components/ButtonStyles.swift`(新建)

两种按钮语法。颜色从环境里的 `ThemeManager` 取(`@EnvironmentObject`)。

- **`PillButtonStyle`**:`Radius.pill` 全圆角 + `theme.accentColor` 填充 + `theme.onAccent` 文字 + 内边距 `11×22`(DESIGN.md button-primary) + 按下 `scaleEffect(0.95)`。**仅对话框主 CTA。**
- **`UtilityButtonStyle`**:`Radius.sm` + 透明背景 + `theme.dividerColor` 1px 边(可选) + `textSecondary` 文字 + 内边距 `8×15`(DESIGN.md button-dark-utility) + 激活 / 按下态 `theme.accentColor` + 按下 `scaleEffect(0.95)`。**工具栏 / 次要动作 / Cancel。**

> `ButtonStyle` 内无法直接 `@EnvironmentObject`;采用「`ViewModifier` + `@EnvironmentObject` 读色 → 传入 `ButtonStyle` 初始化器」或「在 `makeBody` 内用 `Color` 参数」的方式注入。实现时具体取舍在 writing-plans 落实(优先:`PillButtonStyle(accent:onAccent:)` 等显式注入色参,调用点 `.buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))`,保证主题切换实时生效)。
> 注:`ThemeManager` 现有 `accentColor`,**新增** `onAccentColor`(= `Color(hex: activeTheme.ui.onAccent)`)派生访问器供按钮文字色用。

### 1.4 `Treemux/UI/Components/Hairline.swift`(新建)

```swift
/// 1px theme-driven hairline replacing heavy Divider()/Rectangle separators.
extension View {
    func hairline(_ edge: Edge) -> some View { /* overlay 1px theme.dividerColor on edge */ }
}
```

通过 `@EnvironmentObject ThemeManager` 取 `dividerColor`,在指定 `edge` 叠 1px 线。取代散落的 `Divider()` 与 `Rectangle().fill(theme.dividerColor)` 分隔线写法。

## 2. 逐表面套用

| 表面 | 文件 | 改动 |
|---|---|---|
| **工具栏** | `Treemux/UI/MainWindowView.swift` | 左侧加项目 / 连接名(`dialogTitle` + tracking);4 个图标按钮 → `UtilityButtonStyle`(激活态才上 accent,平时 `textSecondary`);底边 `.hairline(.bottom)` |
| **Workspace tab 栏** | `Treemux/UI/Workspace/WorkspaceTabBarView.swift` | Files / Shell 指示条统一 `accentColor`(去 `shellAccent`);区分靠 `eyebrow` 标签 + 组间 hairline;底边 hairline;间距走 `Spacing` token;eyebrow 用 `DesignFonts.eyebrow` |
| **File 子 tab 栏** | `Treemux/UI/FileBrowser/FileSubTabBarView.swift` | 清除 `.white.opacity(0.12/0.06)` → `theme.sidebarSelection`(激活)/ `theme.textPrimary.opacity(0.06)`(hover);`.thickMaterial` → `theme.tabBarBackground`;`Color.accentColor` → `theme.accentColor`;指示条改用 `TabAccentIndicator`,与 Workspace tab 一致;`Divider()` → hairline |
| **tab 指示条** | `Treemux/UI/Components/PhosphorUnderline.swift` | 去 `shadow`;激活 tab = 底部 2px 纯 `accent` 条(扁平);组件 / 文件改名 `TabAccentIndicator`(`.phosphorUnderline(_:active:)` → `.tabAccentIndicator(_:active:)`);更新 `#Preview` |
| **AppKit 侧边栏** | `Treemux/UI/Sidebar/SidebarNodeRow.swift`(及相关行视图) | 硬编码 `.system(size:)` → `DesignFonts` token;行距 / 内边距走 `Spacing`;分组分隔 → hairline 色;标题 `tagline / captionStrong` 对应字号 |
| **对话框 ×7** | `OpenProjectSheet` / `SSHServerEditSheet` / `SettingsSheet` / `SSHRawConfigSheet` / `RemoteDirectoryBrowser` / `SidebarIconCustomizationSheet` / `BatchUnsavedChangesSheet` | 卡片容器 `Radius.lg` + `.hairline`;主 CTA `PillButtonStyle`、次要 / Cancel `UtilityButtonStyle`;内边距 `Spacing.lg`;`Divider()` → `.hairline`;字体走 `DesignFonts` chrome token;清除 `.white.opacity` / 系统色 |
| **文件浏览面板头** | `Treemux/UI/FileBrowser/FileViewerPanelView.swift` 等 | 文件名头 `chromeStrong / sectionTitle` + `.hairline(.bottom)`;`.textBackgroundColor` → `theme.paneBackground` |

> 工具栏项目名取值:从 workspace / 活动 tab 的当前项目或连接名派生(动态数据,非可本地化字符串)。

## 3. 统一清除项

- **阴影**:移除唯一的 `PhosphorUnderline` 辉光 `shadow`(见 §2 tab 指示条)。全 UI 再无 chrome 阴影。功能性 `.ultraThinMaterial`(命令面板浮层)、`.thinMaterial` 保留 —— DESIGN.md 允许 backdrop-blur 作功能性磨砂,非装饰。
- **系统色 → 主题 token**:
  - `Treemux/UI/Workspace/SplitDivider.swift`:`Color(nsColor: .separatorColor)` → `theme.dividerColor`。
  - `Treemux/UI/Sidebar/SidebarItemIconView.swift`:`Color(nsColor: .windowBackgroundColor)` → 主题表面色(`sidebarBackground` / `paneBackground` 视语境)。
  - `Treemux/UI/FileBrowser/FileViewerPanelView.swift`:`Color(nsColor: .textBackgroundColor)` → `theme.paneBackground`。
  - `Treemux/UI/FileBrowser/ImagePreviewView.swift`:`Color.black.opacity(0.05)` → 主题表面色。
  - **保留**:`CommandPaletteView` 的 `Color.black.opacity(0.35)` 模态遮罩(scrim 本就该是黑)。
- **间距 / 圆角字面量**:散落的 `3/4/6/8/10/12/18/20` 收敛到 `Spacing` / `Radius` token(以最近的 token 值替换,允许 ±1 视觉对齐微调)。

## 4. 范围边界(明确 OUT)

不动:三栏主架构与导航逻辑、终端 / 编辑器内核、文件名 / 类型判定、Phase A 定下的颜色映射、主题引擎本身、命令面板布局(仅 token 化,不重构)。不新增功能,不改交互逻辑。

## 5. 实施分阶段 · 测试 · i18n

### 实施分两段(subagent 驱动)
- **B1 基座**:`DesignSystem.swift`、`DesignFonts` 扩展、`ButtonStyles.swift`、`Hairline.swift`、`ThemeManager.onAccentColor`。纯逻辑 / token 可单测(TDD)。
- **B2 逐表面套用**:工具栏、两个 tab 栏、tab 指示条改名、AppKit 侧边栏、对话框 ×7、面板头、统一清除项。编译 + 人工验证。

### 测试
- **单测**:`Spacing` / `Radius` token 值;`DesignFonts` chrome 角色返回预期 size / weight;`ThemeManager.onAccentColor` = `Color(hex: ui.onAccent)`;`ButtonStyle` 可构造性(若行为可断言)。
- **人工验证**(渲染层):切浅 / 深主题,逐项确认 —— 工具栏项目名 + utility 按钮、两个 tab 栏单一 accent + eyebrow 区分、tab 指示条扁平无辉光、AppKit 侧边栏字体 / 行距、7 个对话框 pill 主 CTA + utility 次要 + hairline + 内边距、文件面板头、无残留 `.white.opacity` / 系统色 / chrome 阴影。
- **构建命令**:非交互 `xcodebuild` 加 `-skipPackagePluginValidation`;新增 / 删除源文件后 `xcodegen generate` 并提交重生成的 `Treemux.xcodeproj`。
  ```bash
  cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+ui-theme-unification-phase-b
  xcodebuild build -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
  xcodebuild test -scheme Treemux -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -only-testing:TreemuxTests/<Class>
  ```

### i18n
- 工具栏项目名是动态数据,非可本地化字符串。
- 如有新增可见静态字符串,必须用 `LocalizedStringKey` 并在 `Treemux/Localizable.xcstrings` 补 `zh-Hans`。预期新增极少(本阶段主要是改形 / 改色)。

### Worktree
主目录留在 `main`,本阶段在 `.worktrees/feat+ui-theme-unification-phase-b/` 开发,完成后合并并清理。

## 6. 组件边界与依赖

- `DesignSystem`(Spacing / Radius):无依赖,被所有表面消费。
- `DesignFonts` 扩展:无依赖,被所有表面消费。
- `ButtonStyles`:依赖 `ThemeManager` 颜色(显式注入色参);被对话框 / 工具栏消费。
- `Hairline`:依赖 `ThemeManager.dividerColor`(`@EnvironmentObject`);被所有有分隔线的表面消费。
- `TabAccentIndicator`(原 PhosphorUnderline):被两个 tab 栏消费,接收 `Color` + `active: Bool`。
- 每个表面单元职责单一:读 token + 主题色 → 应用到既有布局,不改结构 / 逻辑。
