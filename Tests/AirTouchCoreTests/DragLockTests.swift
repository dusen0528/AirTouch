import XCTest
@testable import AirTouchCore

private struct DragLockSession {
    var engine = GestureEngine()
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var frame = 0
    var events: [InputIntent] = []
    var time: Double { Double(frame) / 30 }

    init(enabled: Bool = true) {
        engine.configuration.dragLockEnabled = enabled
        _ = engine.rebase(to: Point(300, 500), width: 1800, height: 1125)
        engine.start()
        step(20)
        events = []
    }

    mutating func step(_ count: Int = 1, visible: Bool = true) {
        for _ in 0..<count {
            frame += 1
            events += engine.process(visible ? hand : nil, sequence: frame,
                generation: engine.generation, capturedAt: time, now: time)
        }
    }

    mutating func translate(_ delta: Point, frames: Int = 10) {
        for _ in 0..<frames {
            hand.index = hand.index + delta
            hand.palm = hand.palm + delta
            step()
        }
    }

    mutating func drag() {
        hand.pinchRatio = 0.15
        step(5)
        translate(Point(0.003, 0), frames: 15)
    }

    mutating func lock() {
        drag()
        hand.pinchRatio = 0.8
        step()
    }

    var downs: Int { events.filter { if case .down = $0 { return true }; return false }.count }
    var ups: Int { events.filter { if case .up = $0 { return true }; return false }.count }
}

final class DragLockTests: XCTestCase {
    func testReleaseLocksDragThenFreshPinchDropsOnceWithoutClickingAgain() {
        var s = DragLockSession()
        s.lock()
        XCTAssertTrue(s.engine.dragLocked)
        XCTAssertEqual(s.engine.state, .dragging)
        XCTAssertTrue(s.engine.isButtonHeld)
        XCTAssertEqual(s.downs, 1)
        XCTAssertEqual(s.ups, 0)
        let lockedAt = s.engine.cursor
        s.translate(Point(0.003, 0))
        XCTAssertGreaterThan(s.engine.cursor.x, lockedAt.x + 20)
        s.hand.pinchRatio = 0.15
        s.step(6)
        XCTAssertFalse(s.engine.dragLocked)
        XCTAssertEqual(s.engine.state, .pointer)
        XCTAssertFalse(s.engine.isButtonHeld)
        XCTAssertEqual(s.ups, 1)
        s.step(20)
        XCTAssertEqual(s.downs, 1, "The drop pinch must never become another click")
        XCTAssertEqual(s.ups, 1)
        s.hand.pinchRatio = 0.8
        s.step()
        s.hand.pinchRatio = 0.15
        s.step(6)
        s.hand.pinchRatio = 0.8
        s.step()
        XCTAssertEqual(s.downs, 2, "A new pinch after opening should click normally")
        XCTAssertEqual(s.ups, 2)
    }

    func testSingleFramePinchNoiseCannotDropOrAccumulateConfirmation() {
        var s = DragLockSession()
        s.lock()
        for _ in 0..<8 {
            s.hand.pinchRatio = 0.15; s.step()
            s.hand.pinchRatio = 0.30; s.step(3)
        }
        XCTAssertTrue(s.engine.dragLocked)
        XCTAssertEqual(s.ups, 0)
        s.hand.pinchRatio = 0.8; s.step()
        s.translate(Point(0.002, 0))
        XCTAssertTrue(s.engine.dragLocked)
    }

    func testLockedPointerMovesWithHiddenThumbButHeldDragReleases() {
        var s = DragLockSession()
        s.lock()
        s.hand.isPinchReliable = false
        s.hand.pinchRatio = 1
        let start = s.engine.cursor
        s.translate(Point(0.002, 0))
        XCTAssertTrue(s.engine.dragLocked)
        XCTAssertEqual(s.ups, 0)
        XCTAssertGreaterThan(s.engine.cursor.x, start.x)

        var held = DragLockSession()
        held.drag()
        held.hand.isPinchReliable = false
        held.step()
        XCTAssertEqual(held.engine.state, .suspended)
        XCTAssertEqual(held.ups, 1)
    }

    func testOpenPalmStopPauseRebaseAndRestartReleaseExactlyOnce() {
        for operation in 0..<5 {
            var s = DragLockSession()
            s.lock()
            switch operation {
            case 0: s.hand.isOpenPalm = true; s.step()
            case 1: s.events += s.engine.stop()
            case 2: s.events += s.engine.pause(reason: "물리 입력")
            case 3: s.events += s.engine.rebase(to: Point(900, 400), width: 2000, height: 1200)
            default: s.events += s.engine.start()
            }
            XCTAssertFalse(s.engine.dragLocked)
            XCTAssertEqual(s.ups, 1, "operation \(operation)")
            s.events += s.engine.stop()
            XCTAssertEqual(s.ups, 1)
        }
    }

    func testLossAndFrameTimeoutReleaseWithoutReacquiringLock() {
        for handLoss in [true, false] {
            var s = DragLockSession()
            s.lock()
            if handLoss { s.step(5, visible: false) }
            else { s.events += s.engine.tick(at: s.time + 0.21) }
            XCTAssertFalse(s.engine.dragLocked)
            XCTAssertEqual(s.engine.state, .suspended)
            XCTAssertEqual(s.ups, 1)
            s.frame += 7
            s.hand.pinchRatio = 0.15
            s.step(12)
            XCTAssertFalse(s.engine.dragLocked)
            XCTAssertEqual(s.downs, 1, "Timeout requires fresh activation, never automatic re-lock")
        }
    }

