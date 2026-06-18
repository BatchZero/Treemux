# UI 主题统一(Phase A:正确性) 设计文档

- **日期**: 2026-06-18
- **分支 / worktree**: `feat/ui-theme-unification-phase-a` → `.worktrees/feat+ui-theme-unification-phase-a/`
- **设计依据**: `.claude/DESIGN.md`;承接已合并的主题引擎(`Theme`/`ThemeManager`/`terminal.ansi`)
- **上游**: 主题引擎(P1–P3)已合并到 `main`(commit 7013683)

## 背景与问题

主题引擎已让窗口/侧栏/终端跟随 YAML 主题,但**文件浏览相关的一套硬编码深色 "Phosphor" 调色板(`DesignTokens` 枚举)完全不跟主题走**。浅色主题下这些表面仍是深色,造成"深色孤岛"。

截图实测问题(浅色主题):
- 中间**文件列表整块是深色**(`FileTreePanelView` 用 `DesignTokens.panel/ink/surface/text/line`)。
- 文件/文件夹图标固定蓝、tab "文件"蓝 / "终端"绿(`FileIconCatalog` / `WorkspaceTabBarView` 硬编码 Phosphor accent)。
- 侧栏选中项是**深 navy**(本该浅蓝 `#D2E3FB`)——`SidebarRowView` 的深色默认值未被主题色覆盖。
- Markdown / 代码高亮颜色不随主题(`RenderedMarkdownView` / `CodeHighlightTheme` 硬编码)。

`DesignTokens.` 当前被 7 个文件使用:`FileTreePanelView`、`WorkspaceTabBarView`、`CodeHighlightTheme`、`RenderedMarkdownView`、`FileIconCatalog`、`PhosphorUnderline`、(定义处)`DesignTokens.swift`。

## 目标(本阶段 = Phase A,只做正确性)

把上述所有硬编码 Phosphor 颜色**改为主题驱动**,所有颜色最终都来自 YAML 主题(`ui:` 段 + `terminal.ansi:` 段),修复浅色主题的"深色孤岛"与侧栏选中色 bug。

## 范围与决策(已与用户确认)

- **分两阶段:先 A 后 B。** 本 spec 只做 Phase A(主题驱动正确性);Phase B(DESIGN.md 风格重塑:`DesignSystem` 字体/间距/圆角、pill/utility 按钮、单一 accent 收敛、间距排版重排、工具栏/对话框重塑)是后续独立 spec。
- **语义色复用 YAML 的 `terminal.ansi` + `ui.accent`**,不新增 schema 字段。
- **架构:方案 1 —— 注入 + ThemeManager 派生访问器。** 复用已注入的可观察 `ThemeManager`,视图用 `@EnvironmentObject` 读派生访问器;唯一非视图消费者 `TreeSitterCodeHighlighter` 显式注入主题并监听 `.themeDidChange` 重建。不引入全局单例。
- **`CodeHighlightTheme`** 由静态表改为"工厂函数 + highlighter 注入主题"。
- **`FileIconCatalog`** 改为返回语义角色,由视图层解析成主题色。
- 保持三栏主架构、交互逻辑、文件名/类型判定逻辑不变 —— 纯取色来源替换。

## 1. 颜色映射(Phosphor → 主题)

### 结构色 → `ui:` 字段
| Phosphor token | 主题来源 | 浅色效果 |
|---|---|---|
| `ink`(app 基底) | `ui.window` | 白 |
| `panel`(文件树/tab栏背景) | `ui.pane` | 白(不再深色) |
| `surface`(选中/hover 行) | `ui.selection` | 浅蓝 `#D2E3FB` |
| `line`(发丝线/分隔/缩进线) | `ui.hairline` | 浅灰 |
| `text` | `ui.textPrimary` | 墨 |
| `muted` | `ui.textSecondary` | 灰 |
| `faint` | `ui.textMuted` | 浅灰 |

### 语义色 → `terminal.ansi` + `ui.accent`
| 用途 | 主题来源(ansi 索引) |
|---|---|
| files(文件 tab / 主类型) | `ui.accent` |
| shell(终端 tab) | `ansi[2]`(绿) |
| 代码高亮 keyword / operator | `ansi[5]`(品红) |
| 代码高亮 string | `ansi[2]`(绿) |
| 代码高亮 number / constant / boolean | `ansi[3]`(黄) |
| 代码高亮 function | `ansi[4]`(蓝) |
| 代码高亮 type / attribute | `ansi[6]`(青) |
| 代码高亮 label | `ansi[3]`(黄) |
| 代码高亮 tag | `ansi[5]`(品红) |
| 代码高亮 comment | `ui.textMuted` |
| 代码高亮 variable / property | `ui.textPrimary` |
| 代码高亮 punctuation | `ui.textSecondary` |
| 文件类型图标 tint — code | `ansi[4]`(蓝) |
| 文件类型图标 tint — doc | `ansi[2]`(绿) |
| 文件类型图标 tint — config / data | `ansi[3]`(黄) |
| 文件类型图标 tint — generic | `ui.textSecondary` |

> capture 名沿用现有最长前缀匹配(`keyword.function` → `keyword`)。ansi 索引清单是本阶段的权威映射;浅色主题的 ansi(7/15 号已特调)保证浅底下高亮可读。

## 2. 逐表面改动

