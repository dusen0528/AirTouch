import Foundation
import XCTest
import AirTouchCore
@testable import AirTouchApp

private final class RecoveryEnvironment {
    private let lock = NSLock()
    private var time = 100.0
    private var permission = true
    private var recorded: [InputIntent] = []
    private var interruptions: [SystemInputInterruption] = []
    private var frames: [ProcessedTrackingFrame] = []

    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    var permitted: Bool { lock.lock(); defer { lock.unlock() }; return permission }
    var actions: [InputIntent] { lock.lock(); defer { lock.unlock() }; return recorded }
    var notices: [SystemInputInterruption] { lock.lock(); defer { lock.unlock() }; return interruptions }
    var lastFrame: ProcessedTrackingFrame? { lock.lock(); defer { lock.unlock() }; return frames.last }
    func advance(_ amount: Double) { lock.lock(); time += amount; lock.unlock() }
    func setPermission(_ value: Bool) { lock.lock(); permission = value; lock.unlock() }
    func post(_ actions: [InputIntent]) { lock.lock(); recorded += actions; lock.unlock() }
    func record(_ notice: SystemInputInterruption) { lock.lock(); interruptions.append(notice); lock.unlock() }
    func record(_ frame: ProcessedTrackingFrame) { lock.lock(); frames.append(frame); lock.unlock() }
}

/// Real controller + dispatcher + final gate, with synthetic observations and a
/// fake post sink. This covers their recovery boundary, not AppModel or CGEvents.
private final class SystemRecoveryHarness {
    let environment = RecoveryEnvironment()
    let input: SystemInputDispatcher
    let controller: SystemTrackingController
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var sequence = 0
    private var handledNoticeCount = 0
    private let presentationQueue = DispatchQueue(label: "airtouch.test-recovery-presentation")
    static let display = ControlDisplay(id: 1, name: "Synthetic recovery test",
        area: DisplayArea(origin: Point(1000, 0), width: 1800, height: 1125))

    init() {
        let environment = environment
        let presentationQueue = presentationQueue
        input = SystemInputDispatcher(clock: { environment.now },
            permissionCheck: { environment.permitted }, postSink: { environment.post($0) },
            watchdogEnabled: false)
        controller = SystemTrackingController(input: input, clock: { environment.now },
            cursorPosition: { Point(1600, 400) }, mouseButtonsHeld: { false },
            presentationExecutor: { presentationQueue.async(execute: $0) }, watchdogEnabled: false)
        // Defer recovery until outside the dispatcher's queue, as production's
        // main-actor callback does. Never reproduce the recovery policy here.
        input.onInterruption = { environment.record($0) }
        controller.onProcessed = { environment.record($0) }
        explicitStart()
    }

    func explicitStart() {
        var engine = controller.engineSnapshot
        engine.start()
        controller.start(engine: engine, display: Self.display, handoffUntil: 0)
    }

    func result(capturedAt: Double? = nil, sequence: Int? = nil) -> TrackingResult {
        let time = capturedAt ?? environment.now
        return TrackingResult(generation: controller.engineSnapshot.generation,
            sequence: sequence ?? self.sequence, capturedAt: time, deliveredAt: environment.now,
            completedAt: environment.now, aspectRatio: 16.0 / 9, pixelFormat: 0,
            joints: [:], features: hand, handCount: 1, message: "Synthetic recovery test")
    }

    func flush() {
        _ = controller.engineSnapshot // Processing-queue barrier.
        input.checkWatchdog() // Output-queue barrier and production watchdog.
        presentationQueue.sync {}
    }

    func send(_ count: Int = 1) {
        for _ in 0..<count {
            environment.advance(1.0 / 30); sequence += 1
            XCTAssertTrue(controller.submit(result()))
            flush()
        }
    }

    @discardableResult
    func handleNotices() -> [GestureEngine] {
        let pending = Array(environment.notices.dropFirst(handledNoticeCount))
        handledNoticeCount += pending.count
        return pending.compactMap { controller.handleInputInterruption($0) }
    }

    func press() {
        send(13)
        XCTAssertEqual(controller.engineSnapshot.state, .pointer)
        hand.pinchRatio = 0.1
        send(5)
        XCTAssertTrue(controller.engineSnapshot.isButtonHeld)
        XCTAssertEqual(downs, 1)
    }

    func expireOutput() {
        environment.advance(0.31)
        input.checkWatchdog()
    }

    func move() {
        for _ in 0..<3 {
            hand.palm.x += 0.006
            hand.index.x += 0.006
            send()
        }
    }

    var downs: Int { environment.actions.filter { if case .down = $0 { return true }; return false }.count }
    var ups: Int { environment.actions.filter { if case .up = $0 { return true }; return false }.count }
    var moves: Int { environment.actions.filter { if case .move = $0 { return true }; return false }.count }
}

final class SystemTrackingRecoveryTests: XCTestCase {
    func testTimeoutReleasesOnceAndFreshPointerDwellResumesWithoutManualStart() throws {
        let h = SystemRecoveryHarness()
        h.press()
        let generation = h.controller.engineSnapshot.generation
        h.expireOutput()
        h.input.checkWatchdog()
        XCTAssertEqual(h.ups, 1)
        XCTAssertEqual(h.environment.notices.count, 1)
        XCTAssertEqual(h.environment.notices.first?.cause, .trackingTimeout)
        let paused = try XCTUnwrap(h.handleNotices().first)
        XCTAssertTrue(paused.enabled)
        XCTAssertEqual(paused.state, .suspended)
        XCTAssertFalse(paused.isButtonHeld)
        XCTAssertEqual(paused.generation, generation)
        XCTAssertEqual(h.ups, 1, "Pausing after gate expiry must not emit a second mouse-up")

        h.hand.pinchRatio = 0.8
        h.send()
        XCTAssertEqual(h.controller.engineSnapshot.state, .suspended,
                       "One fresh frame must not bypass the normal activation dwell")
        h.send(12)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        let beforeMove = h.moves
        h.move()
        XCTAssertGreaterThan(h.moves, beforeMove)
        XCTAssertEqual(h.controller.engineSnapshot.generation, generation)
        XCTAssertEqual(h.downs, 1)
        XCTAssertEqual(h.ups, 1)
    }

