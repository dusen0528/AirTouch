import XCTest
@testable import AirTouchCore

private struct CalibrationRun {
    var session = PersonalCalibrationSession()
    var time = 0.0
    var hand = HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5))

    init() { session.start(at: 0, date: Date(timeIntervalSince1970: 1_800_000_000)) }

    mutating func frame(palm: Point = Point(0.5, 0.5), pinch: Double = 0.8,
                        reliable: Bool = true, qualified: Bool = true, dt: Double = 1 / 30) {
        time += dt
        hand.palm = palm; hand.index = Point(palm.x, palm.y - 0.15)
        hand.pinchRatio = pinch; hand.isPinchReliable = reliable
        hand.isPointer = pinch >= 0.5
        session.update(hand, capturedAt: time, now: time + 0.06, confidenceQualified: qualified)
    }

    mutating func completeMovement(noise: Double = 0.001, horizontal: Double = 0.18,
                                   vertical: Double = 0.16, reliable: Bool = true) {
        var n = 0
        while session.stage == .steady && n < 300 {
            frame(palm: Point(0.5 + sin(Double(n) * 1.7) * noise, 0.5), reliable: reliable)
            n += 1
        }
        n = 0
        while session.stage == .horizontal && n < 300 {
            frame(palm: Point(0.5 + sin(Double(n) / 20) * horizontal, 0.5), reliable: reliable)
            n += 1
        }
        n = 0
        while session.stage == .vertical && n < 300 {
            frame(palm: Point(0.5, 0.5 + sin(Double(n) / 20) * vertical), reliable: reliable)
            n += 1
        }
    }

    mutating func completePinches(open: Double = 0.8, closed: Double = 0.15, shift: Double = 0.006) {
        for _ in 0..<30 { frame(pinch: open) }
        for _ in 0..<3 {
            for _ in 0..<20 { frame(palm: Point(0.5 + shift, 0.5), pinch: closed) }
            for _ in 0..<20 { frame(pinch: open) }
        }
        for _ in 0..<60 where session.stage == .pinch { frame(pinch: open) }
    }
}

