//
//  BufferWordIndex.swift
//  Treemux
//
//  Cheap "Tier 3a" word completion store: tokenises any number of buffer
//  contents into identifiers and exposes a frequency-ranked prefix lookup.
//  Used by the editor's CodeSuggestionDelegate to populate the suggestion
//  popover with words that are already typed somewhere in the workspace.
//

import Foundation

/// Thread-safe identifier index keyed by buffer ID.
///
/// `update(bufferID:contents:)` replaces the word set for a buffer in O(N) on
/// the contents length, maintaining a global frequency map across every
/// indexed buffer. `suggestions(prefix:)` returns up to `limit` words starting
/// with `prefix` (case-insensitive), ranked by descending frequency then by
/// ascending lexicographic order as a tie-breaker.
///
/// The regex matches the same pattern VSCode uses for its
/// "default word definition" — a leading letter or underscore followed by one
/// or more letters / digits / underscores. Single-character matches and
/// number-only tokens are intentionally excluded.
actor BufferWordIndex {
    private var wordsByBuffer: [UUID: Set<String>] = [:]
    private var freq: [String: Int] = [:]

    /// Synchronously-readable mirror of `freq`, published after every mutation.
    /// Declared `nonisolated` so the main-thread cursor hook can read it without
    /// awaiting the actor; safe because `WordIndexSnapshotStore` is `Sendable`
    /// and does its own internal locking.
    nonisolated let snapshot = WordIndexSnapshotStore()

    private static let identifierRegex: NSRegularExpression = {
        // \b[\p{L}_][\p{L}\p{N}_]+\b — a unicode-aware identifier of length >= 2.
        // Force-try is safe: the pattern is a constant.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\b[\p{L}_][\p{L}\p{N}_]+\b"#)
    }()

    /// Replaces the indexed words for a given buffer.
    ///
    /// Words present in the previous snapshot but absent from `contents` have
    /// their frequency decremented (and removed from the global map when the
    /// count hits zero). New words are inserted with frequency 1.
    func update(bufferID: UUID, contents: String) {
        let range = NSRange(contents.startIndex..., in: contents)
        var newWords: Set<String> = []
        Self.identifierRegex.enumerateMatches(in: contents, range: range) { match, _, _ in
            guard let match else { return }
            if let r = Range(match.range, in: contents) {
                newWords.insert(String(contents[r]))
            }
        }
        // Decrement old words that disappeared.
        if let prev = wordsByBuffer[bufferID] {
            for word in prev {
                let next = (freq[word] ?? 1) - 1
                if next <= 0 {
                    freq.removeValue(forKey: word)
                } else {
                    freq[word] = next
                }
            }
        }
        wordsByBuffer[bufferID] = newWords
        // Bump frequency for the new snapshot — note this counts a word once
        // per buffer it appears in, not once per occurrence; that's enough
        // signal for ranking and avoids a second pass over the contents.
        for word in newWords {
            freq[word, default: 0] += 1
        }
        snapshot.replace(freq)
    }

    /// Drops a buffer from the index. Use when a sub-tab closes so the
    /// frequency map doesn't keep ghost entries for files no longer open.
    func remove(bufferID: UUID) {
        guard let prev = wordsByBuffer.removeValue(forKey: bufferID) else { return }
        for word in prev {
            let next = (freq[word] ?? 1) - 1
            if next <= 0 {
                freq.removeValue(forKey: word)
            } else {
                freq[word] = next
            }
        }
        snapshot.replace(freq)
    }

    /// Returns up to `limit` indexed words starting with `prefix`
    /// (case-insensitive), excluding any exact match for `prefix` itself.
    func suggestions(prefix: String, limit: Int = 20) -> [String] {
        rankedWordSuggestions(from: freq, prefix: prefix, limit: limit)
    }
}
