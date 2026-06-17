# 主题系统 + UI 重构 设计文档

- **日期**: 2026-06-17
- **分支 / worktree**: `feat/theme-system-and-ui-refactor` → `.worktrees/feat+theme-system-and-ui-refactor/`
- **设计依据**: `.claude/DESIGN.md`(Apple 风格设计语言)

## 目标

1. 引入基于 **YAML** 的主题系统:自带浅 / 深两套默认主题,支持用户自定义 YAML、本地持久化(增删切换)。
2. 主题同时驱动 **App UI** 与基于 **Ghostty(libghostty)** 的终端 —— 软件所有可改色调统一来自主题文件。
3. 把 `.claude/DESIGN.md` 记入 `.claude/CLAUDE.md`,确立为今后 UI 设计的唯一依据。
4. 依据 DESIGN.md 对现有 UI 进行**原则级重构**(保留三栏 IDE 主架构,只换调性/排版/间距/按钮/边框语法)。

## 范围与决策(已与用户确认)

- **一个统一 spec** 覆盖主题引擎(B)+ UI 重构(C),CLAUDE.md 记录(A)并入;实现时分阶段推进。
- 主题 YAML **只管颜色**:`ui`(App 语义色)+ `terminal`(Ghostty 终端色)。字体 / 间距 / 圆角等非颜色 token 来自 DESIGN.md,**固化在代码**(`DesignTokens`),不随主题变。
- 架构采用**方案 1:Token 解析器 + 语义色板**,用 `Yams` 解析 YAML。
- UI 重构走**提炼原则、重塑调性**:保留三栏主架构与交互逻辑,只换"皮"。
- 编辑器语法高亮配色**从主题 ANSI 派生**,不单独维护编辑器配色字段。
- 内置主题**可删 + 可一键恢复**。

## 1. YAML Schema(主题文件格式)

一个 `.yaml` 文件 = 一套主题,放入 `~/.treemux/themes/<id>.yaml`。标准 YAML,分元数据 + `ui` + `terminal` 三部分。

```yaml
id: treemux-dark          # 唯一标识(同 id 覆盖,文件名建议与 id 一致)
name: Treemux Dark        # 显示名
author: BatchZero         # 可选
appearance: dark          # dark | light —— 驱动 NSAppearance

ui:
  # 强调色(DESIGN.md 单一交互色原则)
  accent:          "#418ADE"
  accentOnDark:    "#2997FF"   # 深色表面上的链接/强调
  onAccent:        "#FFFFFF"
  # 表面层级:窗口 → 侧边栏 → 面板 → 头 → tab栏 → 状态栏
  window:          "#0F1114"
  sidebar:         "#0F1114"
  pane:            "#111317"
  paneHeader:      "#151820"
  tabBar:          "#0F1114"
  statusBar:       "#0F1114"
  # 选区 / 发丝线
  selection:       "#1A2A42"
  selectionStroke: "#418ADE"   # 可省 → 退回 accent
  hairline:        "#FFFFFF1A" # 支持 8 位含 alpha
  # 文字阶梯
  textPrimary:     "#F0F0F2"
  textSecondary:   "#C5C8C6"
  textMuted:       "#7A7A7A"
  # 语义状态色
  success:         "#B5BD68"
  warning:         "#F0C674"
  danger:          "#CC6666"

terminal:
  foreground:      "#C5C8C6"
  background:      "#111317"   # 建议与 ui.pane 一致,终端无缝融入面板
  cursor:          "#C5C8C6"
  cursorText:      "#111317"   # 可选(光标下文字反色)
  selection:       "#373B41"
  selectionText:   "#C5C8C6"   # 可选(选区文字色)
  ansi:                        # 必须 16 个:0-7 正常,8-15 高亮
    - "#1D1F21"  # 0  black
    - "#CC6666"  # 1  red
    - "#B5BD68"  # 2  green
    - "#F0C674"  # 3  yellow
    - "#81A2BE"  # 4  blue
    - "#B294BB"  # 5  magenta
    - "#8ABEB7"  # 6  cyan
    - "#C5C8C6"  # 7  white
    - "#969896"  # 8  bright black
    - "#CC6666"  # 9  bright red
    - "#B5BD68"  # 10 bright green
    - "#F0C674"  # 11 bright yellow
    - "#81A2BE"  # 12 bright blue
    - "#B294BB"  # 13 bright magenta
    - "#8ABEB7"  # 14 bright cyan
    - "#FFFFFF"  # 15 bright white
```

### 规则
- **颜色格式**:`#RGB` / `#RRGGBB` / `#RRGGBBAA`(8 位带透明,给 hairline 用)。终端色按不透明处理(Ghostty 用 `#RRGGBB`)。
- **校验**:`id`/`name`/`appearance`/`ui` 全字段 / `terminal.ansi`(恰好 16 个)为必填;缺字段或非法 hex → 该主题加载失败并在设置里提示,不会崩。
- 非颜色 token 不进 YAML。

## 2. 架构与组件

数据流:

