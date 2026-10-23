import CoreGraphics
import XCTest

@testable import DoubaoVoiceRestoreCore

private let sogou = "com.sogou.inputmethod.sogou.pinyin"
private let abc = "com.apple.keylayout.ABC"
private let wechat = "com.tencent.inputmethod.wetype.pinyin"
private let doubao = "com.bytedance.inputmethod.doubaoime.pinyin"

/// Drives a `RestoreMachine` on a virtual clock and records what it asks for.
private struct Harness {
    var machine: RestoreMachine
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var current: String?
    var selected: [String] = []
    var logs: [String] = []
    /// Whether `.select` actions succeed.
    var selectSucceeds = true

    init(startingOn source: String) {
        machine = RestoreMachine(initialSourceID: source)
        current = source
    }

    mutating func advance(_ seconds: TimeInterval) { now += seconds }

    /// The user (or Doubao's hotkey) switched input source.
    mutating func switchTo(_ source: String) {
        current = source
        run(machine.inputSourceSettled(source, at: now))
    }

    /// A duplicate TIS notification for the current source.
    mutating func duplicateNotification() {
        run(machine.inputSourceSettled(current, at: now))
    }

    mutating func poll(pill: Bool = false, window: Bool = false, key: Bool = false) {
        let observation = RestoreMachine.Observation(
            currentSourceID: current, hasPill: pill, hasAnyWindow: window, sawNewKeyDown: key)
        run(machine.poll(observation, at: now))
    }

    /// Polls every 60ms for `seconds` with the given screen state.
    mutating func poll(for seconds: TimeInterval, pill: Bool = false, window: Bool = false) {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            advance(Tuning.pollInterval)
            elapsed += Tuning.pollInterval
            poll(pill: pill, window: window)
        }
    }

    /// Doubao's hotkey as observed in the wild: it first toggles to the
    /// previously selected source, then selects Doubao ~0.35s later.
    mutating func pressVoiceHotkey(hoppingThrough hop: String) {
        switchTo(hop)
        advance(0.35)
        switchTo(doubao)
    }

    /// Pill shows, user speaks, pill and every Doubao window go away.
    mutating func speakAndFinish() {
        poll(for: 0.5, pill: true)
        poll(for: 2.0, pill: true)
        poll(for: 1.0)  // windows gone; debounce then restore
    }

    private mutating func run(_ actions: [RestoreMachine.Action]) {
        for action in actions {
            switch action {
            case .log(let message):
                logs.append(message)
            case .verbose:
                break
            case .select(let target):
                selected.append(target)
                run(machine.selectResult(target, succeeded: selectSucceeds))
                if selectSucceeds {
                    // The system confirms our own switch shortly afterwards.
                    advance(Tuning.inputSourceSettleDelay)
                    switchTo(target)
                }
            }
        }
    }
}

final class RestoreMachineTests: XCTestCase {
    // MARK: Hotkey hop (the 1.0.3 / 1.0.4 regressions)

