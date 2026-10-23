import CoreGraphics
import Foundation

/// Pure helpers for classifying input sources and windows.
///
/// Nothing here touches the system, so the heuristics are unit-testable.
public enum Heuristics {
    /// True for any Doubao input-source variant (pinyin, voice, …).
    public static func isDoubao(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(Tuning.doubaoInputSourcePrefix)
    }

    /// True for a small window hugging the bottom edge of any display — the
    /// shape of Doubao's voice-input pill, as opposed to its candidate bar or
    /// settings windows.
    ///
    /// - Parameter displays: Bounds of every active display, in the same
    ///   top-left-origin global coordinates `CGWindowListCopyWindowInfo` uses.
    public static func looksLikePill(_ frame: CGRect, displays: [CGRect]) -> Bool {
        guard frame.width > Tuning.pillMinWidth, frame.width <= Tuning.pillMaxWidth,
            frame.height > Tuning.pillMinHeight, frame.height <= Tuning.pillMaxHeight
        else { return false }

        return displays.contains { screen in
            frame.maxY >= screen.maxY - Tuning.pillBottomBand && frame.minY < screen.maxY
        }
    }
}
