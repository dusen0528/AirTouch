import AppKit
import ApplicationServices
import AirTouchCore

/// Injecting the sink lets the real processing pipeline run in tests without
/// posting mouse events. The production sink keeps its own final safety gate.
protocol SystemTrackingInputSink: AnyObject {
    func begin(generation: Int, area: DisplayArea, position: Point, doubleClickInterval: Double)
    func frame(generation: Int, capturedAt: Double, validHand: Bool, intents: [InputIntent])
    func release(_ intents: [InputIntent], generation: Int)
    func stop()
    func isCurrent(_ interruption: SystemInputInterruption) -> Bool
}

extension SystemTrackingInputSink {
    func isCurrent(_ interruption: SystemInputInterruption) -> Bool { false }
}

extension SystemInputDispatcher: SystemTrackingInputSink {}

struct TrackingLatencyStatistics: Sendable {
    let sampleCount: Int
    let median: Double
    let p95: Double
    let maximum: Double
}

struct SystemTrackingStatistics: Sendable {
    var acceptedFrames = 0
    var validFrames = 0
    var staleFrames = 0
    var rejectedFrames = 0
    var intentCount = 0
    var watchdogReleases = 0
    // Full timing summaries are computed on explicit statistics reads, never
    // sorted for every frame on the latency-sensitive processing queue.
    var captureToSubmissionMs: TrackingLatencyStatistics?
    var inferenceToSubmissionMs: TrackingLatencyStatistics?
    var processingMs: TrackingLatencyStatistics?
}

private struct BoundedLatencySamples {
    private var values: [Double] = []
    private var next = 0
    mutating func append(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if values.count < 500 { values.append(value) }
        else { values[next] = value; next = (next + 1) % 500 }
    }
    var summary: TrackingLatencyStatistics? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return TrackingLatencyStatistics(sampleCount: sorted.count,
            median: sorted[sorted.count / 2],
            p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            maximum: sorted[sorted.count - 1])
    }
}

// GestureEngine is a value-type snapshot containing no shared mutable objects.
struct ProcessedTrackingFrame: @unchecked Sendable {
    let result: TrackingResult
    let before: GestureEngine
    let engine: GestureEngine
    let processingStartedAt: Double
    let processingCompletedAt: Double
    /// The sink enqueue time, not a claim about OS event delivery or display.
    let inputSubmittedAt: Double?
    let actions: [InputIntent]
    let handoff: Bool
    let outputStarted: Bool
    let rejectionReason: String?
    let statistics: SystemTrackingStatistics
    var accepted: Bool { rejectionReason == nil }
}

struct TrackingWatchdogState: @unchecked Sendable {
    let before: GestureEngine
    let engine: GestureEngine
    let actions: [InputIntent]
    let processedAt: Double
    let outputStarted: Bool
    let statistics: SystemTrackingStatistics
}

/// Camera -> latest result -> gesture engine -> input sink runs independently
/// of AppKit/SwiftUI. Presentation is a separate latest-only mailbox; its default
/// executor is the main queue, and callbacks may use MainActor.assumeIsolated.
/// A custom presentation executor must enqueue its argument and return promptly.
final class SystemTrackingController {
    private struct Intake: Sendable { let epoch: UInt64; let result: TrackingResult }
    private enum Presentation: @unchecked Sendable {
        case frame(UInt64, ProcessedTrackingFrame)
        case watchdog(UInt64, TrackingWatchdogState)
        var epoch: UInt64 {
            switch self { case .frame(let epoch, _), .watchdog(let epoch, _): return epoch }
        }
    }

