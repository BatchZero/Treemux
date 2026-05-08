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

    /// Maximum bytes inspected by `classifyByContent`. Matches VS Code's
    /// `ZERO_BYTE_DETECTION_BUFFER_MAX_LEN` — small enough to keep remote
    /// (SFTP) reads cheap, large enough to catch real binaries reliably.
    static let sniffByteCount = 512

    static func classifyByName(_ filename: String) -> FileViewKind {
        let lower = filename.lowercased()
        // Special filenames without extensions.
        let basename = (lower as NSString).lastPathComponent
        if ["dockerfile", "makefile", "rakefile", "gemfile", "podfile", "license", "readme", "changelog", "authors", "contributors"].contains(basename) {
            return .text
        }
        let ext = (lower as NSString).pathExtension
        if textExts.contains(ext) { return .text }
        // Image and Quick Look formats must be routed by extension because
        // their bytes contain NULs and would otherwise be classified as
        // binary by `classifyByContent`.
        if imageExts.contains(ext) { return .image }
        if quickLookExts.contains(ext) { return .quickLook }
        // Defer to content sniffing for everything else, including unknown
        // source-file extensions (.jl, .zig, .nim, ...) and files without
        // an extension. The caller reads a small prefix and calls
        // `classifyByContent` to decide text vs. binary.
        return .unknown
    }

    /// Decide text vs. binary by examining the first `sniffByteCount` bytes.
    ///
    /// Mirrors VS Code's heuristic: a NUL byte in the window means binary,
    /// unless the data starts with a UTF-16 LE/BE BOM (in which case the
    /// alternating zero bytes are expected and the file is text).
    static func classifyByContent(_ data: Data) -> FileViewKind {
        if hasUTF16BOM(data) { return .text }
        let sample = data.prefix(sniffByteCount)
        if sample.contains(0) { return .binary }
        return .text
    }

    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        // FF FE = UTF-16 LE, FE FF = UTF-16 BE.
        return (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)
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
