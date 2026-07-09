# Perf P2 — Remote Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut remote (SSH) operation latency by reusing one authenticated SSH connection per host (ControlMaster), refreshing multiple remote workspaces in parallel, moving the directory-tree cache read off the main thread, and eliminating the redundant second `stat` in the large-file confirm flow.

**Architecture:** A new `SSHMultiplexing` helper becomes the single source of truth for `/usr/bin/ssh` argument vectors (base options + ControlMaster/ControlPath/ControlPersist), adopted by both `SFTPService` and `GitRepositoryService`. `WorkspaceStore`'s serial remote-refresh loop becomes a `withTaskGroup` fan-out over workspace IDs. `FileBrowserTabController.loadRoot` reads the tree cache in a detached task (mirroring the existing write side), and `confirmLargeFileLoad` reuses the `FileMetadata` captured by `selectFile` instead of re-statting.

**Tech Stack:** Swift 5.x, XCTest, xcodegen, OpenSSH client (system `/usr/bin/ssh`), macOS 26.

**Design doc:** `docs/superpowers/specs/2026-07-07-performance-fluidity-v2-design.md` §3 P2（4 个条目全部覆盖于 Task 2–5）。

## Global Constraints

- 主仓库目录必须始终停在 `main`；本计划所有开发、构建、提交都在 `.worktrees/perf+p2-remote-link/` 内进行（分支 `perf/p2-remote-link`，基线 `c3f01e6`）。
- 每个任务结束时全部测试必须绿（基线 424 个 + 新增）。测试命令（在 worktree 根目录运行）：
  `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`
  （迭代时可加 `-only-testing:TreemuxTests/<ClassName>` 提速；任务收尾必须跑全量。）
- 非交互构建必须带 `-skipPackagePluginValidation`（SwiftLint 插件会卡验证）。
- 新增 Swift 文件后必须运行 `xcodegen generate` 并将 `Treemux.xcodeproj/project.pbxproj` 的变更一并提交。运行后核对 `MARKETING_VERSION = 0.0.19` 未被改动（project.yml 当前即 0.0.19，应无变化）。
- 状态目录一律通过 `treemuxStateDirectoryURL()` 取得（debug 构建为 `~/.treemux-debug/`，release 为 `~/.treemux/`），禁止硬编码路径。
- 本阶段不引入任何新的用户可见字符串或颜色；若实现中意外需要，必须走 `LocalizedStringKey` + `Localizable.xcstrings` zh-Hans 条目 + 主题 token。
- 性能改动不得改变功能语义；`ControlMaster` 不可用时必须静默退化为现状（每次新建连接）。
- 禁止复活 2026-07-01 的旧 perf+overhaul 分支（dangling 50ba57e）——用户已明确放弃。
- 提交信息用 conventional 风格：`perf(p2): …` / `test(p2): …` / `docs(p2): …`。

---

### Task 1: `SSHMultiplexing` — 共享 ssh 参数构建器（含 ControlMaster 选项）

**Files:**
- Create: `Treemux/Services/SFTP/SSHMultiplexing.swift`
- Test: `TreemuxTests/SSHMultiplexingTests.swift`
- Modify: `Treemux.xcodeproj/project.pbxproj`（由 `xcodegen generate` 生成，勿手改）

**Interfaces:**
- Consumes: `SSHTarget`（`Treemux/Domain/SSHTarget.swift`，字段 `host/port/user/identityFile/displayName/remotePath`）、`treemuxStateDirectoryURL(fileManager:)`（`Treemux/Persistence/AppSettingsPersistence.swift:24`）。
- Produces（Task 2 依赖，签名必须一字不差）:
  - `enum SSHMultiplexing`
  - `static let controlPersistSeconds = 60`
  - `static func controlDirectoryURL(stateDirectory: URL = treemuxStateDirectoryURL()) -> URL`
  - `static func controlOptions(stateDirectory: URL = treemuxStateDirectoryURL(), fileManager: FileManager = .default) -> [String]`
  - `static func sshArguments(target: SSHTarget, command: String, stateDirectory: URL = treemuxStateDirectoryURL(), fileManager: FileManager = .default) -> [String]`

- [ ] **Step 1: 写失败测试**

创建 `TreemuxTests/SSHMultiplexingTests.swift`，内容如下：

