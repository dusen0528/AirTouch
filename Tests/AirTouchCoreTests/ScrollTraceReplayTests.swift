import XCTest
@testable import AirTouchCore

final class ScrollTraceReplayTests: XCTestCase {
    func testLocalV035ScrollResumeTraceWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["AIRTOUCH_V035_SCROLL_TRACE"] else {
            throw XCTSkip("User trace stays local and is not stored in Git")
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(root["appVersion"] as? String, "0.3.5")
        let rows = try XCTUnwrap(root["activeFrames"] as? [[String: Any]])
            .filter { (3360...3490).contains($0["sequence"] as? Int ?? -1) }
        XCTAssertGreaterThan(rows.count, 110)
        let start = try XCTUnwrap(rows.first?["capturedAt"] as? Double)
        var engine = GestureEngine(); engine.start()
        var checked = 0, resumed = 0
        for row in rows {
            let hand: HandFeatures?
            if let h = row["features"] as? [String: Any] {
                func n(_ key: String) throws -> Double { try XCTUnwrap(h[key] as? Double) }
                hand = HandFeatures(index: Point(try n("indexX"), try n("indexY")), palm: Point(try n("palmX"), try n("palmY")),
                    palmScale: try n("palmScale"), pinchRatio: try n("pinchRatio"),
                    isPointer: h["isPointer"] as? Bool ?? false, isScroll: h["isScroll"] as? Bool ?? false,
                    isOpenPalm: h["isOpenPalm"] as? Bool ?? false, isPinchReliable: h["isPinchReliable"] as? Bool ?? false,
                    secondaryPinchRatio: h["secondaryPinchRatio"] as? Double)
            } else { hand = nil }
            let sequence = try XCTUnwrap(row["sequence"] as? Int)
            _ = engine.process(hand, sequence: sequence, generation: engine.generation,
                capturedAt: try XCTUnwrap(row["capturedAt"] as? Double) - start,
                now: try XCTUnwrap(row["receivedAt"] as? Double) - start)
            if (3455...3457).contains(sequence) || (3485...3490).contains(sequence) {
                checked += 1
                if engine.state == .scrolling { resumed += 1 }
            }
        }
        print("SCROLL_TRACE_RESUMED=\(resumed)/\(checked)")
        XCTAssertEqual(checked, 9)
        XCTAssertEqual(resumed, checked)
    }
}
