//
//  MarkdownHighlightScanner.swift
//  Treemux
//

import Foundation

/// A markdown source element kind used to drive source-editor highlighting.
enum MarkdownElement: Equatable {
    case heading
    case strong
    case emphasis
    case code
    case link
    case listMarker
    case blockquote
}

/// A pragmatic Markdown source scanner. It intentionally recognizes the
/// presentation-oriented subset needed by the editor rather than attempting
/// to implement the complete CommonMark grammar.
enum MarkdownHighlightScanner {
    struct Token: Equatable {
        let range: NSRange
        let element: MarkdownElement
    }

    private struct Line {
        let range: NSRange
        let text: String
    }

    // swiftlint:disable force_try
    private static let atxHeading = try! NSRegularExpression(pattern: "^\\s{0,3}#{1,6}(?:\\s|$).*$")
    private static let setextUnderline = try! NSRegularExpression(pattern: "^\\s{0,3}(?:=+|-+)\\s*$")
    private static let unorderedList = try! NSRegularExpression(pattern: "^\\s{0,3}[-*+]\\s")
    private static let orderedList = try! NSRegularExpression(pattern: "^\\s{0,3}\\d+[.)]\\s")
    private static let blockquote = try! NSRegularExpression(pattern: "^\\s{0,3}>")
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let link = try! NSRegularExpression(
        pattern: "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|<https?://[^>\\s]+>"
    )
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S).+?(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(
        pattern: "(?<![*\\w])\\*(?!\\*)(?=\\S).+?(?<=\\S)\\*(?!\\*)|(?<![_\\w])_(?!_)(?=\\S).+?(?<=\\S)_(?!_)"
    )
    // swiftlint:enable force_try

    static func scan(_ text: String) -> [Token] {
        let lines = lines(in: text)
        var tokens: [Token] = []
        var fenceMarker: Character?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                tokens.append(Token(range: line.range, element: .code))
                if isFence(trimmed, marker: marker) {
                    fenceMarker = nil
                }
                index += 1
                continue
            }

            if let marker = openingFenceMarker(in: trimmed) {
                tokens.append(Token(range: line.range, element: .code))
                fenceMarker = marker
                index += 1
                continue
            }

            if index + 1 < lines.count,
               !trimmed.isEmpty,
               matches(setextUnderline, in: lines[index + 1].text) {
                tokens.append(Token(range: line.range, element: .heading))
                tokens.append(Token(range: lines[index + 1].range, element: .heading))
                index += 2
                continue
            }

            if matches(atxHeading, in: line.text) {
                tokens.append(Token(range: line.range, element: .heading))
                index += 1
                continue
            }

            appendPrefixTokens(for: line, into: &tokens)
            appendInlineTokens(for: line, into: &tokens)
            index += 1
        }

        return tokens
    }

    private static func lines(in text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        var result: [Line] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let range = NSRange(substringRange, in: text)
            result.append(Line(range: range, text: nsText.substring(with: range)))
        }
        return result
    }

    private static func openingFenceMarker(in trimmedLine: String) -> Character? {
        if trimmedLine.hasPrefix("```") { return "`" }
        if trimmedLine.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func isFence(_ trimmedLine: String, marker: Character) -> Bool {
        trimmedLine.hasPrefix(String(repeating: marker, count: 3))
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func appendPrefixTokens(for line: Line, into tokens: inout [Token]) {
        let fullRange = NSRange(location: 0, length: (line.text as NSString).length)
        if let match = blockquote.firstMatch(in: line.text, range: fullRange) {
            tokens.append(Token(range: shifted(match.range, by: line.range.location), element: .blockquote))
        }

        for expression in [unorderedList, orderedList] {
            if let match = expression.firstMatch(in: line.text, range: fullRange) {
                tokens.append(Token(range: shifted(match.range, by: line.range.location), element: .listMarker))
                break
            }
        }
    }

    /// Inline code claims its range before links and emphasis so markdown-like
    /// punctuation inside code is never styled as prose markup.
    private static func appendInlineTokens(for line: Line, into tokens: inout [Token]) {
        let fullRange = NSRange(location: 0, length: (line.text as NSString).length)
        var claimed: [NSRange] = []

        func append(_ expression: NSRegularExpression, element: MarkdownElement) {
            expression.enumerateMatches(in: line.text, range: fullRange) { match, _, _ in
                guard let range = match?.range,
                      !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else {
                    return
                }
                claimed.append(range)
                tokens.append(Token(range: shifted(range, by: line.range.location), element: element))
            }
        }

        append(inlineCode, element: .code)
        append(link, element: .link)
        append(strong, element: .strong)
        append(emphasis, element: .emphasis)
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
