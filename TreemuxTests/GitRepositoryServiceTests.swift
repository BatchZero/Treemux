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
