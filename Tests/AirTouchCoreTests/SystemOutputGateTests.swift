import XCTest
@testable import AirTouchCore

final class SystemOutputGateTests: XCTestCase {
    let p = Point(100, 200)
    private func started() -> SystemOutputGate {
        var gate = SystemOutputGate()
        _ = gate.begin(generation: 3, position: p, now: 10)
        gate.heartbeat(generation: 3, capturedAt: 10.01, validHand: true, now: 10.01)
        return gate
    }
    func testSecondaryClickRequiresFreshHandAndCannotInterruptDrag() {
        var gate = started()
        XCTAssertEqual(gate.accept([.secondaryClick(p)], generation: 3, now: 10.02, permitted: true), [.secondaryClick(p)])
        _ = gate.accept([.down(p)], generation: 3, now: 10.03, permitted: true)
        XCTAssertEqual(gate.accept([.secondaryClick(p)], generation: 3, now: 10.04, permitted: true), [])
        _ = gate.accept([.up(p)], generation: 3, now: 10.05, permitted: true)
        XCTAssertEqual(gate.accept([.secondaryClick(p)], generation: 3, now: 10.22, permitted: true), [])
        gate = started()
        XCTAssertEqual(gate.accept([.secondaryClick(p)], generation: 3, now: 10.02, permitted: false), [])
    }

