//
//  AdaptiveFontSizeCalculator.swift
//  Treemux
//

import AppKit
import CoreGraphics

/// Computes per-display terminal font sizes so the rendered glyph stays at a
/// consistent physical size as a window moves between monitors with different
/// effective PPI.
///
/// Formula:
///     finalFontSize = clamp(round((BASE + offset) × currentPPI / REF_PPI), 6, 72)
///
/// `BASE` and `REF_PPI` are source-code constants — the user only ever supplies
/// an integer `offset`. Anchoring on a fixed reference PPI lets the absolute
/// "pt" value stay an implementation detail; the offset alone is what gets
/// persisted and exposed to the user.
enum AdaptiveFontSizeCalculator {
    static let base: Int = 14
    static let referencePPI: CGFloat = 109
    static let offsetRange: ClosedRange<Int> = -8 ... 12

    /// Pure formula — used for tests and when PPI is already known.
    static func fontSize(forPPI ppi: CGFloat, offset: Int) -> Int {
        let clamped = clampOffset(offset)
        let raw = CGFloat(base + clamped) * ppi / referencePPI
        let rounded = Int(raw.rounded())
        return max(6, min(72, rounded))
    }

    /// Runtime convenience — falls back to `referencePPI` when the screen has no
    /// usable physical size (AirPlay / virtual / Sidecar / EDID without size).
    static func fontSize(for screen: NSScreen?, offset: Int) -> Int {
        let ppi = effectivePPI(for: screen) ?? referencePPI
        return fontSize(forPPI: ppi, offset: offset)
    }

    static func clampOffset(_ value: Int) -> Int {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// Effective PPI = effective points / physical inches. Returns nil when the
    /// screen does not report usable EDID data.
    static func effectivePPI(for screen: NSScreen?) -> CGFloat? {
        guard let screen else { return nil }
        let displayID = screen.adaptiveDisplayID
        guard displayID != 0 else { return nil }
        let physMm = CGDisplayScreenSize(displayID)
        guard physMm.width > 0 else { return nil }
        let physInches = physMm.width / 25.4
        let effectivePoints = screen.frame.width
        let ppi = effectivePoints / physInches
        return (ppi.isFinite && ppi > 30 && ppi < 600) ? ppi : nil
    }
}

private extension NSScreen {
    /// The Core Graphics display id, or 0 when the screen has none. Scoped to
    /// this file so it does not collide with the existing private `displayID`
    /// extension in `TreemuxGhosttyController.swift`.
    var adaptiveDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) } ?? 0
    }
}
