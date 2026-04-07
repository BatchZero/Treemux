import XCTest
@testable import Treemux

final class GitRepositoryServiceTests: XCTestCase {

    private var testRepoURL: URL!
    private let service = GitRepositoryService()

    override func setUp() async throws {
        testRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testRepoURL, withIntermediateDirectories: true)
        _ = try await ShellCommandRunner.shell(
            "git init && git commit --allow-empty -m 'init'",
            workingDirectory: testRepoURL
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testRepoURL)
    }

    func testCurrentBranch() async throws {
        let branch = try await service.currentBranch(at: testRepoURL)
        XCTAssertFalse(branch.isEmpty)
    }

    func testRepositoryRoot() async throws {
        let root = try await service.repositoryRoot(at: testRepoURL)
        XCTAssertEqual(root.standardizedFileURL, testRepoURL.standardizedFileURL)
    }

    func testListWorktrees() async throws {
        let worktrees = try await service.listWorktrees(at: testRepoURL)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees.first?.isMainWorktree ?? false)
    }

    func testRepositoryStatus() async throws {
        // Create a file to make the repo dirty
        let filePath = testRepoURL.appendingPathComponent("test.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        let status = try await service.repositoryStatus(at: testRepoURL)
        XCTAssertEqual(status.untrackedCount, 1)
    }
}

// MARK: - WorkspaceMetadataWatchService Tests

@MainActor
final class WorkspaceMetadataWatchServiceTests: XCTestCase {

    private var testRepoURL: URL!
    private let watchService = WorkspaceMetadataWatchService()

    override func setUp() async throws {
        testRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testRepoURL, withIntermediateDirectories: true)
        _ = try await ShellCommandRunner.shell(
            "git init && git commit --allow-empty -m 'init'",
            workingDirectory: testRepoURL
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testRepoURL)
    }

    func testResolveCommonGitDirectory_forMainWorktree_returnsItself() throws {
        let mainGitDir = testRepoURL.appendingPathComponent(".git").path
        let resolved = watchService.resolveCommonGitDirectory(for: mainGitDir)
        XCTAssertEqual(
            URL(fileURLWithPath: resolved).standardizedFileURL,
            URL(fileURLWithPath: mainGitDir).standardizedFileURL
        )
    }

    func testResolveCommonGitDirectory_forLinkedWorktree_returnsMainGitDir() async throws {
        // Create a linked worktree on a new branch in a sibling directory.
        let linkedURL = testRepoURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linkedURL) }

        _ = try await ShellCommandRunner.shell(
            "git worktree add \(linkedURL.path) -b test-linked",
            workingDirectory: testRepoURL
        )

        let mainGitDir = testRepoURL.appendingPathComponent(".git").path
        let linkedGitDir = mainGitDir + "/worktrees/" + linkedURL.lastPathComponent

        let resolved = watchService.resolveCommonGitDirectory(for: linkedGitDir)
        XCTAssertEqual(
            URL(fileURLWithPath: resolved).standardizedFileURL,
            URL(fileURLWithPath: mainGitDir).standardizedFileURL
        )
    }
}
