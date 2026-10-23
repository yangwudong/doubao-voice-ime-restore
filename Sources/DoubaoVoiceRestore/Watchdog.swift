import Carbon.HIToolbox
import Foundation

/// Restores the user's previous input source after a Doubao voice-input session.
///
/// Doubao's global voice hotkey selects the Doubao input source to transcribe
/// speech, then leaves it selected. This watchdog notices that switch, waits for
/// the voice session to end, and puts the previous input source back.
///
/// State machine:
/// ```
///   idle ──(Doubao selected)──▶ arming ──(pill appears)──▶ session
///     ▲                           │                          │
///     │                    (grace expires:                (Doubao windows gone
///     │                     manual switch)                 for the debounce)
///     │                           │                          │
///     └───────────────────────────┴──── restoring ◀───────────┘
/// ```
final class Watchdog {
    private enum State {
        case idle
        /// Doubao was selected; waiting to see whether a voice pill shows up.
        case arming(deadline: Date)
        /// Voice input is on screen.
        case session
        /// Restore issued; waiting for the system to confirm it.
        case restoring(deadline: Date)
    }

    private var state: State = .idle
    private var probe = VoicePillProbe()
    private var keyActivity = KeyActivityMonitor()

    /// Input source to return to when the voice session ends.
    private var sourceToRestore: String?
    /// Most recent non-Doubao input source seen — what the user actually types with.
    private var lastUserSourceID: String? = Tuning.fallbackInputSourceID
    /// When `lastUserSourceID` last changed, and what it was before that.
    ///
    /// Doubao's hotkey transiently selects the previously used source before
    /// its own input source lands. Without history that hop overwrites the
    /// real user source, and the restore picks the wrong one.
    private var lastUserSourceChangedAt: Date?
    private var previousUserSourceID: String?
    /// When every Doubao window went away, or `nil` if some are still on screen.
    private var windowsGoneSince: Date?
    private var didTypeDuringSession = false

    private let queue = DispatchQueue(label: "com.doubaovoicerestore.watchdog")
    private let isQuiet: Bool
    private let isVerbose: Bool

    init(isQuiet: Bool = false, isVerbose: Bool = false) {
        self.isQuiet = isQuiet
        self.isVerbose = isVerbose
    }

    // MARK: Lifecycle

    func run() -> Never {
        if let current = InputSource.currentID(), !InputSource.isDoubao(current) {
            lastUserSourceID = current
        }
        log("started; current source: \(InputSource.currentID() ?? "unknown")")

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.inputSourceDidChange()
        }

