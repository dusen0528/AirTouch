import AVFoundation
import Vision
import AirTouchCore

struct TrackingResult: Sendable {
    let generation: Int
    let sequence: Int
    let capturedAt: Double
    let deliveredAt: Double
    let completedAt: Double
    let aspectRatio: Double
    let pixelFormat: UInt32
    let joints: [AirTouchCore.Joint: Landmark]
    let features: HandFeatures?
    let handCount: Int
    let message: String
    // Actual buffer dimensions and cumulative drop counts, for comparisons that
    // do not need to retain camera frames or hand landmarks.
    var captureWidth: Int = 0
    var captureHeight: Int = 0
    var captureDrops: [String: Int] = [:]
}

/// Session and inference each have a serial queue. Late capture frames are dropped.
/// Callbacks are immutable and carry a generation; consumers reject previous sessions.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onResult: ((TrackingResult) -> Void)?
    var onStatus: ((Int, String, Bool) -> Void)?
    private let sessionQueue = DispatchQueue(label: "airtouch.capture-session")
    private let inferenceQueue = DispatchQueue(label: "airtouch.inference", qos: .userInitiated)
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let output = AVCaptureVideoDataOutput()
    private var generation = 0 // Accessed only on inferenceQueue.
    private var sequence = 0
    private var captureDrops: [String: Int] = [:] // Accessed only on inferenceQueue.
    private var configured = false // Accessed only on sessionQueue.
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        handRequest.maximumHandCount = 2
    }

    func start(generation: Int) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.inferenceQueue.sync {
                self.generation = generation
                self.sequence = 0
                self.captureDrops.removeAll(keepingCapacity: true)
            }
            do {
                if !self.configured { try self.configure() }
                self.observeSession(generation: generation)
                self.session.startRunning()
                self.onStatus?(generation, self.session.isRunning ? "카메라 연결됨" : "카메라를 시작하지 못했습니다", !self.session.isRunning)
            } catch {
                self.onStatus?(generation, error.localizedDescription, true)
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.observers.forEach(NotificationCenter.default.removeObserver)
            self.observers.removeAll()
            self.session.stopRunning()
        }
    }

    private func observeSession(generation: Int) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.onStatus?(generation, "카메라가 중단되었습니다. 다시 시작해주세요", true)
            }
        }
    }

    private func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let camera = discovery.devices.first else {
            throw NSError(domain: "AirTouch", code: 1, userInfo: [NSLocalizedDescriptionKey: "MacBook 내장 카메라를 찾지 못했습니다"])
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer {
            if !configured {
                session.outputs.forEach(session.removeOutput)
                session.inputs.forEach(session.removeInput)
            }
            session.commitConfiguration()
        }
        // Keep the recognition resolution unchanged until both timing and hand
        // accuracy are measured. This diagnostic flag permits like-for-like
        // 480p/720p comparisons using the actual capture buffers.
        let requestedPreset: AVCaptureSession.Preset = ProcessInfo.processInfo.arguments.contains("--camera-480p")
            ? .vga640x480 : .hd1280x720
        if session.canSetSessionPreset(requestedPreset) {
            session.sessionPreset = requestedPreset
        } else if requestedPreset == .vga640x480 {
            throw NSError(domain: "AirTouch", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "이 카메라는 640×480 비교 측정을 지원하지 않습니다"])
        }
        guard session.canAddInput(input) else {
            throw NSError(domain: "AirTouch", code: 2, userInfo: [NSLocalizedDescriptionKey: "카메라 입력을 연결하지 못했습니다"])
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: inferenceQueue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw NSError(domain: "AirTouch", code: 3, userInfo: [NSLocalizedDescriptionKey: "영상 출력을 연결하지 못했습니다"])
        }
        session.addOutput(output)
        // Vision accepts bi-planar camera buffers. Avoid an unnecessary BGRA
        // conversion when native video-range YCbCr is available (Apple TN3121).
        let requestedFormat = ProcessInfo.processInfo.arguments.contains("--camera-bgra")
            ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pixelFormat = output.availableVideoPixelFormatTypes.contains(requestedFormat)
            ? requestedFormat : kCVPixelFormatType_32BGRA
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Vision creates Objective-C temporaries every frame. Bound their
        // lifetime to this callback instead of the long-lived inference queue.
        autoreleasepool { process(sampleBuffer) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // TN2445: a discontinuity can represent an unknown number of lost
        // frames, so these values count callbacks/reasons, not guessed frames.
        let attachment = CMGetAttachment(sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        let reason: String
        if attachment == kCMSampleBufferDroppedFrameReason_FrameWasLate as String {
            reason = "late"
        } else if attachment == kCMSampleBufferDroppedFrameReason_OutOfBuffers as String {
            reason = "outOfBuffers"
        } else if attachment == kCMSampleBufferDroppedFrameReason_Discontinuity as String {
            reason = "discontinuity"
        } else {
            reason = "unknown"
        }
        captureDrops[reason, default: 0] += 1
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Capture timestamps use the host clock, as does the controller watchdog.
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let deliveredAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        sequence += 1
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([handRequest])
            let hands = handRequest.results ?? []
            var joints: [AirTouchCore.Joint: Landmark] = [:]
            if hands.count == 1, let hand = hands.first {
                for (joint, visionJoint) in Self.jointMap {
                    if let p = try? hand.recognizedPoint(visionJoint) {
                        joints[joint] = Landmark(Point(1 - p.location.x, 1 - p.location.y), confidence: Double(p.confidence))
                    }
                }
            }
            let features = hands.count == 1 ? FeatureExtractor.extract(joints, width: width, height: height) : nil
            let message: String
            if hands.isEmpty { message = "손을 카메라에 보여주세요" }
            else if hands.count > 1 { message = "한 손만 보여주세요" }
            else if features == nil { message = "검지와 손바닥이 보이도록 손을 카메라 가까이 들어주세요" }
            else if features?.isPinchReliable == false { message = "커서 추적 중 · 클릭하려면 엄지를 보여주세요" }
            else { message = "손 인식 중" }
            onResult?(TrackingResult(generation: generation, sequence: sequence, capturedAt: timestamp,
                deliveredAt: deliveredAt,
                completedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                aspectRatio: width / height, pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                joints: joints, features: features, handCount: hands.count, message: message,
                captureWidth: Int(width), captureHeight: Int(height), captureDrops: captureDrops))
        } catch {
            onResult?(TrackingResult(generation: generation, sequence: sequence, capturedAt: timestamp,
                deliveredAt: deliveredAt,
                completedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                aspectRatio: width / height, pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                joints: [:], features: nil, handCount: 0, message: "손 인식 실패: \(error.localizedDescription)",
                captureWidth: Int(width), captureHeight: Int(height), captureDrops: captureDrops))
        }
    }

    private static let jointMap: [(AirTouchCore.Joint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist), (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
    ]
}
