import XCTest
@testable import AirTouchApp
import AirTouchCore

private final class TestClock {
    private let lock = NSLock()
    private var value: Double = 100
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: Double) { lock.lock(); value += amount; lock.unlock() }
}

private final class BlockedPresentation {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
    func enqueue(_ job: @escaping @Sendable () -> Void) { lock.lock(); jobs.append(job); lock.unlock() }
    func drain() {
        lock.lock(); let current = jobs; jobs = []; lock.unlock()
        current.forEach { $0() }
    }
}

/// Executes the real final gate but never constructs or posts a CGEvent.
private final class RecordingInput: SystemTrackingInputSink {
    private let lock = NSLock()
    private let clock: TestClock
    private var gate = SystemOutputGate()
    private var recorded: [InputIntent] = []
    private var frames = 0
    private var starts: [Point] = []
    var onRelease: (() -> Void)?
    init(clock: TestClock) { self.clock = clock }
    var events: [InputIntent] { lock.lock(); defer { lock.unlock() }; return recorded }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var startPositions: [Point] { lock.lock(); defer { lock.unlock() }; return starts }
    var held: Bool { lock.lock(); defer { lock.unlock() }; return gate.held }
    func begin(generation: Int, area: DisplayArea, position: Point, doubleClickInterval: Double) {
        lock.lock(); defer { lock.unlock() }
        recorded += gate.begin(generation: generation, position: position, now: clock.now)
        starts.append(position)
    }
    func frame(generation: Int, capturedAt: Double, validHand: Bool, intents: [InputIntent]) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        gate.heartbeat(generation: generation, capturedAt: capturedAt, validHand: validHand, now: clock.now)
        recorded += gate.accept(intents, generation: generation, now: clock.now, permitted: true)
    }
    func release(_ intents: [InputIntent], generation: Int) {
        lock.lock()
        let actions = gate.accept(intents, generation: generation, now: clock.now, permitted: true)
        recorded += actions
        lock.unlock()
        if actions.contains(where: { if case .up = $0 { return true }; return false }) { onRelease?() }
    }
    func stop() {
        lock.lock(); recorded += gate.stop(); lock.unlock()
    }
}

private final class TrackingHarness {
    let clock = TestClock()
    let presentation = BlockedPresentation()
    let input: RecordingInput
    let controller: SystemTrackingController
    var engine: GestureEngine
    var hand = HandFeatures(index: Point(0.4, 0.35), palm: Point(0.4, 0.55))
    var sequence = 0
    var snapshots: [ProcessedTrackingFrame] = []
    static let display = ControlDisplay(id: 1, name: "Test",
        area: DisplayArea(origin: Point(1000, 0), width: 1800, height: 1125))
    init(watchdog: Bool = false) {
        input = RecordingInput(clock: clock)
        let clock = clock, presentation = presentation
        controller = SystemTrackingController(input: input, clock: { clock.now },
            cursorPosition: { Point(1600, 400) }, mouseButtonsHeld: { false },
            presentationExecutor: { presentation.enqueue($0) }, watchdogEnabled: watchdog)
        var engine = GestureEngine(); engine.configuration.activationDuration = 0.02
        engine.start(); self.engine = engine
        controller.onProcessed = { [weak self] in self?.snapshots.append($0) }
        controller.start(engine: engine, display: Self.display, handoffUntil: 0)
    }
    func result(generation: Int? = nil, sequence: Int? = nil, capturedAt: Double? = nil) -> TrackingResult {
        let time = capturedAt ?? clock.now
        return TrackingResult(generation: generation ?? engine.generation, sequence: sequence ?? self.sequence,
            capturedAt: time, deliveredAt: time, completedAt: time, aspectRatio: 16 / 9,
            pixelFormat: 0, joints: [:], features: hand, handCount: 1, message: "test")
    }
    func send(_ count: Int = 1) {
        for _ in 0..<count {
            clock.advance(1 / 30); sequence += 1
            XCTAssertTrue(controller.submit(result()))
            _ = controller.engineSnapshot // Real queue barrier, no arbitrary sleep.
        }
    }
    func press() {
        send(4); XCTAssertEqual(controller.engineSnapshot.state, .pointer)
        hand.pinchRatio = 0.1; send(5)
        XCTAssertTrue(input.held)
    }
}

