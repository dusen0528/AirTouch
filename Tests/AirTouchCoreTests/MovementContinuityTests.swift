import XCTest
@testable import AirTouchCore

final class MovementContinuityTests: XCTestCase {
    func testDelayedButContinuouslyDeliveredPointerFramesDoNotRearm() {
        var engine = GestureEngine(); engine.start()
        var interrupted = 0
        for frame in 0..<60 {
            let capture = Double(frame) / 30
            // A 130 ms frame followed by a 176 ms frame has a 79 ms delivery gap.
            let age = frame > 20 ? [0.176, 0.143, 0.130][frame % 3] : 0.130
            let hand = HandFeatures(index: Point(0.3 + capture * 0.05, 0.35), palm: Point(0.3 + capture * 0.05, 0.55))
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: capture, now: capture + age)
            if frame > 20 && engine.state != .pointer { interrupted += 1 }
        }
        print("CONTINUOUS_POINTER_INTERRUPTED_FRAMES=\(interrupted)")
        XCTAssertEqual(interrupted, 0)
    }

    func testFoldedMiddleFingerNearThumbDoesNotStealPointer() {
        var engine = GestureEngine(); engine.start()
        var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55), secondaryPinchRatio: 0.6)
        for frame in 0..<45 {
            hand.palm.x += 0.001; hand.index.x += 0.001
            if frame > 20 { hand.secondaryPinchRatio = 0.17 }
            let t = Double(frame) / 30
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: t, now: t)
            if frame > 20 { XCTAssertEqual(engine.state, .pointer) }
        }
    }

    func testBriefUncertainFingerPoseKeepsPalmMovementContinuous() {
        var engine = GestureEngine()
        _ = engine.rebase(to: Point(300, 500), width: 1800, height: 1125)
        engine.start()
        var hand = HandFeatures(index: Point(0.3, 0.35), palm: Point(0.3, 0.55))
        for frame in 0..<40 {
            hand.palm.x += 0.003; hand.index.x += 0.003
            hand.isPointer = frame != 30
            let t = Double(frame) / 30
            let events = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: t, now: t)
            if frame == 30 || frame == 31 {
                XCTAssertTrue(events.contains { if case .move = $0 { return true }; return false })
            }
        }
    }

    func testSavedUserLatencySegmentWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["AIRTOUCH_REPLAY_PATH"] else {
            throw XCTSkip("Local user trace is intentionally not stored in Git")
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let frames = try XCTUnwrap(root["activeFrames"] as? [[String: Any]])
            .filter { (1088...1114).contains($0["sequence"] as? Int ?? -1) }
        XCTAssertEqual(frames.count, 27)
        let start = try XCTUnwrap(frames.first?["capturedAt"] as? Double)
        var engine = GestureEngine(); engine.start()
        var interrupted = 0, checked = 0
        for frame in frames {
            let h = try XCTUnwrap(frame["features"] as? [String: Any])
            func n(_ key: String) throws -> Double { try XCTUnwrap(h[key] as? Double) }
            let hand = HandFeatures(index: Point(try n("indexX"), try n("indexY")), palm: Point(try n("palmX"), try n("palmY")),
                palmScale: try n("palmScale"), pinchRatio: try n("pinchRatio"),
                isPointer: h["isPointer"] as? Bool ?? false, isScroll: h["isScroll"] as? Bool ?? false,
                isOpenPalm: h["isOpenPalm"] as? Bool ?? false, isPinchReliable: h["isPinchReliable"] as? Bool ?? false,
                secondaryPinchRatio: h["secondaryPinchRatio"] as? Double)
            let capture = try XCTUnwrap(frame["capturedAt"] as? Double) - start
            let arrival = try XCTUnwrap(frame["receivedAt"] as? Double) - start
            _ = engine.process(hand, sequence: try XCTUnwrap(frame["sequence"] as? Int), generation: engine.generation,
                               capturedAt: capture, now: arrival)
            if capture > 0.45 {
                checked += 1
                if engine.state != .pointer { interrupted += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 8)
        print("USER_REPLAY_CHECKED=\(checked) INTERRUPTED=\(interrupted)")
        XCTAssertEqual(interrupted, 0)
    }

    func testPreparedSecondaryPinchWorksBeforeAndAfterScrollActivation() {
        for preparationFrames in [5, 10] {
            var engine = GestureEngine(); engine.start()
            var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55), secondaryPinchRatio: 0.8)
            var frame = 0, events: [InputIntent] = []
            func step(_ count: Int) {
                for _ in 0..<count {
                    frame += 1; let t = Double(frame) / 30
                    events += engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: t, now: t)
                }
            }
            step(20)
            hand.isPointer = false; hand.isScroll = true; step(preparationFrames)
            hand.isPointer = true; hand.isScroll = false; hand.secondaryPinchRatio = 0.1; step(5)
            hand.secondaryPinchRatio = 0.8; step(3)
            XCTAssertEqual(engine.state, .pointer)
            XCTAssertEqual(events.filter { if case .secondaryClick = $0 { return true }; return false }.count, 1)
            XCTAssertFalse(events.contains { if case .down = $0 { return true }; return false })
            hand.secondaryPinchRatio = 0.1; step(5)
            XCTAssertEqual(engine.state, .pointer, "An old preparation must not arm a second click")
        }
    }

    func testFrameSilenceStillStopsPointer() {
        var engine = GestureEngine(); engine.start()
        let hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
        for frame in 0..<30 {
            let t = Double(frame) / 30
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: t, now: t + 0.17)
        }
        XCTAssertEqual(engine.state, .pointer)
        XCTAssertTrue(engine.tick(at: 29.0 / 30 + 0.17 + 0.121).isEmpty)
        XCTAssertEqual(engine.state, .suspended)
    }

    func testProlongedPoseUncertaintyAndOpenPalmStillStopMovement() {
        for openPalm in [false, true] {
            var engine = GestureEngine(); engine.start()
            var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
            for frame in 0..<35 {
                if frame >= 20 { hand.isPointer = false; hand.isOpenPalm = openPalm }
                let t = Double(frame) / 30
                _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: t, now: t)
            }
            XCTAssertEqual(engine.state, .suspended)
        }
    }
}