```
~/.treemux/themes/*.yaml ─┐
app bundle 内置 *.yaml ────┤→ ThemeLoader(Yams 解析 + 校验)→ [Theme]
                          │
            AppSettings.activeThemeID ──┐
                                        ▼
                                  ThemeManager(@Published activeTheme)
                                   │                      │
                       SwiftUI 环境对象               .themeDidChange 通知
                    (语义色 + DesignTokens)               │
                                                  TreemuxGhosttyRuntime
                                              读 terminal 段 → 写 ghostty config
                                          → ghostty_app_update_config(热重载,全部终端同步)
```

| 组件 | 职责 | 新建/改造 |
|---|---|---|
| `Yams`(SPM 依赖) | YAML 解析 | 新增到 `project.yml` packages |
| `DesignTokens` | DESIGN.md 固定 token:字体阶梯、间距(4/8/12/17/24/32/48/80)、圆角(xs5/sm8/md11/lg18/pill)。全主题共用 | 新建 |
| `ThemeColors` | 从 YAML 解码的 `ui` + `terminal` 两段(Codable / Yams) | 新建,替换旧 `UIColors`/`TerminalColors` |
| `Theme` | `appearance + ThemeColors + DesignTokens` 聚合,对外暴露解析好的 `Color`/`NSColor` | 新建,替换 `ThemeDefinition` |
| `ThemeLoader` | 扫描 bundle + `~/.treemux/themes/`,Yams 解析,校验,收集错误 | 新建 |
| `ThemeManager` | 发布 `activeTheme`;`setActiveTheme/importTheme/deleteTheme/resetBuiltIn`;持久化 active id;切换时发 `.themeDidChange` | 改造现有 |
| `TreemuxGhosttyRuntime` | `writeTemporaryGhosttyConfig` 加入 `background/foreground/cursor-color/selection-*/palette`;监听 `.themeDidChange` 触发 `reloadGhosttyConfig` | 改造现有 |

### 主题管理操作(设置面板)
- **切换**:`setActiveTheme(id)` → 更新 `@Published` + 存 `activeThemeID` + 通知 Ghostty 热重载(已开终端立即变色)。
- **导入/添加**:文件选择器选 `.yaml` → 校验通过 → 复制进 `~/.treemux/themes/` → 列表出现。
- **删除**:从 `~/.treemux/themes/` 删文件;内置可删。
- **恢复内置**:从 bundle 重新复制内置 YAML。
- **持久化**:active id 存 `AppSettings`;主题文件即 `~/.treemux/themes/` 下 `.yaml`,天然可增删、跨启动保留。

### 首启行为
bundle 内两套 YAML 复制到 `~/.treemux/themes/`(若不存在);默认 active = `treemux-dark`(可在设置换浅色)。

## 3. 两套默认主题

### Dark(`treemux-dark`,首启默认)
即第 1 节示例(Tomorrow-Night 系深蓝灰,终端背景 `#111317` 与面板无缝)。

### Light(`treemux-light`)
落地 DESIGN.md 的 Apple 浅色语言:

```yaml
id: treemux-light
name: Treemux Light
author: BatchZero
appearance: light
ui:
  accent:          "#0066CC"
  accentOnDark:    "#2997FF"
  onAccent:        "#FFFFFF"
  window:          "#FFFFFF"
  sidebar:         "#F5F5F7"
  pane:            "#FFFFFF"
  paneHeader:      "#FAFAFC"
  tabBar:          "#F5F5F7"
  statusBar:       "#F5F5F7"
  selection:       "#D2E3FB"
  selectionStroke: "#0066CC"
  hairline:        "#1D1D1F14"
  textPrimary:     "#1D1D1F"
  textSecondary:   "#333333"
  textMuted:       "#7A7A7A"
  success:         "#248A3D"
  warning:         "#B25000"
  danger:          "#D70015"
terminal:
  foreground:      "#1D1D1F"
  background:      "#FFFFFF"
  cursor:          "#0066CC"
  cursorText:      "#FFFFFF"
  selection:       "#D2E3FB"
  selectionText:   "#1D1D1F"
  ansi:
    - "#1D1D1F"  # 0  black
    - "#D70015"  # 1  red
    - "#248A3D"  # 2  green
    - "#B25000"  # 3  yellow
    - "#0066CC"  # 4  blue
    - "#8944AB"  # 5  magenta
    - "#0071A4"  # 6  cyan
    - "#6E6E73"  # 7  white(中灰,避免与浅底糊)
    - "#7A7A7A"  # 8  bright black
    - "#E5484D"  # 9  bright red
    - "#30A46C"  # 10 bright green
    - "#D9822B"  # 11 bright yellow
    - "#2997FF"  # 12 bright blue
    - "#A450CF"  # 13 bright magenta
    - "#0091C2"  # 14 bright cyan
    - "#1D1D1F"  # 15 bright white(墨色,保证可读)
```

浅色终端取舍:`background=#FFFFFF`,7/15 号(白)在浅底会"消失",故 7 号取中灰、15 号取墨色,保证高亮文字始终可读。

## 4. UI 重构计划(DESIGN.md 原则落地)

策略:保留三栏 IDE 主架构,把 DESIGN.md 原则贯穿每个表面。分两层。

