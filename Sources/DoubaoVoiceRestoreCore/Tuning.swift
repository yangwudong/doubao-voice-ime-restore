import CoreGraphics
import Foundation

/// Heuristics used to recognise a Doubao voice-input session.
///
/// Doubao exposes no API for "voice input started / ended", so the session is
/// inferred from the small on-screen ASR pill window it draws. If a future
/// Doubao release changes that window's size or placement, these are the knobs
/// to turn — nothing else in the code hard-codes those assumptions.
public enum Tuning {
    // MARK: Identity

    /// Bundle-ID prefix shared by every Doubao input-source variant
    /// (pinyin, handwriting, voice, …).
    public static let doubaoInputSourcePrefix = "com.bytedance.inputmethod.doubaoime"

    /// Process name of the Doubao input method server, used to find its windows.
    public static let doubaoProcessName = "DoubaoIme"

    /// Input source to fall back to if we never observed a non-Doubao source.
    public static let fallbackInputSourceID = "com.apple.keylayout.ABC"

    // MARK: Voice pill geometry

    public static let pillMinWidth: CGFloat = 10
    public static let pillMaxWidth: CGFloat = 280
    public static let pillMinHeight: CGFloat = 8
    public static let pillMaxHeight: CGFloat = 64

    /// The pill must sit within this many points of the bottom of some display.
    public static let pillBottomBand: CGFloat = 200

    /// Upper bound on displays inspected when locating the pill.
    public static let maxDisplays = 8

    // MARK: Timing

    /// How long the pill is allowed to take to appear after Doubao is selected.
    public static let armGrace: TimeInterval = 3.0

    /// Debounce after every Doubao window disappears, before restoring.
    public static let sessionGoneDelay: TimeInterval = 0.35

    /// Shorter debounce when the user ended the session by pressing a key —
    /// the intent is unambiguous, so restore faster.
    public static let sessionGoneDelayAfterKey: TimeInterval = 0.12

    /// Window-polling cadence. The poll timer only runs while there is
    /// something to watch; when idle away from Doubao it is stopped.
    public static let pollInterval: TimeInterval = 0.06

    /// Grace period for the input source to settle after a change notification.
    public static let inputSourceSettleDelay: TimeInterval = 0.12

    /// How long to wait for confirmation that our restore took effect.
    public static let restoreConfirmTimeout: TimeInterval = 1.5

    /// Doubao's hotkey first toggles to the previously selected source and
    /// selects Doubao ~0.35s later. A source that appeared this recently
    /// before Doubao is treated as that hop, and the one before it restored.
    public static let hotkeyHopWindow: TimeInterval = 0.8

    /// A keyDown this recent counts as "the user just typed".
    public static let recentKeyDownWindow: TimeInterval = 0.35

    /// Silence this long re-arms keystroke detection.
    public static let keyIdleThreshold: TimeInterval = 0.7
}
