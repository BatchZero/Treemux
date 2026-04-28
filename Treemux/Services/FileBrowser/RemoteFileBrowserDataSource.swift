//
//  RemoteFileBrowserDataSource.swift
//  Treemux
//
//  Stub implementation. Filled in during Task 6.2.

import Foundation

final class RemoteFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    let sshTarget: SSHTarget

    init(sshTarget: SSHTarget) {
        self.sshTarget = sshTarget
    }

    func listDirectory(_ path: String) async throws -> [FileNode] { [] }
    func fileMetadata(_ path: String) async throws -> FileMetadata {
        FileMetadata(path: path, sizeBytes: 0, modifiedAt: nil, isDirectory: false, isSymbolicLink: false)
    }
    func readFile(_ path: String, maxBytes: Int) async throws -> Data { Data() }
    func writeFile(_ path: String, data: Data) async throws { }
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
