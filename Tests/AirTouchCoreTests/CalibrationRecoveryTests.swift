import XCTest
@testable import AirTouchCore

/// Synthetic frames exercise retry behavior without a camera or saved hand data.
private struct RecoveryRun {
    var session = PersonalCalibrationSession()
    var time = 0.0

    init() { session.start(at: time, date: Date(timeIntervalSince1970: 1_800_000_000)) }

    mutating func frame(palm: Point = Point(0.5, 0.5), valid: Bool = true, pinch: Double = 0.8) {
        time += 1.0 / 30
        let hand = HandFeatures(index: palm + Point(0, -0.15), palm: palm,
                                pinchRatio: pinch, isPointer: pinch >= 0.5)
        session.update(valid ? hand : nil, capturedAt: time, now: time + 0.03,
                       confidenceQualified: valid)
    }

    mutating func steady() {
        for _ in 0..<130 where session.stage == .steady { frame() }
    }

    mutating func horizontal(amplitude: Double = 0.18) {
        for n in 0..<220 where session.stage == .horizontal {
            frame(palm: Point(0.5 + sin(Double(n) / 20) * amplitude, 0.5))
        }
    }

    mutating func vertical(amplitude: Double = 0.16) {
        for n in 0..<220 where session.stage == .vertical {
            frame(palm: Point(0.5, 0.5 + sin(Double(n) / 20) * amplitude))
        }
    }

    mutating func pinches() {
        for _ in 0..<30 { frame() }
        for _ in 0..<3 {
            for _ in 0..<20 { frame(pinch: 0.15) }
            for _ in 0..<20 { frame() }
        }
        for _ in 0..<60 where session.stage == .pinch { frame() }
    }
}

final class CalibrationRecoveryTests: XCTestCase {
    func testCameraStartupDelayDoesNotDiscardCalibrationBeforeAnySamples() {
        var run = RecoveryRun()
        run.time = 25
        run.session.tick(at: run.time)
        XCTAssertEqual(run.session.stage, .steady, "Camera readiness is not a failed hand measurement")
        XCTAssertNil(run.session.failure)
        XCTAssertNil(run.session.profile)
        XCTAssertEqual(run.session.snapshot.acceptedSamples, 0)
        run.steady()
        XCTAssertEqual(run.session.stage, .horizontal)
    }

    func testMovingDuringSteadyStageCanSettleWithoutRestartingWholeSession() {
        var run = RecoveryRun()
        for n in 0..<130 where run.session.stage == .steady {
            run.frame(palm: Point(0.5 + Double(n) * 0.0003, 0.5))
        }
        XCTAssertEqual(run.session.stage, .steady, "Poor samples should retry only the current stage")
        XCTAssertEqual(run.session.snapshot.retryReason, .handWasMoving)
        XCTAssertEqual(run.session.snapshot.retryCount, 1)
        XCTAssertNil(run.session.profile)
        run.steady()
        XCTAssertEqual(run.session.stage, .horizontal)
    }

    func testNarrowHorizontalRangeRetriesWithoutLosingCompletedSteadyStage() {
        var run = RecoveryRun()
        run.steady()
        XCTAssertEqual(run.session.stage, .horizontal)
        run.horizontal(amplitude: 0.01)
        XCTAssertEqual(run.session.stage, .horizontal, "Range retry must retain the completed steady stage")
        XCTAssertEqual(run.session.snapshot.retryReason, .insufficientHorizontalRange)
        XCTAssertGreaterThanOrEqual(run.session.snapshot.progress, 0.25)
        XCTAssertNil(run.session.profile)
        run.horizontal()
        XCTAssertEqual(run.session.stage, .vertical)
    }

    func testVerticalRetryPreservesEarlierStagesAndExcludesDiscardedSamplesFromProfile() throws {
        var run = RecoveryRun()
        run.steady(); run.horizontal()
        XCTAssertEqual(run.session.stage, .vertical)
        run.vertical(amplitude: 0.01)
        XCTAssertEqual(run.session.stage, .vertical)
        XCTAssertEqual(run.session.snapshot.retryReason, .insufficientVerticalRange)
        XCTAssertGreaterThanOrEqual(run.session.snapshot.progress, 0.5)
        let retryCount = run.session.snapshot.retryCount
        run.vertical(); run.pinches()
        let profile = try XCTUnwrap(run.session.profile)
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(run.session.stage, .completed)
        XCTAssertEqual(run.session.snapshot.retryCount, retryCount)
        XCTAssertNil(run.session.snapshot.retryReason)
        XCTAssertGreaterThanOrEqual(profile.observedSeconds, 24)
        XCTAssertLessThan(profile.observedSeconds, 25, "Discarded seven-second attempt must not count")
        XCTAssertLessThan(profile.acceptedSamples, run.session.snapshot.acceptedSamples - 190)
    }

    func testMissingHandTimeoutRetriesCurrentStageAndCanResume() {
        var run = RecoveryRun()
        run.steady()
        for _ in 0..<30 { run.frame() }
        for _ in 0..<900 { run.frame(valid: false) }
        XCTAssertEqual(run.session.stage, .horizontal)
        XCTAssertEqual(run.session.snapshot.retryReason, .insufficientSamples)
        XCTAssertEqual(run.session.snapshot.retryCount, 1)
        XCTAssertEqual(run.session.snapshot.observation, .searchingHand)
        XCTAssertEqual(run.session.snapshot.stageProgress, 0)
        XCTAssertNil(run.session.profile)
        run.horizontal()
        XCTAssertEqual(run.session.stage, .vertical)
    }

    func testHalfValidCameraFramesAccumulateOnlyTheirObservedTime() {
        var run = RecoveryRun()
        for n in 0..<120 { run.frame(valid: n.isMultiple(of: 2)) }
        XCTAssertEqual(run.session.stage, .steady)
        XCTAssertGreaterThan(run.session.snapshot.stageProgress, 0.45)
        XCTAssertLessThan(run.session.snapshot.stageProgress, 0.55,
                          "Four wall-clock seconds with half valid frames earns only about two observed seconds")
        XCTAssertNil(run.session.profile)
        for n in 0..<132 { run.frame(valid: n.isMultiple(of: 2)) }
        XCTAssertEqual(run.session.stage, .horizontal)
        XCTAssertEqual(run.session.snapshot.retryCount, 0)
    }

    func testPinchTimeoutPreservesMovementStagesAndRequiresThreeNewCycles() throws {
        var run = RecoveryRun()
        run.steady(); run.horizontal(); run.vertical()
        XCTAssertEqual(run.session.stage, .pinch)
        for _ in 0..<30 { run.frame() }
        for _ in 0..<20 { run.frame(pinch: 0.15) }
        for _ in 0..<20 { run.frame() }
        XCTAssertEqual(run.session.snapshot.pinchCount, 1)
        for _ in 0..<1400 { run.frame(valid: false) }
        XCTAssertEqual(run.session.stage, .pinch)
        XCTAssertEqual(run.session.snapshot.retryReason, .indistinctPinches)
        XCTAssertEqual(run.session.snapshot.pinchCount, 0)
        XCTAssertGreaterThanOrEqual(run.session.snapshot.progress, 0.75)
        XCTAssertNil(run.session.profile)
        run.pinches()
        let profile = try XCTUnwrap(run.session.profile)
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.pinchCycles, 3)
        XCTAssertLessThan(profile.observedSeconds, 25)
        XCTAssertNil(run.session.snapshot.retryReason)
    }
}
