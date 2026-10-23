import Carbon.HIToolbox
import CoreGraphics
import DoubaoVoiceRestoreCore
import Foundation

// MARK: - Input source

/// Thin wrapper over the public Text Input Source (TIS) API.
///
/// Everything here is read-only except `select(id:)`, which is the single point
/// where this tool changes system state.
enum InputSource {
    /// Bundle ID of the currently selected keyboard input source.
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: source)
    }

    /// Selects the input source with the given bundle ID.
    /// - Returns: `false` if the source is not installed or TIS refused the switch.
    static func select(id wanted: String) -> Bool {
        guard
            let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
                as? [TISInputSource]
        else { return false }

        for source in sources where id(of: source) == wanted {
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

// MARK: - Voice pill probe

/// Infers the lifetime of a Doubao voice-input session from the windows the
/// Doubao input method draws on screen.
///
/// Uses `CGWindowListCopyWindowInfo`, which reports window geometry only — no
/// screen contents are read, so no Screen Recording permission is required.
struct VoicePillProbe {
    /// Whether each window-owner PID is the Doubao IME server. PIDs are only
    /// reused after a process exits, so entries are dropped once a PID no
    /// longer owns any on-screen window.
    private var isDoubaoByPID: [pid_t: Bool] = [:]

    /// Frames of the on-screen windows currently owned by the Doubao input method.
    mutating func doubaoWindows() -> [CGRect] {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var seen: [pid_t: Bool] = [:]
        let frames: [CGRect] = windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            let isDoubao = seen[owner] ?? isDoubaoByPID[owner] ?? Self.isDoubaoProcess(owner)
            seen[owner] = isDoubao
            guard isDoubao, let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            return CGRect(
                x: bounds["X"] as? CGFloat ?? 0,
                y: bounds["Y"] as? CGFloat ?? 0,
                width: bounds["Width"] as? CGFloat ?? 0,
                height: bounds["Height"] as? CGFloat ?? 0
            )
        }
        isDoubaoByPID = seen
        return frames
    }

    /// Bounds of every active display, in window-list coordinates.
    func displayBounds() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: Tuning.maxDisplays)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(Tuning.maxDisplays), &displays, &count)
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// Matches the process name directly (one syscall, no subprocess). The
    /// window list's owner name is localized ("豆包输入法"), so it is not used.
    private static func isDoubaoProcess(_ pid: pid_t) -> Bool {
        // The kernel copies up to 2 × MAXCOMLEN bytes and fails with ENOMEM
        // on anything smaller, so MAXCOMLEN + 1 would never match.
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == Tuning.doubaoProcessName
    }
}

// MARK: - Key activity

/// Detects "the user just typed something" without any input monitoring
/// permission.
///
/// `CGEventSource.secondsSinceLastEventType` reports only *how long ago* the
/// last key-down occurred. Which key was pressed is never available to this
/// process, so this cannot be used to log keystrokes.
struct KeyActivityMonitor {
    private var isIdle = true

    /// - Returns: `true` when a new burst of typing has just started.
    mutating func sawNewKeyDown() -> Bool {
        let elapsed = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )

        if elapsed < Tuning.recentKeyDownWindow {
            defer { isIdle = false }
            return isIdle
        }
        if elapsed > Tuning.keyIdleThreshold {
            isIdle = true
        }
        return false
    }
}