```swift
//
//  SSHMultiplexingTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHMultiplexingTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-mux-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makeTarget(identity: String? = nil, user: String? = "alice") -> SSHTarget {
        SSHTarget(host: "example.com", port: 2222, user: user,
                  identityFile: identity, displayName: "example", remotePath: "/srv/repo")
    }

    // MARK: - controlOptions

    func test_controlOptions_createsSocketDirectoryWithOwnerOnlyPerms() throws {
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        let dir = SSHMultiplexing.controlDirectoryURL(stateDirectory: tmp)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms, 0o700)

        XCTAssertEqual(opts, [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(dir.path)/%C",
            "-o", "ControlPersist=60s"
        ])
    }

    func test_controlOptions_secondCallWithExistingDirectoryStillReturnsOptions() {
        _ = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(opts.count, 6)
    }

    func test_controlOptions_returnsEmptyWhenDirectoryCannotBeCreated() throws {
        // A regular FILE at the state-directory path makes createDirectory throw.
        try Data().write(to: tmp)
        let opts = SSHMultiplexing.controlOptions(stateDirectory: tmp)
        XCTAssertEqual(opts, [])
    }

    // MARK: - sshArguments

    func test_sshArguments_endsWithTargetAndCommand_andCarriesBaseOptions() throws {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(), command: "echo hi", stateDirectory: tmp)

        XCTAssertEqual(Array(args.suffix(2)), ["alice@example.com", "echo hi"])
        // Base options preserved verbatim from the pre-P2 builders.
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=10"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        let pIdx = try XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertEqual(args[pIdx + 1], "2222")
        // Multiplexing options present.
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ControlPersist=60s"))
    }

    func test_sshArguments_expandsTildeInIdentityFile() throws {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(identity: "~/.ssh/id_test"), command: "true", stateDirectory: tmp)
        let iIdx = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertFalse(args[iIdx + 1].hasPrefix("~"))
        XCTAssertTrue(args[iIdx + 1].hasSuffix("/.ssh/id_test"))
    }

    func test_sshArguments_defaultsUserToCurrentUser() {
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(user: nil), command: "true", stateDirectory: tmp)
        XCTAssertEqual(args.suffix(2).first, "\(NSUserName())@example.com")
    }

    func test_sshArguments_omitsMuxOptionsWhenControlDirUnavailable() throws {
        try Data().write(to: tmp)
        let args = SSHMultiplexing.sshArguments(
            target: makeTarget(), command: "true", stateDirectory: tmp)
        XCTAssertFalse(args.contains("ControlMaster=auto"))
        XCTAssertEqual(Array(args.suffix(2)), ["alice@example.com", "true"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

先把测试文件纳入工程再编译（新文件必须过 xcodegen）：

```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/SSHMultiplexingTests
```

预期：**编译失败**，报 `cannot find 'SSHMultiplexing' in scope`。

- [ ] **Step 3: 写实现**

创建 `Treemux/Services/SFTP/SSHMultiplexing.swift`：

```swift
//
//  SSHMultiplexing.swift
//  Treemux
//

import Foundation

/// Builds the OpenSSH argument vector shared by every system-ssh invocation
/// (SFTPService file operations and GitRepositoryService remote inspection).
///
/// Connection multiplexing: the first connection to a host becomes the
/// ControlMaster; subsequent commands within `controlPersistSeconds` reuse its
/// TCP + auth session, eliminating the full handshake per command. Degradation
/// is silent by design: if the socket directory cannot be created the mux
/// options are simply omitted, and `ControlMaster=auto` itself falls back to a
/// plain connection when the socket is unusable or the server forbids
/// multiplexing — behavior then matches pre-P2 (one connection per command).
enum SSHMultiplexing {
    /// How long (seconds) the master connection lingers after its last client.
    static let controlPersistSeconds = 60

    static func controlDirectoryURL(
        stateDirectory: URL = treemuxStateDirectoryURL()
    ) -> URL {
        stateDirectory.appendingPathComponent("ssh-mux", isDirectory: true)
    }

