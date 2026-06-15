# SSH 配置编辑功能 · 设计文档

- 日期：2026-06-15
- 状态：已确认设计，待写实现计划

## 1. 背景与目标

目前 treemux 对 SSH 配置是**只读**的：`SSHConfigParser` 解析 `~/.ssh/config`，
`SSHConfigService` 加载出 `SSHTarget` 列表供「打开项目 → 远程服务器」的下拉框使用；
「设置 → SSH」只能编辑配置文件路径。

目标：在不破坏用户现有配置文件的前提下，为 SSH 服务器增加**新增 / 编辑 / 删除**能力，
入口覆盖两个界面：

1. **设置 → SSH**：作为管理中心，提供服务器列表与增删改。
2. **打开项目 → 远程服务器**：在选择服务器时就地新增 / 编辑。

### 关键约束（用户确认）

- **编辑方式**：表单为主，并保留「高级原文编辑」入口。
- **写回目标**：外科式编辑原文件——直接改 `~/.ssh/config`，但只动「该动的那一块」，
  保留所有注释、通配符 `Host`、表单不认识的指令（如 `ProxyJump`）。
- **共享编辑窗**：两个入口弹出的编辑窗口必须是**同一个**组件，外观与行为完全一致。
- 增删改是**对文件的即时写入**，不绑定设置页底部的「保存 / 取消」。
- **删除**只放在设置页，避免在「打开项目」时误删。
- 高级原文编辑用简单 `TextEditor` 弹窗（v1 不接内置 CodeEdit）。
- 通配符块（`Host *`）与多模式块（`Host a b`）在受管列表中**只读**，仅可通过原文编辑修改。

## 2. 架构总览

分四层，从底向上：

```
SSHConfigDocument  (纯逻辑：保真解析 + 外科式增删改 + 渲染)
        │
SSHConfigService   (actor：加载条目[带来源文件] / 写入 / 测试连接)
        │
SSHServerEditSheet (共享 SwiftUI 编辑弹窗)
        │
两个入口：SSHSettingsView(管理中心) / OpenProjectSheet(远程)
```

## 3. 数据模型

### 3.1 现有 `SSHTarget`（保持不变）

```swift
struct SSHTarget: Codable, Hashable {
    let host: String        // 解析后的 HostName，回落为别名
    let port: Int
    let user: String?
    let identityFile: String?
    let displayName: String // Host 别名
    let remotePath: String? // 非配置文件字段，打开项目时赋值
}
```

`SSHTarget` 继续作为「连接 / 展示」模型，**不**承担编辑职责。

### 3.2 新增编辑表单模型 `SSHServerDraft`

编辑弹窗的可变草稿：

```swift
struct SSHServerDraft: Equatable {
    var alias: String          // Host
    var hostName: String       // HostName
    var port: Int = 22         // Port
    var user: String = ""      // User（空表示不写）
    var identityFile: String = "" // IdentityFile（空表示不写）
}
```

### 3.3 受管条目 `ManagedSSHEntry`

列表展示用，附带来源文件，供编辑 / 删除定位：

```swift
struct ManagedSSHEntry: Identifiable, Hashable {
    let id: String          // 别名（同一文件内唯一）
    let draft: SSHServerDraft
    let sourcePath: String  // 该条目来自哪个配置文件（已展开的绝对路径）
    let isEditable: Bool    // 单 token 且非通配符 = true；否则只读
}
```

## 4. 核心：`SSHConfigDocument`（保真读写）

纯逻辑类型，不依赖 UI / 文件系统（文件 IO 在 service 层），便于 TDD。

### 4.1 解析

把单个配置文件文本解析为**有序块序列**：

- **Preamble**：第一个 `Host` 之前的所有内容（注释、全局指令），原样保留。
- **HostBlock**：每个 `Host` 行起始，到下一个 `Host` 行（或文件末尾）之前的所有行。
  每个 `HostBlock` 记录：
  - `hostLineTokens`：`Host` 行上的 token（可能多个）。
  - `rawLines`：本块原始行（含注释、空行、未知指令）。
  - `knownDirectiveLines`：HostName / Port / User / IdentityFile 各自所在的行索引（若存在）。
  - `indent`：本块指令行使用的缩进（用于新增指令时风格对齐；默认 4 空格）。
  - `isManaged`：`hostLineTokens.count == 1 && 不含 * ?`。

