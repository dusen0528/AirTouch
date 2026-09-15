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

}