    /// ControlMaster/ControlPath/ControlPersist options, creating the socket
    /// directory (owner-only, 0700) on demand. Empty when the directory cannot
    /// be created. `%C` hashes host+port+user so distinct targets never share
    /// a socket, and its fixed length keeps the path under the unix-socket
    /// path limit.
    static func controlOptions(
        stateDirectory: URL = treemuxStateDirectoryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        let dir = controlDirectoryURL(stateDirectory: stateDirectory)
        do {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return []
        }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(dir.path)/%C",
            "-o", "ControlPersist=\(controlPersistSeconds)s"
        ]
    }

    /// Full `/usr/bin/ssh` argument list: base options + multiplexing +
    /// port/identity/target/command. Single source of truth for both services.
    static func sshArguments(
        target: SSHTarget,
        command: String,
        stateDirectory: URL = treemuxStateDirectoryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        args += controlOptions(stateDirectory: stateDirectory, fileManager: fileManager)
        args += ["-p", "\(target.port)"]
        if let identityFile = target.identityFile {
            args += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        args.append("\(target.user ?? NSUserName())@\(target.host)")
        args.append(command)
        return args
    }
}
```

- [ ] **Step 4: 重新 xcodegen + 跑测试确认通过**

```bash
xcodegen generate
git diff Treemux.xcodeproj/project.pbxproj | grep -i "MARKETING_VERSION" || echo "version untouched (expected)"
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/SSHMultiplexingTests
```

预期：7 个测试全 PASS；`MARKETING_VERSION` 无变化。

- [ ] **Step 5: 提交**

```bash
git add Treemux/Services/SFTP/SSHMultiplexing.swift TreemuxTests/SSHMultiplexingTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p2): add SSHMultiplexing shared ssh arg builder with ControlMaster options"
```

---

### Task 2: `SFTPService` 与 `GitRepositoryService` 接入共享构建器

**Files:**
- Modify: `Treemux/Services/SFTP/SFTPService.swift:403-418`（`sshArgs`）
- Modify: `Treemux/Services/Git/GitRepositoryService.swift:204-225`（`runSSH`）
- Test: `TreemuxTests/SFTPServiceTests.swift`（追加）

**Interfaces:**
- Consumes: Task 1 的 `SSHMultiplexing.sshArguments(target:command:)`（默认 stateDirectory/fileManager）。
- Produces: `SFTPService.sshArgs(target:command:)` 从 `private static` 放宽为 `static`（internal），供测试断言；行为 = `SSHMultiplexing.sshArguments`。`GitRepositoryService.runSSH` 保持 `private`，参数构建改为委托共享构建器。

- [ ] **Step 1: 写失败测试**

在 `TreemuxTests/SFTPServiceTests.swift` 末尾（类内）追加：

```swift
    // MARK: - sshArgs multiplexing (P2)

    /// P2: every system-ssh invocation must carry ControlMaster options so
    /// repeated file operations reuse one authenticated connection.
    func test_sshArgs_includesConnectionMultiplexingOptions() {
        let target = SSHTarget(host: "h", port: 22, user: "u", identityFile: nil,
                               displayName: "h", remotePath: nil)
        let args = SFTPService.sshArgs(target: target, command: "echo 1")

        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains(where: { $0.hasPrefix("ControlPath=") && $0.hasSuffix("/%C") }))
        XCTAssertTrue(args.contains("ControlPersist=60s"))
        // Invocation shape unchanged: target second-to-last, command last.
        XCTAssertEqual(Array(args.suffix(2)), ["u@h", "echo 1"])
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/SFTPServiceTests
```

预期：**编译失败**，报 `'sshArgs' is inaccessible due to 'private' protection level`。

- [ ] **Step 3: 改两个服务**

`SFTPService.swift:403-418` 整个方法替换为（`private static` → `static`，本体委托共享构建器）：

```swift
    /// Internal (not private) so tests can assert the mux options are wired in.
    static func sshArgs(target: SSHTarget, command: String) -> [String] {
        SSHMultiplexing.sshArguments(target: target, command: command)
    }
```

`GitRepositoryService.swift` 的 `runSSH(target:command:)`（204-225 行）整个方法替换为：

```swift
    /// Runs a command on a remote host via system SSH. Argument construction
    /// (including ControlMaster connection reuse) is shared with SFTPService
    /// via SSHMultiplexing.
    private func runSSH(target: SSHTarget, command: String) async throws -> SSHResult {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/ssh",
            arguments: SSHMultiplexing.sshArguments(target: target, command: command)
        )
        return SSHResult(exitCode: result.exitCode, output: result.output, errorOutput: result.errorOutput)
    }
```

注意：`GitRepositoryService` 中原有的 `var args` 手工拼装（206-218 行）随替换一并删除；`shellEscape` 与其余方法不动。

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/SFTPServiceTests \
  -only-testing:TreemuxTests/GitRepositoryServiceTests \
  -only-testing:TreemuxTests/SSHMultiplexingTests
```

预期：全 PASS（git 服务的本地仓库测试不受影响）。

- [ ] **Step 5: 提交**

```bash
git add Treemux/Services/SFTP/SFTPService.swift Treemux/Services/Git/GitRepositoryService.swift TreemuxTests/SFTPServiceTests.swift
git commit -m "perf(p2): route SFTPService and GitRepositoryService ssh args through SSHMultiplexing"
```

