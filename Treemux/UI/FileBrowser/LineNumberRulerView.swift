//
//  LineNumberRulerView.swift
//  Treemux

import AppKit

/// Draws line numbers in the gutter alongside an NSTextView. Recomputes
/// line ranges on geometry/text changes.
final class LineNumberRulerView: NSRulerView {
    weak var sourceTextView: NSTextView?
    private var lineStartCharacterIndices: [Int] = [0]

    init(textView: NSTextView) {
        self.sourceTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 36
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func textDidChange(_ note: Notification) {
        recomputeLineStarts()
        needsDisplay = true
    }

    func recomputeLineStarts() {
        guard let tv = sourceTextView else { return }
        let s = tv.string as NSString
        var starts: [Int] = [0]
        var i = 0
        while i < s.length {
            let r = s.range(of: "\n", options: [], range: NSRange(location: i, length: s.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + r.length)
            i = r.location + r.length
        }
        lineStartCharacterIndices = starts
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = sourceTextView,
              let layoutManager = tv.layoutManager,
              let textContainer = tv.textContainer else { return }

        if lineStartCharacterIndices.count == 1 { recomputeLineStarts() }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: tv.visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        for (idx, charStart) in lineStartCharacterIndices.enumerated() {
            guard charStart >= visibleCharRange.location,
                  charStart < visibleCharRange.location + visibleCharRange.length + 1 else { continue }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charStart)
            var glyphRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            glyphRect.origin.y -= tv.visibleRect.origin.y
            let label = "\(idx + 1)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let drawRect = NSRect(
                x: ruleThickness - labelSize.width - 4,
                y: glyphRect.minY + (glyphRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: drawRect, withAttributes: attrs)
        }
    }
}
