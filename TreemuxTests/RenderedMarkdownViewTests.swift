import SwiftUI
import XCTest
@testable import Treemux

final class RenderedMarkdownViewTests: XCTestCase {
    func test_constructs() {
        _ = RenderedMarkdownView(content: "# Hello\n\nWorld `code` and ```swift\nfunc f(){}\n```")
    }
}