---

### Task 3: 远程工作区刷新并行化（TaskGroup）

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:529-541`（`refreshAllRemoteWorkspaces`）
- Test: `TreemuxTests/WorkspaceStoreRemoteRefreshTests.swift`（新建）
- Modify: `Treemux.xcodeproj/project.pbxproj`（`xcodegen generate`，因新增测试文件）

**Interfaces:**
- Consumes: `WorkspaceStore.workspaces`、`refreshWorkspace(_ workspace: WorkspaceModel) async`（`WorkspaceStore.swift:414`，不改）、`isRefreshingRemotes` 重入保护（不改）。
- Produces（测试依赖）: `func refreshRemoteWorkspacesConcurrently(ids: [UUID], using refresh: @escaping @MainActor @Sendable (UUID) async -> Void) async`（internal，on `WorkspaceStore`）。

**关键设计**：跨 task 边界只传 `UUID`（Sendable），闭包内在 main actor 上按 id 重查 `workspaces`——与既有 watcher 回调模式一致（`WorkspaceStore.swift:483-489`），刷新途中被删除的工作区安全跳过。闭包虽然都在 main actor 上执行，但每次 SSH 往返都会挂起让位，网络等待相互重叠——总耗时 ≈ 最慢单个而非求和（设计文档 P2 验收条款）。

- [ ] **Step 1: 写失败测试**

创建 `TreemuxTests/WorkspaceStoreRemoteRefreshTests.swift`：

```swift
//
//  WorkspaceStoreRemoteRefreshTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

/// Rendezvous barrier: every arriving task suspends until `expected` tasks
/// have arrived, then all resume together. Under serial execution the first
/// arrival would wait forever — `failSafe` unblocks stragglers after a
/// timeout and records the failure so the test fails instead of hanging.
private actor Rendezvous {
    private let expected: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var timedOut = false

    init(expected: Int) { self.expected = expected }

    func arrive() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
            if waiters.count == expected {
                for w in waiters { w.resume() }
                waiters.removeAll()
            }
        }
    }

    func failSafe(afterSeconds seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.releaseStragglers()
        }
    }

    private func releaseStragglers() {
        guard !waiters.isEmpty else { return }
        timedOut = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

private actor VisitLog {
    private(set) var values: [UUID] = []
    func record(_ id: UUID) { values.append(id) }
}

@MainActor
final class WorkspaceStoreRemoteRefreshTests: XCTestCase {
    private func clearState() throws {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    override func setUp() async throws { try clearState() }
    override func tearDown() async throws { try clearState() }

    /// P2 acceptance: remote refreshes overlap. All three refresh closures must
    /// be in flight simultaneously — under the old serial for-loop the first
    /// one blocks the rest, the rendezvous times out, and the test fails.
    func test_refreshRemoteWorkspacesConcurrently_overlapsAllRefreshes() async {
        let store = WorkspaceStore()
        let ids = [UUID(), UUID(), UUID()]
        let rendezvous = Rendezvous(expected: ids.count)
        await rendezvous.failSafe(afterSeconds: 5)

        await store.refreshRemoteWorkspacesConcurrently(ids: ids) { _ in
            await rendezvous.arrive()
        }

        let timedOut = await rendezvous.timedOut
        XCTAssertFalse(timedOut, "refreshes ran serially — they must overlap")
    }

    /// Every id is visited exactly once, and the call returns only after all
    /// refreshes complete.
    func test_refreshRemoteWorkspacesConcurrently_visitsEveryIDOnce() async {
        let store = WorkspaceStore()
        let ids = (0..<5).map { _ in UUID() }
        let log = VisitLog()

        await store.refreshRemoteWorkspacesConcurrently(ids: ids) { id in
            await log.record(id)
        }

        let recorded = await log.values
        XCTAssertEqual(Set(recorded), Set(ids))
        XCTAssertEqual(recorded.count, ids.count)
    }
}
```

- [ ] **Step 2: 纳入工程并跑测试确认失败**

```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/WorkspaceStoreRemoteRefreshTests
```

预期：**编译失败**，报 `value of type 'WorkspaceStore' has no member 'refreshRemoteWorkspacesConcurrently'`。

- [ ] **Step 3: 写实现**

`WorkspaceStore.swift:529-541` 的 `refreshAllRemoteWorkspaces` 整体替换为：

```swift
    /// Refreshes every SSH-backed workspace concurrently. No-op for local
    /// workspaces. Reentry-guarded so overlapping triggers (timer + window
    /// focus, or back-to-back) don't stack SSH connections.
    private func refreshAllRemoteWorkspaces() async {
        guard !isRefreshingRemotes else { return }
        let ids = workspaces
            .filter { $0.sshTarget != nil && !$0.isArchived }
            .map(\.id)
        guard !ids.isEmpty else { return }
        isRefreshingRemotes = true
        defer { isRefreshingRemotes = false }
        await refreshRemoteWorkspacesConcurrently(ids: ids) { [weak self] id in
            guard let self,
                  let workspace = self.workspaces.first(where: { $0.id == id }) else { return }
            await self.refreshWorkspace(workspace)
        }
    }

    /// Runs `refresh` for every workspace id concurrently and returns when all
    /// finish. The closures hop to the main actor, but each SSH round-trip
    /// suspends there, so the network waits overlap — total wall-clock is
    /// roughly the slowest workspace instead of the sum. IDs (not models)
    /// cross the task boundary; each closure re-resolves its workspace so a
    /// mid-flight removal is safely skipped. Internal so tests can drive the
    /// concurrency shape without real SSH.
    func refreshRemoteWorkspacesConcurrently(
        ids: [UUID],
        using refresh: @escaping @MainActor @Sendable (UUID) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await refresh(id) }
            }
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/WorkspaceStoreRemoteRefreshTests
```

预期：2 个测试 PASS（`overlaps` 测试应在 1 秒内完成，而不是等满 5 秒 failSafe）。

- [ ] **Step 5: 提交**

```bash
git add Treemux/App/WorkspaceStore.swift TreemuxTests/WorkspaceStoreRemoteRefreshTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p2): refresh remote workspaces concurrently via TaskGroup"
```

---

### Task 4: 目录树磁盘缓存读取移出主线程

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift:226-235`（`loadRoot`）
- Test: `TreemuxTests/TreeCacheOffMainLoadTests.swift`（新建）
- Modify: `Treemux.xcodeproj/project.pbxproj`（`xcodegen generate`）

