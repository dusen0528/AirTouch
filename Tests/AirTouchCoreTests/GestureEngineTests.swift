import XCTest
@testable import AirTouchCore

private struct Session {
    var engine = GestureEngine()
    var time = 0.0
    var sequence = 0
    var events: [InputIntent] = []
    var hand = HandFeatures(index: Point(0.5, 0.4), palm: Point(0.5, 0.6))

    init(activate: Bool = true) {
        engine.start()
        if activate { advance(0.45) }
    }
    mutating func advance(_ duration: Double, fps: Double = 30, valid: Bool = true) {
        let end = time + duration
        while time < end - 0.000001 {
            time = min(end, time + 1 / fps); sequence += 1
            events += engine.process(valid ? hand : nil, sequence: sequence,
                generation: engine.generation, capturedAt: time, now: time)
        }
    }
    mutating func pinch() { hand.pinchRatio = 0.15; advance(0.16) }
    mutating func release() { hand.pinchRatio = 0.8; advance(0.05) }
    var downs: Int { events.filter { if case .down = $0 { return true }; return false }.count }
    var ups: Int { events.filter { if case .up = $0 { return true }; return false }.count }
}

final class GestureEngineTests: XCTestCase {
    func testUncertainThumbCanMoveButCannotPress() {
        var s = Session()
        s.hand.isPinchReliable = false; s.hand.pinchRatio = 0.1
        for _ in 0..<20 { s.hand.index.x += 0.002; s.advance(1 / 30) }
        XCTAssertEqual(s.engine.state, .pointer)
        XCTAssertEqual(s.downs, 0)
        XCTAssertGreaterThan(s.engine.cursor.x, 380)
    }

    func testUncertainThumbReleasesExistingPressImmediately() {
        var s = Session(); s.pinch()
        s.hand.isPinchReliable = false; s.advance(1 / 30)
        XCTAssertEqual(s.ups, 1)
        XCTAssertEqual(s.engine.state, .suspended)
    }

