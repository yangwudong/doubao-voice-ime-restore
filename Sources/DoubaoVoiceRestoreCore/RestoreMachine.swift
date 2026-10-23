import Foundation

/// Decides when a Doubao voice-input session starts and ends, and which input
/// source to put back afterwards.
///
/// This is the whole decision logic with every system call stripped out: the
/// caller feeds in observations stamped with the time they were made, and the
/// machine answers with actions to perform. That keeps every timing scenario —
/// hotkey hops, duplicate notifications, early or late pills — unit-testable.
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
public struct RestoreMachine {
    public enum State: Equatable {
        case idle
        /// Doubao was selected; waiting to see whether a voice pill shows up.
        case arming(deadline: Date)
        /// Voice input is on screen.
        case session
        /// Restore issued; waiting for the system to confirm it.
        case restoring(deadline: Date)
    }

    /// Side effects for the caller to carry out, in order.
    public enum Action: Equatable {
        /// A state transition worth logging by default.
        case log(String)
        /// Per-input-source-change detail, only logged with `--verbose`.
        case verbose(String)
        /// Select this input source, then report back via `selectResult`.
        case select(String)
    }

    /// What one poll tick saw on screen.
    public struct Observation: Equatable {
        public var currentSourceID: String?
        public var hasPill: Bool
        public var hasAnyWindow: Bool
        public var sawNewKeyDown: Bool

        public init(
            currentSourceID: String?, hasPill: Bool = false, hasAnyWindow: Bool = false,
            sawNewKeyDown: Bool = false
        ) {
            self.currentSourceID = currentSourceID
            self.hasPill = hasPill
            self.hasAnyWindow = hasAnyWindow || hasPill
            self.sawNewKeyDown = sawNewKeyDown
        }
    }

    public private(set) var state: State = .idle
    /// Input source to return to when the voice session ends.
    public private(set) var sourceToRestore: String?
    /// Most recent non-Doubao input source seen — what the user actually types with.
    public private(set) var lastUserSourceID: String? = Tuning.fallbackInputSourceID

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
    /// Whether Doubao was the selected source at the latest observation.
    private var isDoubaoSelected = false

    public init(initialSourceID: String?) {
        if let initialSourceID, !initialSourceID.isEmpty, !Heuristics.isDoubao(initialSourceID) {
            lastUserSourceID = initialSourceID
        }
        isDoubaoSelected = Heuristics.isDoubao(initialSourceID)
    }

    /// Whether the caller must keep polling windows. When idle away from
    /// Doubao there is nothing to watch, so the poll timer can stop entirely.
    public var needsPolling: Bool {
        if case .idle = state { return isDoubaoSelected }
        return true
    }

    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    // MARK: Events

    /// The selected input source settled on `current`.
    public mutating func inputSourceSettled(_ current: String?, at now: Date) -> [Action] {
        var actions: [Action] = [
            .verbose("input source -> \(current ?? "unknown") (state: \(stateName))")
        ]
        isDoubaoSelected = Heuristics.isDoubao(current)

        guard isDoubaoSelected else {
            // TIS often fires several notifications per switch; only a real
            // change of source may move the history, or a duplicate would
            // make a long-settled source look like a fresh hotkey hop.
            if let current, !current.isEmpty, current != lastUserSourceID {
                previousUserSourceID = lastUserSourceID
                lastUserSourceChangedAt = now
                lastUserSourceID = current
            }
            switch state {
            case .session:
                actions.append(.log("user switched away mid-session; standing down"))
                state = .idle
            case .restoring:
                actions.append(.log("restore confirmed"))
                // Our own restore is trusted, never a hotkey hop.
                if current == sourceToRestore { lastUserSourceChangedAt = nil }
                state = .idle
            case .idle, .arming:
                break
            }
            // Doubao is no longer selected, so any pending target is stale.
            if case .idle = state { sourceToRestore = nil }
            return actions
        }

        // Doubao just became active. Only a switch from a settled idle state
        // starts a candidate voice session.
        guard case .idle = state else { return actions }
        sourceToRestore = trustedUserSource(at: now, actions: &actions)
        windowsGoneSince = nil
        state = .arming(deadline: now.addingTimeInterval(Tuning.armGrace))
        actions.append(.log("armed; will restore \(sourceToRestore ?? "unknown")"))
        return actions
    }

