import XCTest
@testable import AirTouchCore

final class FeatureExtractorTests: XCTestCase {
    private func joints() -> [Joint: Landmark] {
        var result: [Joint: Landmark] = [.wrist: Landmark(Point(0.5, 0.8)), .thumbTip: Landmark(Point(0.3, 0.5))]
        for (index, chain) in Joint.chains.dropFirst().enumerated() {
            let x = 0.42 + Double(index) * 0.07
            for (i, joint) in chain.dropFirst().enumerated() {
                result[joint] = Landmark(Point(x, 0.62 - Double(i) * 0.10))
            }
        }
        return result
    }

    func testPalmAndAspectCorrectPinchDistance() throws {
        let points = joints()
        let f = try XCTUnwrap(FeatureExtractor.extract(points, width: 1280, height: 720))
        XCTAssertTrue(f.isOpenPalm); XCTAssertFalse(f.isScroll); XCTAssertFalse(f.isPointer)
        let thumb = points[.thumbTip]!.point, index = points[.indexTip]!.point
        let wrist = points[.wrist]!.point, middle = points[.middleMCP]!.point
        let expected = hypot((thumb.x - index.x) * 1280, (thumb.y - index.y) * 720)
            / hypot((wrist.x - middle.x) * 1280, (wrist.y - middle.y) * 720)
        XCTAssertEqual(f.pinchRatio, expected, accuracy: 0.00001)
    }

    func testUncertainThumbDisablesClickButKeepsTracking() throws {
        var points = joints(); points[.thumbTip] = Landmark(Point(0.3, 0.5), confidence: 0.1)
        let features = try XCTUnwrap(FeatureExtractor.extract(points, width: 1280, height: 720))
        XCTAssertFalse(features.isPinchReliable)
        points = joints(); points.removeValue(forKey: .indexTip)
        XCTAssertNil(FeatureExtractor.extract(points, width: 1280, height: 720))
    }

    func testPointingHandDoesNotRequireOccludedFoldedFingertips() throws {
        var points = joints()
        // Folded fingertips may be completely hidden behind the palm.
        for joint in [Joint.middlePIP, .middleDIP, .middleTip, .ringPIP, .ringDIP, .ringTip,
                      .littlePIP, .littleDIP, .littleTip] { points.removeValue(forKey: joint) }
        let hand = try XCTUnwrap(FeatureExtractor.extract(points, width: 1280, height: 720))
        XCTAssertTrue(hand.isPointer)
        XCTAssertFalse(hand.isScroll)
        XCTAssertFalse(hand.isOpenPalm)
    }

    func testFoldedFingersProjectedTowardWristDoNotLookLikeOpenPalm() throws {
        var points = joints()
        // An occluded curl may project as a straight chain, but its tip lies
        // toward the wrist, not beyond the knuckle like an extended finger.
        for chain in Joint.chains.dropFirst(2) {
            let x = try XCTUnwrap(points[chain[1]]).point.x
            for (i, joint) in chain.dropFirst().enumerated() {
                points[joint] = Landmark(Point(x, 0.62 + Double(i) * 0.045))
            }
        }
        let hand = try XCTUnwrap(FeatureExtractor.extract(points, width: 1280, height: 720))
        XCTAssertTrue(hand.isPointer)
        XCTAssertFalse(hand.isOpenPalm)
        XCTAssertFalse(hand.isScroll)
    }

    func testScaleAndRotationDoNotChangePinchRatio() throws {
        let original = joints()
        let a = try XCTUnwrap(FeatureExtractor.extract(original, width: 1000, height: 1000))
        let changed = original.mapValues { landmark -> Landmark in
            let d = (landmark.point - Point(0.5, 0.5)) * 0.7
            return Landmark(Point(0.5 - d.y, 0.5 + d.x))
        }
        let b = try XCTUnwrap(FeatureExtractor.extract(changed, width: 1000, height: 1000))
        XCTAssertEqual(a.pinchRatio, b.pinchRatio, accuracy: 0.00001)
        XCTAssertEqual(a.isOpenPalm, b.isOpenPalm)
    }

    func testFilterResetsAfterGapAndKeepsStationaryInputStable() {
        var filter = OneEuroFilter()
        let point = Point(0.3, 0.4)
        for frame in 0..<60 { XCTAssertEqual(filter.update(point, at: Double(frame) / 30), point) }
        let next = Point(0.7, 0.8)
        XCTAssertEqual(filter.update(next, at: 4), next)
    }
}
