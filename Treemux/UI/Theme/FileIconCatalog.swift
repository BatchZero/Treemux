//
//  FileIconCatalog.swift
//  Treemux
//
//  Maps a file node to a bundled icon asset. Folders/symlink/default use MDI
//  (monochrome, template-tinted); known file types use Material Icon Theme
//  (colorful, original). Brand/language logos are used only as in-tree
//  file-type labels (nominative use); see docs/THIRD_PARTY_ICONS.md.
//
//  NOTE: FileNode.Kind.symlink carries an associated value (target: String?),
//  so the switch uses `case .symlink` (bare pattern) which matches any target.
//

import SwiftUI

enum FileIconCatalog {

    struct Icon: Equatable {
        let asset: String
        let isTemplate: Bool
        let tintRole: FileIconTintRole?
    }

    static func directoryIcon(isExpanded: Bool) -> Icon {
        Icon(asset: isExpanded ? "folder-open" : "folder", isTemplate: true, tintRole: .folder)
    }

    static let symlinkIcon = Icon(asset: "link-variant", isTemplate: true, tintRole: .muted)
    static let defaultFileIcon = Icon(asset: "file-document-outline", isTemplate: true, tintRole: .muted)

    static func icon(for node: FileNode, isExpanded: Bool) -> Icon {
        switch node.kind {
        case .directory:
            return directoryIcon(isExpanded: isExpanded)
        case .symlink:
            // symlink(target: String?) — matches regardless of associated value
            return symlinkIcon
        case .file:
            if let asset = assetForFile(named: node.name) {
                return Icon(asset: asset, isTemplate: false, tintRole: nil)
            }
            return defaultFileIcon
        }
    }

    /// Returns the Material Icon Theme asset name for a file, or nil if unmapped.
    static func assetForFile(named name: String) -> String? {
        let lower = name.lowercased()
        if let byName = byFilename[lower] { return byName }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return nil }
        let ext = String(lower[lower.index(after: dot)...])
        return byExtension[ext]
    }

    private static let byFilename: [String: String] = [
        "dockerfile": "docker",
        ".gitignore": "git",
        ".gitattributes": "git",
        "package.json": "nodejs",
        "cargo.lock": "lock",
        "package-lock.json": "lock",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "react", "jsx": "react",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python",
        "rs": "rust",
        "go": "go",
        "json": "json",
        "md": "markdown", "markdown": "markdown",
        "html": "html", "htm": "html",
        "css": "css",
        "vue": "vue",
        "toml": "toml",
        "lock": "lock",
        "zip": "zip", "tar": "zip", "gz": "zip", "tgz": "zip",
        "pdf": "pdf",
        "png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
        "webp": "image", "svg": "image", "bmp": "image", "tiff": "image",
        "ico": "image", "heic": "image",
        "mp3": "audio", "wav": "audio", "flac": "audio", "aac": "audio", "m4a": "audio",
        "mp4": "video", "mov": "video", "mkv": "video", "avi": "video", "webm": "video",
        "ttf": "font", "otf": "font", "woff": "font", "woff2": "font",
        "prisma": "prisma",
    ]
}
