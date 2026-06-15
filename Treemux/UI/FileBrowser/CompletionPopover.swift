//
//  CompletionPopover.swift
//  Treemux
//
//  Glue between Treemux's `BufferWordIndex` and CodeEditSourceEditor 0.15.x's
//  built-in `CodeSuggestionDelegate` / `SuggestionController` infrastructure.
//
//  CodeEditSourceEditor already ships an NSPanel-backed suggestion popover —
//  including up/down navigation, Enter/Tab acceptance, Esc dismissal, and
//  filter-on-cursor-move handling — provided we install a delegate and set
//  `peripherals.codeSuggestionTriggerCharacters` to a non-empty set so the
//  built-in `SuggestionTriggerCharacterModel` fires on each typed character.
//
//  This file therefore intentionally does not implement an NSPanel of its own:
//  it just bridges async word-index lookups into the synchronous-ish surface
//  the upstream popover expects.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

/// Single suggestion row presented in the completion popover.
///
/// CodeEditSourceEditor's `SuggestionController` accepts any
/// `CodeSuggestionEntry`-conforming type; we only need the label / image
/// fields, with the `prefixRange` carried separately so
/// `completionWindowApplyCompletion` knows what to replace.
struct WordCompletionEntry: CodeSuggestionEntry {
    let label: String
    /// NSRange in the document covering the prefix the user typed. Used by
    /// `WordCompletionDelegate` to decide what to replace on accept; not read
    /// by `SuggestionController` itself.
    let prefixRange: NSRange

    var detail: String? { nil }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var image: Image { Image(systemName: "text.cursor") }
    var imageColor: Color { .secondary }
    var deprecated: Bool { false }
}

/// Bridges editor cursor events into `BufferWordIndex.suggestions(prefix:)`.
///
/// The delegate is held strongly by `WordCompletionCoordinator` (which is in
/// turn retained as a `TextViewCoordinator` on the editor); the
/// `TextViewController` only stores a `weak` reference.
@MainActor
final class WordCompletionDelegate: CodeSuggestionDelegate {
    /// Source of completion candidates. Re-indexed on each text change by
    /// `WordCompletionCoordinator`.
    let wordIndex: BufferWordIndex
    /// Closure resolved at call time so the delegate can short-circuit when
    /// the user has disabled completion in Settings.
    var isEnabled: () -> Bool

    /// Length threshold below which completions never fire — typing a single
    /// letter would surface every identifier in the buffer.
    static let minPrefixLength = 2
    static let suggestionLimit = 20

    init(wordIndex: BufferWordIndex, isEnabled: @escaping () -> Bool) {
        self.wordIndex = wordIndex
        self.isEnabled = isEnabled
    }

    // MARK: - CodeSuggestionDelegate

    /// Returning a non-empty set wires the upstream `SuggestionTriggerCharacterModel`
    /// to invoke us on every typed character — letters and digits already trip
    /// the trigger via `Character.isLetter` / `.isNumber`, but we also forward
    /// `.` and `_` for chained accesses (`foo.b`, `_priv`).
    func completionTriggerCharacters() -> Set<String> {
        [".", "_"]
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard isEnabled() else { return nil }
        guard let prefixInfo = await prefixInfo(in: textView, at: cursorPosition) else {
            return nil
        }
        guard prefixInfo.prefix.count >= Self.minPrefixLength else { return nil }

        let words = await wordIndex.suggestions(
            prefix: prefixInfo.prefix,
            limit: Self.suggestionLimit
        )
        guard !words.isEmpty else { return nil }

        let entries: [CodeSuggestionEntry] = words.map {
            WordCompletionEntry(label: $0, prefixRange: prefixInfo.range)
        }
        // Anchor the popover to the start of the prefix so it stays put as
        // the user keeps typing inside the same word.
        return (CursorPosition(range: NSRange(location: prefixInfo.range.location, length: 0)),
                entries)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard isEnabled() else { return nil }
        guard let prefixInfo = synchronousPrefixInfo(in: textView, at: cursorPosition) else {
            return nil
        }
        guard prefixInfo.prefix.count >= Self.minPrefixLength else { return nil }

        // Read the published snapshot directly on the main thread — O(N) over an
        // in-memory dictionary, no actor await, no semaphore, no blocking wait.
        let words = wordIndex.snapshot.suggestions(prefix: prefixInfo.prefix,
                                                   limit: Self.suggestionLimit)
        guard !words.isEmpty else { return nil }

        return words.map { WordCompletionEntry(label: $0, prefixRange: prefixInfo.range) }
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? WordCompletionEntry else { return }
        // The prefix range we cached at suggestion time may be stale if the
        // user kept typing while the popover was up — recompute against the
        // current caret so we always replace the live word in front of the
        // cursor, not whatever was there when the popover first opened.
        let liveRange: NSRange
        if let cursor = cursorPosition,
           let info = synchronousPrefixInfo(in: textView, at: cursor) {
            liveRange = info.range
        } else {
            liveRange = entry.prefixRange
        }
        textView.textView.replaceCharacters(in: liveRange, with: entry.label)
    }

