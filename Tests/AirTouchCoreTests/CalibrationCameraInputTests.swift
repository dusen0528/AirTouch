import XCTest
@testable import AirTouchCore

/// Synthetic landmarks only. This fixture passes through the same extractor as
/// CameraService, without a camera, recorded coordinates, or macOS input.
final class CalibrationCameraInputTests: XCTestCase {
    func testSteadyStageAcceptsReliablePointerWhenFoldedThumbIsOccluded() throws {
        func run(thumbConfidence: Double) throws -> PersonalCalibrationSession {
            let joints: [Joint: Landmark] = [
                .wrist: Landmark(Point(0.5, 0.8)),
                .middleMCP: Landmark(Point(0.5, 0.62)),
                .indexMCP: Landmark(Point(0.42, 0.62)),
                .indexPIP: Landmark(Point(0.42, 0.52)),
                .indexDIP: Landmark(Point(0.42, 0.42)),
                .indexTip: Landmark(Point(0.42, 0.32)),
                .thumbTip: Landmark(Point(0.3, 0.5), confidence: thumbConfidence)
            ]
            let hand = try XCTUnwrap(FeatureExtractor.extract(joints, width: 1280, height: 720))
            XCTAssertTrue(hand.isPointer)
            XCTAssertFalse(hand.isOpenPalm)
            XCTAssertFalse(hand.isScroll)
            XCTAssertEqual(hand.isPinchReliable, thumbConfidence >= 0.35)

            // AppModel's steady/horizontal/vertical qualification intentionally
            // checks movement landmarks only; thumb is required for pinch stage.
            let required: [Joint] = [.wrist, .indexMCP, .indexPIP, .middleMCP, .indexTip]
            let qualified = required.allSatisfy { (joints[$0]?.confidence ?? 0) >= 0.5 }
            XCTAssertTrue(qualified)
            var calibration = PersonalCalibrationSession()
            calibration.start(at: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
            for frame in 1...150 {
                let time = Double(frame) / 30
                calibration.update(hand, capturedAt: time, now: time + 0.03,
                                   confidenceQualified: qualified)
            }
            return calibration
        }

        let visibleThumb = try run(thumbConfidence: 1)
        XCTAssertEqual(visibleThumb.stage, .horizontal, "Control fixture must complete four seconds of steady observations")
        let occludedThumb = try run(thumbConfidence: 0.1)
        XCTAssertEqual(occludedThumb.stage, .horizontal,
                       "Reliable palm/index must advance movement calibration; accepted=\(occludedThumb.snapshot.acceptedSamples), rejected=\(occludedThumb.snapshot.rejectedSamples), instruction=\(occludedThumb.snapshot.instruction)")
    }
}
