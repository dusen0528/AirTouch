import XCTest
@testable import AirTouchCore

final class ResponsivenessTests: XCTestCase {
    func testMovingFilterAddsLessThan50MillisecondsOfLag() {
        var filter = OneEuroFilter()
        var lags: [Double] = []
        for frame in 0..<90 {
            let time = Double(frame) / 30
            let point = Point(0.1 + time * 0.25, 0.4)
            let output = filter.update(point, at: time)
            if frame > 30 { lags.append((point.x - output.x) / 0.25) }
        }
        let lag = lags.reduce(0, +) / Double(lags.count)
        print("FILTER_MOTION_LAG_MS=\(lag * 1000)")
        XCTAssertLessThan(lag, 0.05)
    }

    func testStationaryNoiseRemainsSmallAndMotionDoesNotOvershoot() {
        var filter = OneEuroFilter()
        var errors: [Double] = []
        for frame in 0..<120 {
            let noise = sin(Double(frame) * 1.7) * 0.0015
            let output = filter.update(Point(0.5 + noise, 0.4), at: Double(frame) / 30)
            if frame > 30 { errors.append(abs(output.x - 0.5)) }
        }
        XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 0.0004)
        filter.reset()
        for frame in 0..<60 {
            let input = Point(min(0.6, 0.2 + Double(frame) * 0.01), 0.4)
            XCTAssertLessThanOrEqual(filter.update(input, at: Double(frame) / 30).x, input.x)
        }
    }

    func testDirectControlSingleAmbiguousPoseDoesNotRequireReactivation() {
        var engine = GestureEngine(); engine.configuration.controlStyle = .direct; engine.start()
        var hand = HandFeatures(index: Point(0.5, 0.4), palm: Point(0.5, 0.6))
        for frame in 0..<18 {
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: Double(frame) / 30, now: Double(frame) / 30)
        }
        let anchor = engine.cursor
        hand.isPointer = false
        _ = engine.process(hand, sequence: 18, generation: engine.generation, capturedAt: 0.6, now: 0.6)
        hand.isPointer = true; hand.index.x += 0.03
        let actions = engine.process(hand, sequence: 19, generation: engine.generation, capturedAt: 19.0 / 30, now: 19.0 / 30)
        XCTAssertEqual(engine.state, .pointer)
        XCTAssertEqual(engine.cursor, anchor)
        XCTAssertTrue(actions.isEmpty)
    }

    func testScrollReturnsToPointerWithoutAnotherHoldOrJump() {
        var engine = GestureEngine(); engine.start()
        var hand = HandFeatures(index: Point(0.5, 0.4), palm: Point(0.5, 0.6))
        for frame in 0..<30 {
            if frame > 15 { hand.isPointer = false; hand.isScroll = true }
            _ = engine.process(hand, sequence: frame, generation: engine.generation, capturedAt: Double(frame) / 30, now: Double(frame) / 30)
        }
        XCTAssertEqual(engine.state, .scrolling)
        let anchor = engine.cursor
        hand.isScroll = false; hand.isPointer = true; hand.index.x += 0.03
        let actions = engine.process(hand, sequence: 30, generation: engine.generation, capturedAt: 1, now: 1)
        XCTAssertEqual(engine.state, .pointer)
        XCTAssertEqual(engine.cursor, anchor)
        XCTAssertTrue(actions.isEmpty)
    }
}