    func testPartiallyOccludedCameraHandWithLatencyReachesSystemOutput() throws {
        var joints: [Joint: Landmark] = [
            .wrist: Landmark(Point(0.5, 0.8)), .indexMCP: Landmark(Point(0.42, 0.62)),
            .indexPIP: Landmark(Point(0.42, 0.52)), .indexTip: Landmark(Point(0.42, 0.32)),
            .middleMCP: Landmark(Point(0.49, 0.62)), .thumbTip: Landmark(Point(0.3, 0.5))
        ]
        var engine = GestureEngine(), gate = SystemOutputGate()
        engine.start()
        _ = gate.begin(generation: engine.generation, position: engine.cursor, now: 0.1)
        var delivered: [InputIntent] = []
        for frame in 1...50 {
            let capture = Double(frame) / 30, arrival = capture + 0.1
            joints[.indexTip] = Landmark(Point(0.42 + Double(frame) * 0.0007, 0.32))
            let hand = try XCTUnwrap(FeatureExtractor.extract(joints, width: 1280, height: 720))
            let watchdogActions = engine.tick(at: arrival - 0.005)
            delivered += gate.accept(watchdogActions, generation: engine.generation, now: arrival - 0.005, permitted: true)
            _ = gate.expire(now: arrival - 0.005, permitted: true)
            let intents = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: capture, now: arrival)
            gate.heartbeat(generation: engine.generation, capturedAt: capture, validHand: true, now: arrival)
            delivered += gate.accept(intents, generation: engine.generation, now: arrival, permitted: true)
        }
        XCTAssertTrue(gate.active)
        XCTAssertTrue(delivered.contains { if case .move = $0 { return true }; return false })
        XCTAssertGreaterThan(gate.position.x, 390)
        XCTAssertFalse(delivered.contains { if case .down = $0 { return true }; return false })
    }
    func testRequiresBeginAndMatchingSession() {
        var gate = SystemOutputGate()
        XCTAssertEqual(gate.accept([.down(p)], generation: 3, now: 10, permitted: true), [])
        gate = started()
        XCTAssertEqual(gate.accept([.down(p)], generation: 2, now: 10.02, permitted: true), [])
        XCTAssertFalse(gate.held)
    }
    func testBeginAloneDoesNotAuthorizeNewPressWithoutValidHand() {
        var gate = SystemOutputGate()
        _ = gate.begin(generation: 1, position: p, now: 10)
        gate.heartbeat(generation: 1, capturedAt: 10.01, validHand: false, now: 10.01)
        XCTAssertEqual(gate.accept([.down(p)], generation: 1, now: 10.02, permitted: true), [])
    }
    func testBalancedPressAndDragRejectDuplicates() {
        var gate = started()
        let result = gate.accept([.drag(p), .up(p), .down(p), .down(p), .move(p), .scroll(5), .drag(p), .up(p), .up(p)],
                                 generation: 3, now: 10.02, permitted: true)
        XCTAssertEqual(result, [.down(p), .drag(p), .up(p)])
        XCTAssertFalse(gate.held)
    }
    func testPermissionRevocationReleasesOnceAndDisarms() {
        var gate = started()
        _ = gate.accept([.down(p)], generation: 3, now: 10.02, permitted: true)
        XCTAssertEqual(gate.accept([.drag(Point(120, 210))], generation: 3, now: 10.03, permitted: false), [.up(p)])
        XCTAssertFalse(gate.active)
        XCTAssertEqual(gate.stop(), [])
        XCTAssertEqual(gate.accept([.down(p)], generation: 3, now: 10.04, permitted: true), [])
    }
    func testEmergencyStopCannotBeUndoneByQueuedFrames() {
        var gate = started()
        _ = gate.accept([.down(p)], generation: 3, now: 10.02, permitted: true)
        XCTAssertEqual(gate.stop(), [.up(p)])
        gate.heartbeat(generation: 3, capturedAt: 10.03, validHand: true, now: 10.03)
        XCTAssertEqual(gate.accept([.down(p)], generation: 3, now: 10.03, permitted: true), [])
        _ = gate.begin(generation: 4, position: p, now: 11)
        XCTAssertEqual(gate.accept([.down(p)], generation: 3, now: 11, permitted: true), [])
    }
    func testIndependentWatchdogReleasesWhenUIStopsSendingFrames() {
        var gate = started()
        _ = gate.accept([.down(p)], generation: 3, now: 10.02, permitted: true)
        XCTAssertEqual(gate.expire(now: 10.28, permitted: true), [.up(p)])
        XCTAssertEqual(gate.expire(now: 11, permitted: true), [])
        XCTAssertFalse(gate.active)
    }
    func testInvalidHandsCannotKeepButtonHeldWithFreshFrames() {
        var gate = started()
        _ = gate.accept([.down(p)], generation: 3, now: 10.02, permitted: true)
        gate.heartbeat(generation: 3, capturedAt: 10.23, validHand: false, now: 10.23)
        XCTAssertEqual(gate.expire(now: 10.23, permitted: true), [.up(p)])
    }
    func testStaleOrFutureHeartbeatCannotExtendLease() {
        var gate = started()
        gate.heartbeat(generation: 3, capturedAt: 12, validHand: true, now: 10.2)
        gate.heartbeat(generation: 3, capturedAt: 10, validHand: true, now: 10.3)
        _ = gate.expire(now: 10.3, permitted: true)
        XCTAssertFalse(gate.active)
    }
    func testNonFiniteEventsAreRejectedAndReleaseUsesLastPosition() {
        var gate = started()
        XCTAssertEqual(gate.accept([.down(Point(.nan, 10)), .scroll(.infinity)], generation: 3, now: 10.02, permitted: true), [])
        _ = gate.accept([.down(p)], generation: 3, now: 10.03, permitted: true)
        XCTAssertEqual(gate.accept([.up(Point(.nan, 10))], generation: 3, now: 10.04, permitted: true), [.up(p)])
    }
    func testDisplayMappingUsesNegativeOriginWithoutRetinaScaling() {
        let area = DisplayArea(origin: Point(-1440, -900), width: 1440, height: 900)
        XCTAssertEqual(area.global(Point(100, 200)), Point(-1340, -700))
        XCTAssertEqual(area.local(Point(-1340, -700)), Point(100, 200))
        XCTAssertEqual(area.global(Point(2000, 1000)), Point(-1, -1))
        XCTAssertEqual(area.local(Point(-2000, -1000)), .zero)
    }
    func testRebaseReleasesHeldStateAndKeepsActualPointerLocation() {
        var engine = GestureEngine()
        _ = engine.rebase(to: Point(1500, 500), width: 1920, height: 1080)
        _ = engine.start()
        let hand = HandFeatures(index: Point(0.5, 0.4), palm: Point(0.5, 0.6))
        for frame in 1...15 {
            let time = Double(frame) / 30
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: time, now: time)
        }
        XCTAssertEqual(engine.cursor, Point(1500, 500))
        XCTAssertEqual(engine.state, .pointer)
        _ = engine.rebase(to: Point(800, 200), width: 1920, height: 1080)
        XCTAssertEqual(engine.state, .suspended)
        XCTAssertEqual(engine.cursor, Point(800, 200))
    }
}
