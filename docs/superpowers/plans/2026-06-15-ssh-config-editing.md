# SSH 配置编辑功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 treemux 增加 SSH 服务器的新增 / 编辑 / 删除能力，两个入口（设置→SSH、打开项目→远程）共用同一个编辑弹窗，并以"外科式"方式写回 `~/.ssh/config`，保留注释与未知指令。

**Architecture:** 底层是纯逻辑的 `SSHConfigDocument`（保真解析 / 增删改 / 渲染），上面是 `SSHConfigService`（actor，负责文件 IO、原子写、权限），再上面是共享 SwiftUI 弹窗 `SSHServerEditSheet`，最后由两个入口视图调用。

**Tech Stack:** Swift 5 / SwiftUI / AppKit（NSOpenPanel）/ XCTest，项目用 XcodeGen（`project.yml`）生成 `Treemux.xcodeproj`。

---

## 执行前置（worktree）

按项目规则，所有代码修改必须在新分支 + worktree 内进行。执行本计划前先创建：

```bash
cd /Users/yanu/Documents/code/Terminal/treemux
git worktree add -b feat+ssh-config-editing .worktrees/feat+ssh-config-editing main
cd .worktrees/feat+ssh-config-editing
```

后续所有命令均在该 worktree 目录内执行。

## 通用命令约定

- 新增 `.swift` 源文件后，必须重新生成工程（XcodeGen 按目录收集源文件）：
  ```bash
  xcodegen generate
  ```
- 运行某个测试类：
  ```bash
  xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
    -destination 'platform=macOS' -skipPackagePluginValidation \
    -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -30
  ```
- 编译（UI 任务用）：
  ```bash
  xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
    -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -30
  ```

## 文件结构

| 文件 | 责任 |
| --- | --- |
| `Treemux/Domain/SSHTarget.swift`（修改） | 在末尾追加 `SSHServerDraft`、`ManagedSSHEntry` 两个模型 |
| `Treemux/Services/SSH/SSHConfigDocument.swift`（新增） | 保真解析 / 增删改 / 渲染，纯逻辑 |
| `Treemux/Services/SSH/SSHConfigService.swift`（修改） | 新增 `loadManagedEntries` / `add` / `update` / `remove` + 原子写 |
| `Treemux/UI/Sheets/SSHServerEditSheet.swift`（新增） | 两入口共享的编辑弹窗 |
| `Treemux/UI/Sheets/SSHRawConfigSheet.swift`（新增） | 高级：原文文本编辑弹窗 |
| `Treemux/UI/Settings/SettingsSheet.swift`（修改） | `SSHSettingsView` 改版：服务器列表 + 增删改 + 原文入口 |
| `Treemux/UI/Sheets/OpenProjectSheet.swift`（修改） | 远程模式加「新建 / 编辑」按钮 |
| `Treemux/Localizable.xcstrings`（修改） | 补 zh-Hans 翻译 |
| `TreemuxTests/SSHConfigDocumentTests.swift`（新增） | `SSHConfigDocument` 单测 |
| `TreemuxTests/SSHConfigServiceWriteTests.swift`（新增） | 文件读写单测 |

---

## Task 1: 编辑模型 `SSHServerDraft` / `ManagedSSHEntry`

**Files:**
- Modify: `Treemux/Domain/SSHTarget.swift`

- [ ] **Step 1: 在 `SSHTarget.swift` 末尾追加两个模型**

在文件末尾（第 17 行 `}` 之后）追加：

```swift

// MARK: - Editable SSH models

/// Mutable draft used by the shared edit sheet. Empty `user` / `identityFile`
/// mean the directive is not written. `port == 22` is treated as the default
/// and omitted on write.
struct SSHServerDraft: Equatable, Hashable {
    var alias: String
    var hostName: String
    var port: Int = 22
    var user: String = ""
    var identityFile: String = ""
}

/// A host entry surfaced in the management list, tagged with its source file.
/// `isEditable` is false for wildcard (`Host *`) or multi-pattern (`Host a b`)
/// blocks — those are shown read-only and only editable via raw editing.
struct ManagedSSHEntry: Identifiable, Hashable {
    let id: String          // "<sourcePath>::<alias>"
    let draft: SSHServerDraft
    let sourcePath: String  // expanded absolute path of the config file
    let isEditable: Bool
}
```