### 4.2 操作

- `entries() -> [SSHServerDraft]`：仅返回 `isManaged` 块。通配符 / 多模式块不出现在受管列表。
- `add(_ draft:)`：在文件末尾追加规整的新块（前置一个空行分隔）：
  ```
  Host <alias>
      HostName <hostName>
      Port <port>          # 仅当 != 22
      User <user>          # 仅当非空
      IdentityFile <path>  # 仅当非空
  ```
- `update(alias:to draft:)`：定位到该块后，逐字段：
  - 已存在该指令行 → 就地替换值（保留原缩进与行内注释处理从简：覆盖整行）。
  - 不存在但新值非空 → 在块内已知指令区追加一行（用块缩进）。
  - 已存在但新值为空 / 默认（Port=22 视为可省略）→ 删除该指令行。
  - 块内未知指令、注释、空行**一律不动**。
  - 若别名变化，改写 `Host` 行的那一个 token。
- `remove(alias:)`：删除该块的全部行（含块尾多余空行的归一化处理）。
- `render() -> String`：按块顺序重建完整文本。

### 4.3 不变量 / 安全

- 往返保真：未受管块（含 `Host *`、多模式、未知指令、注释）在任意操作后逐字保留。
- 渲染结果末尾恰好一个换行；块间至多一个空行。

## 5. 服务层 `SSHConfigService`（扩展现有 actor）

现有：`loadSSHConfig()`、`testConnection(_:)` 保留。新增：

- `loadEntries() -> [ManagedSSHEntry]`：遍历 `configPaths`，对每个文件用 `SSHConfigDocument`
  解析，给条目打上 `sourcePath`。多文件中同名别名以**先出现者**为准（与现有顺序一致）。
- `add(_ draft:) throws`：写入**主配置路径**（`configPaths.first`，默认 `~/.ssh/config`）。
- `update(_ draft: at sourcePath:) throws`：对来源文件做外科式更新。
- `remove(alias: at sourcePath:) throws`：从来源文件删除。

### 文件写入规则

- **原子写入**：写临时文件 → `rename` 覆盖，避免写一半损坏配置。
- **权限**：保留原文件权限；文件不存在时以 `0600` 创建；必要时 `mkdir -p ~/.ssh`（0700）。
- 写入后调用方负责重新 `loadEntries()` 刷新 UI。

## 6. 共享编辑弹窗 `SSHServerEditSheet`

两个入口共用的同一个 SwiftUI `View`。

- 输入：
  ```swift
  enum Mode { case add; case edit(original: ManagedSSHEntry) }
  ```
  保存成功回调 `onSaved: (SSHTarget) -> Void`。
- 字段：别名 Host、主机 HostName、用户 User、端口 Port（默认 22）、
  密钥文件 IdentityFile（带 `NSOpenPanel` 文件选择器）。
- 校验（保存按钮禁用条件）：
  - 别名非空，且不与现有别名重名（编辑模式排除自身）。
  - 主机非空。
  - 端口在 1–65535。
- 「测试连接」按钮：用当前草稿构造临时 `SSHTarget`，调用 `testConnection`，
  就地展示结果（成功 / 需认证 / 不可达）。
- 「保存」：调用 service 的 add / update，**立即写文件**；成功后 `onSaved` 回传保存后的
  `SSHTarget` 并 `dismiss`。
- 「取消」：直接 `dismiss`。

## 7. 入口一：设置 → SSH（`SSHSettingsView` 改版）

`Form` 内三段：

1. **SSH 服务器**
   - 列出 `ManagedSSHEntry`：每行「别名 + `user@host·端口`」。
   - 可编辑条目：点行 → 弹出编辑弹窗（edit 模式）；行尾删除按钮（带确认）。
   - 只读条目（通配符 / 多模式）：灰显并提示「请用原文编辑修改」。
   - 「＋ 新建服务器」→ 弹出编辑弹窗（add 模式）。
   - 增删改后即时 `loadEntries()` 刷新本列表。