**Interfaces:**
- Consumes: `DirectoryTreeCachePersistence.load(identity:rootPath:)`（值类型，已被写侧 `persistTree` 在 detached task 中使用，`FileBrowserTabController.swift:305-308`——读侧照抄该模式）、`applySnapshot(_:)`、`refreshTree()`（都不改）。
- Produces: 无新接口；`loadRoot()` 语义不变（先缓存后刷新，顺序保持）。

- [ ] **Step 1: 写失败测试**

创建 `TreemuxTests/TreeCacheOffMainLoadTests.swift`。测试验证的行为契约是：**缓存快照必须在慢速网络 fetch 完成之前就渲染出来**（"instant render"），且 fetch 完成后被新数据覆盖：

```swift
//
//  TreeCacheOffMainLoadTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

/// Data source whose `listTree` suspends until the test calls `release()`,
/// simulating a slow remote bulk fetch. All other operations are unused by
/// `loadRoot` and just throw.
private final class GatedTreeDataSource: FileBrowserDataSource {
    let supportsWrite = false
    var treeCacheIdentity: String? { "test-host:22:tester" }

    private let stream: AsyncStream<Void>
    private let releaseFn: () -> Void

    init() {
        var cont: AsyncStream<Void>.Continuation!
        stream = AsyncStream { cont = $0 }
        let c = cont!
        releaseFn = { c.finish() }
    }

    func release() { releaseFn() }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        for await _ in stream { } // suspends until release()
        let fresh = FileNode(id: "/r/fresh.txt", name: "fresh.txt", path: "/r/fresh.txt",
                             kind: .file, sizeBytes: 1, modifiedAt: nil)
        return DirectoryTreeFetch(childrenByPath: ["/r": [fresh]], truncatedDirs: [])
    }

    func listDirectory(_ path: String) async throws -> [FileNode] { [] }
    func fileMetadata(_ path: String) async throws -> FileMetadata { throw FileBrowserError.notFound(path) }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { throw FileBrowserError.notFound(path) }
    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data { throw FileBrowserError.notFound(path) }
    func writeFile(_ path: String, data: Data) async throws { throw FileBrowserError.notFound(path) }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        throw FileBrowserError.notFound(path)
    }
}

@MainActor
final class TreeCacheOffMainLoadTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-cache-offmain-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Polls `condition` every 10 ms for up to 2 s; fails the test on timeout.
    private func pollUntil(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(message)", file: file, line: line)
    }

    /// The cached snapshot must render while the (gated) network fetch is
    /// still pending — the cache read moved off the main actor must not break
    /// the cache-first-then-refresh ordering inside `loadRoot`.
    func test_loadRoot_rendersCachedSnapshotWhileFetchStillPending() async throws {
        let cache = DirectoryTreeCachePersistence(baseDirectory: tmp)
        let cachedNode = FileNode(id: "/r/cached.txt", name: "cached.txt", path: "/r/cached.txt",
                                  kind: .file, sizeBytes: 1, modifiedAt: nil)
        try cache.save(
            DirectoryTreeSnapshot(rootPath: "/r", childrenByPath: ["/r": [cachedNode]],
                                  truncatedDirs: [], fetchedAt: Date()),
            identity: "test-host:22:tester")

        let source = GatedTreeDataSource()
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: source,
            treeCache: cache
        )

        let load = Task { await ctrl.loadRoot() }

        await pollUntil("cached snapshot rendered before fetch completes") {
            ctrl.rootChildren.map(\.name) == ["cached.txt"]
        }

        source.release()
        await load.value
        XCTAssertEqual(ctrl.rootChildren.map(\.name), ["fresh.txt"],
                       "fresh fetch must supersede the cached snapshot")
    }
}
```

