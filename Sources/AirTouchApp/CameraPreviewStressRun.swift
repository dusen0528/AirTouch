import AppKit
import AVFoundation

/// Explicit diagnostic only: the caller must opt in with
/// --camera-preview-stress-report <path> and retain this object until completion.
/// Uses the production camera and preview wrappers, without windows or OS input.
@MainActor final class CameraPreviewStressRun {
    private enum Phase { case idle, running, stopping, finishing, finished }

    /// Strip hand landmarks and recognition features before crossing to the UI.
    private struct FrameSample: Sendable {
        let generation: Int
        let sequence: Int
        let capturedAt: Double
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let drops: [String: Int]
    }

    private struct CycleReport: Encodable {
        let cycle: Int
        let generation: Int
        let succeeded: Bool
        let freshFrames: Int
        let rejectedFrames: Int
        let elapsedSeconds: Double
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let captureDrops: [String: Int]
    }

    private struct Report: Encodable {
        let schema = "airtouch.camera-preview-stress.v1"
        let status: String
        let success: Bool
        let osInputEnabled = false
        let imagesStored = false
        let handCoordinatesStored = false
        let visibleWindowsCreated = false
        let requestedCycles: Int
        let completedCycles: Int
        let requiredFreshFramesPerCycle = 3
        let maximumFrameAgeMilliseconds = 200
        let timeoutSecondsPerCycle = 20
        let elapsedSeconds: Double
        let cameraStopped: Bool
        let failure: String?
        let cycles: [CycleReport]
    }

    private let reportURL: URL
    private let requestedCycles: Int
    private var completion: ((Bool) -> Void)?
    private let captureQueue: DispatchQueue
    private let camera: CameraService
    private var preview: PreviewHost?
    private var deadline: Timer?
    private var cleanupDeadline: Timer?
    private var phase: Phase = .idle
    private var runStartedAt = 0.0
    private var cycleStartedAt = 0.0
    private var previewReadyAt: Double?
    private var generation = 0
    private var freshFrames = 0
    private var rejectedFrames = 0
    private var lastSequence = -1
    private var lastCapture = -Double.infinity
    private var captureWidth = 0
    private var captureHeight = 0
    private var pixelFormat: UInt32 = 0
    private var captureDrops: [String: Int] = [:]
    private var cycles: [CycleReport] = []
    private var failure: String?

    init(reportURL: URL, cycles: Int = 10, completion: @escaping (Bool) -> Void) {
        self.reportURL = reportURL
        requestedCycles = max(10, cycles)
        self.completion = completion
        let queue = DispatchQueue(label: "airtouch.preview-stress.capture-session")
        captureQueue = queue
        camera = CameraService(sessionQueue: queue)
    }

    deinit {
        deadline?.invalidate()
        cleanupDeadline?.invalidate()
        camera.stop()
    }