2. **配置文件路径**：保留现有可编辑路径列表（仍走设置页的保存 / 取消）。
3. **高级**：「直接编辑原始配置文件…」→ 弹出 `SSHRawConfigSheet`：
   等宽 `TextEditor` 加载主配置文件全文，提供保存 / 取消（保存同样原子写 + 保权限）。

> 说明：服务器增删改 = 即时文件写入，独立于设置页底部「保存 / 取消」；后者只提交
> `AppSettings`（含配置路径）。这是有意为之，符合 macOS 管理此类列表的习惯。

## 8. 入口二：打开项目 → 远程（`OpenProjectSheet` 调整）

- 保留服务器下拉框与远程路径。
- 下拉框旁新增「＋ 新建」「编辑」按钮 → 弹出**同一个** `SSHServerEditSheet`。
  - 新增 / 编辑成功后：重新加载 targets，并自动选中刚保存的服务器。
- 不提供删除（删除集中在设置页）。

## 9. 国际化

- 所有新增用户可见字符串使用 `LocalizedStringKey`。
- 在 `Treemux/Localizable.xcstrings` 同步补充每条的 `zh-Hans` 翻译。
- 涉及字符串：别名 / 主机 / 用户 / 端口 / 密钥文件 / 新建服务器 / 编辑 / 删除 /
  测试连接 / 连接成功 / 需要认证 / 不可达 / 直接编辑原始配置文件 / 删除确认文案 /
  重名与端口校验提示等。

## 10. 测试

### 单元测试（`SSHConfigDocument`，纯逻辑，TDD）

- 往返保真：含注释 / 空行 / `Host *` / 多模式 / 未知指令（`ProxyJump`）的文件，
  经 parse → render 逐字不变。
- `add`：追加块格式正确；Port=22 / 空 User / 空 IdentityFile 时对应行被省略。
- `update`：就地改值不动其他行；新增缺失指令行用正确缩进；清空字段删除对应行；
  改别名只动 `Host` 行 token；未知指令与注释保留。
- `remove`：只删目标块，相邻块与全局内容不受影响。
- 边界：通配符 / 多模式块不进入 `entries()`、不被增删改触及。

### 服务层测试

- 原子写入后内容正确；新建文件权限为 `0600`；已有文件权限被保留。
- 多文件加载时 `sourcePath` 正确；编辑 / 删除作用于正确文件。

### 手动验证（UI）

- 两入口弹出的编辑窗一致；新建后「打开项目」自动选中新服务器；
  删除确认；只读块灰显；测试连接结果展示；中英文界面无混杂。

## 11. 文件清单（预计）

- 新增：`Treemux/Services/SSH/SSHConfigDocument.swift`
- 新增：`Treemux/UI/Sheets/SSHServerEditSheet.swift`
- 新增：`Treemux/UI/Sheets/SSHRawConfigSheet.swift`
- 修改：`Treemux/Services/SSH/SSHConfigService.swift`（loadEntries / add / update / remove）
- 修改：`Treemux/UI/Settings/SettingsSheet.swift`（`SSHSettingsView` 改版）
- 修改：`Treemux/UI/Sheets/OpenProjectSheet.swift`（新建 / 编辑按钮）
- 修改：`Treemux/Domain/SSHTarget.swift` 或新增模型文件（`SSHServerDraft` / `ManagedSSHEntry`）
- 修改：`Treemux/Localizable.xcstrings`（zh-Hans 翻译）
- 新增：`SSHConfigDocument` 单测文件

## 12. 非目标（YAGNI）

- 不支持 `Match` 块、`Include` 展开后的跨文件编辑（只编辑直接命中的文件）。
- 不接入内置 CodeEdit 做原文编辑（v1 用简单 `TextEditor`）。
- 不做配置文件自动备份（依赖原子写入保证不损坏）。
- 不在「打开项目」提供删除。
