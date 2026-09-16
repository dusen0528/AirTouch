import XCTest
@testable import AirTouchApp
import AirTouchCore

final class CalibrationProfileStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AirTouch.CalibrationProfileStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSaveSurvivesNewStoreAndDefaultsInstanceWithDerivedSettings() throws {
        let profile = try makeProfile()
        let store = CalibrationProfileStore(defaults: defaults)
        XCTAssertTrue(store.save(profile))
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reopened = CalibrationProfileStore(defaults: reopenedDefaults)
        XCTAssertEqual(reopened.load(), profile)
        XCTAssertEqual(reopenedDefaults.double(forKey: "sensitivity"), profile.sensitivity)
        XCTAssertEqual(reopenedDefaults.double(forKey: "smoothing"), profile.minimumCutoff)
        let data = try XCTUnwrap(reopenedDefaults.data(forKey: "personalCalibration.v1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object.values.allSatisfy { $0 is NSNumber }, "Only aggregate numeric values are persisted")
    }

    func testClearRemovesProfileAcrossInstancesAndPreservesManualSettings() throws {
        let store = CalibrationProfileStore(defaults: defaults)
        XCTAssertTrue(store.save(try makeProfile()))
        defaults.set(2.15, forKey: "sensitivity")
        defaults.set(1.35, forKey: "smoothing")
        store.clear()
        XCTAssertNil(CalibrationProfileStore(defaults: UserDefaults(suiteName: suiteName)!).load())
        XCTAssertNil(defaults.object(forKey: "personalCalibration.v1"))
        XCTAssertEqual(defaults.double(forKey: "sensitivity"), 2.15)
        XCTAssertEqual(defaults.double(forKey: "smoothing"), 1.35)
    }

    func testInvalidProfileCannotOverwriteExistingValidProfileOrSettings() throws {
        let valid = try makeProfile()
        let store = CalibrationProfileStore(defaults: defaults)
        XCTAssertTrue(store.save(valid))
        let originalData = try XCTUnwrap(defaults.data(forKey: "personalCalibration.v1"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        object["sensitivity"] = 100
        let invalid = try JSONDecoder().decode(PersonalCalibrationProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(store.save(invalid))
        XCTAssertEqual(store.load(), valid)
        XCTAssertEqual(defaults.data(forKey: "personalCalibration.v1"), originalData)
        XCTAssertEqual(defaults.double(forKey: "sensitivity"), valid.sensitivity)
        XCTAssertEqual(defaults.double(forKey: "smoothing"), valid.minimumCutoff)
    }

    func testMissingCorruptAndInvalidStoredDataAreNotLoaded() throws {
        let store = CalibrationProfileStore(defaults: defaults)
        XCTAssertNil(store.load())
        defaults.set(Data("not JSON".utf8), forKey: "personalCalibration.v1")
        XCTAssertNil(store.load())
        defaults.set("wrong preference type", forKey: "personalCalibration.v1")
        XCTAssertNil(store.load())
        let data = try JSONEncoder().encode(makeProfile())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "personalCalibration.v1")
        XCTAssertNil(store.load())
    }

    /// Synthetic camera samples run the production calibration algorithm to make
    /// this fixture. No fixture bypasses the profile's evidence requirements.
    private func makeProfile() throws -> PersonalCalibrationProfile {
        var session = PersonalCalibrationSession()
        session.start(at: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
        var time = 0.0
        func feed(_ palm: Point = Point(0.5, 0.5), pinch: Double = 0.8) {
            time += 1 / 30
            let hand = HandFeatures(index: Point(palm.x, palm.y - 0.15), palm: palm,
                pinchRatio: pinch, isPointer: pinch >= 0.5)
            session.update(hand, capturedAt: time, now: time + 0.06, confidenceQualified: true)
        }
        for _ in 0..<150 where session.stage == .steady { feed() }
        for n in 0..<250 where session.stage == .horizontal {
            feed(Point(0.5 + sin(Double(n) / 20) * 0.18, 0.5))
        }
        for n in 0..<250 where session.stage == .vertical {
            feed(Point(0.5, 0.5 + sin(Double(n) / 20) * 0.16))
        }
        XCTAssertEqual(session.stage, .pinch)
        for _ in 0..<30 { feed() }
        for _ in 0..<3 {
            for _ in 0..<20 { feed(pinch: 0.15) }
            for _ in 0..<20 { feed() }
        }
        for _ in 0..<60 where session.stage == .pinch { feed() }
        XCTAssertEqual(session.stage, .completed)
        return try XCTUnwrap(session.profile)
    }
}
