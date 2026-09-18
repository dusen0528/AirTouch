import AirTouchCore
import Foundation
import XCTest
@testable import AirTouchApp

private final class DispatcherEnvironment {
    private let lock = NSLock()
    private var time = 10.0
    private var permission = true
    private var recorded: [InputIntent] = []
    private var recordedInterruptions: [SystemInputInterruption] = []
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    var permitted: Bool { lock.lock(); defer { lock.unlock() }; return permission }
    var actions: [InputIntent] { lock.lock(); defer { lock.unlock() }; return recorded }
    var interruptions: [SystemInputInterruption] { lock.lock(); defer { lock.unlock() }; return recordedInterruptions }
    func setTime(_ value: Double) { lock.lock(); time = value; lock.unlock() }
    func setPermission(_ value: Bool) { lock.lock(); permission = value; lock.unlock() }
    func post(_ actions: [InputIntent]) { lock.lock(); recorded += actions; lock.unlock() }
    func interrupt(_ value: SystemInputInterruption) { lock.lock(); recordedInterruptions.append(value); lock.unlock() }
}

final class SystemInputDispatcherTests: XCTestCase {
    private let point = Point(100, 100)
    private let area = DisplayArea(origin: .zero, width: 1000, height: 800)

    private func makeDispatcher(_ environment: DispatcherEnvironment, held: Bool = true) -> SystemInputDispatcher {
        let input = SystemInputDispatcher(clock: { environment.now },
            permissionCheck: { environment.permitted }, postSink: { environment.post($0) },
            watchdogEnabled: false)
        input.onInterruption = { environment.interrupt($0) }
        input.begin(generation: 7, area: area, position: point, doubleClickInterval: 0.5)
        if held {
            environment.setTime(10.01)
            input.frame(generation: 7, capturedAt: 10.01, validHand: true, intents: [.down(point)])
            input.checkWatchdog() // Flushes the asynchronous frame on the same queue.
        }
        return input
    }