final class SystemTrackingControllerTests: XCTestCase {
    func testInputProceedsWhilePresentationExecutorIsBlockedAndOnlyLatestSnapshotWaits() {
        let h = TrackingHarness()
        h.send(4)
        for _ in 0..<12 { h.hand.palm.x += 0.006; h.send() }
        XCTAssertTrue(h.input.events.contains { if case .move = $0 { return true }; return false })
        XCTAssertEqual(h.input.frameCount, 16)
        XCTAssertTrue(h.snapshots.isEmpty, "Presentation has not run at all")
        XCTAssertEqual(h.presentation.count, 1, "A busy UI must not accumulate old presentations")
        XCTAssertEqual(h.controller.statistics.acceptedFrames, 16)
        XCTAssertEqual(h.controller.statistics.validFrames, 16)
        XCTAssertEqual(h.controller.statistics.intentCount, h.input.events.count)
        h.presentation.drain()
        XCTAssertEqual(h.snapshots.count, 1)
        XCTAssertEqual(h.snapshots.last?.result.sequence, h.sequence)
        XCTAssertNotNil(h.snapshots.last?.inputSubmittedAt)
        XCTAssertEqual(h.snapshots.last?.statistics.acceptedFrames, 16)
    }

    func testStaleFutureDuplicateAndOldGenerationFramesNeverReachSink() {
        let h = TrackingHarness(); h.send(3)
        let count = h.input.frameCount
        let badFrames = [
            h.result(generation: h.engine.generation - 1, sequence: 100),
            h.result(sequence: 100, capturedAt: h.clock.now - 0.21),
            h.result(sequence: 100, capturedAt: h.clock.now + 1),
            h.result(), // duplicate sequence and timestamp
            h.result(sequence: 1, capturedAt: h.clock.now + 0.001)
        ]
        for frame in badFrames { h.controller.submit(frame); _ = h.controller.engineSnapshot }
        XCTAssertEqual(h.input.frameCount, count)
        h.send()
        XCTAssertEqual(h.input.frameCount, count + 1, "Bad frames cannot poison the fresh sequence")
    }