    // MARK: - Prefix extraction

    private struct PrefixInfo {
        let prefix: String
        let range: NSRange
    }

    /// Async wrapper around `synchronousPrefixInfo` so call sites that already
    /// run on `MainActor` can stay on `MainActor` without wrapping the read in
    /// an extra `await MainActor.run`. (`completionSuggestionsRequested` is
    /// declared async by the upstream protocol.)
    private func prefixInfo(
        in textView: TextViewController,
        at cursorPosition: CursorPosition
    ) async -> PrefixInfo? {
        synchronousPrefixInfo(in: textView, at: cursorPosition)
    }

    /// Walks left from the caret over identifier characters and returns the
    /// resulting word + its NSRange. Returns `nil` if the caret is at the
    /// start of the document or there is no identifier directly behind it.
    private func synchronousPrefixInfo(
        in textView: TextViewController,
        at cursorPosition: CursorPosition
    ) -> PrefixInfo? {
        guard let storage = textView.textView.textStorage else { return nil }
        let location = cursorPosition.range.location
        guard location > 0, location <= storage.length else { return nil }

        let nsString = storage.string as NSString
        var start = location
        while start > 0 {
            let prevRange = NSRange(location: start - 1, length: 1)
            let ch = nsString.substring(with: prevRange)
            if isIdentifierContinuation(ch) {
                start -= 1
            } else {
                break
            }
        }
        guard start < location else { return nil }

        let length = location - start
        let prefix = nsString.substring(with: NSRange(location: start, length: length))
        guard let leading = prefix.unicodeScalars.first,
              isIdentifierStart(leading) else {
            return nil
        }
        return PrefixInfo(prefix: prefix, range: NSRange(location: start, length: length))
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        // Mirrors the leading character class of BufferWordIndex's regex.
        scalar == "_" || CharacterSet.letters.contains(scalar)
    }

    private func isIdentifierContinuation(_ string: String) -> Bool {
        // A `.` is a trigger character (dot-completion) but not part of the
        // identifier itself; treat it as a boundary so the prefix walks
        // start *after* the dot.
        guard let scalar = string.unicodeScalars.first else { return false }
        if scalar == "_" { return true }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}

/// `TextViewCoordinator` that re-indexes the active buffer after each text
/// change (debounced 300ms), pushes the snapshot into `BufferWordIndex`, and
/// keeps `WordCompletionDelegate` connected to the active text view.
@MainActor
final class WordCompletionCoordinator: ObservableObject, TextViewCoordinator {
    private let bufferID: UUID
    private let wordIndex: BufferWordIndex
    let delegate: WordCompletionDelegate

    private weak var controller: TextViewController?
    private var pendingIndexTask: Task<Void, Never>?

    /// Debounce window — the spec calls for 300ms so we don't re-tokenize a
    /// large file on every keystroke.
    private static let debounceNanoseconds: UInt64 = 300_000_000

    init(bufferID: UUID, wordIndex: BufferWordIndex, delegate: WordCompletionDelegate) {
        self.bufferID = bufferID
        self.wordIndex = wordIndex
        self.delegate = delegate
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        // Index the initial buffer contents immediately so the very first
        // completion attempt has data to work with — debounce only matters
        // for repeated edits.
        scheduleIndex(immediate: true)
    }

    func textViewDidChangeText(controller: TextViewController) {
        scheduleIndex(immediate: false)
    }

    func destroy() {
        pendingIndexTask?.cancel()
        pendingIndexTask = nil
        controller = nil
        // TODO: drop BufferWordIndex entry on sub-tab close. The coordinator's
        // destroy hook only fires when the editor view itself is torn down,
        // which doesn't always coincide with sub-tab closure. Memory cost is
        // bounded (~kilobytes per buffer) so this is deferred.
    }

    private func scheduleIndex(immediate: Bool) {
        pendingIndexTask?.cancel()
        let snapshot = controller?.text ?? ""
        let bufferID = self.bufferID
        let wordIndex = self.wordIndex
        pendingIndexTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                if Task.isCancelled { return }
            }
            await wordIndex.update(bufferID: bufferID, contents: snapshot)
            await MainActor.run { self?.pendingIndexTask = nil }
        }
    }
}
