import XCTest
@testable import Treemux

final class FileTransferPresentationTests: XCTestCase {
    func testDropTargetRoutesDirectoryAndEmptyTreeToExpectedDestination() {
        let directory = FileNode(
            id: "/remote/folder",
            name: "folder",
            path: "/remote/folder",
            kind: .directory,
            sizeBytes: nil,
            modifiedAt: nil
        )
        let file = FileNode(
            id: "/remote/file.txt",
            name: "file.txt",
            path: "/remote/file.txt",
            kind: .file,
            sizeBytes: nil,
            modifiedAt: nil
        )

        XCTAssertEqual(
            FileTransferPresentation.dropDestination(for: directory, rootPath: "/remote"),
            "/remote/folder"
        )
        XCTAssertEqual(
            FileTransferPresentation.dropDestination(for: nil, rootPath: "/remote"),
            "/remote"
        )
        XCTAssertNil(FileTransferPresentation.dropDestination(for: file, rootPath: "/remote"))
    }

    func testDownloadCommandIsAvailableOnlyForRemoteRows() {
        let directory = FileNode(
            id: "/remote/folder",
            name: "folder",
            path: "/remote/folder",
            kind: .directory,
            sizeBytes: nil,
            modifiedAt: nil
        )
        let file = FileNode(
            id: "/remote/file.txt",
            name: "file.txt",
            path: "/remote/file.txt",
            kind: .file,
            sizeBytes: nil,
            modifiedAt: nil
        )

        XCTAssertTrue(FileTransferPresentation.canDownload(directory, isRemote: true))
        XCTAssertTrue(FileTransferPresentation.canDownload(file, isRemote: true))
        XCTAssertFalse(FileTransferPresentation.canDownload(file, isRemote: false))
    }
}