- [ ] **Step 2: 纳入工程并跑测试确认现状**

```bash
xcodegen generate
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/TreeCacheOffMainLoadTests
```

预期：**PASS**（现状同步读取也满足该契约——这是保护「读取后台化不破坏顺序」的回归测试，先绿后改）。若此处意外失败，停下排查再继续。

- [ ] **Step 3: 写实现**

`FileBrowserTabController.swift` 的 `loadRoot()`（226-235 行）替换为：

```swift
    func loadRoot() async {
        loadError = nil
        // 1. Instant render from the on-disk cache if present. The file read +
        //    JSON decode runs off the main actor (mirroring persistTree's write
        //    side) — a large remote snapshot used to block the first frame for
        //    the whole synchronous decode.
        if let identity = dataSource.treeCacheIdentity {
            let cache = treeCache
            let root = rootPath
            let snap = await Task.detached(priority: .userInitiated) {
                cache.load(identity: identity, rootPath: root)
            }.value
            if let snap {
                applySnapshot(snap)
            }
        }
        // 2. Background-refresh via bulk fetch (also the only fetch path on a cache miss).
        await refreshTree()
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/TreeCacheOffMainLoadTests \
  -only-testing:TreemuxTests/DirectoryTreeCacheTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests
```

预期：全 PASS（既有缓存测试与 controller 测试均不回归）。

- [ ] **Step 5: 提交**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/TreeCacheOffMainLoadTests.swift Treemux.xcodeproj/project.pbxproj
git commit -m "perf(p2): decode directory-tree cache off the main actor in loadRoot"
```

---

### Task 5: 大文件确认路径合并两次 stat

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift`（新增属性；`selectFile(_:subTabID:)` 615-642 行；`confirmLargeFileLoad` 645-655 行；`cancelLargeFileLoad` 658-660 行；`closeSubTabImmediate` 528-543 行）
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`（追加 2 个测试 + mock 加计数器）

**Interfaces:**
- Consumes: `FileMetadata`（Equatable，含 `path`）、`dispatchByType(path:meta:subTabID:)`、`activeOpenFile` / `activeSubTabID`（均已存在）。
- Produces: 无新公开接口。`MockFileBrowserDataSource` 增加 `var fileMetadataCallCount = 0`（后续任务/评审可复用）。

**现状问题**：`selectFile` 已 stat 一次拿到 `meta`（622 行），用户点击确认后 `confirmLargeFileLoad` 又 stat 一次（649 行）——对远程文件是一次完整 SSH 往返。修复：进入 `.confirmingLargeFile` 时把 `meta` 按 sub-tab id 暂存，确认时路径校验后直接复用；任何不匹配（如状态从持久化恢复、sub-tab 被复用换了文件）都回退到重新 stat，语义与现状一致。

- [ ] **Step 1: 给 mock 加计数器**

`TreemuxTests/FileBrowserTabControllerTests.swift` 中 `MockFileBrowserDataSource` 的 `fileMetadata` 方法替换为（并在属性区加一行 `var fileMetadataCallCount = 0`）：

```swift
    var fileMetadataCallCount = 0
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        fileMetadataCallCount += 1
        return fileMetas[path] ?? FileMetadata(path: path, sizeBytes: Int64(fileContents[path]?.count ?? 0), modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
    }
