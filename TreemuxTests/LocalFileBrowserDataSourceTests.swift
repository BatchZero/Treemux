//
//  LocalFileBrowserDataSourceTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class LocalFileBrowserDataSourceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-fb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testListDirectoryReturnsFilesAndSubdirs() async throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let ds = LocalFileBrowserDataSource()
        let nodes = try await ds.listDirectory(tmpDir.path)
        let names = Set(nodes.map(\.name))
        XCTAssertTrue(names.contains("sub"))
        XCTAssertTrue(names.contains("hello.txt"))

        let dirNode = nodes.first { $0.name == "sub" }
        XCTAssertEqual(dirNode?.kind, .directory)
        let fileNode = nodes.first { $0.name == "hello.txt" }
        XCTAssertEqual(fileNode?.kind, .file)
        XCTAssertEqual(fileNode?.sizeBytes, 2)
    }

    func testFileMetadata() async throws {
        let file = tmpDir.appendingPathComponent("a.bin")
        try Data(repeating: 0, count: 1024).write(to: file)
        let ds = LocalFileBrowserDataSource()
        let meta = try await ds.fileMetadata(file.path)
        XCTAssertEqual(meta.sizeBytes, 1024)
        XCTAssertFalse(meta.isDirectory)
    }

    func testReadFileSmall() async throws {
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readFile(file.path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
    }

    func testReadFileTooLargeThrows() async throws {
        let file = tmpDir.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: 5000).write(to: file)
        let ds = LocalFileBrowserDataSource()
        do {
            _ = try await ds.readFile(file.path, maxBytes: 1024)
            XCTFail("expected fileTooLarge")
        } catch FileBrowserError.fileTooLarge {
            // expected
        }
    }

    // readPrefix is the read variant used for content sniffing: it must never
    // throw fileTooLarge. It returns up to maxBytes from the start of the file.

    func testReadPrefixReturnsAllBytesForSmallFile() async throws {
        let file = tmpDir.appendingPathComponent("small.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
    }

    func testReadPrefixTruncatesLargeFileWithoutThrowing() async throws {
        let file = tmpDir.appendingPathComponent("big.txt")
        // 5000 bytes of 'A' — well over the 512-byte sniff window.
        try Data(repeating: 0x41, count: 5000).write(to: file)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 512)
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data.first, 0x41)
        XCTAssertEqual(data.last, 0x41)
    }

    func testReadPrefixOnEmptyFileReturnsEmpty() async throws {
        let file = tmpDir.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 512)
        XCTAssertEqual(data.count, 0)
    }

    func testWriteFileAtomic() async throws {
        let file = tmpDir.appendingPathComponent("out.txt")
        let ds = LocalFileBrowserDataSource()
        try await ds.writeFile(file.path, data: "alpha".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha")
        // Overwrite
        try await ds.writeFile(file.path, data: "beta".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "beta")
    }

    // MARK: - buildNodes (skip-unreadable robustness)

    private func fileNode(_ url: URL) -> FileNode {
        FileNode(id: url.path, name: url.lastPathComponent, path: url.path,
                 kind: .file, sizeBytes: nil, modifiedAt: nil)
    }

    private func dirNode(_ url: URL) -> FileNode {
        FileNode(id: url.path, name: url.lastPathComponent, path: url.path,
                 kind: .directory, sizeBytes: nil, modifiedAt: nil)
    }

    // Core of the bug fix: one entry whose node-build throws (e.g. the
    // TCC-protected ~/.Trash) must NOT abort the whole listing.
    func testBuildNodesSkipsEntriesThatThrow() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["a.txt", ".Trash", "b.txt"].map { parent.appendingPathComponent($0) }

        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { url in
            if url.lastPathComponent == ".Trash" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return self.fileNode(url)
        }

        XCTAssertEqual(nodes.map(\.name), ["a.txt", "b.txt"])
    }

    func testBuildNodesSortsDirectoriesFirstThenAlpha() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["zebra.txt", "alpha", "beta.txt"].map { parent.appendingPathComponent($0) }

        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { url in
            url.lastPathComponent == "alpha" ? self.dirNode(url) : self.fileNode(url)
        }

        XCTAssertEqual(nodes.map(\.name), ["alpha", "beta.txt", "zebra.txt"])
    }

    func testBuildNodesAllSucceedReturnsAll() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["one", "two"].map { parent.appendingPathComponent($0) }
        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { self.fileNode($0) }
        XCTAssertEqual(Set(nodes.map(\.name)), Set(["one", "two"]))
    }

    // MARK: - Symlink target type resolution

    func testSymlinkToDirectoryMarkedExpandable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let realDir = root.appendingPathComponent("real")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = root.appendingPathComponent("file.txt")
        try Data("hi".utf8).write(to: realFile)

        let dirLink = root.appendingPathComponent("dirlink")
        try fm.createSymbolicLink(at: dirLink, withDestinationURL: realDir)
        let fileLink = root.appendingPathComponent("filelink")
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: realFile)

        let source = LocalFileBrowserDataSource()
        let nodes = try await source.listDirectory(root.path)
        let byName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })

        XCTAssertTrue(byName["dirlink"]!.isSymlink)
        XCTAssertTrue(byName["dirlink"]!.isExpandableDirectory)
        XCTAssertEqual(
            byName["dirlink"]!.symlinkTargetResolution,
            .directory(canonicalIdentity: realDir.resolvingSymlinksInPath().standardizedFileURL.path)
        )
        XCTAssertTrue(byName["filelink"]!.isSymlink)
        XCTAssertFalse(byName["filelink"]!.isExpandableDirectory)
        XCTAssertEqual(byName["filelink"]!.symlinkTargetResolution, .file)
    }

    func testRelativeDirectorySymlinkUsesResolvedCanonicalIdentity() async throws {
        let realDir = tmpDir.appendingPathComponent("targets/real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let link = tmpDir.appendingPathComponent("relative-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "targets/../targets/real"
        )

        let source = LocalFileBrowserDataSource()
        let nodes = try await source.listDirectory(tmpDir.path)
        let node = try XCTUnwrap(nodes.first { $0.name == "relative-link" })

        XCTAssertEqual(
            node.symlinkTargetResolution,
            .directory(canonicalIdentity: realDir.resolvingSymlinksInPath().standardizedFileURL.path)
        )
        let canonicalIdentity = try await source.canonicalDirectoryIdentity(link.path)
        XCTAssertEqual(canonicalIdentity, realDir.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testBrokenSymlinkRemainsVisibleWithBrokenResolution() async throws {
        let link = tmpDir.appendingPathComponent("missing-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "does-not-exist"
        )

        let nodes = try await LocalFileBrowserDataSource().listDirectory(tmpDir.path)
        let node = try XCTUnwrap(nodes.first { $0.name == "missing-link" })

        XCTAssertTrue(node.isSymlink)
        XCTAssertEqual(node.symlinkTargetResolution, .broken)
        XCTAssertFalse(node.isExpandableDirectory)
    }

    // MARK: - createDirectory / createFile

    func testCreateDirectoryAndFile() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = LocalFileBrowserDataSource()
        let dirPath = root.appendingPathComponent("newdir").path
        let filePath = root.appendingPathComponent("new.txt").path

        try await source.createDirectory(dirPath)
        try await source.createFile(filePath)

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: dirPath, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(fm.fileExists(atPath: filePath, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue)
    }

    func testCreateDirectoryRejectsExisting() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = LocalFileBrowserDataSource()
        let p = root.appendingPathComponent("dup").path
        try? await source.createDirectory(p)
        do {
            try await source.createDirectory(p)
            XCTFail("expected an error for existing path")
        } catch {
            // expected
        }
    }

    // MARK: - searchNames

    func testSearchNamesFindsNestedMatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("alpha.txt"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("alphabet.md"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("other.txt"))

        let source = LocalFileBrowserDataSource()
        let results = try await source.searchNames(root: root.path, query: "ALPHA", maxResults: 100, includeHidden: true)
        let names = Set(results.map(\.name))
        XCTAssertTrue(names.contains("alpha.txt"))
        XCTAssertTrue(names.contains("alphabet.md"))
        XCTAssertFalse(names.contains("other.txt"))
    }

    func testSearchNamesHonorsMaxResults() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<10 { try Data("x".utf8).write(to: root.appendingPathComponent("match\(i).txt")) }
        let source = LocalFileBrowserDataSource()
        let results = try await source.searchNames(root: root.path, query: "match", maxResults: 3, includeHidden: true)
        XCTAssertEqual(results.count, 3)
    }

    // Core of the depth-bound fix: a no-match (or few-match) query over a
    // very deep tree must not walk past the bound (12, mirroring the remote
    // search's searchMaxDepth), or it stalls the shared serial queue.
    func testSearchNamesRespectsDepthBound() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Build a chain of 14 nested directories: d1/d2/.../d14. This is
        // deeper than the 12-level bound, so the walk must not descend into
        // d13/d14.
        var current = root
        var dirs: [URL] = []
        for i in 1...14 {
            current = current.appendingPathComponent("d\(i)")
            dirs.append(current)
        }
        try fm.createDirectory(at: dirs.last!, withIntermediateDirectories: true)

        // Shallow match: inside d5 (enumerator level 6), well within the bound.
        let shallowFile = dirs[4].appendingPathComponent("findme_shallow.md")
        try Data("x".utf8).write(to: shallowFile)

        // Deep match: inside d13 (enumerator level 14). d12 sits at the
        // bound (level 12), so its descendants — d13 onward — are pruned
        // and this file must never be visited.
        let deepFile = dirs[12].appendingPathComponent("findme_deep.md")
        try Data("x".utf8).write(to: deepFile)

        let source = LocalFileBrowserDataSource()
        let results = try await source.searchNames(root: root.path, query: "findme", maxResults: 100, includeHidden: true)
        let names = Set(results.map(\.name))
        XCTAssertTrue(names.contains("findme_shallow.md"))
        XCTAssertFalse(names.contains("findme_deep.md"))
    }

    // Regression: FIX I1 — a recursive search with hidden files off must not
    // surface non-hidden leaves living under a hidden directory (e.g.
    // `.git/config`), since the tree UI can never display/navigate to such a
    // result when "Show Hidden Files" is off.
    func testSearchNamesExcludesFilesUnderHiddenDirWhenHiddenOff() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gitDir = root.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("x".utf8).write(to: gitDir.appendingPathComponent("config"))
        try Data("x".utf8).write(to: root.appendingPathComponent("config.txt"))

        let source = LocalFileBrowserDataSource()

        // Compare by (name, parent-directory-name) rather than absolute path:
        // `FileManager`'s enumerator resolves the temp dir through its
        // /var → /private/var symlink, so `url.path` on results differs from
        // `root.appendingPathComponent(...).path` even though they name the
        // same file — the existing tests in this file sidestep this by
        // comparing names, matched here for consistency.
        func parentName(_ path: String) -> String {
            ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }

        let hiddenOff = try await source.searchNames(root: root.path, query: "config", maxResults: 100, includeHidden: false)
        XCTAssertTrue(hiddenOff.contains { $0.name == "config.txt" && parentName($0.path) == root.lastPathComponent })
        XCTAssertFalse(hiddenOff.contains { $0.name == "config" && parentName($0.path) == ".git" },
                        "FIX I1: a leaf under a hidden directory must not leak when hidden files are off")

        let hiddenOn = try await source.searchNames(root: root.path, query: "config", maxResults: 100, includeHidden: true)
        XCTAssertTrue(hiddenOn.contains { $0.name == "config.txt" && parentName($0.path) == root.lastPathComponent })
        XCTAssertTrue(hiddenOn.contains { $0.name == "config" && parentName($0.path) == ".git" })
    }

    // Regression: FIX M1 — a symlink to a directory must be classified so the
    // tree can route a tap to `revealInTree`, not `openInTree` (which would
    // try to read the directory as a file and open an error tab).
    func testSearchNamesClassifiesSymlinkedDirectory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realDir = root.appendingPathComponent("realdir")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let linkURL = root.appendingPathComponent("linktodir")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: realDir)

        let source = LocalFileBrowserDataSource()
        let results = try await source.searchNames(root: root.path, query: "linktodir", maxResults: 100, includeHidden: true)
        guard let node = results.first(where: { $0.name == "linktodir" }) else {
            XCTFail("expected a result for the symlink")
            return
        }
        XCTAssertTrue(node.isSymlink)
        XCTAssertTrue(node.symlinkTargetIsDirectory)
        XCTAssertTrue(node.isExpandableDirectory,
                      "FIX M1: a symlinked directory must be expandable so it routes to revealInTree, not openInTree")
        XCTAssertEqual(
            node.symlinkTargetResolution,
            .directory(canonicalIdentity: realDir.resolvingSymlinksInPath().standardizedFileURL.path)
        )
    }
}