    func testStopReleasesHeldButtonRejectsRoutingAndInvalidatesQueuedPresentation() {
        let h = TrackingHarness(); h.press()
        let count = h.input.frameCount
        let stopped = h.controller.stop()
        XCTAssertFalse(stopped.enabled)
        XCTAssertFalse(h.input.held)
        XCTAssertEqual(h.input.events.filter { if case .up = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(h.controller.submit(h.result(sequence: 100)))
        _ = h.controller.engineSnapshot
        h.presentation.drain()
        XCTAssertTrue(h.snapshots.isEmpty, "Stopped session must not repaint the UI as running")
        XCTAssertEqual(h.input.frameCount, count)
    }

    func testPauseReleasesThenRebasesOnlyAfterDeadlineUsingFreshCapture() {
        let h = TrackingHarness(); h.press()
        let beforePause = h.result(sequence: 100)
        let deadline = h.clock.now + 0.1
        let paused = h.controller.pause(until: deadline, reason: "physical mouse")
        XCTAssertTrue(paused.enabled)
        XCTAssertFalse(h.input.held)
        XCTAssertTrue(h.controller.submit(beforePause))
        _ = h.controller.engineSnapshot
        h.presentation.drain()
        XCTAssertEqual(h.snapshots.last?.accepted, false)
        let count = h.input.frameCount
        h.hand.pinchRatio = 0.8
        h.send(2)
        XCTAssertEqual(h.input.frameCount, count, "No input during physical handoff")
        h.clock.advance(0.1); h.send()
        XCTAssertEqual(h.input.frameCount, count + 1)
        XCTAssertEqual(h.input.startPositions.count, 2)
        XCTAssertFalse(h.input.held)
        XCTAssertEqual(h.controller.engineSnapshot.cursor, Point(600, 400))
    }

    func testRestartCannotProcessPreviousGenerationEvenIfItsSequenceIsLarger() {
        let h = TrackingHarness(); h.send(3)
        let old = h.result(sequence: 1000)
        h.engine = h.controller.stop(); h.engine.start()
        h.controller.start(engine: h.engine, display: TrackingHarness.display, handoffUntil: 0)
        let count = h.input.frameCount
        XCTAssertTrue(h.controller.submit(old))
        _ = h.controller.engineSnapshot
        XCTAssertEqual(h.input.frameCount, count)
        h.send()
        XCTAssertEqual(h.input.frameCount, count + 1)
    }

    func testIndependentWatchdogReleasesHeldInputWhilePresentationIsBlocked() {
        let h = TrackingHarness(watchdog: true); h.press()
        let release = expectation(description: "independent timer released mouse")
        h.input.onRelease = { release.fulfill() }
        h.clock.advance(0.14)
        wait(for: [release], timeout: 1)
        XCTAssertFalse(h.input.held)
        XCTAssertEqual(h.controller.engineSnapshot.state, .suspended)
        XCTAssertEqual(h.controller.statistics.watchdogReleases, 1)
        XCTAssertEqual(h.controller.statistics.intentCount, h.input.events.count)
        XCTAssertTrue(h.snapshots.isEmpty)
    }

    func testTimingSummariesRemainBoundedWhileCumulativeCountsKeepAllProcessedFrames() {
        let h = TrackingHarness()
        for sequence in 1...520 {
            h.clock.advance(1 / 30)
            let now = h.clock.now
            h.controller.submit(TrackingResult(generation: h.engine.generation, sequence: sequence,
                capturedAt: now - 0.1, deliveredAt: now - 0.03, completedAt: now - 0.02,
                aspectRatio: 1, pixelFormat: 0, joints: [:], features: h.hand, handCount: 1, message: "test"))
            _ = h.controller.engineSnapshot
        }
        let stats = h.controller.statistics
        XCTAssertEqual(stats.acceptedFrames, 520)
        XCTAssertEqual(stats.captureToSubmissionMs?.sampleCount, 500)
        XCTAssertEqual(stats.inferenceToSubmissionMs?.sampleCount, 500)
        XCTAssertEqual(stats.captureToSubmissionMs?.median ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(stats.inferenceToSubmissionMs?.p95 ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(h.presentation.count, 1)
        h.presentation.drain()
        XCTAssertEqual(h.snapshots.last?.statistics.acceptedFrames, 520)
    }

    func testPhysicalMouseButtonsDelayInitialAcquisitionAndRebaseAtAcquisition() {
        let clock = TestClock(), presentation = BlockedPresentation()
        let input = RecordingInput(clock: clock)
        var buttonsHeld = true
        var cursor = Point(1300, 200)
        let controller = SystemTrackingController(input: input, clock: { clock.now },
            cursorPosition: { cursor }, mouseButtonsHeld: { buttonsHeld },
            presentationExecutor: { presentation.enqueue($0) }, watchdogEnabled: false)
        var engine = GestureEngine(); engine.start()
        controller.start(engine: engine, display: TrackingHarness.display, handoffUntil: 0)
        func send(_ sequence: Int) {
            clock.advance(1 / 30)
            controller.submit(TrackingResult(generation: engine.generation, sequence: sequence,
                capturedAt: clock.now, deliveredAt: clock.now, completedAt: clock.now,
                aspectRatio: 1, pixelFormat: 0, joints: [:], features: nil, handCount: 0, message: "test"))
            _ = controller.engineSnapshot
        }
        send(1); XCTAssertTrue(input.startPositions.isEmpty)
        buttonsHeld = false; cursor = Point(1700, 600)
        send(2)
        XCTAssertEqual(input.startPositions, [Point(700, 600)])
    }
}
