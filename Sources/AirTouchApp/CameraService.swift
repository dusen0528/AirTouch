import AVFoundation
import Vision
import AirTouchCore

struct TrackingResult {
    let generation: Int
    let sequence: Int
    let capturedAt: Double
    let deliveredAt: Double
    let completedAt: Double
    let aspectRatio: Double
    let joints: [AirTouchCore.Joint: Landmark]
    let features: HandFeatures?
    let handCount: Int
    let message: String
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
            self.inferenceQueue.sync { self.generation = generation; self.sequence = 0 }
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
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else {
            throw NSError(domain: "AirTouch", code: 2, userInfo: [NSLocalizedDescriptionKey: "카메라 입력을 연결하지 못했습니다"])
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: inferenceQueue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw NSError(domain: "AirTouch", code: 3, userInfo: [NSLocalizedDescriptionKey: "영상 출력을 연결하지 못했습니다"])
        }
        session.addOutput(output)
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
                aspectRatio: width / height,
                joints: joints, features: features, handCount: hands.count, message: message))
        } catch {
            onResult?(TrackingResult(generation: generation, sequence: sequence, capturedAt: timestamp,
                deliveredAt: deliveredAt,
                completedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                aspectRatio: width / height,
                joints: [:], features: nil, handCount: 0, message: "손 인식 실패: \(error.localizedDescription)"))
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
