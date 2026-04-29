//
//  HookBackupService.swift
//  Treemux
//

import Foundation

/// Result of a successful backup write.
struct HookBackupResult: Equatable {
    let localPath: URL
    let timestamp: Date
}

/// Snapshots a `HookInstallChange.current` payload to a deterministic path
/// under `~/.treemux/backups/<targetID>/<provider>/`. The original config file
/// (local or remote) is never read or written here — the caller is expected to
/// have already populated `change.current` with the file's existing contents.
@MainActor
final class HookBackupService {
    private let now: () -> Date
    private let home: URL
    private let fm: FileManager

    init(now: @escaping () -> Date = Date.init,
         home: URL = URL(fileURLWithPath: NSHomeDirectory()),
         fm: FileManager = .default) {
        self.now = now
        self.home = home
        self.fm = fm
    }

    /// Write `change.current` to a timestamped file. Throws
    /// `HookInstallError.ioError` if `change.current` is nil or the write fails.
    func backup(
        change: HookInstallChange,
        target: HookTarget,
        provider: AIHookProvider
    ) async throws -> HookBackupResult {
        guard let current = change.current else {
            throw HookInstallError.ioError("Nothing to back up: file does not exist")
        }

        let timestamp = now()
        let dir = home
            .appendingPathComponent(".treemux/backups", isDirectory: true)
            .appendingPathComponent(Self.sanitize(target.id), isDirectory: true)
            .appendingPathComponent(provider.kind.rawValue, isDirectory: true)
        let basename = (change.path as NSString).lastPathComponent
        let filename = "\(basename).\(Self.formatter.string(from: timestamp))"
        let url = dir.appendingPathComponent(filename)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try current.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError("backup \(url.path): \(error.localizedDescription)")
        }
        return HookBackupResult(localPath: url, timestamp: timestamp)
    }

    /// Replace characters that aren't safe in a path segment. Only ":" appears
    /// in our target IDs today (`remote:user@host`), so a single substitution
    /// suffices.
    private static func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: ":", with: "_")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
