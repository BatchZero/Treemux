import XCTest
@testable import Treemux

final class FileNodeSymlinkTests: XCTestCase {
    private func node(_ kind: FileNode.Kind, targetDir: Bool = false) -> FileNode {
        FileNode(id: "/p", name: "p", path: "/p", kind: kind,
                 sizeBytes: nil, modifiedAt: nil, symlinkTargetIsDirectory: targetDir)
    }

    func testRealDirectoryIsExpandable() {
        XCTAssertTrue(node(.directory).isExpandableDirectory)
    }

    func testFileIsNotExpandable() {
        XCTAssertFalse(node(.file).isExpandableDirectory)
    }

    func testSymlinkToDirectoryIsExpandable() {
        XCTAssertTrue(node(.symlink(target: "/t"), targetDir: true).isExpandableDirectory)
    }

    func testSymlinkToFileIsNotExpandable() {
        XCTAssertFalse(node(.symlink(target: "/t"), targetDir: false).isExpandableDirectory)
    }

    func testDefaultFlagIsFalse() {
        let n = FileNode(id: "/p", name: "p", path: "/p", kind: .symlink(target: "/t"),
                         sizeBytes: nil, modifiedAt: nil)
        XCTAssertFalse(n.symlinkTargetIsDirectory)
    }

    func testDecodesLegacyJSONWithoutFlag() throws {
        // A snapshot encoded before the flag existed must still decode.
        let legacy = #"{"id":"/p","name":"p","path":"/p","kind":{"symlink":{"target":"/t"}},"sizeBytes":null,"modifiedAt":null}"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(FileNode.self, from: data)
        XCTAssertFalse(decoded.symlinkTargetIsDirectory)
    }
}