final class PersonalCalibrationTests: XCTestCase {
    func testRealSampleSequenceCompletesAndPersistsOnlyBoundedAggregates() throws {
        var run = CalibrationRun()
        run.completeMovement()
        XCTAssertEqual(run.session.stage, .pinch)
        run.completePinches()
        XCTAssertEqual(run.session.stage, .completed)
        let profile = try XCTUnwrap(run.session.profile)
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.pinchCycles, 3)
        XCTAssertGreaterThanOrEqual(profile.observedSeconds, 24)
        XCTAssertLessThan(profile.observedSeconds, 26)
        XCTAssertGreaterThan(profile.acceptedSamples, 700)
        XCTAssertGreaterThan(profile.pinchEnter, profile.pinchClosedRatio)
        XCTAssertLessThan(profile.pinchExit, profile.pinchOpenRatio)
        XCTAssertGreaterThanOrEqual(profile.dragTolerance, 0.008)
        XCTAssertEqual(run.session.snapshot.progress, 1)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PersonalCalibrationProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(object.keys.contains { ["palm", "index", "landmarks", "samples", "coordinates"].contains($0) })
        XCTAssertTrue(object.values.allSatisfy { $0 is NSNumber }, "Profile must not persist arrays of hand coordinates")
    }

    func testTimeAloneAndCameraAbsenceNeverCompleteCalibration() {
        var run = CalibrationRun()
        run.session.tick(at: 15)
        XCTAssertEqual(run.session.stage, .steady)
        XCTAssertEqual(run.session.snapshot.stageProgress, 0)
        run.session.tick(at: 21)
        XCTAssertEqual(run.session.stage, .failed)
        XCTAssertEqual(run.session.failure, .insufficientSamples)
        XCTAssertNil(run.session.profile)
    }

    func testStaleDuplicateAndUnqualifiedSamplesDoNotEarnTime() {
        var run = CalibrationRun()
        for _ in 0..<30 { run.frame() }
        let before = run.session.snapshot.stageProgress
        for _ in 0..<10 {
            run.session.update(run.hand, capturedAt: run.time, now: run.time + 0.1, confidenceQualified: true)
        }
        XCTAssertEqual(run.session.snapshot.stageProgress, before)
        for _ in 0..<30 { run.frame(qualified: false) }
        run.session.update(run.hand, capturedAt: run.time + 0.01, now: run.time + 0.4, confidenceQualified: true)
        XCTAssertEqual(run.session.snapshot.stageProgress, before)
        XCTAssertEqual(run.session.stage, .steady)
        XCTAssertEqual(run.session.snapshot.rejectedSamples, 41)
        XCTAssertNil(run.session.profile)
    }

    func testOccludedThumbAllowsMovementStagesButStillBlocksPinchCalibration() {
        var run = CalibrationRun()
        run.completeMovement(reliable: false)
        XCTAssertEqual(run.session.stage, .pinch)
        XCTAssertEqual(run.session.snapshot.observation, .collecting)
        let accepted = run.session.snapshot.acceptedSamples
        for _ in 0..<30 { run.frame(reliable: false, qualified: false) }
        XCTAssertEqual(run.session.snapshot.observation, .showThumb)
        XCTAssertEqual(run.session.snapshot.acceptedSamples, accepted)
        XCTAssertEqual(run.session.snapshot.stageProgress, 0)
        XCTAssertEqual(run.session.snapshot.pinchCount, 0)
        XCTAssertNil(run.session.profile)
        for _ in 0..<30 { run.frame(qualified: false) }
        XCTAssertEqual(run.session.snapshot.observation, .adjustHand)
        XCTAssertEqual(run.session.snapshot.acceptedSamples, accepted)
        run.completePinches()
        XCTAssertEqual(run.session.stage, .completed)
        XCTAssertTrue(run.session.profile?.isValid == true)
    }

    func testObservationSeparatesMissingCameraMissingHandAndFreshRecovery() {
        var session = PersonalCalibrationSession()
        let hand = HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5))
        session.start(at: 0)
        XCTAssertEqual(session.snapshot.observation, .waitingForCamera)
        session.tick(at: 0.1)
        XCTAssertEqual(session.snapshot.observation, .waitingForCamera)
        session.tick(at: 0.21)
        XCTAssertEqual(session.snapshot.observation, .waitingForCamera)
        session.tick(at: 7.99)
        XCTAssertEqual(session.snapshot.observation, .waitingForCamera)
        session.tick(at: 8.01)
        XCTAssertEqual(session.snapshot.observation, .staleFrame)
        XCTAssertTrue(session.snapshot.instruction.contains("아직 도착하지 않았습니다"))
        XCTAssertEqual(session.snapshot.acceptedSamples, 0)
        session.update(nil, capturedAt: 8.1, now: 8.13, confidenceQualified: false)
        XCTAssertEqual(session.snapshot.observation, .searchingHand)
        session.tick(at: 8.27)
        XCTAssertEqual(session.snapshot.observation, .searchingHand)
        session.tick(at: 8.34)
        XCTAssertEqual(session.snapshot.observation, .staleFrame)
        XCTAssertTrue(session.snapshot.instruction.contains("잠시 멈췄습니다"))
        session.update(hand, capturedAt: 8.35, now: 8.38, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .collecting)
        session.update(hand, capturedAt: 8.42, now: 8.45, confidenceQualified: true)
        let progress = session.snapshot.stageProgress
        XCTAssertGreaterThan(progress, 0)
        session.tick(at: 8.67)
        XCTAssertEqual(session.snapshot.observation, .staleFrame)
        XCTAssertEqual(session.snapshot.stageProgress, progress)
        session.reset()
        XCTAssertEqual(session.snapshot.observation, .waitingForCamera)
        XCTAssertEqual(session.snapshot.acceptedSamples, 0)
    }

    func testMovementRejectionsExplainConfidencePoseAndStaleFrames() {
        var session = PersonalCalibrationSession()
        let hand = HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5))
        session.start(at: 0)
        session.update(hand, capturedAt: 0.1, now: 0.13, confidenceQualified: false)
        XCTAssertEqual(session.snapshot.observation, .adjustHand)
        var nonPointer = hand; nonPointer.isPointer = false
        session.update(nonPointer, capturedAt: 0.2, now: 0.23, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .pointIndex)
        var scroll = hand; scroll.isScroll = true; scroll.isPointer = false
        session.update(scroll, capturedAt: 0.3, now: 0.33, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .pointIndex)
        var open = hand; open.isOpenPalm = true; open.isPointer = false
        session.update(open, capturedAt: 0.4, now: 0.43, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .pointIndex)
        var invalid = hand; invalid.palm.x = .nan
        session.update(invalid, capturedAt: 0.5, now: 0.53, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .adjustHand)
        session.update(hand, capturedAt: 0.6, now: 0.9, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.observation, .staleFrame)
        XCTAssertEqual(session.snapshot.acceptedSamples, 0)
        XCTAssertEqual(session.snapshot.stageProgress, 0)
        XCTAssertEqual(session.snapshot.rejectedSamples, 6)
        XCTAssertNil(session.profile)
    }

    func testInFlightImageFromBeforeCalibrationStartDoesNotCount() {
        var session = PersonalCalibrationSession()
        let hand = HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5))
        session.start(at: 10)
        session.update(hand, capturedAt: 9.95, now: 10.05, confidenceQualified: true)
        XCTAssertEqual(session.snapshot.acceptedSamples, 0)
        XCTAssertEqual(session.snapshot.rejectedSamples, 1)
        XCTAssertNil(session.profile)
    }

    func testSparseFramesCannotPassByAccruingMissingIntervals() {
        var run = CalibrationRun()
        for _ in 0..<30 { run.frame(dt: 0.3) }
        XCTAssertEqual(run.session.stage, .steady)
        XCTAssertEqual(run.session.snapshot.stageProgress, 0)
        XCTAssertNil(run.session.profile)
    }

    func testDeliberateMotionIsNotLearnedAsIdleNoise() {
        var run = CalibrationRun()
        for n in 0..<150 where run.session.stage == .steady {
            run.frame(palm: Point(0.5 + Double(n) * 0.0003, 0.5))
        }
        XCTAssertEqual(run.session.stage, .failed)
        XCTAssertEqual(run.session.failure, .handWasMoving)
        XCTAssertNil(run.session.profile)
    }

    func testHoldingStillOrOnlyMovingOneSideDoesNotSaveRange() {
        for oneSided in [false, true] {
            var run = CalibrationRun()
            for _ in 0..<130 where run.session.stage == .steady { run.frame() }
            for n in 0..<230 where run.session.stage == .horizontal {
                let x = oneSided ? 0.5 + abs(sin(Double(n) / 20)) * 0.3 : 0.5
                run.frame(palm: Point(x, 0.5))
            }
            XCTAssertEqual(run.session.failure, .insufficientHorizontalRange)
            XCTAssertNil(run.session.profile)
        }
    }

    func testVerticalRangeAlsoRequiresActualMovement() {
        var run = CalibrationRun()
        run.completeMovement(vertical: 0.01)
        XCTAssertEqual(run.session.failure, .insufficientVerticalRange)
        XCTAssertNil(run.session.profile)
    }

    func testUnclearPinchesAndSingleFrameContactsCannotProduceProfile() {
        for tooClose in [false, true] {
            var run = CalibrationRun()
            run.completeMovement()
            for n in 0..<900 {
                let pinch = tooClose ? (n % 40 < 20 ? 0.5 : 0.38) : (n % 30 == 0 ? 0.15 : 0.8)
                run.frame(pinch: pinch)
            }
            XCTAssertEqual(run.session.stage, .pinch)
            XCTAssertEqual(run.session.snapshot.pinchCount, 0)
            XCTAssertNil(run.session.profile)
            run.session.tick(at: run.time + 50)
            XCTAssertEqual(run.session.failure, .indistinctPinches)
        }
    }

    func testThreeFastPinchesStillRequireAdequateObservedTime() {
        var run = CalibrationRun()
        run.completeMovement()
        for _ in 0..<8 { run.frame() }
        for _ in 0..<3 {
            for _ in 0..<8 { run.frame(pinch: 0.15) }
            for _ in 0..<8 { run.frame() }
        }
        XCTAssertEqual(run.session.snapshot.pinchCount, 3)
        XCTAssertEqual(run.session.stage, .pinch)
        XCTAssertNil(run.session.profile)
        for _ in 0..<140 where run.session.stage == .pinch { run.frame() }
        XCTAssertEqual(run.session.stage, .completed)
    }

    func testComfortablePinchCanCalibrateAboveOldFixedThreshold() throws {
        var run = CalibrationRun()
        run.completeMovement()
        run.completePinches(open: 0.75, closed: 0.32)
        let profile = try XCTUnwrap(run.session.profile)
        XCTAssertGreaterThan(profile.pinchEnter, 0.32)
        XCTAssertLessThanOrEqual(profile.pinchEnter, 0.42)
        XCTAssertTrue(profile.isValid)
    }

    func testCalibratedPinchThresholdChangesActualGestureRecognition() throws {
        var run = CalibrationRun()
        run.completeMovement(); run.completePinches(open: 0.75, closed: 0.32)
        let profile = try XCTUnwrap(run.session.profile)
        func clickCount(calibrated: Bool) -> Int {
            var engine = GestureEngine()
            if calibrated {
                engine.configuration.pinchEnter = profile.pinchEnter
                engine.configuration.pinchExit = profile.pinchExit
            }
            engine.start()
            var downCount = 0
            for frame in 1...60 {
                let closed = (31...45).contains(frame)
                let hand = HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5),
                    pinchRatio: closed ? 0.32 : 0.75, isPointer: !closed)
                let time = Double(frame) / 30
                let events = engine.process(hand, sequence: frame, generation: engine.generation,
                    capturedAt: time, now: time)
                downCount += events.filter { if case .down = $0 { return true }; return false }.count
            }
            return downCount
        }
        XCTAssertEqual(clickCount(calibrated: false), 0)
        XCTAssertEqual(clickCount(calibrated: true), 1)
    }

    func testBoundsAndNoiseAdaptationAreConservative() throws {
        var quiet = CalibrationRun()
        quiet.completeMovement(noise: 0, horizontal: 0.075, vertical: 0.065)
        quiet.completePinches(open: 2, closed: 0.10, shift: 0.03)
        let fast = try XCTUnwrap(quiet.session.profile)
        XCTAssertEqual(fast.sensitivity, 3.2)
        XCTAssertEqual(fast.minimumCutoff, 2.4)
        XCTAssertEqual(fast.pinchEnter, 0.42)
        XCTAssertEqual(fast.pinchExit, 0.65)
        XCTAssertEqual(fast.dragTolerance, 0.025)
        var noisy = CalibrationRun()
        noisy.completeMovement(noise: 0.012, horizontal: 0.38, vertical: 0.33)
        noisy.completePinches()
        let stable = try XCTUnwrap(noisy.session.profile)
        XCTAssertEqual(stable.sensitivity, 1.2)
        XCTAssertEqual(stable.minimumCutoff, 1)
        XCTAssertTrue(stable.isValid)
        XCTAssertLessThan(stable.minimumCutoff, fast.minimumCutoff)
    }

    func testCancelledAndRestartedSessionDoesNotReusePreviousSamples() {
        var run = CalibrationRun()
        run.completeMovement()
        run.session.cancel()
        XCTAssertEqual(run.session.stage, .cancelled)
        XCTAssertNil(run.session.profile)
        XCTAssertEqual(run.session.snapshot.acceptedSamples, 0)
        run.session.start(at: run.time)
        XCTAssertEqual(run.session.stage, .steady)
        XCTAssertEqual(run.session.snapshot.progress, 0)
        XCTAssertEqual(run.session.snapshot.pinchCount, 0)
        run.session.reset()
        XCTAssertEqual(run.session.stage, .idle)
    }

    func testPersistedOutOfBoundsProfileIsRejectedByValidation() throws {
        var run = CalibrationRun()
        run.completeMovement(); run.completePinches()
        let profile = try XCTUnwrap(run.session.profile)
        let data = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sensitivity"] = 100
        let changed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PersonalCalibrationProfile.self, from: changed)
        XCTAssertFalse(decoded.isValid)
    }
}