    func testReturningWithPinchHeldCannotCreateAnotherClick() {
        let h = SystemRecoveryHarness()
        h.press()
        h.expireOutput()
        h.handleNotices()
        h.send(16)
        XCTAssertEqual(h.controller.engineSnapshot.state, .suspended)
        XCTAssertEqual(h.downs, 1, "Continuing the interrupted pinch must not become a new press")
        XCTAssertEqual(h.ups, 1)
        h.hand.pinchRatio = 0.8
        h.send(13)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        h.hand.pinchRatio = 0.1
        h.send(5)
        XCTAssertEqual(h.downs, 2, "A new pinch after open-hand activation may press normally")
        XCTAssertEqual(h.ups, 1)
    }

    func testCaptureBeforeRecoveryFenceIsRejectedEvenWhenItsAgeIsFresh() {
        let h = SystemRecoveryHarness()
        h.send(13)
        h.expireOutput()
        h.sequence += 1
        let capturedBeforePause = h.result(capturedAt: h.environment.now - 0.01)
        h.handleNotices()
        let before = h.environment.actions
        XCTAssertTrue(h.controller.submit(capturedBeforePause))
        h.flush()
        XCTAssertEqual(h.environment.lastFrame?.accepted, false)
        XCTAssertTrue(h.environment.lastFrame?.rejectionReason?.contains("제어 중지 전에 촬영") == true)
        XCTAssertEqual(h.environment.actions, before)
        XCTAssertEqual(h.controller.engineSnapshot.state, .suspended)
        h.send(13)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        h.move()
        XCTAssertGreaterThan(h.moves, 0)
    }

    func testPermissionRestorationDoesNotResumeUntilExplicitStart() throws {
        let h = SystemRecoveryHarness()
        h.press()
        h.environment.setPermission(false)
        h.send()
        XCTAssertEqual(h.environment.notices.first?.cause, .permissionRevoked)
        let stopped = try XCTUnwrap(h.handleNotices().first)
        XCTAssertFalse(stopped.enabled)
        XCTAssertEqual(h.ups, 1)
        let before = h.environment.actions
        h.environment.setPermission(true)
        h.hand.pinchRatio = 0.8
        for _ in 0..<15 {
            h.environment.advance(1.0 / 30); h.sequence += 1
            XCTAssertFalse(h.controller.submit(h.result()))
            h.flush()
        }
        XCTAssertFalse(h.controller.engineSnapshot.enabled)
        XCTAssertEqual(h.environment.actions, before)
        h.explicitStart()
        h.send(13)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        let beforeMove = h.moves
        h.move()
        XCTAssertGreaterThan(h.moves, beforeMove)
    }

    func testDelayedInterruptionCannotPauseANewerLeaseInTheSameGeneration() throws {
        let h = SystemRecoveryHarness()
        h.send(13)
        let generation = h.controller.engineSnapshot.generation
        h.expireOutput()
        let old = try XCTUnwrap(h.environment.notices.first)
        h.controller.pause(until: h.environment.now, reason: "Synthetic physical-input handoff")
        h.send(13)
        XCTAssertEqual(h.controller.engineSnapshot.generation, generation)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        XCTAssertFalse(h.input.isCurrent(old))
        XCTAssertNil(h.controller.handleInputInterruption(old))
        XCTAssertTrue(h.controller.engineSnapshot.enabled)
        XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
        let beforeMove = h.moves
        h.move()
        XCTAssertGreaterThan(h.moves, beforeMove)
    }

    func testFiveTrackingTimeoutsRecoverRepeatedlyWithinTheSameSession() throws {
        let h = SystemRecoveryHarness()
        h.send(13)
        let generation = h.controller.engineSnapshot.generation
        var leases: Set<UInt64> = []
        for attempt in 1...5 {
            h.expireOutput()
            XCTAssertEqual(h.environment.notices.count, attempt)
            let notice = try XCTUnwrap(h.environment.notices.last)
            XCTAssertEqual(notice.cause, .trackingTimeout)
            XCTAssertTrue(leases.insert(notice.leaseID).inserted,
                          "Each recovery must acquire a new output lease")
            let recovered = try XCTUnwrap(h.handleNotices().first)
            XCTAssertTrue(recovered.enabled)
            XCTAssertEqual(recovered.generation, generation)
            XCTAssertEqual(recovered.state, .suspended)
            h.send()
            XCTAssertEqual(h.controller.engineSnapshot.state, .suspended)
            h.send(12)
            XCTAssertEqual(h.controller.engineSnapshot.state, .pointer)
            let beforeMove = h.moves
            h.move()
            XCTAssertGreaterThan(h.moves, beforeMove, "Recovery attempt \(attempt)")
            XCTAssertEqual(h.controller.engineSnapshot.generation, generation)
        }
        XCTAssertEqual(h.downs, 0)
        XCTAssertEqual(h.ups, 0)
    }
}
