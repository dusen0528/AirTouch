import XCTest
@testable import AirTouchCore

private struct UsabilitySession {
    var engine = GestureEngine()
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var sequence = 0
    var events: [InputIntent] = []
    init(activate: Bool = true) {
        _ = engine.rebase(to: Point(900, 500), width: 1800, height: 1125)
        engine.start()
        if activate { frames(20) }
        events = []
    }
    mutating func frames(_ count: Int) {
        for _ in 0..<count {
            sequence += 1
            let t = Double(sequence) / 30
            events += engine.process(hand, sequence: sequence, generation: engine.generation, capturedAt: t, now: t)
        }
    }
    mutating func scrollPose() { hand.isPointer = false; hand.isScroll = true }
}

final class GestureUsabilityTests: XCTestCase {
    func testTwoFingerPoseCanStartAndResumeScrollingDirectly() {
        var s = UsabilitySession(activate: false)
        s.scrollPose(); s.frames(20)
        XCTAssertEqual(s.engine.state, .scrolling)
        s.hand.palm.y += 0.03; s.frames(4)
        XCTAssertTrue(s.events.contains { if case .scroll = $0 { return true }; return false })
        _ = s.engine.pause(reason: "test hand loss")
        s.frames(20)
        XCTAssertEqual(s.engine.state, .scrolling)
    }

    func testBriefAmbiguousScrollPoseFreezesThenResumesWithoutJump() {
        var s = UsabilitySession(); s.scrollPose(); s.frames(12)
        s.events = []
        s.hand.isScroll = false; s.hand.palm.y += 0.03; s.frames(2)
        XCTAssertEqual(s.engine.state, .scrolling)
        XCTAssertTrue(s.events.isEmpty)
        s.hand.isScroll = true; s.frames(1)
        XCTAssertEqual(s.engine.state, .scrolling)
        XCTAssertTrue(s.events.isEmpty, "Do not replay travel made while the pose was unclear")
        s.hand.palm.y += 0.02; s.frames(4)
        XCTAssertTrue(s.events.contains { if case .scroll = $0 { return true }; return false })
    }

    func testSustainedAmbiguousScrollStopsAndOpenPalmStillStopsImmediately() {
        var s = UsabilitySession(); s.scrollPose(); s.frames(12)
        s.hand.isScroll = false; s.frames(8)
        XCTAssertEqual(s.engine.state, .suspended)
        s.scrollPose(); s.frames(20)
        s.hand.isOpenPalm = true; s.frames(1)
        XCTAssertEqual(s.engine.state, .suspended)
        XCTAssertFalse(s.events.contains { if case .down = $0 { return true }; return false })
    }

    func testQuickDeliberatePinchClicksButSingleFrameContactDoesNot() {
        var s = UsabilitySession()
        s.hand.pinchRatio = 0.15; s.frames(3) // 67 ms of observed contact.
        s.hand.pinchRatio = 0.8; s.frames(1)
        XCTAssertEqual(s.events.filter { if case .down = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(s.events.filter { if case .up = $0 { return true }; return false }.count, 1)
        s.events = []
        s.hand.pinchRatio = 0.15; s.frames(1)
        s.hand.pinchRatio = 0.8; s.frames(1)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testSecondClickKeepsTargetThroughSmallReleaseMotion() {
        var s = UsabilitySession()
        s.hand.pinchRatio = 0.15; s.frames(5)
        s.hand.pinchRatio = 0.8; s.frames(1)
        let target = s.engine.cursor
        s.hand.palm.x += 0.005; s.frames(4)
        s.hand.pinchRatio = 0.15; s.frames(5)
        s.hand.pinchRatio = 0.8; s.frames(1)
        let clicks = s.events.compactMap { event -> Point? in if case .down(let p) = event { return p }; return nil }
        XCTAssertEqual(clicks.count, 2)
        XCTAssertTrue(clicks.allSatisfy { $0 == target }, "Pinching twice must not drift off the first target")
        s.hand.palm.x += 0.06; s.frames(6)
        XCTAssertGreaterThan(s.engine.cursor.x, target.x + 20, "Deliberate movement must break the click anchor")
    }
}