    func testLockedDragCannotStartScrollOrSecondaryClick() {
        var s = DragLockSession()
        s.lock()
        s.hand.isPointer = false
        s.hand.isScroll = true
        s.hand.secondaryPinchRatio = 0.12
        s.translate(Point(0, 0.001), frames: 12)
        XCTAssertFalse(s.events.contains { if case .scroll = $0 { return true }; return false })
        XCTAssertFalse(s.events.contains { if case .secondaryClick = $0 { return true }; return false })
        XCTAssertEqual(s.downs, 1)
        XCTAssertEqual(s.ups, 1, "A sustained incompatible pose releases the held button")
    }

    func testClickWithoutMovementStillReleasesAndDefaultDragDoesNotLock() {
        var click = DragLockSession()
        click.hand.pinchRatio = 0.15; click.step(6)
        click.hand.pinchRatio = 0.8; click.step()
        XCTAssertFalse(click.engine.dragLocked)
        XCTAssertEqual(click.downs, 1)
        XCTAssertEqual(click.ups, 1)

        XCTAssertFalse(GestureConfiguration().dragLockEnabled)
        var drag = DragLockSession(enabled: false)
        drag.lock()
        XCTAssertFalse(drag.engine.dragLocked)
        XCTAssertEqual(drag.engine.state, .pointer)
        XCTAssertEqual(drag.downs, 1)
        XCTAssertEqual(drag.ups, 1)
    }

    func testCancellingDropReanchorsBeforeResumingMovement() {
        var s = DragLockSession()
        s.lock()
        s.hand.pinchRatio = 0.15
        s.translate(Point(0.025, 0), frames: 1)
        let target = s.engine.cursor
        s.hand.pinchRatio = 0.8
        s.step()
        XCTAssertEqual(s.engine.cursor, target, "Opening a cancelled drop must not apply a filter tail")
        s.step(6)
        XCTAssertEqual(s.engine.cursor, target)
        s.translate(Point(0.002, 0))
        XCTAssertGreaterThan(s.engine.cursor.x, target.x)
        XCTAssertEqual(s.ups, 0)
    }

    func testHiddenThumbAfterDropDoesNotRearmClick() {
        var s = DragLockSession()
        s.lock()
        s.hand.pinchRatio = 0.15; s.step(6)
        s.hand.isPinchReliable = false; s.hand.pinchRatio = 1; s.step(6)
        s.hand.isPinchReliable = true; s.hand.pinchRatio = 0.15; s.step(10)
        XCTAssertEqual(s.downs, 1)
        XCTAssertEqual(s.ups, 1)
        XCTAssertEqual(s.engine.state, .pointer)
    }

    func testDisablingLockOrCaptureDeadlineReleasesHeldInput() {
        var disabled = DragLockSession()
        disabled.lock()
        disabled.engine.configuration.dragLockEnabled = false
        disabled.step()
        XCTAssertEqual(disabled.engine.state, .suspended)
        XCTAssertFalse(disabled.engine.dragLocked)
        XCTAssertEqual(disabled.ups, 1)

        var expired = DragLockSession()
        expired.lock()
        let staleTime = expired.time
        let ignored = expired.engine.process(expired.hand, sequence: expired.frame + 1,
            generation: expired.engine.generation, capturedAt: staleTime + 0.001, now: staleTime + 0.3)
        XCTAssertTrue(ignored.isEmpty, "A stale sample cannot move or release on behalf of the user")
        expired.events += expired.engine.tick(at: staleTime + 0.3)
        XCTAssertEqual(expired.ups, 1)
        XCTAssertFalse(expired.engine.dragLocked)
        expired.events += expired.engine.tick(at: staleTime + 0.4)
        XCTAssertEqual(expired.ups, 1)
    }

    func testCalibratedDragToleranceUsesFiniteBoundsAndLeavesDirectStyleAlone() {
        func state(tolerance: Double, distance: Double, style: ControlStyle = .comfortable) -> GestureState {
            var s = DragLockSession()
            s.engine.configuration.controlStyle = style
            s.engine.configuration.calibratedDragTolerance = tolerance
            s.hand.pinchRatio = 0.15; s.step(6)
            s.translate(Point(distance / 20, 0), frames: 20)
            s.step(30)
            return s.engine.state
        }
        XCTAssertEqual(state(tolerance: 0.035, distance: 0.030), .pressed,
            "Measured pinch wobble should remain a click below its calibrated tolerance")
        XCTAssertEqual(state(tolerance: 0.035, distance: 0.045), .dragging)
        XCTAssertEqual(state(tolerance: 1, distance: 0.045), .dragging,
            "An excessively large value must not make dragging unreachable")
        XCTAssertEqual(state(tolerance: -1, distance: 0.004), .pressed,
            "A corrupt negative value must still retain minimum click slack")
        XCTAssertEqual(state(tolerance: .nan, distance: 0.020), .dragging,
            "Non-finite values fall back to hand-size tolerance")
        XCTAssertEqual(state(tolerance: .infinity, distance: 0.010), .pressed)
        XCTAssertEqual(state(tolerance: 0.04, distance: 0.006, style: .direct), .dragging,
            "Direct style keeps its existing screen-point threshold")
    }
}
