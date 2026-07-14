//
//  LocalFileBrowserDataSource.swift
//  Treemux

import Foundation

final class LocalFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    private let queue = DispatchQueue(label: "treemux.localfs", qos: .userInitiated)

    // Dedicated queue for `searchNames`. A no-match recursive search over a
    // wide tree can visit tens of thousands of entries; running it on the
    // shared `queue` above would block every other file op (listDirectory,
    // readFile, writeFile, createFile) queued behind it for the duration of
    // the walk. Search only reads the FS, so isolating it here is safe and
    // keeps interactive file ops responsive while a search is in flight.
    private let searchQueue = DispatchQueue(label: "treemux.localfs.search", qos: .userInitiated)

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await runOnQueue {
            let parentURL = URL(fileURLWithPath: path)
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            // Use contentsOfDirectory(at:) for resource keys but re-derive each
            // child's path via appendingPathComponent so that symlinks in the
            // temporary directory hierarchy (e.g. /var → /private/var on macOS)
            // are not transparently resolved, keeping paths stable for callers.
            let contents = try fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: keys, options: [])
            return Self.buildNodes(from: contents, parent: parentURL, make: Self.makeNode)
        }
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            return FileMetadata(
                path: path,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false
            )
        }
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size: Int64
            if let n = attrs[.size] as? NSNumber {
                size = n.int64Value
            } else if let i = attrs[.size] as? Int64 {
                size = i
            } else if let i = attrs[.size] as? Int {
                size = Int64(i)
            } else {
                size = 0
            }
            if size > Int64(maxBytes) {
                throw FileBrowserError.fileTooLarge(path: path, sizeBytes: size, limit: Int64(maxBytes))
            }
            return try Data(contentsOf: url)
        }
    }

    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        try await runOnQueue {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            // FileHandle.read returns up to the requested count; never throws
            // on EOF, so empty / short files just yield short Data.
            return handle.readData(ofLength: maxBytes)
        }
    }

    func writeFile(_ path: String, data: Data) async throws {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
        }
    }

    func createDirectory(_ path: String) async throws {
        try await runOnQueue {
            if FileManager.default.fileExists(atPath: path) {
                throw FileBrowserError.notWritable(path)
            }
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
        }
    }

    func createFile(_ path: String) async throws {
        try await runOnQueue {
            if FileManager.default.fileExists(atPath: path) {
                throw FileBrowserError.notWritable(path)
            }
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw FileBrowserError.notWritable(path)
            }
        }
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        // Local: just return the path itself.
        URL(fileURLWithPath: path)
    }

    // Mirrors the remote search depth bound (`searchMaxDepth = 12`) so a
    // no-match query over a large/deep tree (e.g. node_modules, .build)
    // cannot walk the entire hierarchy before returning — that would stall
    // other file operations queued behind this on the shared serial queue.
    private static let searchMaxDepth = 12

    // Hard ceiling on the number of entries examined during a single
    // `searchNames` walk, independent of the depth bound. The depth bound
    // caps how deep the walk goes but not its fan-out — a wide, shallow,
    // non-hidden tree (e.g. a top-level `node_modules`) can still contain
    // 100k+ entries within 12 levels. Without this cap a no-match query over
    // such a tree would visit every entry before returning. Silent when hit
    // (no error surfaced) — a partial, capped result set is preferable to a
    // stalled search; worth logging if this ever needs diagnosis.
    private static let searchMaxVisited = 50_000

    func searchNames(root: String, query: String, maxResults: Int, includeHidden: Bool) async throws -> [FileNode] {
        try await runOnSearchQueue {
            let fm = FileManager.default
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []) else { return [] }

            var results: [FileNode] = []
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited >= Self.searchMaxVisited { break }

                // `level` is 1 for direct children of rootURL. Once we're at
                // or beyond the depth bound, stop descending further (but
                // still consider the current entry itself for a match).
                if enumerator.level >= Self.searchMaxDepth {
                    enumerator.skipDescendants()
                }

                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                // FIX I1: prune hidden directories during the walk itself —
                // not just filter the leaf name after the fact. The tree UI
                // can only ever show a hidden directory's contents when
                // "Show Hidden Files" is on, so descending into one and
                // returning a non-hidden leaf underneath it (e.g.
                // `.git/config`) would surface a result the tree can never
                // navigate to.
                if !includeHidden && name.hasPrefix(".") {
                    if isDir { enumerator.skipDescendants() }
                    continue
                }

                guard name.range(of: query, options: [.caseInsensitive]) != nil else { continue }

                // FIX M1: classify symlinks the same way `makeNode` does —
                // `.isDirectoryKey` reflects the LINK, not its target, so a
                // symlink-to-directory would otherwise come back as `.file`
                // and get routed to `openInTree` (read-as-file → error tab)
                // instead of `revealInTree`.
                let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                let kind: FileNode.Kind
                var symlinkTargetIsDirectory = false
                if isSymlink {
                    let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
                    kind = .symlink(target: target)
                    var isTargetDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isTargetDir) {
                        symlinkTargetIsDirectory = isTargetDir.boolValue
                    }
                } else {
                    kind = isDir ? .directory : .file
                }

                results.append(FileNode(
                    id: url.path, name: name, path: url.path,
                    kind: kind, sizeBytes: nil, modifiedAt: nil,
                    symlinkTargetIsDirectory: symlinkTargetIsDirectory))
                if results.count >= maxResults { break }
            }
            return results
        }
    }

    // MARK: - helpers

    /// Builds `FileNode`s from raw directory entries, skipping any entry whose
    /// node cannot be built. A single un-stattable entry — e.g. the
    /// TCC-protected `~/.Trash`, whose `resourceValues` throws a permission
    /// error — must not abort the whole listing. `make` is injectable for tests.
    static func buildNodes(
        from rawURLs: [URL],
        parent: URL,
        make: (URL) throws -> FileNode
    ) -> [FileNode] {
        rawURLs.compactMap { rawURL -> FileNode? in
            // Re-derive each child's path via the parent so symlinks in the
            // hierarchy (e.g. /var → /private/var) are not transparently
            // resolved, keeping paths stable for callers.
            let stableURL = parent.appendingPathComponent(rawURL.lastPathComponent)
            return try? make(stableURL)
        }
        .sorted(by: naturalOrder)
    }

    private static func makeNode(from url: URL) throws -> FileNode {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let kind: FileNode.Kind
        var symlinkTargetIsDirectory = false
        if values.isSymbolicLink == true {
            // Resolve target lazily — readlink not exposed via URLResourceKey.
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            kind = .symlink(target: target)
            // Follow the link to classify the target. `isDirectory` on the resolved
            // path follows symlinks; a broken link yields false (not expandable).
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                symlinkTargetIsDirectory = isDir.boolValue
            }
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        return FileNode(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            kind: kind,
            sizeBytes: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            symlinkTargetIsDirectory: symlinkTargetIsDirectory
        )
    }

    /// Natural ordering: directories first, then case-insensitive alpha.
    private static func naturalOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private func runOnQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Like `runOnQueue`, but dispatches onto `searchQueue` instead of the
    /// shared `queue` so a long-running search walk never blocks interactive
    /// file operations (see `searchQueue`'s doc comment).
    private func runOnSearchQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            searchQueue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