    func testFromSogouHopThroughABCRestoresSogou() {
        var h = Harness(startingOn: sogou)
        h.advance(30)
        h.pressVoiceHotkey(hoppingThrough: abc)
        XCTAssertEqual(h.machine.sourceToRestore, sogou)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [sogou])
        XCTAssertEqual(h.machine.state, .idle)
    }

    func testFromABCHopThroughSogouRestoresABC() {
        var h = Harness(startingOn: sogou)
        h.advance(5)
        h.switchTo(abc)  // user picks English on purpose
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: sogou)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [abc])
    }

    func testAlternatingDirectionsAlwaysRestoreTheUsersSource() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()

        h.advance(5)
        h.switchTo(abc)
        h.advance(5)
        h.pressVoiceHotkey(hoppingThrough: sogou)
        h.speakAndFinish()

        h.advance(5)
        h.switchTo(sogou)
        h.advance(5)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()

        XCTAssertEqual(h.selected, [sogou, abc, sogou])
    }

    func testRetriggerRightAfterRestoreStillRestoresSogou() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()
        // Immediately again: the hop is the source before our restore.
        h.advance(0.2)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [sogou, sogou])
    }

    func testOwnRestoreIsNeverTreatedAsAHop() {
        // Re-trigger with no hop within the hop window after our restore:
        // the just-restored source must be kept, not the pre-restore hop.
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()
        h.advance(0.1)
        h.switchTo(doubao)
        XCTAssertEqual(h.machine.sourceToRestore, sogou)
    }

    // MARK: History bookkeeping

    func testDuplicateNotificationsDoNotFakeAFreshSwitch() {
        var h = Harness(startingOn: abc)
        h.advance(1)
        h.switchTo(sogou)
        h.advance(30)
        // TIS repeats the same source several times right before Doubao.
        for _ in 0..<5 { h.duplicateNotification() }
        h.advance(0.1)
        h.switchTo(doubao)  // no hop this time
        XCTAssertEqual(h.machine.sourceToRestore, sogou)
    }

    func testSettledManualSwitchIsKept() {
        var h = Harness(startingOn: sogou)
        h.advance(5)
        h.switchTo(wechat)
        h.advance(5)
        h.pressVoiceHotkey(hoppingThrough: sogou)
        XCTAssertEqual(h.machine.sourceToRestore, wechat)
    }

    func testStartingOnDoubaoFallsBackToABC() {
        let machine = RestoreMachine(initialSourceID: doubao)
        XCTAssertEqual(machine.lastUserSourceID, Tuning.fallbackInputSourceID)
    }

    // MARK: Pill timing

    func testPillBeforeNotificationIsAdoptedWithHopCorrection() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.switchTo(abc)  // hop notification has settled
        h.advance(0.35)
        h.current = doubao  // Doubao selected, its notification not settled yet
        h.poll(pill: true)
        XCTAssertEqual(h.machine.state, .session)
        XCTAssertEqual(h.machine.sourceToRestore, sogou)
        XCTAssertTrue(h.logs.contains("voice session started (pill detected while idle)"))
    }

    func testLatePillAfterArmGraceIsStillAdopted() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.poll(for: Tuning.armGrace + 0.5)  // cold IME start, no pill yet
        XCTAssertEqual(h.machine.state, .idle)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [sogou])
    }

    func testManualSwitchToDoubaoWithoutPillRestoresNothing() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.switchTo(doubao)
        h.poll(for: Tuning.armGrace + 1)
        XCTAssertEqual(h.machine.state, .idle)
        XCTAssertTrue(h.selected.isEmpty)
    }

    // MARK: Session end

    func testUserSwitchingAwayMidSessionStandsDown() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.poll(for: 0.5, pill: true)
        h.switchTo(wechat)
        h.poll(for: 1.0)
        XCTAssertEqual(h.machine.state, .idle)
        XCTAssertTrue(h.selected.isEmpty)
    }

    func testWindowsReturningCancelsTheRestore() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.poll(for: 0.5, pill: true)
        h.poll(for: 0.2)  // gone, but shorter than the debounce
        h.poll(for: 0.5, window: true)  // candidate window came back
        XCTAssertTrue(h.selected.isEmpty)
        XCTAssertTrue(h.logs.contains("Doubao windows are back; restore cancelled"))
        h.poll(for: 1.0)
        XCTAssertEqual(h.selected, [sogou])
    }

    func testKeystrokeShortensTheDebounce() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.poll(for: 0.5, pill: true)
        h.advance(Tuning.pollInterval)
        h.poll(pill: true, key: true)
        h.advance(Tuning.pollInterval)
        h.poll()  // windows gone
        h.advance(Tuning.sessionGoneDelayAfterKey + 0.01)
        h.poll()
        XCTAssertEqual(h.selected, [sogou])
    }

    func testWithoutKeystrokeTheDebounceIsLonger() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.poll(for: 0.5, pill: true)
        h.advance(Tuning.pollInterval)
        h.poll()  // windows gone
        h.advance(Tuning.sessionGoneDelayAfterKey)
        h.poll()
        XCTAssertTrue(h.selected.isEmpty)
        h.advance(Tuning.sessionGoneDelay)
        h.poll()
        XCTAssertEqual(h.selected, [sogou])
    }

    func testFailedSelectReturnsToIdle() {
        var h = Harness(startingOn: sogou)
        h.selectSucceeds = false
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [sogou])
        XCTAssertTrue(h.logs.contains("voice session ended; could not select \(sogou)"))
    }

    func testRetriggerAfterFailedRestoreKeepsTheTarget() {
        // Restore failed, so Doubao stays selected; re-triggering voice gives
        // no source change, only a pill — the original target must be reused.
        var h = Harness(startingOn: sogou)
        h.selectSucceeds = false
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        h.speakAndFinish()
        h.selectSucceeds = true
        h.advance(5)
        h.speakAndFinish()
        XCTAssertEqual(h.selected, [sogou, sogou])
    }

    func testUnconfirmedRestoreTimesOut() {
        var machine = RestoreMachine(initialSourceID: sogou)
        var now = Date(timeIntervalSinceReferenceDate: 100)
        _ = machine.inputSourceSettled(doubao, at: now)
        now += 0.1
        _ = machine.poll(.init(currentSourceID: doubao, hasPill: true), at: now)
        now += 0.1
        _ = machine.poll(.init(currentSourceID: doubao), at: now)
        now += 1
        let actions = machine.poll(.init(currentSourceID: doubao), at: now)
        XCTAssertEqual(actions, [.select(sogou)])
        // No confirming notification ever arrives.
        now += Tuning.restoreConfirmTimeout + 0.1
        _ = machine.poll(.init(currentSourceID: doubao), at: now)
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: Polling demand

    func testPollingOnlyWhileThereIsSomethingToWatch() {
        var h = Harness(startingOn: sogou)
        XCTAssertFalse(h.machine.needsPolling, "idle away from Doubao")
        h.advance(10)
        h.pressVoiceHotkey(hoppingThrough: abc)
        XCTAssertTrue(h.machine.needsPolling, "arming")
        h.poll(for: 0.5, pill: true)
        XCTAssertTrue(h.machine.needsPolling, "session")
        h.poll(for: 1.0)
        XCTAssertFalse(h.machine.needsPolling, "restored and idle again")
    }

    func testPollingContinuesWhileIdleOnDoubao() {
        var h = Harness(startingOn: sogou)
        h.advance(10)
        h.switchTo(doubao)
        h.poll(for: Tuning.armGrace + 1)
        XCTAssertEqual(h.machine.state, .idle)
        XCTAssertTrue(h.machine.needsPolling, "a late pill must still be noticed")
    }
}

