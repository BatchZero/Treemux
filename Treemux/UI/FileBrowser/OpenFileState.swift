//
//  OpenFileState.swift
//  Treemux

import AppKit
import Foundation

enum OpenFileState: Equatable {
    case empty
    case loadingMeta(path: String)
    case loadingContent(path: String)
    case confirmingLargeFile(path: String, sizeBytes: Int64)
    case text(path: String, content: String, encoding: String.Encoding, dirty: Bool)
    case image(path: String, image: NSImage)
    case quickLook(path: String, localFileURL: URL)
    case binary(path: String, metadata: FileMetadata)
    case error(path: String, message: String)

    static func == (lhs: OpenFileState, rhs: OpenFileState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.loadingMeta(let a), .loadingMeta(let b)): return a == b
        case (.loadingContent(let a), .loadingContent(let b)): return a == b
        case (.confirmingLargeFile(let a, let s1), .confirmingLargeFile(let b, let s2)):
            return a == b && s1 == s2
        case (.text(let a1, let c1, let e1, let d1), .text(let a2, let c2, let e2, let d2)):
            return a1 == a2 && c1 == c2 && e1 == e2 && d1 == d2
        case (.image(let a, _), .image(let b, _)): return a == b
        case (.quickLook(let a, _), .quickLook(let b, _)): return a == b
        case (.binary(let a, let m1), .binary(let b, let m2)): return a == b && m1 == m2
        case (.error(let a, let m1), .error(let b, let m2)): return a == b && m1 == m2
        default: return false
        }
    }
}
