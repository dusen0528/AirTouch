import XCTest
@testable import AirTouchCore

/// Deterministic synthetic observations; no camera or personal hand recording.
private struct PinchContinuityRun {
    enum Dropout: CaseIterable { case missingHand, occludedThumb, lowConfidence }
    var session = PersonalCalibrationSession()
    var time = 0.0

    init() {
        session.start(at: time, date: Date(timeIntervalSince1970: 1_800_000_000))
        for _ in 0..<130 where session.stage == .steady { frame() }
        for n in 0..<220 where session.stage == .horizontal {
            frame(palm: Point(0.5 + sin(Double(n) / 20) * 0.18, 0.5))
        }
        for n in 0..<220 where session.stage == .vertical {
            frame(palm: Point(0.5, 0.5 + sin(Double(n) / 20) * 0.16))
        }
    }

    mutating func frame(pinch: Double = 0.8, palm: Point = Point(0.5, 0.5),
                        dropout: Dropout? = nil, after interval: Double = 1.0 / 30) {
        time += interval
        let hand = HandFeatures(index: palm + Point(0, -0.15), palm: palm,
                                pinchRatio: pinch, isPointer: pinch >= 0.5,
                                isPinchReliable: dropout != .occludedThumb)
        session.update(dropout == .missingHand ? nil : hand, capturedAt: time,
                       now: time + 0.06, confidenceQualified: dropout != .lowConfidence)
    }

    mutating func hold(_ pinch: Double, frames: Int = 20, alternating dropout: Dropout? = nil,
                       palm: Point = Point(0.5, 0.5)) {
        for n in 0..<frames where session.stage == .pinch {
            frame(pinch: pinch, palm: palm, dropout: n.isMultiple(of: 2) ? nil : dropout)
        }
    }
}

final class PinchCalibrationContinuityTests: XCTestCase {
    func testThreePinchesCompleteWithHalfMissingOccludedOrWeakFrames() {
        for dropout in PinchContinuityRun.Dropout.allCases {
            var run = PinchContinuityRun()
            XCTAssertEqual(run.session.stage, .pinch)
            run.hold(0.8, frames: 60, alternating: dropout)
            for _ in 0..<3 {
                run.hold(0.15, frames: 60, alternating: dropout)
                run.hold(0.8, frames: 60, alternating: dropout)
            }
            XCTAssertEqual(run.session.snapshot.pinchCount, 3, "Dropout: \(dropout)")
            XCTAssertEqual(run.session.stage, .completed, "Dropout: \(dropout)")
            XCTAssertNotNil(run.session.profile, "Dropout: \(dropout)")
            if let profile = run.session.profile {
                XCTAssertTrue(profile.isValid)
                XCTAssertGreaterThanOrEqual(profile.observedSeconds, 24)
                XCTAssertLessThan(profile.observedSeconds, 25,
                                  "Rejected frames must not earn observed time")
            }
        }
    }

    func testSingleClosedFrameNeverCountsAsDeliberatePinch() {
        var run = PinchContinuityRun()
        run.hold(0.8)
        for _ in 0..<12 {
            run.frame(pinch: 0.15)
            run.hold(0.8)
        }
        XCTAssertEqual(run.session.snapshot.pinchCount, 0)
        XCTAssertEqual(run.session.stage, .pinch)
        XCTAssertNil(run.session.profile)
    }

    func testContradictingValidRatioCannotJoinSeparateShortPlateaus() {
        var run = PinchContinuityRun()
        run.hold(0.8)
        for _ in 0..<20 {
            run.hold(0.15, frames: 3)
            run.frame(dropout: .missingHand)
            run.frame(pinch: 0.8)
            run.frame(dropout: .missingHand)
        }
        XCTAssertEqual(run.session.snapshot.pinchCount, 0,
                       "A visible open hand ends the closed plateau, even between brief dropouts")
        XCTAssertNil(run.session.profile)
        run.hold(0.15)
        run.hold(0.8)
        XCTAssertEqual(run.session.snapshot.pinchCount, 1)
    }

    func testLongGapRequiresFreshOpenButKeepsConfirmedCycle() {
        for receivesEmptyFrames in [false, true] {
            var run = PinchContinuityRun()
            run.hold(0.8)
            run.hold(0.15)
            run.hold(0.8)
            XCTAssertEqual(run.session.snapshot.pinchCount, 1)
            run.hold(0.15) // The next cycle is closed, but its release is not yet seen.
            if receivesEmptyFrames {
                for _ in 0..<30 { run.frame(dropout: .missingHand) }
            } else {
                run.time += 1
                run.session.tick(at: run.time)
            }
            XCTAssertEqual(run.session.snapshot.pinchCount, 1)
            XCTAssertNil(run.session.profile)
            run.hold(0.8)
            XCTAssertEqual(run.session.snapshot.pinchCount, 1,
                           "A release after a long unobserved gap must establish a fresh open baseline")
            run.hold(0.15)
            run.hold(0.8)
            XCTAssertEqual(run.session.snapshot.pinchCount, 2,
                           "Only the unfinished cycle is discarded; the first confirmed cycle remains")
        }
    }

