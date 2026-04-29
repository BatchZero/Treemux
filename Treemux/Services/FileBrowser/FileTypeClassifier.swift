//
//  FileTypeClassifier.swift
//  Treemux

import Foundation

enum FileViewKind: Equatable {
    case text
    case image
    case quickLook
    case binary
    case unknown
}

enum FileTypeClassifier {
    private static let textExts: Set<String> = [
        "txt", "md", "markdown", "rst", "log",
        "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "py", "rb", "js", "jsx", "ts", "tsx", "css", "scss", "html", "xml", "json", "yaml", "yml", "toml", "ini", "conf", "sh", "zsh", "bash", "fish", "lua", "vim",
        "gitignore", "gitattributes", "env", "dockerfile", "makefile",
        "plist", "xcconfig", "pbxproj", "podspec",
        "csv", "tsv", "sql"
    ]

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg", "ico"
    ]

    private static let quickLookExts: Set<String> = [
        "pdf",
        "mp4", "mov", "m4v", "avi", "mkv",
        "mp3", "wav", "aiff", "m4a", "flac",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "rtf", "rtfd"
    ]

    static func classifyByName(_ filename: String) -> FileViewKind {
        let lower = filename.lowercased()
        // Special filenames without extensions.
        let basename = (lower as NSString).lastPathComponent
        if ["dockerfile", "makefile", "rakefile", "gemfile", "podfile", "license", "readme", "changelog", "authors", "contributors"].contains(basename) {
            return .text
        }
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty { return .unknown }
        if textExts.contains(ext) { return .text }
        if imageExts.contains(ext) { return .image }
        if quickLookExts.contains(ext) { return .quickLook }
        // Anything else with a known extension is treated as binary by default.
        return .binary
    }

    /// Sniff up to 8 KB to decide text vs. binary (null bytes => binary).
    static func classifyByContent(_ data: Data) -> FileViewKind {
        let sample = data.prefix(8192)
        if sample.contains(0) { return .binary }
        if String(data: sample, encoding: .utf8) != nil { return .text }
        return .binary
    }

    /// Returns a `SupportedLanguage` for the file at `path` based on its
    /// extension, or `nil` for files we don't have a tree-sitter grammar for.
    static func language(forPath path: String) -> SupportedLanguage? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "js", "mjs", "cjs": return .javascript
        case "ts": return .typescript
        case "tsx", "jsx": return .tsx
        case "py": return .python
        case "go": return .go
        case "rs": return .rust
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        case "css", "scss", "less": return .css
        case "sh", "bash", "zsh": return .bash
        default: return nil
        }
    }
}

/// Subset of languages the in-app editor highlights via tree-sitter. Maps to
/// `CodeLanguage` cases in the editor representable.
enum SupportedLanguage: String {
    case swift, javascript, typescript, tsx, python, go, rust, json, yaml, markdown, html, css, bash
}
