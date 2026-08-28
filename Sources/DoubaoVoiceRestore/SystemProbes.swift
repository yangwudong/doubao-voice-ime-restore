import Carbon.HIToolbox
import CoreGraphics
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

    static func isDoubao(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(Tuning.doubaoInputSourcePrefix)
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
    private var cachedPID: pid_t = 0

    /// On-screen windows currently owned by the Doubao input method.
    mutating func doubaoWindows() -> [CGRect] {
        let pid = resolvePID()
        guard pid != 0 else { return [] }
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        return windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            return CGRect(
                x: bounds["X"] as? CGFloat ?? 0,
                y: bounds["Y"] as? CGFloat ?? 0,
                width: bounds["Width"] as? CGFloat ?? 0,
                height: bounds["Height"] as? CGFloat ?? 0
            )
        }
    }

    /// True for a small window hugging the bottom edge of any display — the
    /// shape of Doubao's voice-input pill, as opposed to its candidate bar or
    /// settings windows.
    func looksLikePill(_ frame: CGRect) -> Bool {
        guard frame.width > Tuning.pillMinWidth, frame.width <= Tuning.pillMaxWidth,
            frame.height > Tuning.pillMinHeight, frame.height <= Tuning.pillMaxHeight
        else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Tuning.maxDisplays)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(Tuning.maxDisplays), &displays, &count)

        for index in 0..<Int(count) {
            let screen = CGDisplayBounds(displays[index])
            if frame.maxY >= screen.maxY - Tuning.pillBottomBand, frame.minY < screen.maxY {
                return true
            }
        }
        return false
    }

    /// PID of the Doubao input method server, cached until the process exits.
    private mutating func resolvePID() -> pid_t {
        if cachedPID != 0, kill(cachedPID, 0) == 0 { return cachedPID }

        let output = try? Self.run("/usr/bin/pgrep", ["-x", Tuning.doubaoProcessName])
        let firstLine = output?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
        cachedPID = firstLine.flatMap { pid_t($0) } ?? 0
        return cachedPID
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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