    func testTrackingTimeoutReleasesOnceAndDisarmedLeaseRejectsFreshHeartbeat() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.checkWatchdog()
        let interruption = try XCTUnwrap(environment.interruptions.first)
        XCTAssertEqual(interruption.generation, 7)
        XCTAssertEqual(interruption.cause, .trackingTimeout)
        XCTAssertTrue(input.isCurrent(interruption))
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        environment.setTime(10.32)
        input.frame(generation: 7, capturedAt: 10.32, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point)],
                       "A new heartbeat must not silently rearm a timed-out output lease")
        XCTAssertEqual(environment.interruptions, [interruption])
    }

    func testHeldHandTimeoutReleasesDespiteRecentNoHandHeartbeat() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.15)
        input.frame(generation: 7, capturedAt: 10.15, validHand: false, intents: [])
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point)])
        environment.setTime(10.22) // 210 ms from valid hand, only 70 ms from delivery.
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertEqual(try XCTUnwrap(environment.interruptions.first).cause, .trackingTimeout)
        XCTAssertEqual(environment.interruptions.count, 1)
    }

    func testPermissionRevocationInFrameReportsInterruptionImmediately() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setPermission(false)
        environment.setTime(10.02)
        input.frame(generation: 7, capturedAt: 10.02, validHand: true, intents: [.drag(point)])
        input.checkWatchdog()
        let interruption = try XCTUnwrap(environment.interruptions.first)
        XCTAssertEqual(interruption.cause, .permissionRevoked)
        XCTAssertEqual(interruption.generation, 7)
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertEqual(environment.interruptions, [interruption],
                       "frame.accept must notify when it disables the gate before the timer")
        environment.setPermission(true)
        environment.setTime(10.03)
        input.frame(generation: 7, capturedAt: 10.03, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertTrue(input.isCurrent(interruption), "Permission restoration alone does not authorize restart")
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertEqual(environment.interruptions, [interruption])
    }

    func testPermissionRevocationInReleaseReportsOnceBeforeNextTimer() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setPermission(false)
        environment.setTime(10.02)
        input.release([.up(point)], generation: 7)
        let interruption = try XCTUnwrap(environment.interruptions.first)
        XCTAssertEqual(interruption.cause, .permissionRevoked)
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        input.checkWatchdog()
        input.release([.up(point)], generation: 7)
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertEqual(environment.interruptions, [interruption])
    }

    func testTimerClassifiesPermissionRevocationEvenWhenTrackingAlsoExpired() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setPermission(false)
        environment.setTime(10.31)
        input.checkWatchdog()
        let interruption = try XCTUnwrap(environment.interruptions.first)
        XCTAssertEqual(interruption.cause, .permissionRevoked)
        XCTAssertTrue(input.isCurrent(interruption))
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
    }

    func testStaleFrameCanExpireDeliveryAndMustReportOnce() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.frame(generation: 7, capturedAt: 10.01, validHand: true, intents: [.drag(point)])
        input.checkWatchdog()
        let interruption = try XCTUnwrap(environment.interruptions.first)
        XCTAssertEqual(interruption.cause, .trackingTimeout)
        XCTAssertEqual(environment.interruptions, [interruption])
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
    }

    func testTimedOutReleaseReportsTrackingTimeout() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.release([.up(point)], generation: 7)
        XCTAssertEqual(try XCTUnwrap(environment.interruptions.first).cause, .trackingTimeout)
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        input.checkWatchdog()
        XCTAssertEqual(environment.interruptions.count, 1)
    }

    func testNewLeaseInSameGenerationInvalidatesPendingInterruption() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.checkWatchdog()
        let previous = try XCTUnwrap(environment.interruptions.first)
        input.begin(generation: 7, area: area, position: point, doubleClickInterval: 0.5)
        XCTAssertFalse(input.isCurrent(previous))
        environment.setTime(10.32)
        input.frame(generation: 7, capturedAt: 10.32, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point), .down(point)])
        environment.setTime(10.63)
        input.checkWatchdog()
        let current = try XCTUnwrap(environment.interruptions.last)
        XCTAssertEqual(environment.interruptions.count, 2)
        XCTAssertEqual(current.generation, previous.generation)
        XCTAssertGreaterThan(current.leaseID, previous.leaseID)
        XCTAssertFalse(input.isCurrent(previous))
        XCTAssertTrue(input.isCurrent(current))
        XCTAssertEqual(environment.actions, [.down(point), .up(point), .down(point), .up(point)])
    }

    func testExplicitStopInvalidatesInterruptionAndRejectsFurtherFrames() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.checkWatchdog()
        let previous = try XCTUnwrap(environment.interruptions.first)
        input.stop()
        XCTAssertFalse(input.isCurrent(previous))
        environment.setTime(10.32)
        input.frame(generation: 7, capturedAt: 10.32, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertEqual(environment.interruptions, [previous])
    }

    func testExplicitStopWhileHeldReleasesOnceWithoutInterruption() {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        input.stop()
        input.stop()
        environment.setTime(11)
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        XCTAssertTrue(environment.interruptions.isEmpty)
    }

    func testBeginRequiresFreshValidHandBeforeAnyInput() {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment, held: false)
        input.release([.down(point)], generation: 7)
        environment.setTime(10.01)
        input.frame(generation: 7, capturedAt: 9, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        environment.setTime(10.02)
        input.frame(generation: 7, capturedAt: 10.02, validHand: false, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertTrue(environment.actions.isEmpty)
        XCTAssertTrue(environment.interruptions.isEmpty)
        environment.setTime(10.03)
        input.frame(generation: 7, capturedAt: 10.03, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point)])
        input.stop()
    }

    func testBeginWithoutFramesTimesOutWithoutGrantOrRelease() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment, held: false)
        environment.setTime(10.26)
        input.checkWatchdog()
        XCTAssertTrue(environment.actions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(environment.interruptions.first).cause, .trackingTimeout)
    }

    func testOldGenerationCannotRevokeNewLease() throws {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        environment.setTime(10.31)
        input.checkWatchdog()
        let previous = try XCTUnwrap(environment.interruptions.first)
        input.begin(generation: 8, area: area, position: point, doubleClickInterval: 0.5)
        environment.setPermission(false)
        environment.setTime(10.32)
        input.frame(generation: 7, capturedAt: 10.32, validHand: true, intents: [.down(point)])
        input.release([.up(point)], generation: 7) // Synchronous flush without running timer.
        XCTAssertFalse(input.isCurrent(previous))
        XCTAssertEqual(environment.interruptions, [previous])
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
        environment.setPermission(true)
        environment.setTime(10.33)
        input.frame(generation: 8, capturedAt: 10.33, validHand: true, intents: [.down(point)])
        input.checkWatchdog()
        XCTAssertEqual(environment.actions, [.down(point), .up(point), .down(point)])
        input.stop()
    }

    func testCallbackCanCheckLeaseAndStopWithoutQueueDeadlock() {
        let environment = DispatcherEnvironment()
        let input = makeDispatcher(environment)
        input.onInterruption = { [weak input] interruption in
            guard let input else { return XCTFail("Dispatcher must live through callback") }
            XCTAssertTrue(input.isCurrent(interruption))
            XCTAssertEqual(environment.actions, [.down(self.point), .up(self.point)],
                           "Held input must be released before interruption is delivered")
            environment.interrupt(interruption)
            input.stop()
            XCTAssertFalse(input.isCurrent(interruption))
        }
        environment.setTime(10.31)
        input.checkWatchdog()
        XCTAssertEqual(environment.interruptions.count, 1)
        XCTAssertEqual(environment.actions, [.down(point), .up(point)])
    }
}