    func testSecondaryPinchClicksOnceOnReleaseWithoutPrimaryPress() {
        var s = Session()
        s.hand.secondaryPinchRatio = 0.1; s.advance(1)
        XCTAssertEqual(s.engine.state, .pressed)
        XCTAssertEqual(s.downs, 0)
        s.hand.secondaryPinchRatio = 0.8; s.advance(0.5)
        XCTAssertEqual(s.events.filter { if case .secondaryClick = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(s.ups, 0)
    }

    func testSecondaryPinchLossOrMovementCancelsClick() {
        for lost in [true, false] {
            var s = Session(); s.hand.secondaryPinchRatio = 0.1; s.advance(0.3)
            if lost { s.hand.secondaryPinchRatio = nil }
            else { s.hand.palm.x += 0.05 }
            s.advance(0.2); s.hand.secondaryPinchRatio = 0.8; s.advance(0.2)
            XCTAssertFalse(s.events.contains { if case .secondaryClick = $0 { return true }; return false })
            XCTAssertEqual(s.downs, 0)
        }
    }

    func testLatencyDoesNotPreventReleaseWhenCameraActuallyStops() {
        var engine = GestureEngine(); engine.start()
        var hand = HandFeatures(index: Point(0.4, 0.4), palm: Point(0.5, 0.6))
        var events: [InputIntent] = []
        for frame in 0..<30 {
            if frame > 18 { hand.pinchRatio = 0.1 }
            let time = Double(frame) / 30
            events += engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: time, now: time + 0.1)
        }
        XCTAssertEqual(engine.state, .pressed)
        events += engine.tick(at: 29.0 / 30 + 0.201)
        XCTAssertEqual(engine.state, .suspended)
        XCTAssertEqual(events.filter { if case .up = $0 { return true }; return false }.count, 1)
    }
    func testContinuousCameraWithInferenceLatencyCanActivateAndMove() {
        // Camera callbacks carry capture time, but arrive later. The UI watchdog
        // also runs between callbacks. No frame or hand is actually missing.
        var engine = GestureEngine()
        engine.start()
        var intents: [InputIntent] = []
        for frame in 0..<45 {
            let capture = Double(frame) / 30
            let arrival = capture + 0.100
            intents += engine.tick(at: arrival - 0.005)
            let hand = HandFeatures(index: Point(0.4 + Double(frame) * 0.002, 0.4), palm: Point(0.5, 0.6))
            intents += engine.process(hand, sequence: frame, generation: engine.generation,
                                      capturedAt: capture, now: arrival)
        }
        XCTAssertEqual(engine.state, .pointer, "Continuous valid hands must complete activation despite 100 ms inference time")
        XCTAssertTrue(intents.contains { if case .move = $0 { return true }; return false }, "Cursor must move")
    }

    func testCannotPinchToActivate() {
        var session = Session(activate: false)
        session.hand.pinchRatio = 0.1; session.advance(2)
        XCTAssertEqual(session.engine.state, .suspended)
        XCTAssertEqual(session.downs, 0)
        session.release(); session.advance(0.5)
        XCTAssertEqual(session.engine.state, .pointer)
    }

    func testShortPinchDoesNotClick() {
        var s = Session(); s.hand.pinchRatio = 0.15
        s.advance(0.04); s.release()
        XCTAssertEqual(s.downs, 0); XCTAssertEqual(s.ups, 0)
        XCTAssertEqual(s.engine.state, .pointer)
    }

    func testHeldPinchIsOneBalancedClick() {
        var s = Session(); s.pinch(); s.advance(3)
        XCTAssertEqual(s.engine.state, .pressed)
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.ups, 0)
        s.release(); s.advance(0.5)
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.ups, 1)
    }

    func testDragHasNoExtraClickAndDoesNotJumpBackOnRelease() {
        var s = Session(); s.pinch()
        let original = s.engine.cursor
        for _ in 0..<30 { s.hand.palm.x += 0.002; s.advance(1 / 30) }
        XCTAssertEqual(s.engine.state, .dragging)
        XCTAssertGreaterThan(s.engine.cursor.x, original.x)
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.ups, 0)
        XCTAssertTrue(s.events.contains { if case .drag = $0 { return true }; return false })
        s.release(); let released = s.engine.cursor; s.advance(0.2)
        XCTAssertEqual(s.ups, 1)
        XCTAssertEqual(s.engine.cursor.x, released.x, accuracy: 0.7)
    }

    func testHysteresisDoesNotRepeatPressAtBoundary() {
        var s = Session(); s.pinch()
        for ratio in [0.27, 0.35, 0.29, 0.37, 0.26] {
            s.hand.pinchRatio = ratio; s.advance(0.2)
        }
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.ups, 0)
        s.release(); XCTAssertEqual(s.ups, 1)
    }

    func testScrollCannotStealHeldButton() {
        var s = Session(); s.pinch(); s.hand.isScroll = true
        for _ in 0..<20 { s.hand.palm.y += 0.003; s.advance(1 / 30) }
        XCTAssertFalse(s.events.contains { if case .scroll = $0 { return true }; return false })
        XCTAssertEqual(s.downs, 1)
    }

    func testPinchInterruptsScrollActivationTimer() {
        var s = Session()
        s.hand.isPointer = false; s.hand.isScroll = true; s.advance(0.1)
        s.hand.isScroll = false; s.hand.isPointer = true; s.pinch()
        s.hand.pinchRatio = 0.8; s.advance(1 / 30)
        s.hand.isPointer = false; s.hand.isScroll = true; s.advance(0.1)
        XCTAssertEqual(s.engine.state, .pointer)
        s.advance(0.15)
        XCTAssertEqual(s.engine.state, .scrolling)
    }

    func testScrollDoesNotMoveCursorOrReplayEntryMovement() {
        var s = Session(); let original = s.engine.cursor
        s.hand.isPointer = false; s.hand.isScroll = true
        s.hand.palm.y += 0.04; s.advance(0.3)
        let initialScroll = s.events.compactMap { event -> Double? in
            if case .scroll(let value) = event { return value }; return nil
        }.reduce(0, +)
        XCTAssertEqual(initialScroll, 0, accuracy: 0.00001)
        for _ in 0..<20 { s.hand.palm.y += 0.002; s.advance(1 / 30) }
        XCTAssertEqual(s.engine.cursor, original)
        XCTAssertTrue(s.events.contains { if case .scroll = $0 { return true }; return false })
        s.hand.isScroll = false; s.advance(0.03)
        XCTAssertEqual(s.engine.state, .suspended)
    }

    func testWatchdogReleasesWithoutAnyNewFramesAndIsIdempotent() {
        var s = Session(); s.pinch()
        s.events += s.engine.tick(at: s.time + 0.21)
        s.events += s.engine.tick(at: s.time + 0.3)
        s.events += s.engine.stop(); s.events += s.engine.stop()
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.ups, 1)
        XCTAssertEqual(s.engine.state, .suspended)
    }

    func testInvalidHandReleasesAfterTimeoutAndNeedsActivation() {
        var s = Session(); s.pinch(); s.advance(0.16, valid: false)
        XCTAssertEqual(s.ups, 1); XCTAssertEqual(s.engine.state, .suspended)
        s.advance(0.2) // Still pinched: do not resume.
        XCTAssertEqual(s.downs, 1); XCTAssertEqual(s.engine.state, .suspended)
        s.release(); s.advance(0.4)
        XCTAssertEqual(s.engine.state, .pointer)
    }

    func testMissingCandidateFrameCannotCountTowardsHold() {
        var s = Session(); s.hand.pinchRatio = 0.15; s.advance(0.04)
        s.advance(0.04, valid: false); s.advance(0.15)
        XCTAssertEqual(s.downs, 0)
    }

    func testPreviousGenerationDuplicateAndStaleFramesAreDiscarded() {
        var s = Session(); let oldGeneration = s.engine.generation
        s.engine.stop(); s.engine.start()
        let state = s.engine.state
        let old = s.engine.process(s.hand, sequence: 100, generation: oldGeneration,
                                   capturedAt: s.time + 0.1, now: s.time + 0.1)
        let stale = s.engine.process(s.hand, sequence: 101, generation: s.engine.generation,
                                     capturedAt: s.time, now: s.time + 1)
        XCTAssertTrue(old.isEmpty); XCTAssertTrue(stale.isEmpty); XCTAssertEqual(s.engine.state, state)
        s.advance(0.5)
        let current = s.engine.cursor
        s.hand.index.x += 0.1
        XCTAssertTrue(s.engine.process(s.hand, sequence: s.sequence, generation: s.engine.generation,
            capturedAt: s.time + 0.01, now: s.time + 0.01).isEmpty)
        XCTAssertEqual(s.engine.cursor, current)
    }

    func testHandSwitchSuspendsInsteadOfTeleporting() {
        var s = Session(); s.pinch(); let position = s.engine.cursor
        s.hand.palm.x += 0.35; s.hand.index.x += 0.35; s.advance(0.03)
        XCTAssertEqual(s.ups, 1); XCTAssertEqual(s.engine.state, .suspended)
        XCTAssertEqual(s.engine.cursor, position)
    }

    func testRestAndReactivationUseCurrentCursor() {
        var s = Session(); let original = s.engine.cursor
        s.hand.isOpenPalm = true; s.advance(0.2)
        s.hand.index.x += 0.12; s.hand.palm.x += 0.12
        s.hand.isOpenPalm = false; s.advance(0.5)
        XCTAssertEqual(s.engine.state, .pointer)
        XCTAssertEqual(s.engine.cursor, original)
    }

    func testShortOcclusionRebasesMovement() {
        var s = Session(); s.advance(0.05, valid: false)
        let original = s.engine.cursor
        s.hand.index.x += 0.08; s.hand.palm.x += 0.08
        s.advance(0.03)
        XCTAssertEqual(s.engine.cursor, original)
    }

    func testSmallMovementAccumulatesAndScreenEdgeDoesNotStoreDebt() {
        var s = Session(); let start = s.engine.cursor
        for _ in 0..<100 { s.hand.index.x += 0.0001; s.advance(1 / 30) }
        XCTAssertGreaterThan(s.engine.cursor.x, start.x + 5)
        for _ in 0..<180 { s.hand.index.x += 0.005; s.advance(1 / 30) }
        XCTAssertEqual(s.engine.cursor.x, 760)
        for _ in 0..<20 { s.hand.index.x -= 0.005; s.advance(1 / 30) }
        XCTAssertLessThan(s.engine.cursor.x, 755)
    }

    func testActivationAtDifferentFrameRates() {
        for fps in [15.0, 30, 60] {
            var s = Session(activate: false)
            s.advance(0.3, fps: fps); XCTAssertEqual(s.engine.state, .suspended)
            s.advance(0.2, fps: fps); XCTAssertEqual(s.engine.state, .pointer)
            s.hand.pinchRatio = 0.1; s.advance(0.2, fps: fps)
            XCTAssertEqual(s.downs, 1)
        }
    }

    func testNonFiniteFeaturesNeverCreateInput() {
        var s = Session(); s.hand.pinchRatio = .nan; s.advance(0.3)
        XCTAssertEqual(s.downs, 0); XCTAssertEqual(s.engine.state, .suspended)
    }

    func testCompleteDemonstrationClicksDragsScrollsAndReleases() {
        var engine = GestureEngine(), scene = PracticeScene(), demo = Demonstration()
        engine.start(); var states: Set<String> = []
        while !demo.isFinished {
            let hand = demo.next(cursor: engine.cursor, scene: scene, sensitivity: engine.configuration.sensitivity)
            let time = Double(demo.frame) / 30
            let actions = engine.process(hand, sequence: demo.frame, generation: engine.generation, capturedAt: time, now: time)
            actions.forEach { scene.apply($0) }; states.insert(engine.state.rawValue)
        }
        engine.stop().forEach { scene.apply($0) }
        XCTAssertEqual(scene.clickCount, 1)
        XCTAssertEqual(scene.dropCount, 1)
        XCTAssertGreaterThan(scene.scrollDistance, 150)
        XCTAssertFalse(scene.isPressed)
        XCTAssertEqual(states, Set(GestureStateValues.all))
    }
}

private enum GestureStateValues {
    static let all = ["suspended", "pointer", "pinchCandidate", "pressed", "dragging", "scrolling"]
}
