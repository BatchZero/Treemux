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

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Avoid silent overwrite when two backups land in the same second.
            let baseURL = dir.appendingPathComponent(filename)
            var url = baseURL
            var n = 2
            while fm.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(filename)-\(n)")
                n += 1
            }
            try current.write(to: url, atomically: true, encoding: .utf8)
            return HookBackupResult(localPath: url, timestamp: timestamp)
        } catch {
            throw HookInstallError.ioError("backup \(dir.path)/\(filename): \(error.localizedDescription)")
        }
    }

    /// Whitelist of characters allowed in a sanitized target-ID path segment.
    /// Anything else (including "/", ":", "..") is replaced with "_" to keep
    /// the backup tree strictly under `~/.treemux/backups/<targetID>/`.
    private static let safeChars: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "._@-")
        return s
    }()

    private static func sanitize(_ id: String) -> String {
        String(id.unicodeScalars.map { safeChars.contains($0) ? Character($0) : "_" })
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
