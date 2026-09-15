import XCTest
@testable import AirTouchCore

private struct ControlSession {
    var engine = GestureEngine()
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var frame = 0
    var events: [InputIntent] = []

    init() {
        _ = engine.rebase(to: Point(300, 500), width: 1800, height: 1125)
        engine.start()
        for _ in 0..<20 { step() }
        events = []
    }
    mutating func step() {
        frame += 1
        let time = Double(frame) / 30
        events += engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: time, now: time)
    }
    mutating func translate(_ delta: Point) {
        hand.index = hand.index + delta; hand.palm = hand.palm + delta
        step()
    }
}

final class ComfortableControlTests: XCTestCase {
    func testBendingIndexToPrepareClickDoesNotMoveTarget() {
        var s = ControlSession()
        let target = s.engine.cursor
        // Finger flexes before the pinch threshold; the hand itself stays put.
        for _ in 0..<9 { s.hand.index.y += 0.004; s.step() }
        XCTAssertLessThan((s.engine.cursor - target).length, 1)
    }

    func testSlowMovementIsPreciseWhileFastMovementCoversDistance() {
        func travel(frames: Int) -> Double {
            var s = ControlSession()
            let start = s.engine.cursor
            for _ in 0..<frames { s.translate(Point(0.12 / Double(frames), 0)) }
            for _ in 0..<20 { s.step() }
            return s.engine.cursor.x - start.x
        }
        let slow = travel(frames: 90), fast = travel(frames: 12)
        print("POINTER_TRAVEL_PT slow=\(slow) fast=\(fast)")
        XCTAssertGreaterThan(slow, 40, "Small deliberate movements must not be swallowed")
        XCTAssertLessThan(slow, 200, "Aiming needs a lower gain")
        XCTAssertGreaterThan(fast, 300, "Crossing the screen must still be practical")
        XCTAssertGreaterThan(fast, slow * 1.7)
    }

    func testSmallHandShiftDuringClickDoesNotBecomeDrag() {
        var s = ControlSession()
        let target = s.engine.cursor
        s.hand.pinchRatio = 0.15
        for _ in 0..<7 { s.step() }
        for _ in 0..<6 { s.translate(Point(0.004 / 6, 0)) }
        for _ in 0..<10 { s.step() }
        s.hand.pinchRatio = 0.8; s.step()
        XCTAssertFalse(s.events.contains { if case .drag = $0 { return true }; return false })
        XCTAssertEqual(s.engine.cursor, target)
        XCTAssertEqual(s.events.filter { if case .down = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(s.events.filter { if case .up = $0 { return true }; return false }.count, 1)
    }

    func testStationaryScrollPoseDoesNotCreep() {
        var s = ControlSession()
        s.hand.isPointer = false; s.hand.isScroll = true
        for _ in 0..<12 { s.step() }
        s.events = []
        for frame in 0..<60 {
            s.hand.palm.y = 0.55 + sin(Double(frame) * 1.7) * 0.0015
            s.step()
        }
        let travel = s.events.compactMap { event -> Double? in if case .scroll(let value) = event { return abs(value) }; return nil }.reduce(0, +)
        XCTAssertLessThan(travel, 1)
    }

    func testDeliberateDragReleasesWithoutJumpAndCanMoveAgain() {
        var s = ControlSession()
        s.hand.pinchRatio = 0.15
        for _ in 0..<7 { s.step() }
        for _ in 0..<20 { s.translate(Point(0.002, 0)) }
        XCTAssertEqual(s.engine.state, .dragging)
        XCTAssertGreaterThan(s.engine.cursor.x, 330)
        s.hand.index.y -= 0.08 // Finger opens while the palm stays put.
        s.hand.pinchRatio = 0.8; s.step()
        let released = s.engine.cursor
        for _ in 0..<15 { s.step() }
        XCTAssertEqual(s.engine.cursor, released)
        XCTAssertEqual(s.events.filter { if case .down = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(s.events.filter { if case .up = $0 { return true }; return false }.count, 1)
        for _ in 0..<10 { s.translate(Point(-0.002, 0)) }
        XCTAssertLessThan(s.engine.cursor.x, released.x)
    }

    func testSlowScrollStillMovesBothWaysAndReturnsWithoutJump() {
        var s = ControlSession()
        s.hand.isPointer = false; s.hand.isScroll = true
        for _ in 0..<12 { s.step() }
        let cursor = s.engine.cursor
        s.events = []
        for _ in 0..<30 { s.translate(Point(0, 0.0005)) }
        let forward = s.events.compactMap { event -> Double? in
            if case .scroll(let value) = event { return value }; return nil
        }.reduce(0, +)
        XCTAssertGreaterThan(forward, 15)
        s.events = []
        for _ in 0..<40 { s.translate(Point(0, -0.0005)) }
        let reverse = s.events.compactMap { event -> Double? in
            if case .scroll(let value) = event { return value }; return nil
        }.reduce(0, +)
        XCTAssertLessThan(reverse, -15)
        s.hand.isScroll = false; s.hand.isPointer = true; s.step()
        XCTAssertEqual(s.engine.state, .pointer)
        XCTAssertEqual(s.engine.cursor, cursor)
    }

    func testPrecisionGainDoesNotDependOnCameraFrameRate() {
        var distances: [Double] = []
        for fps in [15, 30, 60] {
            var engine = GestureEngine()
            engine.start()
            var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
            for frame in 0..<(fps * 4) {
                let time = Double(frame) / Double(fps)
                if frame >= fps && frame < fps * 3 {
                    hand.index.x += 0.06 / Double(fps)
                    hand.palm.x += 0.06 / Double(fps)
                }
                _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: time, now: time)
            }
            distances.append(engine.cursor.x - 380)
        }
        XCTAssertGreaterThan(distances.min()!, 40)
        XCTAssertLessThan(distances.max()! / distances.min()!, 1.10)
    }
}