```

- [ ] **Step 2: 写失败测试**

在 `FileBrowserTabControllerTests` 类内追加：

```swift
    // MARK: - Large-file confirm (P2: single stat)

    /// P2: `confirmLargeFileLoad` must reuse the metadata already fetched by
    /// `selectFile` instead of paying a second remote stat round-trip.
    func test_confirmLargeFileLoad_reusesMetadata_noSecondStat() async {
        let mock = MockFileBrowserDataSource()
        let path = "/r/big.txt"
        mock.fileMetas[path] = FileMetadata(path: path, sizeBytes: 6 * 1024 * 1024,
                                            modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents[path] = Data("hello".utf8)
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock
        )

        await ctrl.openInTree(path)
        guard case .confirmingLargeFile = ctrl.activeSubTab?.openFile else {
            return XCTFail("expected large-file prompt, got \(String(describing: ctrl.activeSubTab?.openFile))")
        }
        XCTAssertEqual(mock.fileMetadataCallCount, 1)

        await ctrl.confirmLargeFileLoad()

        XCTAssertEqual(mock.fileMetadataCallCount, 1, "confirm must not re-stat")
        guard case .text(_, let content, _, _) = ctrl.activeSubTab?.openFile else {
            return XCTFail("expected text content after confirm, got \(String(describing: ctrl.activeSubTab?.openFile))")
        }
        XCTAssertEqual(content, "hello")
    }

    /// Cancelling the prompt clears the stashed metadata and resets state, so
    /// a stray confirm afterwards is a harmless no-op (no dispatch, no stat).
    func test_cancelLargeFileLoad_clearsPendingMetadata() async {
        let mock = MockFileBrowserDataSource()
        let path = "/r/big.txt"
        mock.fileMetas[path] = FileMetadata(path: path, sizeBytes: 6 * 1024 * 1024,
                                            modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
        mock.fileContents[path] = Data("hello".utf8)
        let ctrl = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: "/r", rootKind: .project),
            dataSource: mock
        )

        await ctrl.openInTree(path)
        ctrl.cancelLargeFileLoad()
        if case .empty = ctrl.activeSubTab?.openFile {} else {
            XCTFail("expected empty state after cancel")
        }

        await ctrl.confirmLargeFileLoad()
        XCTAssertEqual(mock.fileMetadataCallCount, 1, "stray confirm must not stat")
    }
```

- [ ] **Step 3: 跑测试确认失败**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests
```

预期：`test_confirmLargeFileLoad_reusesMetadata_noSecondStat` FAIL（计数为 2）；`test_cancelLargeFileLoad_clearsPendingMetadata` PASS（现状确认时 state 已 empty，guard 直接返回）。其余既有测试 PASS。

- [ ] **Step 4: 写实现**

`FileBrowserTabController` 属性区（`liveBufferByTab` 附近）新增：

```swift
    /// Metadata captured when a load enters `.confirmingLargeFile`, keyed by
    /// sub-tab. Lets `confirmLargeFileLoad()` reuse the stat from `selectFile`
    /// instead of paying a second remote round-trip. Path-checked on read so a
    /// repurposed sub-tab can never dispatch stale metadata.
    private var pendingLargeFileMeta: [UUID: FileMetadata] = [:]
```

`selectFile(_:subTabID:)` 中 635-639 行的分支改为：

```swift
        // Prompt for files between large threshold and quickLookOnly threshold.
        if meta.sizeBytes > Self.largeFileThreshold {
            pendingLargeFileMeta[subTabID] = meta
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes))
            return
        }
```

`confirmLargeFileLoad`（645-655 行）整体替换为：

```swift
    /// Called from UI when user confirms the large-file prompt. Reuses the
    /// metadata captured by `selectFile` when it still matches this sub-tab's
    /// path; falls back to a fresh stat otherwise (e.g. state restored from
    /// persistence, or the size-gate was hit via a `readFile` failure).
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = activeOpenFile,
              let id = activeSubTabID else { return }
        if let meta = pendingLargeFileMeta.removeValue(forKey: id), meta.path == path {
            await dispatchByType(path: path, meta: meta, subTabID: id)
            return
        }
        do {
            let meta = try await dataSource.fileMetadata(path)
            await dispatchByType(path: path, meta: meta, subTabID: id)
        } catch {
            setOpenFile(forSubTab: id, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
        }
    }
```

`cancelLargeFileLoad`（658-660 行）替换为：

```swift
    /// Called from UI when user cancels the large-file prompt.
    func cancelLargeFileLoad() {
        if let id = activeSubTabID {
            pendingLargeFileMeta[id] = nil
        }
        setActiveOpenFile(.empty)
    }
```

