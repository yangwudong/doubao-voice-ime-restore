import CoreGraphics
import Foundation

/// Heuristics used to recognise a Doubao voice-input session.
///
/// Doubao exposes no API for "voice input started / ended", so the session is
/// inferred from the small on-screen ASR pill window it draws. If a future
/// Doubao release changes that window's size or placement, these are the knobs
/// to turn — nothing else in the code hard-codes those assumptions.
enum Tuning {
    // MARK: Identity

    /// Bundle-ID prefix shared by every Doubao input-source variant
    /// (pinyin, handwriting, voice, …).
    static let doubaoInputSourcePrefix = "com.bytedance.inputmethod.doubaoime"

    /// Process name of the Doubao input method server, used to find its windows.
    static let doubaoProcessName = "DoubaoIme"

    /// Input source to fall back to if we never observed a non-Doubao source.
    static let fallbackInputSourceID = "com.apple.keylayout.ABC"

    // MARK: Voice pill geometry

    static let pillMinWidth: CGFloat = 10
    static let pillMaxWidth: CGFloat = 280
    static let pillMinHeight: CGFloat = 8
    static let pillMaxHeight: CGFloat = 64

    /// The pill must sit within this many points of the bottom of some display.
    static let pillBottomBand: CGFloat = 200

    /// Upper bound on displays inspected when locating the pill.
    static let maxDisplays = 8

    // MARK: Timing

    /// How long the pill is allowed to take to appear after Doubao is selected.
    static let armGrace: TimeInterval = 3.0

    /// Debounce after every Doubao window disappears, before restoring.
    static let sessionGoneDelay: TimeInterval = 0.35

    /// Shorter debounce when the user ended the session by pressing a key —
    /// the intent is unambiguous, so restore faster.
    static let sessionGoneDelayAfterKey: TimeInterval = 0.12

    /// Window-polling cadence. Polling is skipped entirely while idle.
    static let pollInterval: TimeInterval = 0.06

    /// Grace period for the input source to settle after a change notification.
    static let inputSourceSettleDelay: TimeInterval = 0.12

    /// How long to wait for confirmation that our restore took effect.
    static let restoreConfirmTimeout: TimeInterval = 1.5

    /// A keyDown this recent counts as "the user just typed".
    static let recentKeyDownWindow: TimeInterval = 0.35

    /// Silence this long re-arms keystroke detection.
    static let keyIdleThreshold: TimeInterval = 0.7
}
