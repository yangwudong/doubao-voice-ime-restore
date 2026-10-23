import Carbon.HIToolbox
import DoubaoVoiceRestoreCore
import Foundation

/// Restores the user's previous input source after a Doubao voice-input session.
///
/// Doubao's global voice hotkey selects the Doubao input source to transcribe
/// speech, then leaves it selected. This watchdog notices that switch, waits for
/// the voice session to end, and puts the previous input source back.
///
/// All decisions live in `RestoreMachine`; this class only feeds it system
/// observations and carries out the actions it returns. Everything runs on one
/// serial queue, so the machine never sees concurrent events.
final class Watchdog {
    private var machine: RestoreMachine
    private var probe = VoicePillProbe()
    private var keyActivity = KeyActivityMonitor()

    private let queue = DispatchQueue(label: "com.doubaovoicerestore.watchdog")
    /// Runs only while `machine.needsPolling`; idle away from Doubao the
    /// process makes no wakeups at all.
    private var pollTimer: DispatchSourceTimer?
    /// Last Doubao window set logged in verbose mode, to log only changes.
    private var lastLoggedWindows: [CGRect] = []
    private let isQuiet: Bool
    private let isVerbose: Bool

    init(isQuiet: Bool = false, isVerbose: Bool = false) {
        self.isQuiet = isQuiet
        self.isVerbose = isVerbose
        self.machine = RestoreMachine(initialSourceID: InputSource.currentID())
    }

    // MARK: Lifecycle

    func run() -> Never {
        log("started; current source: \(InputSource.currentID() ?? "unknown")")

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.inputSourceDidChange()
        }

        queue.async { self.updatePolling() }
        // Distributed notifications are delivered through the main run loop,
        // so it must run (dispatchMain would not service it).
        RunLoop.main.run()
        fatalError("run loop exited unexpectedly")
    }

    // MARK: Events

    private func inputSourceDidChange() {
        // TIS reports the change before it has fully settled; let it land first.
        queue.asyncAfter(deadline: .now() + Tuning.inputSourceSettleDelay) { [self] in
            perform(machine.inputSourceSettled(InputSource.currentID(), at: Date()))
        }
    }

    private func poll() {
        let current = InputSource.currentID()
        // Skip the window query when the machine would ignore it anyway.
        var observation = RestoreMachine.Observation(currentSourceID: current)
        if !machine.isIdle || Heuristics.isDoubao(current) {
            let windows = probe.doubaoWindows()
            let displays = probe.displayBounds()
            observation.hasPill = windows.contains {
                Heuristics.looksLikePill($0, displays: displays)
            }
            observation.hasAnyWindow = !windows.isEmpty
            observation.sawNewKeyDown = keyActivity.sawNewKeyDown()
            if isVerbose, windows != lastLoggedWindows {
                lastLoggedWindows = windows
                log("doubao windows: \(windows.map(describe)) pill: \(observation.hasPill)")
            }
        }
        perform(machine.poll(observation, at: Date()))
    }

    private func perform(_ actions: [RestoreMachine.Action]) {
        for action in actions {
            switch action {
            case .log(let message):
                log(message)
            case .verbose(let message):
                if isVerbose { log(message) }
            case .select(let target):
                let succeeded = InputSource.select(id: target)
                perform(machine.selectResult(target, succeeded: succeeded))
            }
        }
        updatePolling()
    }

    /// Starts or stops the poll timer to match what the machine needs.
    private func updatePolling() {
        if machine.needsPolling, pollTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(), repeating: Tuning.pollInterval, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            pollTimer = timer
        } else if !machine.needsPolling, let timer = pollTimer {
            timer.cancel()
            pollTimer = nil
        }
    }

    // MARK: Logging

    private func describe(_ frame: CGRect) -> String {
        "(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))"
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
}