    private let queue = DispatchQueue(label: "airtouch.system-tracking", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let input: SystemTrackingInputSink
    private let clock: () -> Double
    private let cursorPosition: () -> Point
    private let mouseButtonsHeld: () -> Bool
    private let present: (@escaping @Sendable () -> Void) -> Void
    private var timer: DispatchSourceTimer?

    // Only routing and callback access cross queues. Engine state stays on queue.
    private let lock = NSLock()
    private var routingActive = false
    private var routingEpoch: UInt64 = 0
    private var routingGeneration = 0
    private var processedCallback: ((ProcessedTrackingFrame) -> Void)?
    private var watchdogCallback: ((TrackingWatchdogState) -> Void)?
    var onProcessed: ((ProcessedTrackingFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return processedCallback }
        set { lock.lock(); processedCallback = newValue; lock.unlock() }
    }
    var onWatchdogState: ((TrackingWatchdogState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return watchdogCallback }
        set { lock.lock(); watchdogCallback = newValue; lock.unlock() }
    }

    private var engine = GestureEngine()
    private var display: ControlDisplay?
    private var epoch: UInt64 = 0
    private var running = false
    private var handoffUntil = 0.0
    private var minimumCaptureTime = -Double.infinity
    private var lastSequence = -1
    private var lastCapturedAt = -Double.infinity
    private var outputStarted = false
    private var doubleClickInterval = 0.5
    private var counters = SystemTrackingStatistics()
    private var captureSubmissionSamples = BoundedLatencySamples()
    private var inferenceSubmissionSamples = BoundedLatencySamples()
    private var processingSamples = BoundedLatencySamples()

    private lazy var intake = LatestValueDelivery<Intake>(schedule: { [weak self] work in
        self?.queue.async(execute: work)
    }, consume: { [weak self] value in self?.process(value) })
    // One shared mailbox preserves ordering between frame and watchdog updates.
    private lazy var presentation = LatestValueDelivery<Presentation>(schedule: { [weak self] work in
        self?.present(work)
    }, consume: { [weak self] value in self?.deliver(value) })

    init(input: SystemTrackingInputSink,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         cursorPosition: @escaping () -> Point = {
             let p = CGEvent(source: nil)?.location ?? .zero
             return Point(p.x, p.y)
         },
         mouseButtonsHeld: @escaping () -> Bool = {
             CGEventSource.buttonState(.combinedSessionState, button: .left)
                 || CGEventSource.buttonState(.combinedSessionState, button: .right)
         },
         presentationExecutor: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         watchdogEnabled: Bool = true) {
        self.input = input; self.clock = clock; self.cursorPosition = cursorPosition
        self.mouseButtonsHeld = mouseButtonsHeld; self.present = presentationExecutor
        queue.setSpecific(key: queueKey, value: true)
        // Initialize lazy mailboxes before start/submit can arrive on other queues.
        _ = intake; _ = presentation
        if watchdogEnabled {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.03, repeating: 0.03)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }

    deinit { timer?.cancel(); input.stop() }

    /// `engine` must already be started; camera and controller share its generation.
    @discardableResult
    func start(engine: GestureEngine, display: ControlDisplay, handoffUntil: Double,
               doubleClickInterval: Double = 0.5) -> GestureEngine {
        sync {
            input.stop()
            self.engine = engine; self.display = display
            self.handoffUntil = handoffUntil; self.doubleClickInterval = doubleClickInterval
            outputStarted = false; minimumCaptureTime = -.infinity
            lastSequence = -1; lastCapturedAt = -.infinity
            counters = SystemTrackingStatistics()
            captureSubmissionSamples = BoundedLatencySamples()
            inferenceSubmissionSamples = BoundedLatencySamples()
            processingSamples = BoundedLatencySamples()
            running = engine.enabled
            advanceEpoch(active: running)
            intake.resetStatistics(); presentation.resetStatistics()
            return self.engine
        }
    }

    /// Synchronous fence: no queued frame can press a button after this returns.
    @discardableResult
    func stop(reason: String = "제어가 멈췄습니다") -> GestureEngine {
        sync {
            running = false; advanceEpoch(active: false)
            counters.intentCount += engine.stop(reason: reason).count
            input.stop(); outputStarted = false
            return engine
        }
    }

    /// Physical input owns the pointer until the deadline. Camera routing remains
    /// active, but observations captured before the pause cannot resume control.
    @discardableResult
    func pause(until: Double, reason: String) -> GestureEngine {
        sync {
            guard running else { return engine }
            advanceEpoch(active: true)
            handoffUntil = until; minimumCaptureTime = clock()
            counters.intentCount += engine.pause(reason: reason).count
            input.stop(); outputStarted = false
            return engine
        }
    }

    /// A final-output timeout releases input immediately, but must not close the
    /// camera session. Resume only from a fresh capture and normal pose activation.
    /// Run this off the output queue: pause/stop synchronously fence that queue.
    func handleInputInterruption(_ interruption: SystemInputInterruption) -> GestureEngine? {
        sync {
            guard running, engine.generation == interruption.generation,
                  input.isCurrent(interruption) else { return nil }
            switch interruption.cause {
            case .trackingTimeout:
                return pause(until: clock(), reason: "영상이 잠깐 끊겼습니다 · 검지를 펴면 다시 이어집니다")
            case .permissionRevoked:
                return stop(reason: "입력 권한이 해제되어 전체 제어를 멈췄습니다")
            }
        }
    }

    /// False means the caller should route this frame to camera practice instead.
    @discardableResult
    func submit(_ result: TrackingResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let active = routingActive
        if active, result.generation == routingGeneration {
            intake.submit(Intake(epoch: routingEpoch, result: result))
        }
        return active
    }

    var engineSnapshot: GestureEngine { sync { engine } }
    var replacedFrameCount: Int { intake.replacedCount }
    var replacedPresentationCount: Int { presentation.replacedCount }
    var statistics: SystemTrackingStatistics {
        sync {
            var result = counters
            result.captureToSubmissionMs = captureSubmissionSamples.summary
            result.inferenceToSubmissionMs = inferenceSubmissionSamples.summary
            result.processingMs = processingSamples.summary
            return result
        }
    }

    /// Same watchdog path as the independent timer; deterministic test seam.
    func checkWatchdog() { sync { tick() } }

    private func process(_ value: Intake) {
        guard running, value.epoch == epoch else { return }
        let result = value.result
        guard result.generation == engine.generation else { return }
        let before = engine
        let now = clock()
        var actions: [InputIntent] = []
        var submittedAt: Double?
        var handoff = false
        var rejection: String?
        if !now.isFinite || !result.capturedAt.isFinite || result.capturedAt > now
            || now - result.capturedAt >= engine.configuration.frameTimeout {
            rejection = "영상 처리가 지연되고 있습니다"
            counters.staleFrames += 1
        } else if result.sequence <= lastSequence || result.capturedAt <= lastCapturedAt
            || result.capturedAt <= minimumCaptureTime {
            rejection = "이미 처리했거나 제어 중지 전에 촬영한 영상입니다"
        } else {
            counters.acceptedFrames += 1
            if result.features?.isValid == true { counters.validFrames += 1 }
            lastSequence = result.sequence; lastCapturedAt = result.capturedAt
            if now < handoffUntil || (!outputStarted && mouseButtonsHeld()) {
                handoff = true
            } else if let display {
                if !outputStarted {
                    _ = engine.rebase(to: display.area.local(cursorPosition()),
                                      width: display.area.width, height: display.area.height)
                    input.begin(generation: engine.generation, area: display.area, position: engine.cursor,
                                doubleClickInterval: doubleClickInterval)
                    outputStarted = true
                }
                actions = engine.process(result.features, sequence: result.sequence,
                    generation: result.generation, capturedAt: result.capturedAt, now: now)
                input.frame(generation: result.generation, capturedAt: result.capturedAt,
                            validHand: result.features?.isValid == true, intents: actions)
                submittedAt = clock()
                counters.intentCount += actions.count
                if let submittedAt {
                    captureSubmissionSamples.append((submittedAt - result.capturedAt) * 1000)
                    inferenceSubmissionSamples.append((submittedAt - result.completedAt) * 1000)
                }
            }
        }
        if rejection != nil { counters.rejectedFrames += 1 }
        let completedAt = clock()
        processingSamples.append((completedAt - now) * 1000)
        let snapshot = ProcessedTrackingFrame(result: result, before: before, engine: engine,
            processingStartedAt: now, processingCompletedAt: completedAt, inputSubmittedAt: submittedAt,
            actions: actions, handoff: handoff, outputStarted: outputStarted, rejectionReason: rejection,
            statistics: counters)
        presentation.submit(.frame(epoch, snapshot))
    }

    private func tick() {
        guard running, outputStarted else { return }
        let before = engine
        let now = clock()
        let actions = engine.tick(at: now)
        if !actions.isEmpty {
            input.release(actions, generation: engine.generation)
            counters.intentCount += actions.count
            counters.watchdogReleases += actions.filter { if case .up = $0 { return true }; return false }.count
        }
        if before.state != engine.state || before.reason != engine.reason || !actions.isEmpty {
            presentation.submit(.watchdog(epoch, TrackingWatchdogState(before: before,
                engine: engine, actions: actions, processedAt: now, outputStarted: outputStarted,
                statistics: counters)))
        }
    }

    private func advanceEpoch(active: Bool) {
        epoch &+= 1
        lock.lock()
        routingEpoch = epoch; routingActive = active; routingGeneration = engine.generation
        lock.unlock()
    }

    private func deliver(_ value: Presentation) {
        lock.lock()
        let current = routingActive && routingEpoch == value.epoch
        let processed = processedCallback
        let watchdog = watchdogCallback
        lock.unlock()
        guard current else { return }
        switch value {
        case .frame(_, let snapshot): processed?(snapshot)
        case .watchdog(_, let snapshot): watchdog?(snapshot)
        }
    }

    private func sync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        return queue.sync(execute: work)
    }
}
