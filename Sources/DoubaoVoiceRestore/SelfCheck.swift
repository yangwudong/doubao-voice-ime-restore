import Darwin
import DoubaoVoiceRestoreCore
import Foundation

/// Exercises every system call the watchdog relies on, read-only, and reports
/// what it sees.
///
/// The decision logic is unit-tested in `DoubaoVoiceRestoreCore`; this covers
/// the glue those tests cannot reach (TIS, the window server, `proc_name`).
/// Hard failures exit non-zero, so CI and `install.sh` catch a broken build.
/// Doubao itself is optional: a missing IME only produces a warning.
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(label): \(detail)")
            if !ok { failures += 1 }
        }
        func note(_ ok: Bool, _ label: String, _ detail: String) {
            print("\(ok ? "ok  " : "warn") \(label): \(detail)")
        }

        let current = InputSource.currentID()
        check(current != nil, "current input source", current ?? "unreadable")

        let installed = InputSource.installedIDs()
        check(
            current.map(installed.contains) ?? false, "input source list",
            "\(installed.count) enabled, current one found: \(current.map(installed.contains) ?? false)"
        )

        // The exact call that broke 1.1.0 during development: a too-small
        // buffer made proc_name fail for every process.
        let ownName = VoicePillProbe.processName(getpid())
        check(ownName == programName, "proc_name", "own process is \(ownName ?? "unreadable")")

        var probe = VoicePillProbe()
        let windows = probe.doubaoWindowList()
        check(
            windows != nil, "window list",
            windows.map { "\($0.count) Doubao window(s)" } ?? "query failed")

        let displays = probe.displayBounds()
        check(!displays.isEmpty, "displays", "\(displays.count) active")

        let doubaoSources = installed.filter(Heuristics.isDoubao)
        note(
            !doubaoSources.isEmpty, "Doubao input source",
            doubaoSources.isEmpty ? "not enabled" : doubaoSources.joined(separator: ", "))

        let doubaoRunning = runningProcessIDs().contains {
            VoicePillProbe.processName($0) == Tuning.doubaoProcessName
        }
        note(doubaoRunning, "Doubao IME process", doubaoRunning ? "running" : "not running")

        print(failures == 0 ? "self-check passed" : "self-check failed: \(failures) problem(s)")
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE
    }

    private static func runningProcessIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(filled))))
    }
}