final class HeuristicsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testDoubaoVariantsAreRecognised() {
        XCTAssertTrue(Heuristics.isDoubao(doubao))
        XCTAssertTrue(Heuristics.isDoubao("com.bytedance.inputmethod.doubaoime"))
        XCTAssertFalse(Heuristics.isDoubao(sogou))
        XCTAssertFalse(Heuristics.isDoubao(nil))
    }

    func testPillAtTheBottomIsRecognised() {
        let pill = CGRect(x: 700, y: 900, width: 120, height: 36)
        XCTAssertTrue(Heuristics.looksLikePill(pill, displays: [screen]))
    }

    func testWindowsThatAreNotThePill() {
        let tooWide = CGRect(x: 100, y: 900, width: 600, height: 36)
        let tooHigh = CGRect(x: 700, y: 300, width: 120, height: 36)
        let tooTall = CGRect(x: 700, y: 800, width: 120, height: 150)
        for frame in [tooWide, tooHigh, tooTall] {
            XCTAssertFalse(Heuristics.looksLikePill(frame, displays: [screen]), "\(frame)")
        }
    }

    func testPillOnASecondDisplay() {
        let external = CGRect(x: 1512, y: -300, width: 2560, height: 1440)
        let pill = CGRect(x: 2600, y: 1080, width: 120, height: 36)
        XCTAssertFalse(Heuristics.looksLikePill(pill, displays: [screen]))
        XCTAssertTrue(Heuristics.looksLikePill(pill, displays: [screen, external]))
    }
}