### A. 设计系统基座(`DesignTokens` + 可复用样式)
- **字体阶梯**:SF Pro 体系 → SwiftUI `Font` 扩展(`.heroDisplay/.displayMd/.tagline/.body/.caption/.finePrint`…),显示级负字距(`-0.374`)。
- **间距 / 圆角常量**:`Spacing`(4/8/12/17/24/32/48/80)、`Radius`(xs5/sm8/md11/lg18/pill)。
- **单一强调色**:交互元素只用 `theme.accent`,删散落自定义色。
- **按钮语法**:`PillButtonStyle`(主操作,`Radius.pill` + accent + 按下 `scale(0.95)`)、`UtilityButtonStyle`(工具操作,`Radius.sm` 紧凑)。
- **发丝线修饰符** `.hairline(edge:)`:`theme.hairline` 1px 取代重分隔线。
- **表面修饰符**:`window → sidebar → pane → paneHeader` 层级背景,统一取主题。

### B. 逐表面套用

| 表面 | 重构后 |
|---|---|
| 工具栏 | 更薄、退隐;项目名 `displayMd` 紧排;按钮统一 `UtilityButtonStyle`;激活态才上 accent |
| 侧边栏 | `sidebar` 表面;行距加大;选中 = `selection` 填充 + `accent` 描边;分组用 hairline;标题 `tagline/captionStrong` |
| Tab 栏 | 扁平 tab,激活 tab 底部 `accent` 指示条;底边 hairline;关闭按钮收敛 |
| 编辑器面板 | `pane` 表面;文件名头 `captionStrong` + hairline;语法配色从主题 terminal/ansi 派生 |
| 终端 | 颜色全部来自主题 `terminal` 段;背景 = `terminal.background` |
| 状态/底栏 | `statusBar` 表面;`finePrint` + `textMuted`;顶边 hairline |
| 对话框(Open Project / New Server / Settings) | 卡片 `Radius.lg` + hairline;主 CTA pill;内边距 24px;单一 accent;Settings 的 Theme 页加入主题列表 + 导入/删除/恢复 + 实时预览 |

### C. 统一清除项
- 删 chrome 上装饰阴影(阴影只留给产品图,IDE 基本不用)。
- 重分隔线 → hairline。
- 硬编码颜色 → 主题 token。

### 范围说明
不动三栏主架构、不改导航逻辑、不重写编辑器/终端内核;只换皮。具体组件文件清单在 writing-plans 阶段落实。

## 5. CLAUDE.md 记录 · 迁移 · 错误处理 · 测试 · i18n

### CLAUDE.md 记录
`.claude/CLAUDE.md` 新增「UI 设计规范」小节:今后所有 UI 设计 / 重构以 `.claude/DESIGN.md` 为唯一依据(单一 accent、SF Pro 紧排、pill/utility 两种按钮语法、hairline、克制阴影、间距/圆角 token、浅深表面节奏);颜色由主题 YAML 驱动,非颜色 token 由 DESIGN.md 固化。

### 迁移
- 内置仅两套 → 用新 YAML 替换旧 JSON。
- 旧 `.json` 不再读取;只认 `.yaml`/`.yml`。
- 移除旧 `ThemeDefinition`/`UIColors`/`TerminalColors`(JSON)及 `ensureBuiltInThemesExist` 的 JSON 写出逻辑。

### 错误处理
- 非法 YAML / 缺字段 / `ansi` 不是 16 个 → 跳过该文件,设置页列出错误,绝不崩。
- active id 指向主题不存在 → 回退 `treemux-dark`。
- 内置被删光 → "恢复内置"从 bundle 复制。

### 测试
- `ThemeLoader`:合法解析、各类非法输入(坏 hex、少字段、ansi≠16)、bundle+用户目录合并、同 id 覆盖。
- `ThemeManager`:切换 / 导入 / 删除 / 恢复 / active id 持久化 / 回退。
- Ghostty 配置生成:terminal 段 → ghostty config 文本正确;切换发 `.themeDidChange`。
- UI:遵循 CLAUDE.md,编译后给出运行命令做人工验证。

### i18n
新增字符串全部 `LocalizedStringKey` + `Localizable.xcstrings` 补 `zh-Hans`。

### Worktree
主目录留在 `main`,本分支在 `.worktrees/feat+theme-system-and-ui-refactor/` 开发。

## 6. 实现分阶段

| 阶段 | 内容 | 可见效果 |
|---|---|---|
| P1 | Yams + `DesignTokens` + `Theme` 模型 + `ThemeLoader` + 内置转 YAML + 记录 CLAUDE.md | 内部地基,无可见变化 |
| P2 | `ThemeManager` 改造 + 持久化 + Ghostty 终端配色接通 + 热切换 | 切主题终端跟着变 |
| P3 | 设置页主题管理 UI(列表/导入/删除/恢复/预览) | 可增删切换主题 |
| P4 | UI 重构 — 设计系统基座(token + 按钮/hairline/表面样式) | 全局调性变化 |
| P5 | UI 重构 — 逐表面套用 | 完整新外观 |