    func testThreeConfirmedCyclesStillNeedObservedTimeAndMissingFramesEarnNone() {
        var run = PinchContinuityRun()
        run.hold(0.8)
        for _ in 0..<3 {
            run.hold(0.15)
            run.hold(0.8)
        }
        XCTAssertEqual(run.session.snapshot.pinchCount, 3)
        XCTAssertEqual(run.session.stage, .pinch)
        let beforeMissing = run.session.snapshot.stageProgress
        let beforeSamples = run.session.snapshot.acceptedSamples
        for _ in 0..<60 { run.frame(dropout: .missingHand) }
        XCTAssertEqual(run.session.snapshot.stageProgress, beforeMissing, accuracy: 0.000_001)
        XCTAssertEqual(run.session.snapshot.acceptedSamples, beforeSamples)
        XCTAssertEqual(run.session.snapshot.pinchCount, 3)
        XCTAssertNil(run.session.profile)

        run.hold(0.8, frames: 60, alternating: .missingHand)
        XCTAssertEqual(run.session.snapshot.stageProgress - beforeMissing, 1.0 / 6,
                       accuracy: 0.01,
                       "Two seconds of half-valid 30 Hz input contributes only one observed second")
        XCTAssertEqual(run.session.snapshot.acceptedSamples - beforeSamples, 30)
        XCTAssertEqual(run.session.stage, .pinch)
        XCTAssertNil(run.session.profile)
        run.hold(0.8, frames: 90, alternating: .missingHand)
        XCTAssertEqual(run.session.stage, .completed)
        XCTAssertTrue(run.session.profile?.isValid == true)
    }

    func testBriefGapBoundaryUsesLastAcceptedCaptureAndMissingCallbacksDoNotExtendIt() {
        for gap in [0.149, 0.151] {
            var run = PinchContinuityRun()
            run.hold(0.8, frames: 4)
            let beforeGap = run.session.snapshot.pinchHoldProgress
            XCTAssertGreaterThan(beforeGap, 0)
            XCTAssertLessThan(beforeGap, 1)
            run.frame(dropout: .missingHand, after: 0.05)
            run.frame(dropout: .missingHand, after: 0.049)
            XCTAssertEqual(run.session.snapshot.pinchHoldProgress, beforeGap,
                           accuracy: 0.000_001, "Missing frames earn no hold time")
            run.frame(after: gap - 0.099)
            if gap < 0.15 {
                XCTAssertEqual(run.session.snapshot.pinchHoldProgress,
                               beforeGap + (1.0 / 30) / 0.15, accuracy: 0.000_001,
                               "A preserved hold earns at most one frame's time, not the missing interval")
            } else {
                XCTAssertEqual(run.session.snapshot.pinchHoldProgress, 0,
                               "Two intervening nil callbacks must not extend the 150ms allowance")
            }
            XCTAssertEqual(run.session.snapshot.pinchCount, 0)
            XCTAssertNil(run.session.profile)
        }
    }

    func testPalmJumpAtReleaseCannotConfirmUnfinishedCycle() {
        var run = PinchContinuityRun()
        run.hold(0.8)
        run.hold(0.15)
        run.hold(0.8)
        XCTAssertEqual(run.session.snapshot.pinchCount, 1)
        run.hold(0.15)
        let newPalm = Point(0.6, 0.5)
        run.hold(0.8, palm: newPalm)
        XCTAssertEqual(run.session.snapshot.pinchCount, 1,
                       "A release at a different position must start a fresh open baseline")
        XCTAssertNil(run.session.profile)
        run.hold(0.15, palm: newPalm)
        run.hold(0.8, palm: newPalm)
        XCTAssertEqual(run.session.snapshot.pinchCount, 2)
    }

    func testAbandonedExtremeCyclesDoNotContaminateCompletedPinchRatiosOrShift() throws {
        func completeThreeCycles(_ run: inout PinchContinuityRun) {
            run.hold(0.8)
            for _ in 0..<3 {
                run.hold(0.15)
                run.hold(0.8)
            }
            run.hold(0.8, frames: 80)
        }
        var baseline = PinchContinuityRun()
        completeThreeCycles(&baseline)
        let expected = try XCTUnwrap(baseline.session.profile)

        var interrupted = PinchContinuityRun()
        // Four abandoned shifts outnumber the three completed shifts, so even
        // a robust median would expose accidental inclusion of pending data.
        for _ in 0..<4 {
            interrupted.hold(1.4)
            interrupted.hold(0.38, palm: Point(0.53, 0.5))
            interrupted.frame(dropout: .missingHand, after: 0.2)
            XCTAssertEqual(interrupted.session.snapshot.pinchCount, 0)
            XCTAssertNil(interrupted.session.profile)
        }
        completeThreeCycles(&interrupted)
        let actual = try XCTUnwrap(interrupted.session.profile)
        XCTAssertTrue(actual.isValid)
        XCTAssertEqual(actual.pinchCycles, 3)
        XCTAssertEqual(actual.pinchEnter, expected.pinchEnter, accuracy: 0.000_001)
        XCTAssertEqual(actual.pinchExit, expected.pinchExit, accuracy: 0.000_001)
        XCTAssertEqual(actual.dragTolerance, expected.dragTolerance, accuracy: 0.000_001)
        XCTAssertEqual(actual.pinchOpenRatio, expected.pinchOpenRatio, accuracy: 0.000_001)
        XCTAssertEqual(actual.pinchClosedRatio, expected.pinchClosedRatio, accuracy: 0.000_001)
    }
}