`ThemeManager` 新增派生访问器(单一取色出口):
```
treePanelBackground -> pane
rowSurface          -> selection
filesAccent         -> accent
shellAccent         -> Color(hex: activeTheme.terminal.ansi[2])
func syntaxColor(_ role: SyntaxRole) -> Color   // role -> ansi/ui 映射(见 §1)
func fileIconTint(_ role: FileIconRole) -> Color // role -> ansi/ui 映射(见 §1)
```
(沿用现有 `sidebarSelectionFillNS / sidebarSelectionStrokeNS / dividerColor / accentColor / textPrimary/Secondary/Muted` 等。)

| 文件 | 改动 |
|---|---|
| `Treemux/UI/FileBrowser/FileTreePanelView.swift` | 所有 `DesignTokens.panel/surface/line/text/muted/faint/files` → `@EnvironmentObject theme` 的对应访问器;整块面板、行背景、图标、缩进线主题化 |
| `Treemux/UI/Workspace/WorkspaceTabBarView.swift` | 背景 `Color(nsColor: .windowBackgroundColor)` → `theme.tabBarBackground`;eyebrow / 分隔 / 活动 tab → `theme.filesAccent / shellAccent / dividerColor`;底边 hairline → `theme.dividerColor` |
| `Treemux/UI/Theme/FileIconCatalog.swift` | 不再返回固定 `DesignTokens` 色,改返回**语义角色**(`FileIconRole`:code/doc/config/data/generic);颜色由 `FileTreePanelView` 用 `theme.fileIconTint(role)` 解析 |
| `Treemux/Services/Rendering/CodeHighlightTheme.swift` | 静态表 → 工厂 `static func table(ansi:[String], ui: ThemeUIColors) -> [String: Color]` 或等价的 `color(forCapture:ansi:ui:)`;映射见 §1 |
| `Treemux/Services/Rendering/TreeSitterCodeHighlighter.swift` | 注入当前主题(`ansi` + `ui`)构建高亮表;监听 `.themeDidChange` 重建并触发重新高亮 |
| `Treemux/UI/FileBrowser/RenderedMarkdownView.swift` | `DesignTokens.*` → `@EnvironmentObject theme` 对应访问器(正文/代码块/链接色) |
| `Treemux/UI/Components/PhosphorUnderline.swift` | `DesignTokens.line / files` → `theme.dividerColor / accentColor` |
| 侧栏选中 bug:`Treemux/UI/Sidebar/SidebarRowView.swift` + `SidebarCoordinator.swift` | 去掉 `SidebarRowView` 的深 navy 默认 `selectionFillColor/strokeColor`;`SidebarCoordinator` 在 `.themeDidChange` 时刷新所有可见行的 `selectionFillColor/strokeColor`(取 `theme.sidebarSelectionFillNS / StrokeNS`),修复浅色下选中仍是深蓝 |
| `Treemux/UI/Theme/DesignTokens.swift` | 语义角色映射迁移走后**整体删除**(硬编码深色孤岛的根) |

### 非视图消费者:highlighter 注入
`TreeSitterCodeHighlighter` 在构建时接收当前主题的 `ansi`(`[String]`)与 `ui`(`ThemeUIColors`),用 `CodeHighlightTheme.table(ansi:ui:)` 生成 capture→Color 映射。监听 `.themeDidChange`(object 为新 `Theme`)→ 重建表并请求编辑器重新高亮。其余视图消费者通过 `@EnvironmentObject ThemeManager` 自然在主题变化时重渲染。

## 3. 测试

### 可测纯逻辑(单测)
- `CodeHighlightTheme.table(ansi:ui:)`:给定已知 ansi/ui,断言 keyword→ansi[5]、string→ansi[2]、number→ansi[3]、function→ansi[4]、type→ansi[6]、comment→textMuted、variable→textPrimary、punctuation→textSecondary;capture 最长前缀匹配保持(`keyword.function`→`keyword`)。
- `FileIconCatalog` 角色映射:给定文件名/类型 → 断言返回正确 `FileIconRole`(code/doc/config/data/generic)。
- `ThemeManager` 派生访问器:用一个已知 ansi 的主题断言 `shellAccent == Color(hex: ansi[2])`、`syntaxColor(.keyword) == Color(hex: ansi[5])`、`fileIconTint(.code) == Color(hex: ansi[4])` 等派生公式。

### 人工验证(SwiftUI 渲染 / AppKit 侧栏)
编译后运行 app,肉眼验证浅/深切换:文件面板背景、行选中色、tab、代码高亮、markdown、侧栏选中色全部跟随主题;切主题时实时刷新(含 highlighter 重建)。

## 4. 范围边界

- ✅ 做:硬编码 Phosphor 全部改为主题驱动、修浅色 bug、删 `DesignTokens` 枚举。
- ❌ 不做(留给 Phase B):`DesignSystem`(字体/间距/圆角)、pill/utility 按钮语法、蓝/绿 tab 收敛为单一 accent、间距/排版重排、工具栏/对话框重塑。
- 保持三栏主架构、交互逻辑、文件名/类型判定逻辑不变 —— 纯取色来源替换。
- i18n:本阶段不新增用户可见字符串,无需补翻译。

## 5. Worktree

主目录留在 `main`;本阶段在 `.worktrees/feat+ui-theme-unification-phase-a/` 开发,完成后合并并清理。
