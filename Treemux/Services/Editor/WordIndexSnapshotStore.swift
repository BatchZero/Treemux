//
//  WordIndexSnapshotStore.swift
//  Treemux
//
//  Synchronously-readable mirror of `BufferWordIndex`'s frequency map. The
//  cursor-move completion hook is a synchronous upstream protocol method, so it
//  cannot `await` the actor. Instead the actor publishes an immutable frequency
//  snapshot here after every mutation, and the main thread reads it under a
//  short-held lock — no `DispatchSemaphore`, no main-thread blocking.
//

import Foundation

/// Pure, shared ranking used by both the actor and the snapshot store so they
/// produce identical results. Ranks by descending frequency, then ascending
/// lexicographic order; excludes any exact match for `prefix`; case-insensitive.
func rankedWordSuggestions(from freq: [String: Int], prefix: String, limit: Int) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let lower = prefix.lowercased()
    return freq.keys
        .filter { $0.lowercased().hasPrefix(lower) && $0 != prefix }
        .sorted { lhs, rhs in
            let lf = freq[lhs] ?? 0
            let rf = freq[rhs] ?? 0
            if lf != rf { return lf > rf }
            return lhs < rhs
        }
        .prefix(limit)
        .map { $0 }
}

/// Thread-safe holder for the latest frequency snapshot. `@unchecked Sendable`
/// because all access to `freq` is guarded by `lock`.
final class WordIndexSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var freq: [String: Int] = [:]

    /// Atomically replaces the published snapshot.
    func replace(_ newFreq: [String: Int]) {
        lock.lock()
        freq = newFreq
        lock.unlock()
    }

    /// Synchronously returns up to `limit` ranked suggestions for `prefix`.
    func suggestions(prefix: String, limit: Int = 20) -> [String] {
        lock.lock()
        let snapshot = freq
        lock.unlock()
        return rankedWordSuggestions(from: snapshot, prefix: prefix, limit: limit)
    }
}