    func start() {
        guard phase == .idle else { return }
        runStartedAt = Self.now
        // Never open a permission prompt as part of an unattended diagnostic.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            failure = "camera_permission_not_authorized"
            finish(success: false, cameraStopped: true)
            return
        }
        camera.onResult = { [weak self] result in
            let sample = FrameSample(generation: result.generation, sequence: result.sequence,
                capturedAt: result.capturedAt, width: result.captureWidth,
                height: result.captureHeight, pixelFormat: result.pixelFormat,
                drops: result.captureDrops)
            DispatchQueue.main.async { [weak self] in self?.receive(sample) }
        }
        camera.onStatus = { [weak self] generation, message, failed in
            guard failed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation,
                      self.phase == .running || self.phase == .stopping else { return }
                self.fail("camera_failed: \(message)")
            }
        }
        beginCycle()
    }

    func cancel() {
        guard phase != .finished else { return }
        if phase == .idle {
            runStartedAt = Self.now
            failure = "cancelled"
            finish(success: false, cameraStopped: true)
        } else { fail("cancelled") }
    }

    private func beginCycle() {
        generation += 1
        let cycleGeneration = generation
        cycleStartedAt = Self.now
        previewReadyAt = nil
        freshFrames = 0; rejectedFrames = 0
        lastSequence = -1; lastCapture = -.infinity
        captureWidth = 0; captureHeight = 0; pixelFormat = 0; captureDrops = [:]
        phase = .running
        deadline = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == cycleGeneration,
                      self.phase == .running || self.phase == .stopping else { return }
                self.fail("cycle_\(cycleGeneration)_timeout")
            }
        }
        if let deadline { RunLoop.main.add(deadline, forMode: .common) }
        guard writeReport(status: "running", cameraStopped: false) else {
            fail("report_write_failed"); return
        }

        // Keep the real replacement ordering that raced with startRunning.
        // These views have no window and are never ordered onscreen.
        let oldView = PreviewHost(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        oldView.connect(to: camera)
        camera.start(generation: cycleGeneration)
        let replacement = PreviewHost(frame: oldView.frame)
        replacement.connect(to: camera)
        oldView.disconnect()
        preview = replacement

        // The injected serial queue is the production CameraService queue. This
        // marker runs after start, replacement attachment and old-view detach.
        captureQueue.async { [weak self] in
            let readyAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == cycleGeneration, self.phase == .running else { return }
                self.previewReadyAt = readyAt
            }
        }
    }

    private func receive(_ frame: FrameSample) {
        guard phase == .running, frame.generation == generation, let readyAt = previewReadyAt else { return }
        let now = Self.now
        guard frame.capturedAt.isFinite, frame.capturedAt >= readyAt,
              frame.capturedAt <= now, now - frame.capturedAt < 0.2,
              frame.sequence > lastSequence, frame.capturedAt > lastCapture,
              frame.width > 0, frame.height > 0 else {
            rejectedFrames += 1; return
        }
        lastSequence = frame.sequence; lastCapture = frame.capturedAt
        captureWidth = frame.width; captureHeight = frame.height
        pixelFormat = frame.pixelFormat; captureDrops = frame.drops
        freshFrames += 1
        guard freshFrames >= 3 else { return }
        phase = .stopping
        preview?.disconnect(); preview = nil
        let cycleGeneration = generation
        camera.stop { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.completeCycle(generation: cycleGeneration) }
        }
    }

    private func completeCycle(generation: Int) {
        guard phase == .stopping, self.generation == generation else { return }
        deadline?.invalidate(); deadline = nil
        recordCycle(succeeded: true)
        if cycles.count == requestedCycles { finish(success: true, cameraStopped: true) }
        else { beginCycle() }
    }

    private func fail(_ reason: String) {
        guard phase != .finished, phase != .finishing else { return }
        failure = reason
        deadline?.invalidate(); deadline = nil
        if generation > 0, cycles.last?.generation != generation { recordCycle(succeeded: false) }
        phase = .finishing
        preview?.disconnect(); preview = nil
        // A stuck startRunning must not make a timeout report wait forever for
        // stopRunning queued behind it. Such a report explicitly fails cleanup.
        cleanupDeadline = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(success: false, cameraStopped: false) }
        }
        if let cleanupDeadline { RunLoop.main.add(cleanupDeadline, forMode: .common) }
        camera.stop { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.finish(success: false, cameraStopped: true) }
        }
    }

    private func recordCycle(succeeded: Bool) {
        cycles.append(CycleReport(cycle: generation, generation: generation,
            succeeded: succeeded, freshFrames: freshFrames, rejectedFrames: rejectedFrames,
            elapsedSeconds: max(0, Self.now - cycleStartedAt), width: captureWidth,
            height: captureHeight, pixelFormat: pixelFormat, captureDrops: captureDrops))
    }

    private func finish(success: Bool, cameraStopped: Bool) {
        guard phase != .finished else { return }
        phase = .finished
        deadline?.invalidate(); deadline = nil
        cleanupDeadline?.invalidate(); cleanupDeadline = nil
        let written = writeReport(status: success ? "passed" : "failed", cameraStopped: cameraStopped)
        let callback = completion
        completion = nil
        // CameraService.stop removes its observers. Camera callbacks retain only
        // weak references and are left unchanged while its inference queue drains.
        callback?(success && written)
    }

    private func writeReport(status: String, cameraStopped: Bool) -> Bool {
        let completed = cycles.filter(\.succeeded).count
        let report = Report(status: status,
            success: status == "passed" && completed >= requestedCycles && cameraStopped,
            requestedCycles: requestedCycles, completedCycles: completed,
            elapsedSeconds: max(0, Self.now - runStartedAt), cameraStopped: cameraStopped,
            failure: failure, cycles: cycles)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            return true
        } catch {
            NSLog("AirTouch preview stress report failed: %@", error.localizedDescription)
            return false
        }
    }

    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
