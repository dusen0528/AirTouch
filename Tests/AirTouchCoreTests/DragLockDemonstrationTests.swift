import XCTest
@testable import AirTouchCore

final class DragLockDemonstrationTests: XCTestCase {
    func testDemonstrationShowsUnlockedAndLockedDragging() {
        for enabled in [false, true] {
            var engine = GestureEngine(); engine.configuration.dragLockEnabled = enabled
            engine.start()
            var demo = Demonstration(dragLock: enabled), scene = PracticeScene()
            var lockedFrames = 0
            while !demo.isFinished {
                let frame = demo.frame
                let hand = demo.next(cursor: engine.cursor, scene: scene, sensitivity: engine.configuration.sensitivity)
                for event in engine.process(hand, sequence: frame, generation: engine.generation,
                                            capturedAt: Double(frame) / 30, now: Double(frame) / 30) { scene.apply(event) }
                if engine.dragLocked { lockedFrames += 1 }
            }
            for event in engine.stop() { scene.apply(event) }
            XCTAssertEqual(scene.clickCount, 1)
            XCTAssertEqual(scene.dropCount, 1)
            XCTAssertGreaterThan(scene.scrollDistance, 150)
            XCTAssertFalse(scene.isPressed)
            if enabled { XCTAssertGreaterThan(lockedFrames, 50) } else { XCTAssertEqual(lockedFrames, 0) }
        }
    }
}