        let timer = Timer(timeInterval: Tuning.pollInterval, repeats: true) { [weak self] _ in
            self?.queue.async { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()

        fatalError("run loop exited unexpectedly")
    }

    // MARK: Input source changes

    private func inputSourceDidChange() {
        // TIS reports the change before it has fully settled; let it land first.
        queue.asyncAfter(deadline: .now() + Tuning.inputSourceSettleDelay) { [self] in
            let current = InputSource.currentID()
            verbose("input source -> \(current ?? "unknown") (state: \(stateName))")

            guard InputSource.isDoubao(current) else {
                // TIS often fires several notifications per switch; only a real
                // change of source may move the history, or a duplicate would
                // make a long-settled source look like a fresh hotkey hop.
                if let current, !current.isEmpty, current != lastUserSourceID {
                    previousUserSourceID = lastUserSourceID
                    lastUserSourceChangedAt = Date()
                    lastUserSourceID = current
                }
                switch state {
                case .session:
                    log("user switched away mid-session; standing down")
                    state = .idle
                case .restoring:
                    log("restore confirmed")
                    // Our own restore is trusted, never a hotkey hop.
                    if current == sourceToRestore { lastUserSourceChangedAt = nil }
                    state = .idle
                case .idle, .arming:
                    break
                }
                return
            }

            // Doubao just became active. Only a switch from a settled idle state
            // starts a candidate voice session.
            guard case .idle = state else { return }
            sourceToRestore = trustedUserSource()
            windowsGoneSince = nil
            state = .arming(deadline: Date().addingTimeInterval(Tuning.armGrace))
            log("armed; will restore \(sourceToRestore ?? "unknown")")
        }
    }

    // MARK: Polling

    private func poll() {
        // While idle and Doubao is not the selected source there is nothing
        // to watch, so skip the window query entirely and stay at ~0% CPU.
        // While Doubao IS selected, keep watching at idle: a pill that shows
        // up late (cold IME start) or after a re-trigger with no source
        // change must still be adopted, or the user is stuck on Doubao.
        if case .idle = state, !InputSource.isDoubao(InputSource.currentID()) { return }

        if keyActivity.sawNewKeyDown(), case .session = state {
            didTypeDuringSession = true
        }

        let windows = probe.doubaoWindows()
        let hasPill = windows.contains { probe.looksLikePill($0) }
        let hasAnyWindow = !windows.isEmpty

        switch state {
        case .idle:
            // Adopt the session whenever a pill is on screen while Doubao is
            // selected — whether the input-source notification already fired
            // (early pill) or the arming grace has since expired (late pill).
            if hasPill, InputSource.isDoubao(InputSource.currentID()) {
                sourceToRestore = trustedUserSource()
                beginSession(reason: "pill detected while idle")
            }

        case .arming(let deadline):
            if hasPill {
                beginSession(reason: "pill detected")
            } else if Date() > deadline {
                log("no pill within \(Tuning.armGrace)s; treating as a manual switch")
                state = .idle
            }

        case .session:
            if hasAnyWindow {
                if windowsGoneSince != nil { log("Doubao windows are back; restore cancelled") }
                windowsGoneSince = nil
            } else if windowsGoneSince == nil {
                windowsGoneSince = Date()
                log("Doubao windows gone; restoring in \(String(format: "%.2f", restoreDelay))s")
            } else if Date().timeIntervalSince(windowsGoneSince!) >= restoreDelay {
                restore()
            }

        case .restoring(let deadline):
            if Date() > deadline {
                log("no confirmation for the restore; standing down")
                state = .idle
            }
        }
    }

    private func beginSession(reason: String) {
        state = .session
        windowsGoneSince = nil
        didTypeDuringSession = false
        log("voice session started (\(reason))")
    }

    private func restore() {
        guard let target = sourceToRestore, !target.isEmpty else {
            state = .idle
            return
        }

        if InputSource.select(id: target) {
            log("voice session ended; restored \(target)")
            state = .restoring(deadline: Date().addingTimeInterval(Tuning.restoreConfirmTimeout))
        } else {
            log("voice session ended; could not select \(target)")
            state = .idle
        }
    }

    // MARK: Helpers

    /// The source to restore: skips the hop that landed right before Doubao
    /// was selected.
    ///
    /// Doubao's hotkey first toggles to the *previously* selected source and
    /// only ~0.35s later selects Doubao — so from Sogou it hops through ABC,
    /// and from ABC it hops through Sogou. The hop can be any kind of source.
    private func trustedUserSource() -> String? {
        guard let changedAt = lastUserSourceChangedAt,
            Date().timeIntervalSince(changedAt) < Tuning.hotkeyHopWindow,
            let previous = previousUserSourceID, !previous.isEmpty
        else { return lastUserSourceID }
        log("skipping transient \(lastUserSourceID ?? "unknown"); restoring \(previous) instead")
        return previous
    }

    /// A keystroke is an explicit end-of-session signal, so restore sooner.
    private var restoreDelay: TimeInterval {
        didTypeDuringSession ? Tuning.sessionGoneDelayAfterKey : Tuning.sessionGoneDelay
    }

    private var stateName: String {
        switch state {
        case .idle: "idle"
        case .arming: "arming"
        case .session: "session"
        case .restoring: "restoring"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private func log(_ message: String) {
        guard !isQuiet else { return }
        print("\(Self.timestampFormatter.string(from: Date())) \(message)")
        fflush(stdout)
    }

    /// Per-input-source-change detail; only emitted with `--verbose`.
    private func verbose(_ message: String) {
        guard isVerbose, !isQuiet else { return }
        log(message)
    }
}
