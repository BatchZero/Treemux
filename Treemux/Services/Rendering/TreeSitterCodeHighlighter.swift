import SwiftUI
import CodeEditLanguages
import SwiftTreeSitter

/// Standalone tree-sitter highlighter: turns a code string + language name into a
/// colored AttributedString, reusing the grammars shipped by CodeEditLanguages.
/// Never throws — any failure yields plain (monospace, uncolored) text.
final class TreeSitterCodeHighlighter {

    /// Maps a markdown code-fence info string to a CodeLanguage, handling common aliases.
    static func language(named name: String?) -> CodeLanguage? {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return nil }
        let alias: [String: String] = [
            "py": "python", "js": "javascript", "ts": "typescript",
            "rs": "rust", "sh": "bash", "shell": "bash", "yml": "yaml",
            "objc": "objc", "c++": "cpp", "cs": "c-sharp", "rb": "ruby"
        ]
        let resolved = alias[raw] ?? raw
        return CodeLanguage.allLanguages.first {
            $0.tsName.lowercased() == resolved || $0.extensions.contains(resolved)
        }
    }

    /// Capture → color table built from the active theme (injected at construction).
    private let captureColors: [String: Color]

    init(captureColors: [String: Color]) {
        self.captureColors = captureColors
    }

    /// Cache loaded queries per language to avoid re-reading the .scm on every code block.
    private var queryCache: [String: Query] = [:]

    func attributed(code: String, languageName: String?) -> AttributedString {
        var plain = AttributedString(code)
        guard let codeLanguage = Self.language(named: languageName),
              let tsLanguage = codeLanguage.language,
              let query = query(for: codeLanguage, tsLanguage: tsLanguage) else {
            return plain
        }

        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return plain
        }
        guard let tree = parser.parse(code) else { return plain }

        let cursor = query.execute(in: tree)
        let highlights = cursor.resolve(with: .init(string: code)).highlights()

        let nsString = code as NSString
        for named in highlights {
            guard let color = CodeHighlightTheme.color(forCapture: named.name, in: captureColors) else { continue }
            let nsRange = named.range
            guard nsRange.location != NSNotFound,
                  nsRange.location + nsRange.length <= nsString.length,
                  let swiftRange = Range(nsRange, in: code),
                  let attrRange = attributedRange(swiftRange, in: code, attributed: plain) else { continue }
            plain[attrRange].foregroundColor = color
        }
        return plain
    }

    private func query(for codeLanguage: CodeLanguage, tsLanguage: Language) -> Query? {
        if let cached = queryCache[codeLanguage.tsName] { return cached }
        guard let url = codeLanguage.queryURL,
              let data = try? Data(contentsOf: url),
              let query = try? Query(language: tsLanguage, data: data) else { return nil }
        queryCache[codeLanguage.tsName] = query
        return query
    }

    /// Convert a String range to the matching AttributedString range.
    /// Swift 6.3's AttributedString.index(_:offsetByCharacters:) has no `limitedBy:` overload
    /// and crashes if the offset exceeds the string length, so we guard manually.
    private func attributedRange(
        _ range: Range<String.Index>,
        in source: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let lower = source.distance(from: source.startIndex, to: range.lowerBound)
        let upper = source.distance(from: source.startIndex, to: range.upperBound)
        let charCount = attributed.characters.count
        guard lower >= 0, upper <= charCount, lower <= upper else { return nil }
        let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
        let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
        return start..<end
    }
}
