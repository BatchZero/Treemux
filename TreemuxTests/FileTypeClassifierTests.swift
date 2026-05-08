//
//  FileTypeClassifierTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class FileTypeClassifierTests: XCTestCase {
    // MARK: - Name-based fast paths

    func testTextByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("README.md"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.swift"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("data.json"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.txt"), .text)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.YML"), .text)
    }

    func testImageByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.png"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("foo.JPG"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("anim.gif"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("photo.heic"), .image)
        XCTAssertEqual(FileTypeClassifier.classifyByName("vector.svg"), .image)
    }

    func testQuickLookByExtension() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.pdf"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("clip.mp4"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("song.mp3"), .quickLook)
        XCTAssertEqual(FileTypeClassifier.classifyByName("doc.docx"), .quickLook)
    }

    /// Unknown extensions defer to content sniffing rather than being
    /// pre-judged as binary. Source files for languages we don't have in our
    /// fast-path whitelist (Julia, Zig, Nim, ...) used to render as binary —
    /// they must now reach the content-sniff fallback.
    func testUnknownExtensionDefersToContentSniff() {
        XCTAssertEqual(FileTypeClassifier.classifyByName("script.jl"), .unknown)
        XCTAssertEqual(FileTypeClassifier.classifyByName("main.zig"), .unknown)
        XCTAssertEqual(FileTypeClassifier.classifyByName("lib.nim"), .unknown)
        XCTAssertEqual(FileTypeClassifier.classifyByName("a.exe"), .unknown)
        XCTAssertEqual(FileTypeClassifier.classifyByName("noext"), .unknown)
    }

    // MARK: - Content sniffing

    func testTextSniffOnUtf8Bytes() {
        let utf8 = "Hello 你好\nworld".data(using: .utf8)!
        XCTAssertEqual(FileTypeClassifier.classifyByContent(utf8), .text)
    }

    func testBinarySniffOnNullBytes() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .binary)
    }

    /// UTF-16 LE text contains alternating zero bytes for ASCII codepoints.
    /// A naive null-byte sniff would call this binary; the BOM tells us it's
    /// text and the sniff should respect that.
    func testSniffUtf16LEBOMIsText() {
        // BOM (FF FE) + "Hi" in UTF-16 LE: 'H'=0x48,0x00 'i'=0x69,0x00
        let bytes = Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .text)
    }

    func testSniffUtf16BEBOMIsText() {
        // BOM (FE FF) + "Hi" in UTF-16 BE: 'H'=0x00,0x48 'i'=0x00,0x69
        let bytes = Data([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .text)
    }

    /// Empty files have no null bytes, so they classify as text. Matches
    /// VS Code's behavior — empty files open in the text editor.
    func testSniffEmptyDataIsText() {
        XCTAssertEqual(FileTypeClassifier.classifyByContent(Data()), .text)
    }

    /// Only the first 512 bytes are inspected. A NUL beyond that boundary
    /// must not flip the verdict — matches VS Code's
    /// ZERO_BYTE_DETECTION_BUFFER_MAX_LEN = 512.
    func testSniffOnlyExaminesFirst512Bytes() {
        var bytes = Data(repeating: 0x41, count: 512) // 512 'A's
        bytes.append(0x00) // NUL at offset 512 — past the window
        XCTAssertEqual(FileTypeClassifier.classifyByContent(bytes), .text)
    }
}