- [ ] **Step 2: 编译确认无语法错误**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Treemux/Domain/SSHTarget.swift
git commit -m "feat(ssh): add SSHServerDraft and ManagedSSHEntry models"
```

---

## Task 2: `SSHConfigDocument` 解析 / 渲染 / 分类

**Files:**
- Create: `Treemux/Services/SSH/SSHConfigDocument.swift`
- Test: `TreemuxTests/SSHConfigDocumentTests.swift`

- [ ] **Step 1: 写失败测试（往返保真 + 分类）**

创建 `TreemuxTests/SSHConfigDocumentTests.swift`：

```swift
//
//  SSHConfigDocumentTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHConfigDocumentTests: XCTestCase {

    func testRoundTripPreservesUnmanagedContent() {
        let config = """
        # global
        Host *
            ForwardAgent yes

        Host server1
            HostName 1.2.3.4
            Port 2222
            # inline note
            ProxyJump bastion
        """
        let doc = SSHConfigDocument(contents: config)
        XCTAssertEqual(doc.render(), config)
    }

    func testAllEntriesClassifiesManaged() {
        let config = """
        Host *
            ForwardAgent yes
        Host server1
            HostName 1.2.3.4
            User bob
        Host alpha beta
            HostName multi
        """
        let entries = SSHConfigDocument(contents: config).allEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries[0].isEditable)        // Host *
        XCTAssertTrue(entries[1].isEditable)
        XCTAssertEqual(entries[1].draft.alias, "server1")
        XCTAssertEqual(entries[1].draft.hostName, "1.2.3.4")
        XCTAssertEqual(entries[1].draft.user, "bob")
        XCTAssertEqual(entries[1].draft.port, 22)
        XCTAssertFalse(entries[2].isEditable)        // multi-pattern
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
xcodegen generate && xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -20
```
Expected: 编译失败 / `cannot find 'SSHConfigDocument' in scope`

- [ ] **Step 3: 实现 `SSHConfigDocument`（解析 / 渲染 / 分类 + 私有 helper）**

创建 `Treemux/Services/SSH/SSHConfigDocument.swift`：

```swift
//
//  SSHConfigDocument.swift
//  Treemux
//

import Foundation

/// A fidelity-preserving, line-based model of an OpenSSH config file.
/// Parsing keeps every line verbatim; mutations only touch the relevant block,
/// leaving comments, wildcard hosts, and unknown directives untouched.
struct SSHConfigDocument {

    /// One entry surfaced to the UI (without source-file info).
    struct Entry: Equatable {
        let draft: SSHServerDraft
        let isEditable: Bool
    }

    /// Internal description of a `Host` block's line range.
    private struct HostBlock {
        let tokens: [String]   // tokens after the `Host` keyword
        let start: Int         // index of the `Host` line
        let end: Int           // exclusive
        var alias: String { tokens.first ?? "" }
        var isEditable: Bool {
            tokens.count == 1 && !tokens[0].contains("*") && !tokens[0].contains("?")
        }
    }

    private(set) var lines: [String]

    init(contents: String) {
        lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
    }

    /// Reconstruct the full file text verbatim.
    func render() -> String {
        lines.joined(separator: "\n")
    }

    /// All host blocks, in file order, classified by editability.
    func allEntries() -> [Entry] {
        hostBlocks().map { block in
            Entry(draft: draft(for: block, editable: block.isEditable),
                  isEditable: block.isEditable)
        }
    }

    // MARK: - Parsing helpers

    /// Parse a line into (lowercased keyword, value). Returns nil for blanks/comments.
    static func directive(of line: String) -> (keyword: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let range = trimmed.rangeOfCharacter(from: .whitespaces) {
            let keyword = String(trimmed[..<range.lowerBound]).lowercased()
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (keyword, value)
        }
        return (trimmed.lowercased(), "")
    }