`closeSubTabImmediate`（528-543 行）中紧跟 `liveBufferByTab[id] = nil` 之后加一行清理：

```swift
        liveBufferByTab[id] = nil
        pendingLargeFileMeta[id] = nil
```

- [ ] **Step 5: 跑测试确认通过**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/FileBrowserTabControllerTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerSubTabTests \
  -only-testing:TreemuxTests/FileBrowserTabControllerStaleLoadTests
```

预期：全 PASS。

- [ ] **Step 6: 提交**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "perf(p2): reuse selectFile metadata in large-file confirm, dropping the second remote stat"
```

---

### Task 6: 全量验证、基准证据与收尾

**Files:**
- Modify: `docs/perf/baseline.md`（追加 P2 小节）
- 无产品代码改动。

- [ ] **Step 1: 全量测试**

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' \
  -skipPackagePluginValidation
```

预期：全绿（424 个基线测试 + 本计划新增约 12 个）。任何失败都必须修复后重跑，不得跳过。

- [ ] **Step 2: 本地基准回归（场景 B 为主信号）**

在 worktree 内运行 `scripts/perf-baseline.sh`（用法见脚本头部注释；同一天内先在 main 构建跑一轮做对照，去首跑、取均值，同机低负载）。P2 全部改动都在远程链路与 I/O 侧，**本地场景 A/B 不应回归**（阈值：场景 B 均值劣化 < 20% 视为噪声内）。

- [ ] **Step 3: SSH 复用真机验证（需用户远程主机，可与用户协作）**

用用户实际配置的远程主机 `<host>` 验证 ControlMaster 生效与收益：

```bash
# 改后（带 mux 选项，第一次建 master，后四次应显著加速）：
time ( for i in 1 2 3 4 5; do \
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -o ControlMaster=auto -o "ControlPath=$HOME/.treemux-debug/ssh-mux/%C" -o ControlPersist=60s \
      <host> true; done )
# 对照（现状，无 mux）：
time ( for i in 1 2 3 4 5; do \
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new <host> true; done )
ls -la ~/.treemux-debug/ssh-mux/   # 应出现 master socket 文件
```

把两组耗时与 app 内实测感受记入 `docs/perf/baseline.md` 的 P2 小节（模板：改动列表、本地场景 A/B 对照数字、远程 5 连发对照数字、结论）。若无可用远程主机，此步记为「用户 GUI 冒烟时补测」。

- [ ] **Step 4: 用户 GUI 冒烟清单（请用户在真实远程工作区操作）**

编译后告知用户运行 `rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`（编号以本机 DerivedData 实际目录为准），并核对：

1. 远程工作区文件树展开/刷新明显变快（首个操作后）；`~/.treemux-debug/ssh-mux/` 出现 socket 文件。
2. 打开 >5MB 远程文件：确认弹窗出现 → 点确认 → 内容加载正常（且比之前少一次等待）。
3. 多个远程工作区时，侧栏 git 状态在窗口获焦后并行刷新（总等待 ≈ 最慢的一个）。
4. 远程文件编辑、保存、Quick Look 均正常；断网/服务器禁用 multiplexing 时功能照常（退化为逐次连接）。
5. 本地工作区完全无感知差异（树、编辑器、终端）。

- [ ] **Step 5: 最终评审与合并**

按 superpowers:requesting-code-review 做全分支终审（对照本计划与设计文档 P2 小节逐项核验），然后按 superpowers:finishing-a-development-branch 处理合并回 `main`（no-ff）与 worktree 清理；合并前主目录确认仍在 `main`。

```bash
git log --oneline main..perf/p2-remote-link   # 终审提交清单
```

---

## Self-Review 记录

- **Spec coverage**：设计文档 P2 四条 → Task 1+2（ControlMaster 复用，含 debug/release 状态目录、静默退化）、Task 3（TaskGroup 并行 + 保留重入保护与获焦触发）、Task 4（缓存读取后台化，对齐写侧模式）、Task 5（两次 stat 合并，带路径校验回退）。验收条款 → Task 6 的基准与真机验证。无遗漏。
- **Placeholder scan**：所有代码步骤均给出完整代码与预期输出；无 TBD/TODO 类占位。
- **Type consistency**：`SSHMultiplexing.sshArguments(target:command:stateDirectory:fileManager:)` 在 Task 1 定义、Task 2 两处消费（默认参数调用 `sshArguments(target:command:)`）一致；`refreshRemoteWorkspacesConcurrently(ids:using:)` 定义与测试调用一致；`pendingLargeFileMeta` 仅 Task 5 内部使用。
