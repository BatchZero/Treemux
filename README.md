# Treemux

一款原生 macOS 终端多路复用器，为开发者打造的现代化工作空间管理工具。

基于 Swift & SwiftUI 构建，使用 [Ghostty](https://ghostty.org/) 作为终端渲染引擎，提供流畅的多面板、多标签页终端体验。

![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-blue)
![Swift 5](https://img.shields.io/badge/Swift-5-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
![Version](https://img.shields.io/badge/version-0.0.1-yellow)

---

## 目录

- [功能特性](#功能特性)
- [截图](#截图)
- [系统要求](#系统要求)
- [安装](#安装)
- [从源码构建](#从源码构建)
- [使用指南](#使用指南)
- [快捷键](#快捷键)
- [技术架构](#技术架构)
- [项目结构](#项目结构)
- [依赖项](#依赖项)
- [开发指南](#开发指南)
- [许可证](#许可证)

---

## 功能特性

### 工作空间管理

- **项目工作空间** — 将终端会话与项目目录关联，自动检测 Git 仓库信息
- **Git Worktree 感知** — 自动识别和管理 Git worktree，在侧边栏展示分支信息
- **远程 SSH 仓库** — 通过 SSH 连接远程服务器，支持 `~/.ssh/config` 解析
- **SFTP 目录浏览** — 图形化浏览远程服务器文件系统
- **工作空间固定与归档** — 灵活管理常用和不活跃的工作空间
- **状态持久化** — 退出时保存所有会话状态，下次启动自动恢复

### 终端会话

- **多面板分屏** — 支持水平和垂直分割，可拖拽调整面板大小
- **多标签页** — 每个 worktree 会话支持多个标签页
- **面板导航** — 在面板间快速切换焦点（方向导航 / 上一个 / 下一个）
- **面板缩放** — 临时最大化当前聚焦的面板
- **多种会话类型：**
  - 本地 Shell（默认 zsh）
  - SSH 远程会话
  - Tmux 会话检测与重新连接
  - Agent 会话（集成 Claude Code 等 AI 工具）

### Ghostty 终端引擎

- 基于 Ghostty 2.0+ 的高性能终端渲染
- Shell 集成支持命令状态检测
- Tmux 会话自动检测（面板头部显示）
- AI 工具检测（Claude、Codex 等）
- 终端标题和工作目录上报
- 剪贴板集成

### 侧边栏导航

- 基于 `NSOutlineView` 的项目大纲导航
- Worktree 感知，展示分支名称
- 当前面板 / 标签页指示徽标
- **自定义图标** — 100+ 图标库，支持为每个工作空间和 worktree 自定义图标

### 命令面板

- 模糊搜索命令界面（`⌘⇧P`）
- 实时过滤与键盘导航
- 动态展示可用快捷键

### 设置与配置

- 终端外观设置（字号、光标样式、默认 Shell）
- 14 项可自定义快捷键
- 内置暗色 / 亮色主题，支持跟随系统
- SSH 配置自动解析
- 双语支持（English / 简体中文）
- 自动更新配置

---

## 截图

> 即将添加

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | macOS 15.0 (Sequoia) 或更高版本 |
| 芯片架构 | Apple Silicon (arm64) |
| 磁盘空间 | ~25 MB |

---

## 安装

### 通过 GitHub Releases 下载

1. 前往 [Releases](https://github.com/BatchZero/Treemux/releases) 页面
2. 下载最新版本的 `Treemux-x.x.x.app.zip`
3. 解压后将 `Treemux.app` 拖入 `/Applications` 目录
4. 首次启动时，右键点击应用并选择「打开」以绕过 Gatekeeper

应用内置了基于 [Sparkle](https://sparkle-project.org/) 的自动更新功能，后续版本将自动提示更新。

---

## 从源码构建

### 前置条件

| 工具 | 版本 |
|------|------|
| Xcode | 16.0+ |
| macOS SDK | 15.0+ |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 最新版 |

### 构建步骤

```bash
# 1. 克隆仓库
git clone https://github.com/BatchZero/Treemux.git
cd Treemux

# 2. 使用 XcodeGen 生成 Xcode 项目（如果需要重新生成）
xcodegen generate

# 3. 打开 Xcode 项目
open Treemux.xcodeproj

# 4. 选择 Treemux target，点击 Build & Run (⌘R)
```

或者使用命令行构建：

```bash
xcodebuild -project Treemux.xcodeproj \
           -scheme Treemux \
           -configuration Debug \
           build
```

构建产物位于 `~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`。

---

## 使用指南

### 快速开始

1. 启动 Treemux
2. 点击侧边栏底部的 **+** 按钮或使用 `⌘O` 打开项目目录
3. 在侧边栏中选择工作空间，终端会话将自动启动
4. 使用快捷键分割面板、创建标签页，开始你的工作流

### 工作空间类型

- **本地项目** — 选择本地目录，自动检测 Git 仓库和 worktree
- **远程 SSH** — 配置 SSH 连接，浏览远程目录
- **独立终端** — 不绑定特定项目的通用终端会话

### 面板操作

- **水平分屏** — 在当前面板下方创建新面板
- **垂直分屏** — 在当前面板右侧创建新面板
- **调整大小** — 拖拽分割线调整面板比例
- **关闭面板** — 关闭当前聚焦的面板
- **缩放面板** — 临时最大化 / 恢复当前面板

---

## 快捷键

所有快捷键均可在设置中自定义。

### 通用

| 快捷键 | 功能 |
|--------|------|
| `⌘ ,` | 打开设置 |
| `⌘ ⇧ P` | 命令面板 |
| `⌘ ⌃ S` | 切换侧边栏 |
| `⌘ O` | 打开项目 |

### 标签页

| 快捷键 | 功能 |
|--------|------|
| `⌘ T` | 新建标签页 |
| `⌘ W` | 关闭标签页 |
| `⌘ ⇧ ]` | 下一个标签页 |
| `⌘ ⇧ [` | 上一个标签页 |

### 面板

| 快捷键 | 功能 |
|--------|------|
| `⌘ D` | 垂直分屏（向右） |
| `⌘ ⇧ D` | 水平分屏（向下） |
| `⌘ ⇧ W` | 关闭面板 |
| `⌘ ]` | 聚焦下一个面板 |
| `⌘ [` | 聚焦上一个面板 |
| `⌘ ⇧ ↩` | 缩放 / 恢复面板 |

---

## 技术架构

### 架构概览

Treemux 采用 **MVVM** 架构模式，结合 SwiftUI 的响应式数据流：

```
┌─────────────────────────────────────────────────┐
│                  TreemuxApp                      │
│              (应用入口 & 窗口管理)                │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │   Sidebar     │    │   WorkspaceDetail      │  │
│  │  (NSOutline   │    │  ┌──────────────────┐  │  │
│  │   View)       │    │  │    TabBar         │  │  │
│  │               │    │  ├──────────────────┤  │  │
│  │  Workspaces   │    │  │  SplitNodeView   │  │  │
│  │  └ Worktrees  │    │  │  ┌────┬────────┐ │  │  │
│  │    └ Tabs     │    │  │  │Pane│  Pane  │ │  │  │
│  │               │    │  │  │    ├────────┤ │  │  │
│  │               │    │  │  │    │  Pane  │ │  │  │
│  │               │    │  │  └────┴────────┘ │  │  │
│  └──────────────┘    │  └──────────────────┘  │  │
│                       └────────────────────────┘  │
│                                                   │
├─────────────────────────────────────────────────┤
│              WorkspaceStore (ViewModel)           │
│         (中央状态管理 & 业务逻辑协调)              │
├─────────────────────────────────────────────────┤
│                   Services                       │
│  ┌─────────┐ ┌─────┐ ┌──────┐ ┌─────────────┐  │
│  │Terminal  │ │ SSH │ │ Git  │ │   Sparkle   │  │
│  │(Ghostty) │ │     │ │      │ │  (Updates)  │  │
│  └─────────┘ └─────┘ └──────┘ └─────────────┘  │
└─────────────────────────────────────────────────┘
```

### 核心模块

| 模块 | 职责 |
|------|------|
| **App** | 应用生命周期、窗口管理、中央状态协调 |
| **Domain** | 数据模型定义（Workspace、Pane、Theme、Settings 等） |
| **Services** | 终端引擎、SSH/SFTP、Git、Tmux、自动更新等服务 |
| **UI** | SwiftUI 视图层（侧边栏、面板、设置、弹窗等） |
| **Persistence** | JSON 序列化的会话状态和用户偏好持久化 |

### 终端引擎

Treemux 使用 [GhosttyKit](https://ghostty.org/) 作为底层终端引擎：

- `TreemuxGhosttyController` — 主控制器，管理 Ghostty Surface 生命周期
- `TreemuxGhosttyRuntime` — 运行时初始化与资源加载
- `TreemuxGhosttyInputSupport` — 键盘输入处理
- `TreemuxGhosttyClipboardSupport` — 剪贴板集成

GhosttyKit 以预编译的 `.xcframework` 形式集成，通过 C 接口桥接到 Swift。

---

## 项目结构

```
Treemux/
├── Treemux/                        # 主应用源码
│   ├── main.swift                  # 应用入口
│   ├── AppDelegate.swift           # macOS 应用生命周期
│   ├── App/                        # 应用层（窗口、状态管理）
│   ├── Domain/                     # 领域模型
│   ├── Persistence/                # 持久化层
│   ├── Services/                   # 服务层
│   │   ├── Terminal/Ghostty/       #   Ghostty 终端引擎集成
│   │   ├── SSH/                    #   SSH 连接服务
│   │   ├── SFTP/                   #   SFTP 文件浏览
│   │   ├── Git/                    #   Git 仓库服务
│   │   ├── Tmux/                   #   Tmux 会话检测
│   │   ├── AITool/                 #   AI 工具检测
│   │   └── Updates/                #   Sparkle 自动更新
│   ├── UI/                         # SwiftUI 视图层
│   │   ├── Sidebar/                #   侧边栏组件
│   │   ├── Workspace/              #   工作区 & 面板组件
│   │   ├── Components/             #   通用组件
│   │   ├── Settings/               #   设置面板
│   │   ├── Sheets/                 #   弹窗 & 对话框
│   │   └── Theme/                  #   主题管理
│   ├── Support/                    # 工具类
│   ├── Vendor/                     # 第三方二进制框架
│   │   └── GhosttyKit.xcframework #   Ghostty 终端库
│   ├── ghostty/                    # Ghostty Shell 集成脚本
│   └── terminfo/                   # 终端信息定义
├── TreemuxTests/                   # 单元测试
├── scripts/                        # 构建 & 发布脚本
├── docs/plans/                     # 设计与实现计划文档
├── project.yml                     # XcodeGen 项目配置
├── sparkle-feed.xml                # Sparkle 更新源
└── LICENSE                         # MIT 许可证
```

---

## 依赖项

| 依赖 | 版本 | 用途 |
|------|------|------|
| [GhosttyKit](https://ghostty.org/) | 2.0+ | 终端渲染引擎（预编译 xcframework） |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.9.2+ | SSH 客户端库 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.7.3 | macOS 自动更新框架 |

系统框架依赖：`AppKit`、`SwiftUI`、`Carbon`、`C++`

---

## 开发指南

### 分支管理

- `main` — 主分支，保持稳定
- `stable` — 发布分支，托管 Sparkle 更新源 `sparkle-feed.xml`
- 功能开发请创建独立分支或 Git worktree

### 构建脚本

| 脚本 | 用途 |
|------|------|
| `scripts/build_macos_app.sh` | 编译应用 |
| `scripts/sign_macos.sh` | 代码签名 |
| `scripts/deploy.sh` | 完整发布流程 |
| `scripts/bump_version.sh` | 版本号更新 |
| `scripts/sparkle_tools.sh` | 生成 Sparkle 更新源 |

### 代码规范

- SwiftUI 视图遵循 MVVM 模式
- 通过 `@EnvironmentObject` 注入 `WorkspaceStore`
- 服务层与视图层解耦
- 代码注释使用英文

---

## 许可证

本项目基于 [MIT License](LICENSE) 开源。

Copyright (c) 2026 BatchZero
