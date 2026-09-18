import AppKit
import AVFoundation
import Combine
import AirTouchCore
import Darwin

enum ControlMode: String { case practice, system }

@MainActor final class AppModel: ObservableObject {
    private(set) var engine = GestureEngine()
    private(set) var scene = PracticeScene()
    private(set) var joints: [Joint: Landmark] = [:]
    @Published private(set) var source = "꺼짐"
    @Published private(set) var status = "카메라를 켜거나 데모를 재생해보세요"
    @Published private(set) var isRunning = false
    @Published private(set) var isDemo = false
    @Published private(set) var needsCameraPermission = false
    private(set) var fps = 0.0
    private(set) var latency = 0.0
    private(set) var inferenceTime = 0.0
    private(set) var captureDeliveryTime = 0.0
    private(set) var uiDeliveryTime = 0.0
    private(set) var pinchRatio: Double?
    private(set) var cameraAspectRatio = 16.0 / 9.0
    @Published var mode: ControlMode = .system
    @Published var destination: AppDestination? = .control
    @Published var showSetup = false {
        didSet { if showSetup { destination = .permissions } }
    }
    @Published private(set) var hotKeyReady = false
    @Published private(set) var emergencyTested = false
    @Published private(set) var displays: [ControlDisplay] = []
    @Published var selectedDisplayID: UInt32 = CGMainDisplayID() {
        didSet { if selectedDisplayID != oldValue { stop(message: "제어 화면을 변경했습니다"); preferences.set(Int(selectedDisplayID), forKey: "displayID") } }
    }
    private(set) var systemEventCount = 0
    private(set) var validHandFrameCount = 0
    private(set) var staleFrameCount = 0
    private(set) var physicalHandoffCount = 0
    var receivedFrameCount: Int { receivedFrames }
    var handRecognitionRate: String {
        receivedFrames == 0 ? "—" : String(format: "%.0f%%", Double(validHandFrameCount) / Double(receivedFrames) * 100)
    }
    var latencyP95Description: String {
        let sorted = inferenceLatencies.sorted()
        return sorted.isEmpty ? "—" : String(format: "%.0f ms", sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }
    private var frameTrace: [[String: Any]] = []
    private var activeFrameTrace: [[String: Any]] = []
    private var lastActiveCapture: Double?
    let permissions = PermissionManager()
    let systemInput = SystemInputDispatcher()
    let emergencyHotKey = EmergencyHotKey()
    private var permissionSubscription: AnyCancellable?
    private var handoffUntil = 0.0
    private var outputStarted = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var emergencyKeyMonitor: Any?
    private var systemSession = false
    var isSystemControl: Bool { isRunning && systemSession && !isDemo && !isPipelineBenchmark }
    var canStartSystem: Bool { permissions.ready && hotKeyReady && !displays.isEmpty }
    var controlDisplay: ControlDisplay? { displays.first { $0.id == selectedDisplayID } }
    @Published var controlStyle: ControlStyle {
        didSet {
            if controlStyle != oldValue { stop(message: "조작 방식을 변경했습니다") }
            engine.configuration.controlStyle = controlStyle
            preferences.set(controlStyle.rawValue, forKey: "controlStyle")
        }
    }
    @Published var sensitivity: Double {
        didSet { engine.configuration.sensitivity = sensitivity; preferences.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var smoothing: Double {
        didSet { engine.configuration.smoothing = smoothing; preferences.set(smoothing, forKey: "smoothing") }
    }
    @Published var reverseScroll: Bool {
        didSet { engine.configuration.scrollMultiplier = reverseScroll ? -1 : 1; preferences.set(reverseScroll, forKey: "reverseScroll") }
    }
    @Published var dragLockEnabled: Bool {
        didSet {
            if dragLockEnabled != oldValue { stop(message: "드래그 방식을 변경했습니다") }
            engine.configuration.dragLockEnabled = dragLockEnabled
            preferences.set(dragLockEnabled, forKey: "dragLockEnabled")
        }
    }
    @Published var showCursorStatus: Bool {
        didSet {
            preferences.set(showCursorStatus, forKey: "showCursorStatus")
            if !showCursorStatus { cursorOverlay.hide() }
        }
    }
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProfile: PersonalCalibrationProfile?
    private(set) var calibration = PersonalCalibrationSession()
    var calibrationSnapshot: PersonalCalibrationSnapshot { calibration.snapshot }
    private lazy var calibrationStore = CalibrationProfileStore(defaults: preferences)
    private let preferences: UserDefaults
    private let cursorOverlay = CursorStatusOverlay()
    private lazy var systemTracking = SystemTrackingController(input: isPipelineBenchmark ? BenchmarkInputSink() : systemInput)
    let camera = CameraService()
    // Input processes every delivered result; diagnostics redraw at 20 Hz.
    private var presentationTimer: Timer?
    private lazy var trackingDelivery = LatestValueDelivery<TrackingResult>(
        schedule: { DispatchQueue.main.async(execute: $0) },
        consume: { [weak self] in self?.receive($0) })
    private var watchdog: Timer?
    private var demoTimer: Timer?
    private var demonstration = Demonstration()
    private var demoTime = 0.0
    private var previousFrame: Double?
    private var previousFrameArrival: Double?
    private var previousValidCapture: Double?
    private var cameraConnectionStartedAt: Double?
    private var receivedFrames = 0
    private var inferenceLatencies: [Double] = []
    private var transitions: [String] = []
    private var interruptionReasons: [String: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var localKeys: Any?
    private var reportURL: URL?
    private var handledLaunchArguments = false
    private var cameraPixelFormat: UInt32 = 0
    private var captureSize = [0, 0]
    private var captureDrops: [String: Int] = [:]
    private var captureConfiguration: [String: String] = [:]
    private var isPipelineBenchmark: Bool { isCameraBenchmark && ProcessInfo.processInfo.arguments.contains("--pipeline-benchmark") }
    private var isCameraBenchmark: Bool { ProcessInfo.processInfo.arguments.contains("--camera-benchmark") }
    private var terminationSignal: DispatchSourceSignal?

    init(preferences: UserDefaults = .standard, runtimeServicesEnabled: Bool = true,
         initialCalibration: PersonalCalibrationSession = PersonalCalibrationSession()) {
        self.preferences = preferences
        calibration = initialCalibration
        isCalibrating = initialCalibration.stage.isCollecting
        let defaults = preferences
        controlStyle = defaults.string(forKey: "controlStyle").flatMap(ControlStyle.init(rawValue:)) ?? .comfortable
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 1.6
        smoothing = defaults.object(forKey: "smoothing") as? Double ?? 1.5
        reverseScroll = defaults.bool(forKey: "reverseScroll")
        dragLockEnabled = defaults.object(forKey: "dragLockEnabled") as? Bool ?? true
        showCursorStatus = defaults.object(forKey: "showCursorStatus") as? Bool ?? true
        engine.configuration.sensitivity = sensitivity
        engine.configuration.controlStyle = controlStyle
        engine.configuration.smoothing = smoothing
        engine.configuration.scrollMultiplier = reverseScroll ? -1 : 1
        engine.configuration.dragLockEnabled = dragLockEnabled
        if let profile = CalibrationProfileStore(defaults: defaults).load() {
            calibrationProfile = profile
            engine.configuration.pinchEnter = profile.pinchEnter
            engine.configuration.pinchExit = profile.pinchExit
            engine.configuration.calibratedDragTolerance = profile.dragTolerance
        }
        displays = ControlDisplay.current()
        if let saved = defaults.object(forKey: "displayID") as? Int, displays.contains(where: { $0.id == UInt32(saved) }) {
            selectedDisplayID = UInt32(saved)
        }
        if controlDisplay == nil, let display = displays.first { selectedDisplayID = display.id }
        guard runtimeServicesEnabled else { return }
        permissionSubscription = permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        permissions.onChange = { [weak self] in
            guard let self else { return }
            if self.isSystemControl && !self.permissions.ready {
                self.stop(message: "권한이 변경되어 전체 제어를 멈췄습니다"); self.showSetup = true
            }
        }
        emergencyHotKey.onPress = { [weak self] in
            self?.emergencyStop()
        }
        hotKeyReady = emergencyHotKey.register()
        // A normal updater/process stop must release owned input before exiting.
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler { [weak self] in
            self?.stop(); NSApp.terminate(nil)
        }
        terminationSignal.resume(); self.terminationSignal = terminationSignal
        systemInput.onInterruption = { [weak self] interruption in
            Task { @MainActor in
                guard let self, self.isSystemControl,
                      let recovered = self.systemTracking.handleInputInterruption(interruption) else { return }
                if recovered.enabled {
                    self.engine = recovered; self.outputStarted = false
                    self.status = recovered.reason
                    self.interruptionReasons["영상 지연 후 자동 복구 대기", default: 0] += 1
                    self.cursorOverlay.hide()
                } else {
                    self.stop(message: recovered.reason)
                }
            }
        }
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in self?.physicalInput(event) }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in self?.physicalInput(event); return event }
        emergencyKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isEmergencyKey(event) { self?.emergencyStop() }
        }
        let trackingDelivery = self.trackingDelivery
        let systemTracking = self.systemTracking
        systemTracking.onProcessed = { [weak self] frame in
            MainActor.assumeIsolated { self?.receive(frame.result, processed: frame) }
        }
        systemTracking.onWatchdogState = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.isSystemControl, self.engine.generation == state.engine.generation else { return }
                self.engine = state.engine
                self.updateSystemCounters(state.statistics)
                self.recordTransition(state.before.state)
            }
        }
        camera.onResult = { result in
            if !systemTracking.submit(result) { trackingDelivery.submit(result) }
        }
        presentationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Timer is installed on the main run loop, like the camera watchdog.
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.cursorOverlay.update(engine: self.engine, handoff: Self.now < self.handoffUntil,
                    trackingFresh: self.previousValidCapture.map { Self.now - $0 < 0.2 } ?? false,
                    visible: self.showCursorStatus && self.isSystemControl)
                self.objectWillChange.send()
            }
        }
        camera.onStatus = { [weak self] generation, message, failed in
            DispatchQueue.main.async {
                guard let self, generation == self.engine.generation, self.isRunning, !self.isDemo else { return }
                if failed { self.stop(message: message) } else { self.status = message }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isDemo else { return }
                if self.isCalibrating {
                    self.calibration.tick(at: Self.now)
                    self.checkCalibrationCompletion()
                    return
                }
                if !self.systemSession {
                    let previous = self.engine.state
                    self.apply(self.engine.tick(at: Self.now))
                    self.recordTransition(previous)
                }
                if let started = self.cameraConnectionStartedAt, self.previousFrame == nil, Self.now - started > 8 {
                    self.stop(message: "카메라 영상이 도착하지 않습니다. 다른 카메라 앱을 닫고 다시 시작해주세요")
                } else if let last = self.previousFrameArrival, Self.now - last > 0.2 {
                    self.fps = 0; self.joints = [:]; self.status = "영상이 지연되어 입력을 멈췄습니다"
                }
            }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isEmergencyKey(event) { self?.emergencyStop(); return nil }
            if event.keyCode == 53, self?.isRunning == true { self?.stop(); return nil }
            return event
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(message: "잠자기 전 연습을 멈췄습니다") } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(message: "사용자 세션이 잠겨 제어를 멈췄습니다") } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stop(message: "화면 구성이 바뀌어 제어를 멈췄습니다")
                self.displays = ControlDisplay.current()
                if self.controlDisplay == nil, let first = self.displays.first { self.selectedDisplayID = first.id }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.permissions.refresh() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.pauseWhenInactive() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(message: "화면이 잠들어 전체 제어를 멈췄습니다") } })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop(message: "화면이 잠겨 전체 제어를 멈췄습니다") } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == "practice" || window.title == "AirTouch · 손동작 연습실" else { return }
            Task { @MainActor in if self?.isSystemControl != true { self?.stop(message: "창을 닫아 카메라를 껐습니다") } }
        })
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--demo-report"), flag + 1 < args.count {
            reportURL = URL(fileURLWithPath: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "--camera-benchmark-report"), flag + 1 < args.count {
            reportURL = URL(fileURLWithPath: args[flag + 1])
        }
        // The application delegate handles all launch modes once, including
        // diagnostics, without depending on a control window being visible.
    }

    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        if isCameraBenchmark { startCameraBenchmark() }
        else if ProcessInfo.processInfo.arguments.contains("--demo") { startDemo() }
        else { showSetup = !preferences.bool(forKey: "setupCompleted.v2") || !permissions.ready }
    }

    func startSelectedMode() { if mode == .system { startSystemControl() } else { startCamera() } }

    func startSystemControl() {
        stop(); permissions.refresh()
        guard canStartSystem, let display = controlDisplay else { showSetup = true; return }
        engine.configuration.dragLockEnabled = dragLockEnabled
        mode = .system; systemSession = true; isDemo = false; systemEventCount = 0; scene = PracticeScene()
        let location = CGEvent(source: nil)?.location ?? CGPoint(x: display.area.origin.x, y: display.area.origin.y)
        _ = engine.rebase(to: display.area.local(Point(location.x, location.y)), width: display.area.width, height: display.area.height)
        _ = engine.start()
        clearMetrics(); isRunning = true; source = "macOS 전체 제어"
        status = "2초 뒤 시작합니다 · 검지를 펴서 제어하세요"; needsCameraPermission = false
        handoffUntil = Self.now + 2; outputStarted = false
        engine = systemTracking.start(engine: engine, display: display, handoffUntil: handoffUntil,
                                      doubleClickInterval: NSEvent.doubleClickInterval)
        connectCamera(generation: engine.generation)
    }

    func finishSetup() {
        permissions.refresh()
        guard canStartSystem else { return }
        preferences.set(true, forKey: "setupCompleted.v2")
        showSetup = false; mode = .system; destination = .control
    }

    func retryHotKey() { emergencyTested = false; hotKeyReady = emergencyHotKey.register() }

    private static func isEmergencyKey(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option, .command]
    }

    private func emergencyStop() {
        systemInput.stop(); emergencyTested = true
        stop(message: "전역 단축키로 전체 제어를 중지했습니다")
    }

    func installApp() {
        stop(); emergencyHotKey.unregister(); hotKeyReady = false
        AppInstallation.installAndRelaunch { [weak self] error in
            if let error { self?.status = error; self?.retryHotKey() }
        }
    }

    private func physicalInput(_ event: NSEvent) {
        guard isSystemControl, let cg = event.cgEvent,
              cg.getIntegerValueField(.eventSourceUserData) != SystemInputDispatcher.eventTag else { return }
        if outputStarted { physicalHandoffCount += 1 }
        // Do not let our own control window's launch click start a competing session.
        handoffUntil = Self.now + 1.5
        engine = systemTracking.pause(until: handoffUntil, reason: "마우스에 제어권을 넘겼습니다 · 멈춘 뒤 검지를 펴세요")
        outputStarted = false
    }

    func openCalibration() {
        stop(message: "내 손에 맞추기")
        calibration.reset()
        destination = .calibration
    }

    func startCalibration() {
        startCamera()
        guard isRunning else { return }
        calibration.start(at: Self.now, date: Date())
        isCalibrating = true; destination = .calibration
        status = "안내에 따라 손을 움직여주세요"
    }

    func cancelCalibration() {
        stop(message: "손 보정을 취소했습니다")
        destination = .calibration
    }

    private func checkCalibrationCompletion() {
        guard isCalibrating, !calibration.stage.isCollecting else { return }
        isCalibrating = false
        stop(message: calibration.stage == .completed ? "보정이 끝났습니다. 결과를 확인하고 적용하세요" : "보정을 다시 진행해주세요")
    }

    func applyCalibration() {
        guard calibration.stage == .completed, let profile = calibration.profile,
              calibrationStore.save(profile) else { return }
        stop(message: "내 손에 맞는 보정을 적용했습니다")
        controlStyle = .comfortable; sensitivity = profile.sensitivity; smoothing = profile.minimumCutoff
        engine.configuration.pinchEnter = profile.pinchEnter
        engine.configuration.pinchExit = profile.pinchExit
        engine.configuration.calibratedDragTolerance = profile.dragTolerance
        calibrationProfile = profile; destination = .control; mode = .system
    }

    func resetCalibration() {
        stop(message: "손 보정을 초기화했습니다")
        calibrationStore.clear()
        calibrationProfile = nil; calibration.reset()
        let defaults = GestureConfiguration()
        sensitivity = defaults.sensitivity; smoothing = defaults.smoothing
        engine.configuration.pinchEnter = defaults.pinchEnter
        engine.configuration.pinchExit = defaults.pinchExit
        engine.configuration.calibratedDragTolerance = nil
    }

    func startCamera() {
        stop()
        engine.configuration.dragLockEnabled = dragLockEnabled
        mode = .practice; systemSession = false
        _ = engine.rebase(to: Point(380, 220), width: 760, height: 440)
        scene = PracticeScene() // Never count synthetic-demo successes as camera results.
        apply(engine.start()); isRunning = true; isDemo = false
        source = "내장 카메라"; status = "카메라 연결 준비 중"; needsCameraPermission = false
        clearMetrics()
        let generation = engine.generation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: connectCamera(generation: generation)
        case .notDetermined:
            status = "macOS의 카메라 사용 요청을 확인해주세요"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.engine.generation == generation, self.isRunning else { return }
                    if granted { self.connectCamera(generation: generation) }
                    else { self.cameraDenied() }
                }
            }
        default: cameraDenied()
        }
    }

    private func connectCamera(generation: Int) {
        cameraConnectionStartedAt = Self.now
        camera.start(generation: generation)
    }

    private func cameraDenied() {
        stop(message: "시스템 설정에서 AirTouch의 카메라 접근을 허용해주세요")
        needsCameraPermission = true
    }

    func openCameraSettings() {
        permissions.openCameraSettings()
    }

    func startDemo() {
        stop(); resetPractice(); clearMetrics()
        mode = .practice; destination = .practice; systemSession = false; showSetup = false
        _ = engine.rebase(to: Point(380, 220), width: 760, height: 440)
        engine.configuration.dragLockEnabled = dragLockEnabled
        apply(engine.start()); isRunning = true; isDemo = true; needsCameraPermission = false
        source = "시뮬레이션"; status = "합성 손 좌표로 연습 동작을 재생합니다"
        demonstration = Demonstration(dragLock: dragLockEnabled); demoTime = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepDemo() }
        }
    }

    private func stepDemo() {
        guard isRunning, isDemo else { return }
        guard !demonstration.isFinished else {
            demoTimer?.invalidate(); demoTimer = nil
            apply(engine.stop(reason: "데모 완료")); isRunning = false
            status = "데모 완료 · 실제 손 인식은 카메라 연습에서 확인하세요"
            if let reportURL { try? writeReport(to: reportURL) }
            return
        }
        let hand = demonstration.next(cursor: engine.cursor, scene: scene, sensitivity: sensitivity)
        demoTime += 1.0 / 30
        let previous = engine.state
        apply(engine.process(hand, sequence: demonstration.frame, generation: engine.generation,
                             capturedAt: demoTime, now: demoTime))
        recordTransition(previous)
        pinchRatio = hand.pinchRatio; receivedFrames += 1
    }

    func stop(message: String = "제어가 멈췄습니다") {
        cursorOverlay.hide()
        if isCalibrating { calibration.cancel(); isCalibrating = false }
        demoTimer?.invalidate(); demoTimer = nil
        let stopped = systemTracking.stop(reason: message)
        outputStarted = false
        if systemSession && !isDemo {
            // Settings may have changed after a prior stop. A worker snapshot
            // supplies state, never stale configuration for the next session.
            let configuration = engine.configuration
            engine = stopped; engine.configuration = configuration
        } else { apply(engine.stop(reason: message)) }
        camera.stop()
        isRunning = false; joints = [:]; pinchRatio = nil; status = message
        cameraConnectionStartedAt = nil
        fps = 0; latency = 0
        inferenceTime = 0; captureDeliveryTime = 0; uiDeliveryTime = 0
    }

    private func pauseWhenInactive() {
        // Practice has no OS input; preserve camera permission dialogs and the demo.
        guard isRunning, !isDemo, !isCameraBenchmark, !systemSession, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        stop(message: isCalibrating ? "다른 앱으로 이동해 손 보정을 취소했습니다" : "다른 앱으로 이동해 연습을 멈췄습니다")
    }

    func resetPractice() {
        stop(message: "기록을 초기화했습니다")
        scene = PracticeScene()
    }

    private func receive(_ result: TrackingResult, processed: ProcessedTrackingFrame? = nil) {
        guard isRunning, !isDemo, result.generation == engine.generation else { return }
        let now = Self.now
        if let processed { updateSystemCounters(processed.statistics) }
        guard processed?.accepted ?? (now - result.capturedAt >= 0 && now - result.capturedAt < engine.configuration.frameTimeout) else {
            if processed == nil { staleFrameCount += 1 }
            status = "영상 처리가 지연되고 있습니다"; return
        }
        if systemSession, processed == nil { return }
        let previousState = processed?.before.state ?? engine.state
        if let processed { engine = processed.engine; outputStarted = processed.outputStarted }
        joints = result.joints; pinchRatio = result.features?.pinchRatio
        if status != result.message { status = result.message }
        cameraAspectRatio = result.aspectRatio
        cameraPixelFormat = result.pixelFormat
        captureSize = [result.captureWidth, result.captureHeight]; captureDrops = result.captureDrops
        captureConfiguration = result.captureConfiguration
        latency = max(0, (result.completedAt - result.capturedAt) * 1000)
        inferenceTime = max(0, (result.completedAt - result.deliveredAt) * 1000)
        captureDeliveryTime = max(0, (result.deliveredAt - result.capturedAt) * 1000)
        uiDeliveryTime = max(0, (now - result.completedAt) * 1000)
        inferenceLatencies.append(latency)
        if inferenceLatencies.count > 1800 { inferenceLatencies.removeFirst() }
        if let previousFrame, result.capturedAt > previousFrame {
            let current = 1 / (result.capturedAt - previousFrame)
            fps = fps == 0 ? current : fps * 0.85 + current * 0.15
        }
        previousFrame = result.capturedAt; previousFrameArrival = now; receivedFrames += 1
        if result.features != nil { validHandFrameCount += 1; previousValidCapture = result.capturedAt }
        // Calibration keeps aggregate settings only; its samples must never
        // enter the general-purpose hand-coordinate diagnostic trace.
        if isCalibrating {
            let required: [Joint] = calibration.stage == .pinch
                ? [.wrist, .indexMCP, .indexPIP, .middleMCP, .indexTip, .thumbTip]
                : [.wrist, .indexMCP, .indexPIP, .middleMCP, .indexTip]
            let qualified = required.allSatisfy { (result.joints[$0]?.confidence ?? 0) >= 0.5 }
            calibration.update(result.features, capturedAt: result.capturedAt, now: now, confidenceQualified: qualified)
            checkCalibrationCompletion()
            return
        }
        var trace: [String: Any] = ["sequence": result.sequence, "capturedAt": result.capturedAt,
            "receivedAt": now, "latencyMs": latency, "hands": result.handCount,
            "captureDeliveryMs": captureDeliveryTime, "inferenceMs": inferenceTime, "uiDeliveryMs": uiDeliveryTime,
            "valid": result.features != nil, "stateBefore": previousState.rawValue,
            "message": result.message, "handoff": processed?.handoff ?? (systemSession && now < handoffUntil)]
        if let processed {
            trace["gestureQueueMs"] = (processed.processingStartedAt - result.completedAt) * 1000
            trace["gestureProcessingMs"] = (processed.processingCompletedAt - processed.processingStartedAt) * 1000
            if let submitted = processed.inputSubmittedAt { trace["captureToInputSubmissionMs"] = (submitted - result.capturedAt) * 1000 }
        }
        if let hand = result.features {
            trace["features"] = ["indexX": hand.index.x, "indexY": hand.index.y,
                "palmX": hand.palm.x, "palmY": hand.palm.y, "palmScale": hand.palmScale,
                "pinchRatio": hand.pinchRatio, "isPointer": hand.isPointer,
                "isScroll": hand.isScroll, "isOpenPalm": hand.isOpenPalm,
                "isPinchReliable": hand.isPinchReliable,
                "secondaryPinchRatio": hand.secondaryPinchRatio as Any? ?? NSNull()] as [String: Any]
            trace["landmarks"] = Dictionary(uniqueKeysWithValues: result.joints.map { joint, landmark in
                (joint.rawValue, ["x": landmark.point.x, "y": landmark.point.y, "confidence": landmark.confidence])
            })
        }
        defer {
            trace["stateAfter"] = engine.state.rawValue
            trace["reason"] = engine.reason
            frameTrace.append(trace)
            if frameTrace.count > 600 { frameTrace.removeFirst() }
            if result.features != nil { lastActiveCapture = result.capturedAt }
            if let lastActiveCapture, result.capturedAt - lastActiveCapture < 1 {
                activeFrameTrace.append(trace)
                if activeFrameTrace.count > 1800 { activeFrameTrace.removeFirst() }
            }
        }
        if let processed {
            updateSystemCounters(processed.statistics)
            recordTransition(processed.before.state)
            return
        }
        let previous = engine.state
        let actions = engine.process(result.features, sequence: result.sequence, generation: result.generation,
                                     capturedAt: result.capturedAt, now: now)
        if systemSession {
            systemInput.frame(generation: result.generation, capturedAt: result.capturedAt,
                              validHand: result.features != nil, intents: actions)
            systemEventCount += actions.count
        } else { apply(actions) }
        recordTransition(previous)
    }

    private func updateSystemCounters(_ stats: SystemTrackingStatistics) {
        receivedFrames = stats.acceptedFrames
        validHandFrameCount = stats.validFrames
        staleFrameCount = stats.staleFrames
        systemEventCount = stats.intentCount
    }

    private func apply(_ intents: [InputIntent]) {
        if systemSession && !isDemo { systemInput.release(intents, generation: engine.generation) }
        else { for intent in intents { scene.apply(intent) } }
    }
    private func recordTransition(_ previous: GestureState) {
        if previous != engine.state {
            transitions.append("\(previous.rawValue) → \(engine.state.rawValue)")
            if transitions.count > 300 { transitions.removeFirst() }
            if engine.state == .suspended { interruptionReasons[engine.reason, default: 0] += 1 }
        }
    }
    private func clearMetrics() {
        trackingDelivery.resetStatistics()
        receivedFrames = 0; previousFrame = nil; previousFrameArrival = nil; previousValidCapture = nil; inferenceLatencies = []; transitions = []; fps = 0; latency = 0
        interruptionReasons = [:]
        validHandFrameCount = 0; staleFrameCount = 0; physicalHandoffCount = 0; frameTrace = []
        activeFrameTrace = []; lastActiveCapture = nil
        captureSize = [0, 0]; captureDrops = [:]; captureConfiguration = [:]; cameraPixelFormat = 0
        inferenceTime = 0; captureDeliveryTime = 0; uiDeliveryTime = 0
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "airtouch-session.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try writeReport(to: url); status = "세션 기록을 저장했습니다" }
            catch { status = "저장 실패: \(error.localizedDescription)" }
        }
    }

    /// Development measurement: real camera + Vision, no OS input, aggregate
    /// timings only. It never saves images or the user's hand coordinates.
    private func startCameraBenchmark() {
        guard let url = reportURL else { status = "카메라 측정 기록 경로를 지정해주세요"; return }
        startCamera()
        if isPipelineBenchmark, let display = controlDisplay {
            systemSession = true; handoffUntil = 0
            engine = systemTracking.start(engine: engine, display: display, handoffUntil: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let rows = self.frameTrace.filter { ($0["sequence"] as? Int ?? 0) > 60 }
            func stats(_ values: [Double]) -> [String: Double] {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return [:] }
                return ["median": sorted[sorted.count / 2], "p95": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
            }
            let format = String(bytes: (0..<4).reversed().map { UInt8((self.cameraPixelFormat >> ($0 * 8)) & 0xff) }, encoding: .ascii) ?? "unknown"
            let processing = self.isPipelineBenchmark ? self.systemTracking.statistics : nil
            func timing(_ value: TrackingLatencyStatistics?) -> Any {
                guard let value else { return NSNull() }
                return ["sampleCount": value.sampleCount, "median": value.median, "p95": value.p95, "maximum": value.maximum] as [String: Any]
            }
            let report: [String: Any] = [
                "pipelineBenchmark": self.isPipelineBenchmark,
                "captureToInputSubmissionMs": timing(processing?.captureToSubmissionMs),
                "inferenceToInputSubmissionMs": timing(processing?.inferenceToSubmissionMs),
                "gestureProcessingMs": timing(processing?.processingMs),
                "processedFrames": processing?.acceptedFrames as Any? ?? NSNull(),
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "pixelFormat": format, "measuredFrames": rows.count, "coalescedFrames": self.trackingDelivery.replacedCount, "osInputEnabled": false,
                "cameraRunningAtEnd": self.isRunning, "status": self.status,
                "captureSize": self.captureSize, "captureDrops": self.captureDrops,
                "captureConfiguration": self.captureConfiguration,
                "captureDeliveryMs": stats(rows.compactMap { $0["captureDeliveryMs"] as? Double }),
                "inferenceMs": stats(rows.compactMap { $0["inferenceMs"] as? Double }),
                "uiDeliveryMs": stats(rows.compactMap { $0["uiDeliveryMs"] as? Double }),
                "captureToReceiptMs": stats(rows.compactMap { row in
                    guard let capture = row["capturedAt"] as? Double, let receive = row["receivedAt"] as? Double else { return nil }
                    return (receive - capture) * 1000
                })
            ]
            self.stop(message: "카메라 지연 측정을 마쳤습니다")
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
            catch { self.status = "측정 기록 저장 실패: \(error.localizedDescription)" }
        }
    }

    private func writeReport(to url: URL) throws {
        let sorted = inferenceLatencies.sorted()
        let report: [String: Any] = [
            "schemaVersion": 6, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "source": source == "꺼짐" ? "none" : isDemo ? "synthetic-demo" : "camera",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "frames": receivedFrames, "clicks": scene.clickCount, "drops": scene.dropCount,
            "scrollDistance": scene.scrollDistance, "inputEvents": scene.eventCount,
            "buttonHeld": systemSession ? engine.isButtonHeld : scene.isPressed, "state": engine.state.rawValue,
            "isRunning": isRunning, "status": status, "engineReason": engine.reason,
            "sensitivity": sensitivity, "minimumCutoff": smoothing, "controlStyle": controlStyle.rawValue,
            "dragLockEnabled": dragLockEnabled, "showCursorStatus": showCursorStatus,
            "personalCalibrationApplied": calibrationProfile != nil,
            "captureSize": captureSize, "captureDrops": captureDrops, "captureConfiguration": captureConfiguration,
            "captureToInferenceP95Ms": sorted.isEmpty ? NSNull() : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] as Any,
            "transitions": transitions, "interruptionReasons": interruptionReasons, "osInputEnabled": systemSession, "systemIntentCount": systemEventCount,
            "cameraPermission": permissions.camera == .authorized, "accessibilityPermission": permissions.accessibility,
            "validHandFrames": validHandFrameCount, "staleFrames": staleFrameCount,
            "coalescedFrames": systemSession ? systemTracking.replacedFrameCount : trackingDelivery.replacedCount,
            "traceDelivery": systemSession ? "presentation-snapshots" : "received-frames",
            "physicalHandoffs": physicalHandoffCount, "recentFrames": frameTrace,
            "activeFrames": activeFrameTrace,
            "note": "합성 데모는 카메라 정확도나 실제 OS 제어 검증 결과가 아닙니다. 영상은 저장하지 않습니다."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