    private func hostBlocks() -> [HostBlock] {
        var blocks: [HostBlock] = []
        var start: Int?
        var tokens: [String] = []
        for (i, line) in lines.enumerated() {
            if let d = Self.directive(of: line), d.keyword == "host" {
                if let s = start {
                    blocks.append(HostBlock(tokens: tokens, start: s, end: i))
                }
                start = i
                tokens = d.value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
        }
        if let s = start {
            blocks.append(HostBlock(tokens: tokens, start: s, end: lines.count))
        }
        return blocks
    }

    private func draft(for block: HostBlock, editable: Bool) -> SSHServerDraft {
        let aliasForDisplay = editable ? block.alias : block.tokens.joined(separator: " ")
        var d = SSHServerDraft(alias: aliasForDisplay, hostName: "")
        for i in block.start..<block.end {
            guard let dir = Self.directive(of: lines[i]) else { continue }
            switch dir.keyword {
            case "hostname": d.hostName = dir.value
            case "port": d.port = Int(dir.value) ?? 22
            case "user": d.user = dir.value
            case "identityfile": d.identityFile = dir.value
            default: break
            }
        }
        return d
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```bash
xcodegen generate && xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SSH/SSHConfigDocument.swift TreemuxTests/SSHConfigDocumentTests.swift Treemux.xcodeproj
git commit -m "feat(ssh): add SSHConfigDocument parse/render/classify"
```

---

## Task 3: `SSHConfigDocument.add`

**Files:**
- Modify: `Treemux/Services/SSH/SSHConfigDocument.swift`
- Test: `TreemuxTests/SSHConfigDocumentTests.swift`

- [ ] **Step 1: 写失败测试**

在 `SSHConfigDocumentTests` 类内追加：

```swift
    func testAddAppendsBlockWithSeparator() {
        var doc = SSHConfigDocument(contents: "Host existing\n    HostName 1.1.1.1")
        doc.add(SSHServerDraft(alias: "newsrv", hostName: "2.2.2.2", port: 2200,
                               user: "carol", identityFile: "~/.ssh/k"))
        let expected = """
        Host existing
            HostName 1.1.1.1

        Host newsrv
            HostName 2.2.2.2
            Port 2200
            User carol
            IdentityFile ~/.ssh/k
        """
        XCTAssertEqual(doc.render(), expected)
    }

    func testAddOmitsDefaultsAndUserOnEmptyFile() {
        var doc = SSHConfigDocument(contents: "")
        doc.add(SSHServerDraft(alias: "x", hostName: "h"))
        XCTAssertEqual(doc.render(), "Host x\n    HostName h")
    }
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests/testAddAppendsBlockWithSeparator 2>&1 | tail -15
```
Expected: 编译失败 / `value of type 'SSHConfigDocument' has no member 'add'`

- [ ] **Step 3: 实现 `add`**

在 `SSHConfigDocument` 中、`render()` 之后追加：

```swift
    // MARK: - Mutations

    /// Append a well-formatted block at the end of the file.
    mutating func add(_ draft: SSHServerDraft) {
        // Trim trailing blank lines, then add exactly one separator if non-empty.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var block: [String] = []
        if !lines.isEmpty { block.append("") }
        block.append("Host \(draft.alias)")
        block.append("    HostName \(draft.hostName)")
        if draft.port != 22 { block.append("    Port \(draft.port)") }
        if !draft.user.isEmpty { block.append("    User \(draft.user)") }
        if !draft.identityFile.isEmpty { block.append("    IdentityFile \(draft.identityFile)") }
        lines.append(contentsOf: block)
    }
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SSH/SSHConfigDocument.swift TreemuxTests/SSHConfigDocumentTests.swift
git commit -m "feat(ssh): SSHConfigDocument.add appends formatted block"
```

---

## Task 4: `SSHConfigDocument.update`

**Files:**
- Modify: `Treemux/Services/SSH/SSHConfigDocument.swift`
- Test: `TreemuxTests/SSHConfigDocumentTests.swift`

- [ ] **Step 1: 写失败测试**

在 `SSHConfigDocumentTests` 类内追加：

```swift
    func testUpdateInPlacePreservesUnknownDirectives() {
        let config = """
        Host srv
            HostName old.com
            # keep me
            ProxyJump bastion
            Port 22
        """
        var doc = SSHConfigDocument(contents: config)
        doc.update(alias: "srv",
                   to: SSHServerDraft(alias: "srv", hostName: "new.com", port: 2222,
                                      user: "u", identityFile: ""))
        let expected = """
        Host srv
            HostName new.com
            # keep me
            ProxyJump bastion
            Port 2222
            User u
        """
        XCTAssertEqual(doc.render(), expected)
    }

    func testUpdateRenamesAliasOnly() {
        var doc = SSHConfigDocument(contents: "Host old\n    HostName h.com")
        doc.update(alias: "old", to: SSHServerDraft(alias: "new", hostName: "h.com"))
        XCTAssertEqual(doc.render(), "Host new\n    HostName h.com")
    }

    func testUpdateClearingUserRemovesLine() {
        let config = "Host s\n    HostName h\n    User bob"
        var doc = SSHConfigDocument(contents: config)
        doc.update(alias: "s", to: SSHServerDraft(alias: "s", hostName: "h", user: ""))
        XCTAssertEqual(doc.render(), "Host s\n    HostName h")
    }
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests/testUpdateInPlacePreservesUnknownDirectives 2>&1 | tail -15
```
Expected: 编译失败 / `no member 'update'`

- [ ] **Step 3: 实现 `update` 及其私有 helper**

在 `add(_:)` 之后追加：

```swift
    /// Surgically update a managed block's known directives in place.
    mutating func update(alias: String, to draft: SSHServerDraft) {
        guard hostBlocks().contains(where: { $0.isEditable && $0.alias == alias }) else { return }
        setDirective(blockAlias: alias, keyword: "HostName",
                     value: draft.hostName.isEmpty ? nil : draft.hostName)
        setDirective(blockAlias: alias, keyword: "Port",
                     value: draft.port == 22 ? nil : String(draft.port))
        setDirective(blockAlias: alias, keyword: "User",
                     value: draft.user.isEmpty ? nil : draft.user)
        setDirective(blockAlias: alias, keyword: "IdentityFile",
                     value: draft.identityFile.isEmpty ? nil : draft.identityFile)
        // Rename last so the lookups above still resolve by the original alias.
        if draft.alias != alias,
           let block = hostBlocks().first(where: { $0.isEditable && $0.alias == alias }) {
            lines[block.start] = replaceHostToken(lines[block.start], with: draft.alias)
        }
    }

    /// Set / insert / remove a single known directive within a block.
    /// `value == nil` removes the line if present; otherwise replaces or appends.
    private mutating func setDirective(blockAlias: String, keyword: String, value: String?) {
        guard let block = hostBlocks().first(where: { $0.isEditable && $0.alias == blockAlias })
        else { return }

        var existing: Int?
        for i in block.start..<block.end {
            if let d = Self.directive(of: lines[i]), d.keyword == keyword.lowercased() {
                existing = i
                break
            }
        }

        if let value {
            let newLine = "\(blockIndent(block))\(keyword) \(value)"
            if let idx = existing {
                lines[idx] = newLine
            } else {
                // Append after the last non-blank line of the block.
                var insertAt = block.start + 1
                for i in (block.start + 1)..<block.end
                where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertAt = i + 1
                }
                lines.insert(newLine, at: insertAt)
            }
        } else if let idx = existing {
            lines.remove(at: idx)
        }
    }

    /// Indentation used by directive lines in the block (default 4 spaces).
    private func blockIndent(_ block: HostBlock) -> String {
        for i in (block.start + 1)..<block.end where Self.directive(of: lines[i]) != nil {
            let ws = lines[i].prefix { $0 == " " || $0 == "\t" }
            return ws.isEmpty ? "    " : String(ws)
        }
        return "    "
    }

    /// Replace the single host token on a `Host` line, preserving leading
    /// whitespace and the original keyword text.
    private func replaceHostToken(_ line: String, with newAlias: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(leading.count)
        if let range = rest.rangeOfCharacter(from: .whitespaces) {
            let keyword = rest[..<range.lowerBound]
            return "\(leading)\(keyword) \(newAlias)"
        }
        return "\(leading)Host \(newAlias)"
    }
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SSH/SSHConfigDocument.swift TreemuxTests/SSHConfigDocumentTests.swift
git commit -m "feat(ssh): SSHConfigDocument.update surgical in-place edit"
```

---

## Task 5: `SSHConfigDocument.remove`

**Files:**
- Modify: `Treemux/Services/SSH/SSHConfigDocument.swift`
- Test: `TreemuxTests/SSHConfigDocumentTests.swift`

- [ ] **Step 1: 写失败测试**

在 `SSHConfigDocumentTests` 类内追加：

```swift
    func testRemoveDeletesBlockOnly() {
        let config = """
        Host a
            HostName a.com

        Host b
            HostName b.com
        """
        var doc = SSHConfigDocument(contents: config)
        doc.remove(alias: "a")
        XCTAssertEqual(doc.render(), "Host b\n    HostName b.com")
    }

    func testRemoveLeavesTrailingBlock() {
        let config = """
        Host a
            HostName a.com

        Host b
            HostName b.com
        """
        var doc = SSHConfigDocument(contents: config)
        doc.remove(alias: "b")
        XCTAssertEqual(doc.render(), "Host a\n    HostName a.com")
    }
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests/testRemoveDeletesBlockOnly 2>&1 | tail -15
```
Expected: 编译失败 / `no member 'remove'`

- [ ] **Step 3: 实现 `remove` + 空行归一化**

在 `update(...)` 之后、`setDirective` 之前（或任意 mutations 区内）追加：

```swift
    /// Remove a managed block entirely, then collapse blank-line runs.
    mutating func remove(alias: String) {
        guard let block = hostBlocks().first(where: { $0.isEditable && $0.alias == alias })
        else { return }
        lines.removeSubrange(block.start..<block.end)
        normalizeBlankRuns()
    }

    /// Collapse consecutive blank lines to one and drop leading blanks.
    private mutating func normalizeBlankRuns() {
        var result: [String] = []
        var prevBlank = false
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && prevBlank { continue }
            result.append(line)
            prevBlank = blank
        }
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeFirst()
        }
        lines = result
    }
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Treemux/Services/SSH/SSHConfigDocument.swift TreemuxTests/SSHConfigDocumentTests.swift
git commit -m "feat(ssh): SSHConfigDocument.remove deletes block and tidies blanks"
```

---

## Task 6: `SSHConfigService` 文件读写

**Files:**
- Modify: `Treemux/Services/SSH/SSHConfigService.swift`
- Test: `TreemuxTests/SSHConfigServiceWriteTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `TreemuxTests/SSHConfigServiceWriteTests.swift`：

```swift
//
//  SSHConfigServiceWriteTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHConfigServiceWriteTests: XCTestCase {

    private func makeTempConfigPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config").path
    }

    func testAddCreatesFileWith0600() async throws {
        let path = try makeTempConfigPath()
        let service = SSHConfigService(configPaths: [path])
        try await service.add(SSHServerDraft(alias: "s", hostName: "h"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("Host s"))
        XCTAssertTrue(content.hasSuffix("\n"))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testLoadManagedEntriesTagsSourcePath() async throws {
        let path = try makeTempConfigPath()
        try "Host one\n    HostName 1.1.1.1\nHost *\n    ForwardAgent yes"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let service = SSHConfigService(configPaths: [path])

        let entries = await service.loadManagedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].draft.alias, "one")
        XCTAssertEqual(entries[0].sourcePath, path)
        XCTAssertTrue(entries[0].isEditable)
        XCTAssertFalse(entries[1].isEditable)
    }

    func testUpdateAndRemoveRoundTrip() async throws {
        let path = try makeTempConfigPath()
        try "Host s\n    HostName old\n    # note"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let service = SSHConfigService(configPaths: [path])

        try await service.update(SSHServerDraft(alias: "s", hostName: "new"),
                                 originalAlias: "s", atSourcePath: path)
        var content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("HostName new"))
        XCTAssertTrue(content.contains("# note"))   // unknown content preserved

        try await service.remove(alias: "s", atSourcePath: path)
        content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(content.contains("Host s"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run:
```bash
xcodegen generate && xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/SSHConfigServiceWriteTests 2>&1 | tail -20
```
Expected: 编译失败 / `no member 'add'`

- [ ] **Step 3: 在 `SSHConfigService` 内实现读写方法**

在 `SSHConfigService` actor 内、`testConnection(_:)` 之前追加：

```swift
    // MARK: - Managed entries (editing)

    /// Load all host blocks across config files, tagged with source path.
    /// First occurrence of an alias wins (mirrors load ordering).
    func loadManagedEntries() -> [ManagedSSHEntry] {
        var result: [ManagedSSHEntry] = []
        var seen = Set<String>()
        for path in configPaths {
            let expanded = (path as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            for entry in SSHConfigDocument(contents: contents).allEntries() {
                let alias = entry.draft.alias
                guard !seen.contains(alias) else { continue }
                seen.insert(alias)
                result.append(ManagedSSHEntry(
                    id: "\(expanded)::\(alias)",
                    draft: entry.draft,
                    sourcePath: expanded,
                    isEditable: entry.isEditable
                ))
            }
        }
        return result
    }

    /// Add a new server to the primary config file.
    func add(_ draft: SSHServerDraft) throws {
        let primary = (configPaths.first ?? "~/.ssh/config" as NSString).expandingTildeInPath
        try mutate(path: primary) { $0.add(draft) }
    }

    /// Update an existing server in its source file.
    func update(_ draft: SSHServerDraft, originalAlias: String, atSourcePath sourcePath: String) throws {
        try mutate(path: (sourcePath as NSString).expandingTildeInPath) {
            $0.update(alias: originalAlias, to: draft)
        }
    }

    /// Remove a server from its source file.
    func remove(alias: String, atSourcePath sourcePath: String) throws {
        try mutate(path: (sourcePath as NSString).expandingTildeInPath) {
            $0.remove(alias: alias)
        }
    }

    // MARK: - File IO

    private func mutate(path: String, _ transform: (inout SSHConfigDocument) -> Void) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var doc = SSHConfigDocument(contents: existing)
        transform(&doc)
        try writeAtomically(doc.render(), to: path)
    }

    private func writeAtomically(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        let perms = (fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600

        var data = Data(text.utf8)
        if text.last != "\n" { data.append(0x0A) }  // ensure trailing newline

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
```

注意：`attributesOfItem(atPath:)` 是 `throws`，上面用在不存在文件时会抛错；用 `try?` 包一层——把那一行改为：

```swift
        let perms = ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
```

- [ ] **Step 4: 运行确认通过**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigServiceWriteTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: 跑全量 SSH 单测确保无回归**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SSHConfigDocumentTests \
  -only-testing:TreemuxTests/SSHConfigServiceWriteTests \
  -only-testing:TreemuxTests/SSHConfigParserTests 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Treemux/Services/SSH/SSHConfigService.swift TreemuxTests/SSHConfigServiceWriteTests.swift Treemux.xcodeproj
git commit -m "feat(ssh): SSHConfigService managed-entry load + atomic write"
```

---

## Task 7: 共享编辑弹窗 `SSHServerEditSheet`

**Files:**
- Create: `Treemux/UI/Sheets/SSHServerEditSheet.swift`

- [ ] **Step 1: 创建弹窗视图**

创建 `Treemux/UI/Sheets/SSHServerEditSheet.swift`：

```swift
//
//  SSHServerEditSheet.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Shared add/edit form for an SSH server. Presented identically from both the
/// Settings → SSH list and the Open Project → Remote dialog.
struct SSHServerEditSheet: View {
    enum Mode: Equatable {
        case add
        case edit(ManagedSSHEntry)
    }

    let mode: Mode
    /// Aliases already present, for uniqueness validation.
    let existingAliases: [String]
    let service: SSHConfigService
    /// Called after a successful save with the resulting connection target.
    let onSaved: (SSHTarget) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: SSHServerDraft
    @State private var portText: String
    @State private var testResult: LocalizedStringKey?
    @State private var isTesting = false
    @State private var saveError: String?

    init(mode: Mode,
         existingAliases: [String],
         service: SSHConfigService,
         onSaved: @escaping (SSHTarget) -> Void) {
        self.mode = mode
        self.existingAliases = existingAliases
        self.service = service
        self.onSaved = onSaved
        switch mode {
        case .add:
            _draft = State(initialValue: SSHServerDraft(alias: "", hostName: ""))
            _portText = State(initialValue: "22")
        case .edit(let entry):
            _draft = State(initialValue: entry.draft)
            _portText = State(initialValue: String(entry.draft.port))
        }
    }

    private var originalAlias: String? {
        if case .edit(let e) = mode { return e.draft.alias }
        return nil
    }

    private var isValid: Bool {
        let alias = draft.alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty,
              !draft.hostName.trimmingCharacters(in: .whitespaces).isEmpty,
              let port = Int(portText), (1...65535).contains(port) else { return false }
        let collision = existingAliases.contains { $0 == alias && $0 != originalAlias }
        return !collision
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .add ? "New Server" : "Edit Server")
                .font(.headline)

            Form {
                TextField("Alias (Host)", text: $draft.alias)
                TextField("Host (HostName)", text: $draft.hostName)
                HStack {
                    TextField("User", text: $draft.user)
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                }
                HStack {
                    TextField("Identity File", text: $draft.identityFile)
                    Button("Choose…") { chooseIdentityFile() }
                }
            }
            .formStyle(.grouped)

            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Test Connection") { Task { await testConnection() } }
                    .disabled(isTesting || draft.hostName.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private func target(from d: SSHServerDraft) -> SSHTarget {
        SSHTarget(
            host: d.hostName,
            port: Int(portText) ?? 22,
            user: d.user.isEmpty ? nil : d.user,
            identityFile: d.identityFile.isEmpty ? nil : d.identityFile,
            displayName: d.alias,
            remotePath: nil
        )
    }

    private func testConnection() async {
        isTesting = true
        testResult = "Testing…"
        let status = await service.testConnection(target(from: draft))
        switch status {
        case .connected: testResult = "Connected"
        case .authRequired: testResult = "Authentication required"
        case .unreachable: testResult = "Unreachable"
        }
        isTesting = false
    }

    private func save() {
        var toSave = draft
        toSave.alias = draft.alias.trimmingCharacters(in: .whitespaces)
        toSave.port = Int(portText) ?? 22
        Task {
            do {
                switch mode {
                case .add:
                    try await service.add(toSave)
                case .edit(let entry):
                    try await service.update(toSave,
                                             originalAlias: entry.draft.alias,
                                             atSourcePath: entry.sourcePath)
                }
                onSaved(target(from: toSave))
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 2: 生成工程并编译**

Run:
```bash
xcodegen generate && xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/Sheets/SSHServerEditSheet.swift Treemux.xcodeproj
git commit -m "feat(ssh): add shared SSHServerEditSheet"
```

---

## Task 8: 设置 → SSH 改版 + 原文编辑弹窗

**Files:**
- Create: `Treemux/UI/Sheets/SSHRawConfigSheet.swift`
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:301-314`

- [ ] **Step 1: 创建原文编辑弹窗**

创建 `Treemux/UI/Sheets/SSHRawConfigSheet.swift`：

```swift
//
//  SSHRawConfigSheet.swift
//  Treemux
//

import SwiftUI

/// Advanced raw-text editor for the primary SSH config file. Saves atomically
/// via SSHConfigService's writer (same fidelity guarantees).
struct SSHRawConfigSheet: View {
    let path: String                 // expanded absolute path
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Edit Raw Config File").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 520, minHeight: 360)
                .border(.quaternary)

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .task { load() }
    }

    private func load() {
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        do {
            // Reuse atomic write by routing through a throwaway document that
            // replaces the whole file content.
            try SSHConfigRawWriter.write(text, to: path)
            dismiss()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: 暴露一个可复用的原子写入入口**

`SSHRawConfigSheet` 不在 actor 内，需要一个同步的原子写函数。在
`Treemux/Services/SSH/SSHConfigDocument.swift` 末尾追加一个独立 helper（纯文件 IO，不依赖 actor）：

```swift

/// Standalone atomic writer for raw config text, reused by the raw editor.
enum SSHConfigRawWriter {
    static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let perms = ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        var data = Data(text.utf8)
        if text.last != "\n" { data.append(0x0A) }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
```

并把 Task 6 中 `SSHConfigService.writeAtomically` 的函数体替换为对它的调用，避免重复（DRY）：

```swift
    private func writeAtomically(_ text: String, to path: String) throws {
        try SSHConfigRawWriter.write(text, to: path)
    }
```

- [ ] **Step 3: 改写 `SSHSettingsView`**

把 `SettingsSheet.swift` 中现有的 `SSHSettingsView`（第 301–314 行）整体替换为：

```swift
private struct SSHSettingsView: View {
    @Binding var settings: AppSettings

    @State private var entries: [ManagedSSHEntry] = []
    @State private var editSheet: SSHServerEditSheet.Mode?
    @State private var showRawEditor = false
    @State private var pendingDelete: ManagedSSHEntry?

    private var service: SSHConfigService {
        SSHConfigService(configPaths: settings.ssh.configPaths)
    }

    private var primaryPath: String {
        (settings.ssh.configPaths.first ?? "~/.ssh/config" as NSString).expandingTildeInPath
    }

    var body: some View {
        Form {
            Section("SSH Servers") {
                if entries.isEmpty {
                    Text("No SSH hosts found")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    serverRow(entry)
                }
                Button {
                    editSheet = .add
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }

            Section("SSH Config Paths") {
                ForEach(settings.ssh.configPaths.indices, id: \.self) { index in
                    TextField("Path", text: $settings.ssh.configPaths[index])
                }
            }

            Section("Advanced") {
                Button("Edit Raw Config File…") { showRawEditor = true }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(item: $editSheet) { mode in
            SSHServerEditSheet(
                mode: mode,
                existingAliases: entries.map { $0.draft.alias },
                service: service
            ) { _ in
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showRawEditor, onDismiss: { Task { await reload() } }) {
            SSHRawConfigSheet(path: primaryPath)
        }
        .confirmationDialog(
            "Delete this server?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    try? await service.remove(alias: entry.draft.alias, atSourcePath: entry.sourcePath)
                    await reload()
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ entry: ManagedSSHEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.draft.alias)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isEditable {
                Button("Edit") { editSheet = .edit(entry) }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { pendingDelete = entry } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Read-only · edit in raw file")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(entry.isEditable ? 1 : 0.55)
    }

    private func subtitle(for entry: ManagedSSHEntry) -> String {
        let d = entry.draft
        let host = d.hostName.isEmpty ? d.alias : d.hostName
        var parts: [String] = []
        if !d.user.isEmpty { parts.append("\(d.user)@\(host)") } else { parts.append(host) }
        parts.append("Port \(d.port)")
        if !d.identityFile.isEmpty { parts.append(d.identityFile) }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        entries = await service.loadManagedEntries()
    }
}
```

注意：`@State private var editSheet: SSHServerEditSheet.Mode?` 通过 `.sheet(item:)` 呈现，
要求 `Mode` 满足 `Identifiable`。在 `SSHServerEditSheet.swift` 的 `Mode` 定义后追加扩展：

```swift
extension SSHServerEditSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let entry): return "edit:\(entry.id)"
        }
    }
}
```

- [ ] **Step 4: 生成工程并编译**

Run:
```bash
xcodegen generate && xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Sheets/SSHRawConfigSheet.swift Treemux/UI/Settings/SettingsSheet.swift \
  Treemux/Services/SSH/SSHConfigDocument.swift Treemux/Services/SSH/SSHConfigService.swift \
  Treemux/UI/Sheets/SSHServerEditSheet.swift Treemux.xcodeproj
git commit -m "feat(ssh): rework Settings SSH with server list, delete, raw editor"
```

---

## Task 9: 打开项目 → 远程：新建 / 编辑按钮

**Files:**
- Modify: `Treemux/UI/Sheets/OpenProjectSheet.swift:100-147`

- [ ] **Step 1: 在 remote 模式加入按钮与共享弹窗**

把 `remoteModeView`（第 100–147 行）替换为：

```swift
    private var remoteModeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingTargets {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if sshTargets.isEmpty {
                Text("No SSH hosts found in ~/.ssh/config")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Server:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedTargetIndex) {
                    ForEach(sshTargets.indices, id: \.self) { index in
                        let target = sshTargets[index]
                        Text(targetLabel(target))
                            .tag(index)
                    }
                }
                .labelsHidden()

                Text("Remote Path:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("/home/user/project", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        showRemoteBrowser = true
                    }
                    .disabled(sshTargets.isEmpty)
                }
            }

            HStack {
                Button {
                    serverEditMode = .add
                } label: {
                    Label("New", systemImage: "plus")
                }
                Button("Edit") {
                    if let entry = selectedManagedEntry() {
                        serverEditMode = .edit(entry)
                    }
                }
                .disabled(selectedManagedEntry()?.isEditable != true)
                Spacer()
            }
        }
        .sheet(isPresented: $showRemoteBrowser) {
            if selectedTargetIndex < sshTargets.count {
                RemoteDirectoryBrowser(
                    sshTarget: sshTargets[selectedTargetIndex]
                ) { selectedPath in
                    remotePath = selectedPath
                }
                .environment(\.locale, languageManager.locale)
            }
        }
        .sheet(item: $serverEditMode) { mode in
            SSHServerEditSheet(
                mode: mode,
                existingAliases: managedEntries.map { $0.draft.alias },
                service: SSHConfigService(configPaths: store.settings.ssh.configPaths)
            ) { savedTarget in
                Task { await loadSSHTargets(selecting: savedTarget.displayName) }
            }
        }
    }
```

- [ ] **Step 2: 新增状态与辅助逻辑**

在 `OpenProjectSheet` 的状态声明区（第 26–30 行附近 `@State private var showRemoteBrowser = false` 之后）追加：

```swift
    @State private var managedEntries: [ManagedSSHEntry] = []
    @State private var serverEditMode: SSHServerEditSheet.Mode?
```

把现有 `loadSSHTargets()`（第 201–206 行）替换为支持"加载后选中指定别名"的版本：

```swift
    private func loadSSHTargets(selecting alias: String? = nil) async {
        isLoadingTargets = true
        let service = SSHConfigService(configPaths: store.settings.ssh.configPaths)
        sshTargets = await service.loadSSHConfig()
        managedEntries = await service.loadManagedEntries()
        if let alias, let idx = sshTargets.firstIndex(where: { $0.displayName == alias }) {
            selectedTargetIndex = idx
        } else if selectedTargetIndex >= sshTargets.count {
            selectedTargetIndex = 0
        }
        isLoadingTargets = false
    }

    /// The managed entry corresponding to the currently selected picker target.
    private func selectedManagedEntry() -> ManagedSSHEntry? {
        guard selectedTargetIndex < sshTargets.count else { return nil }
        let alias = sshTargets[selectedTargetIndex].displayName
        return managedEntries.first { $0.draft.alias == alias }
    }
```

`.task { await loadSSHTargets() }`（第 69–71 行）保持不变（默认参数 `selecting: nil`）。

- [ ] **Step 3: 生成工程并编译**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/Sheets/OpenProjectSheet.swift
git commit -m "feat(ssh): add new/edit server buttons to Open Project remote mode"
```

---

## Task 10: 国际化（zh-Hans 翻译）

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

本任务为前面新增的所有用户可见英文字符串补中文翻译。`Localizable.xcstrings` 是 JSON，
`sourceLanguage` 为 `en`；每个 key 形如：

```json
"New Server" : {
  "localizations" : {
    "zh-Hans" : {
      "stringUnit" : { "state" : "translated", "value" : "新建服务器" }
    }
  }
}
```

- [ ] **Step 1: 用脚本批量插入翻译**

在 worktree 根目录运行以下 Python 脚本（幂等：已存在的 key 会被覆盖为给定翻译）：

```bash
python3 - <<'PY'
import json
path = "Treemux/Localizable.xcstrings"
data = json.load(open(path, encoding="utf-8"))
tr = {
    "New Server": "新建服务器",
    "Edit Server": "编辑服务器",
    "Alias (Host)": "别名 (Host)",
    "Host (HostName)": "主机 (HostName)",
    "User": "用户",
    "Port": "端口",
    "Identity File": "密钥文件",
    "Choose…": "选择…",
    "Test Connection": "测试连接",
    "Testing…": "测试中…",
    "Connected": "连接成功",
    "Authentication required": "需要认证",
    "Unreachable": "无法连接",
    "SSH Servers": "SSH 服务器",
    "No SSH hosts found": "未找到 SSH 主机",
    "Advanced": "高级",
    "Edit Raw Config File…": "直接编辑原始配置文件…",
    "Edit Raw Config File": "编辑原始配置文件",
    "Read-only · edit in raw file": "只读 · 请用原文编辑",
    "Delete this server?": "确定删除该服务器？",
    "New": "新建",
    "Edit": "编辑",
    "Delete": "删除",
}
strings = data.setdefault("strings", {})
for key, value in tr.items():
    entry = strings.setdefault(key, {})
    loc = entry.setdefault("localizations", {})
    loc["zh-Hans"] = {"stringUnit": {"state": "translated", "value": value}}
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("done; total strings:", len(strings))
PY
```

- [ ] **Step 2: 校验 JSON 合法 + 关键 key 已译**

Run:
```bash
python3 -c "
import json
d=json.load(open('Treemux/Localizable.xcstrings'))
for k in ['New Server','Test Connection','Edit Raw Config File…','SSH Servers']:
    print(k, '->', d['strings'][k]['localizations']['zh-Hans']['stringUnit']['value'])
"
```
Expected: 打印出四个中文翻译，无异常。

- [ ] **Step 3: 编译确认 xcstrings 仍被正确打包**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n(ssh): add zh-Hans translations for SSH editing UI"
```

---

## Task 11: 全量验证

**Files:** 无（仅验证）

- [ ] **Step 1: 跑全部单测**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`，无失败用例。

- [ ] **Step 2: 手动验证（参照 CLAUDE.md 运行 app）**

构建 Debug 后按 CLAUDE.md 指引运行 app，逐项确认：

- 设置 → SSH：服务器列表显示正确；「新建服务器」弹出共享弹窗；新增后列表刷新。
- 编辑某服务器：弹窗预填字段；改 HostName / Port / User / 密钥后保存；
  用编辑器或 `cat ~/.ssh/config` 确认注释、`Host *`、未知指令（如 `ProxyJump`）仍在。
- 删除服务器：确认对话框出现；确认后该块从文件消失，其他块不动。
- 通配符 / 多模式块在列表中灰显且无编辑 / 删除按钮。
- 「直接编辑原始配置文件…」打开原文、保存生效。
- 打开项目 → 远程：「新建」「编辑」弹出的是**同一个**弹窗；新增后下拉自动选中新服务器。
- 切换中文界面，确认上述所有文案为中文、无中英混杂。

- [ ] **Step 3: 文件权限抽查**

Run:
```bash
stat -f '%Sp %N' ~/.ssh/config
```
Expected: 权限为 `-rw-------`（0600），未被改坏。

---

## Self-Review（计划作者已核对）

- **Spec 覆盖**：§4 文档模型 → Task 2–5；§5 服务层 → Task 6；§6 共享弹窗 → Task 7；
  §7 设置改版 + 原文编辑 → Task 8；§8 打开项目 → Task 9；§9 i18n → Task 10；
  §10 测试 → Task 2–6 单测 + Task 11 手动验证。无遗漏。
- **占位符**：无 TBD / TODO；每个代码步骤均给出完整代码。
- **类型一致**：`SSHServerDraft` / `ManagedSSHEntry` / `SSHConfigDocument.Entry` /
  `SSHServerEditSheet.Mode` 的字段与方法签名（`add` / `update(alias:to:)` /
  `remove(alias:)` / `loadManagedEntries` / `update(_:originalAlias:atSourcePath:)` /
  `remove(alias:atSourcePath:)`）在各任务间保持一致。
- **DRY**：原子写入逻辑抽到 `SSHConfigRawWriter`，service 与原文编辑弹窗共用。
```
