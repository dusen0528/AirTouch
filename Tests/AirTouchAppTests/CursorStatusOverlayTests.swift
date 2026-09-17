import AppKit
import XCTest
import AirTouchCore
@testable import AirTouchApp

/// Inspects only an unshown panel and pure status snapshots. No event posting,
/// camera access, activation, window ordering, or desktop capture occurs here.
final class CursorStatusOverlayTests: XCTestCase {
    func testPanelCannotTakeFocusOrConsumeClicksAndHideIsIdempotent() async {
        await MainActor.run {
            _ = NSApplication.shared
            let overlay = CursorStatusOverlay()
            let behavior = overlay.panelSnapshot
            XCTAssertFalse(behavior.isVisible)
            XCTAssertTrue(behavior.ignoresMouseEvents)
            XCTAssertFalse(behavior.canBecomeKey)
            XCTAssertFalse(behavior.canBecomeMain)
            XCTAssertTrue(behavior.isNonactivating)
            XCTAssertTrue(behavior.canJoinAllSpaces)
            XCTAssertTrue(behavior.canJoinFullScreen)
            overlay.hide()
            overlay.hide()
            overlay.update(engine: GestureEngine(), handoff: false, trackingFresh: true, visible: false)
            XCTAssertFalse(overlay.panelSnapshot.isVisible)
        }
    }

    func testMissingHandAndPhysicalHandoffOverrideGestureStatus() async {
        await MainActor.run {
            var s = OverlaySession()
            s.lock()
            XCTAssertTrue(s.engine.dragLocked)
            XCTAssertEqual(CursorStatusOverlay.status(engine: s.engine, handoff: false,
                trackingFresh: false).text, "손을 찾는 중")
            XCTAssertEqual(CursorStatusOverlay.status(engine: s.engine, handoff: true,
                trackingFresh: false).text, "마우스 사용 중")
            _ = s.engine.stop()
            let ready = CursorStatusOverlay.status(engine: s.engine, handoff: false, trackingFresh: true)
            XCTAssertEqual(ready.text, "손동작 안내")
            XCTAssertNotNil(ready.instructions)
            if let directory = ProcessInfo.processInfo.environment["AIRTOUCH_RENDER_DIRECTORY"] {
                let overlay = CursorStatusOverlay()
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                for locked in [true, false] {
                    s.engine.configuration.dragLockEnabled = locked
                    let status = CursorStatusOverlay.status(engine: s.engine, handoff: false, trackingFresh: true)
                    let data = overlay.previewPNG(status: status)
                    XCTAssertNotNil(data)
                    try? data?.write(to: url.appendingPathComponent("airtouch-v042-guide-\(locked ? "locked" : "held").png"))
                    XCTAssertFalse(overlay.panelSnapshot.isVisible)
                }
            }
        }
    }

    func testLockConfirmationAndDropReleaseHaveDistinctFeedback() async {
        await MainActor.run {
            var s = OverlaySession()
            s.lock()
            let locked = CursorStatusOverlay.status(engine: s.engine, handoff: false, trackingFresh: true)
            XCTAssertEqual(locked.text, "끌기 잠금 · 집으면 놓기")
            XCTAssertTrue(locked.locked)
            s.hand.pinchRatio = 0.15
            s.step(2)
            let confirming = CursorStatusOverlay.status(engine: s.engine, handoff: false, trackingFresh: true)
            XCTAssertGreaterThan(confirming.progress, 0)
            XCTAssertLessThan(confirming.progress, 1)
            s.step(5)
            XCTAssertTrue(s.engine.waitingForPinchRelease)
            let completed = CursorStatusOverlay.status(engine: s.engine, handoff: false, trackingFresh: true)
            XCTAssertEqual(completed.text, "끌기 완료 · 손가락 펴기")
            XCTAssertFalse(completed.locked)
            XCTAssertEqual(completed.progress, 0)
            s.hand.pinchRatio = 0.8
            s.step()
            XCTAssertEqual(CursorStatusOverlay.status(engine: s.engine, handoff: false,
                trackingFresh: true).text, "이동")
        }
    }
}

private struct OverlaySession {
    var engine = GestureEngine()
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var frame = 0

    init() {
        engine.configuration.dragLockEnabled = true
        engine.start()
        step(20)
    }

    mutating func step(_ count: Int = 1) {
        for _ in 0..<count {
            frame += 1
            let time = Double(frame) / 30
            _ = engine.process(hand, sequence: frame, generation: engine.generation,
                capturedAt: time, now: time)
        }
    }

    mutating func lock() {
        hand.pinchRatio = 0.15
        step(6)
        for _ in 0..<15 {
            hand.palm.x += 0.003; hand.index.x += 0.003
            step()
        }
        hand.pinchRatio = 0.8
        step()
    }
}