    /// One poll tick's observation of the screen.
    public mutating func poll(_ observation: Observation, at now: Date) -> [Action] {
        isDoubaoSelected = Heuristics.isDoubao(observation.currentSourceID)
        if case .idle = state, !isDoubaoSelected { return [] }

        if observation.sawNewKeyDown, case .session = state {
            didTypeDuringSession = true
        }

        var actions: [Action] = []
        switch state {
        case .idle:
            // Adopt the session whenever a pill is on screen while Doubao is
            // selected — whether the input-source notification has not settled
            // yet (early pill) or the arming grace has expired (late pill).
            if observation.hasPill {
                // A late pill belongs to the Doubao selection we already armed
                // for: keep that target. Recomputing now would fall outside
                // the hop window and mistake the hotkey hop for the user's source.
                if sourceToRestore == nil {
                    sourceToRestore = trustedUserSource(at: now, actions: &actions)
                }
                beginSession(reason: "pill detected while idle", actions: &actions)
            }

        case .arming(let deadline):
            if observation.hasPill {
                beginSession(reason: "pill detected", actions: &actions)
            } else if now > deadline {
                actions.append(
                    .log("no pill within \(Tuning.armGrace)s; treating as a manual switch"))
                state = .idle
            }

        case .session:
            if observation.hasAnyWindow {
                if windowsGoneSince != nil {
                    actions.append(.log("Doubao windows are back; restore cancelled"))
                }
                windowsGoneSince = nil
            } else if let goneSince = windowsGoneSince {
                if now.timeIntervalSince(goneSince) >= restoreDelay {
                    restore(at: now, actions: &actions)
                }
            } else {
                windowsGoneSince = now
                let delay = String(format: "%.2f", restoreDelay)
                actions.append(.log("Doubao windows gone; restoring in \(delay)s"))
            }

        case .restoring(let deadline):
            if now > deadline {
                actions.append(.log("no confirmation for the restore; standing down"))
                state = .idle
            }
        }
        return actions
    }

    /// Outcome of carrying out a `.select` action.
    public mutating func selectResult(_ target: String, succeeded: Bool) -> [Action] {
        guard succeeded else {
            state = .idle
            return [.log("voice session ended; could not select \(target)")]
        }
        return [.log("voice session ended; restored \(target)")]
    }

    // MARK: Helpers

    private mutating func beginSession(reason: String, actions: inout [Action]) {
        state = .session
        windowsGoneSince = nil
        didTypeDuringSession = false
        actions.append(.log("voice session started (\(reason))"))
    }

    private mutating func restore(at now: Date, actions: inout [Action]) {
        guard let target = sourceToRestore, !target.isEmpty else {
            state = .idle
            return
        }
        state = .restoring(deadline: now.addingTimeInterval(Tuning.restoreConfirmTimeout))
        actions.append(.select(target))
    }

    /// The source to restore: skips the hop that landed right before Doubao
    /// was selected.
    ///
    /// Doubao's hotkey first toggles to the *previously* selected source and
    /// only ~0.35s later selects Doubao — so from Sogou it hops through ABC,
    /// and from ABC it hops through Sogou. The hop can be any kind of source.
    private func trustedUserSource(at now: Date, actions: inout [Action]) -> String? {
        guard let changedAt = lastUserSourceChangedAt,
            now.timeIntervalSince(changedAt) < Tuning.hotkeyHopWindow,
            let previous = previousUserSourceID, !previous.isEmpty
        else { return lastUserSourceID }
        actions.append(
            .log(
                "skipping transient \(lastUserSourceID ?? "unknown"); restoring \(previous) instead"
            ))
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
}
