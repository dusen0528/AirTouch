import AppKit
import AVFoundation
import Combine
import AirTouchCore
import Darwin

enum ControlMode: String { case practice, system }

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var engine = GestureEngine()
    @Published private(set) var scene = PracticeScene()
    @Published private(set) var joints: [Joint: Landmark] = [:]
    @Published private(set) var source = "꺼짐"
    @Published private(set) var status = "카메라를 켜거나 데모를 재생해보세요"
    @Published private(set) var isRunning = false
    @Published private(set) var isDemo = false
    @Published private(set) var needsCameraPermission = false
    @Published private(set) var fps = 0.0
    @Published private(set) var latency = 0.0
    @Published private(set) var inferenceTime = 0.0
    @Published private(set) var captureDeliveryTime = 0.0
    @Published private(set) var uiDeliveryTime = 0.0
    @Published private(set) var pinchRatio: Double?
    @Published private(set) var cameraAspectRatio = 16.0 / 9.0
    @Published var mode: ControlMode = .system
    @Published var destination: AppDestination? = .control
    @Published var showSetup = false {
        didSet { if showSetup { destination = .permissions } }
    }
    @Published private(set) var hotKeyReady = false
    @Published private(set) var emergencyTested = false
    @Published private(set) var displays: [ControlDisplay] = []
    @Published var selectedDisplayID: UInt32 = CGMainDisplayID() {
        didSet { if selectedDisplayID != oldValue { stop(message: "제어 화면을 변경했습니다"); UserDefaults.standard.set(Int(selectedDisplayID), forKey: "displayID") } }
    }
    @Published private(set) var systemEventCount = 0
    @Published private(set) var validHandFrameCount = 0
    @Published private(set) var staleFrameCount = 0
    @Published private(set) var physicalHandoffCount = 0
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
    var isSystemControl: Bool { isRunning && systemSession && !isDemo }
    var canStartSystem: Bool { permissions.ready && hotKeyReady && !displays.isEmpty }
    var controlDisplay: ControlDisplay? { displays.first { $0.id == selectedDisplayID } }
    @Published var controlStyle: ControlStyle {
        didSet {
            if controlStyle != oldValue { stop(message: "조작 방식을 변경했습니다") }
            engine.configuration.controlStyle = controlStyle
            UserDefaults.standard.set(controlStyle.rawValue, forKey: "controlStyle")
        }
    }
    @Published var sensitivity: Double {
        didSet { engine.configuration.sensitivity = sensitivity; UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var smoothing: Double {
        didSet { engine.configuration.smoothing = smoothing; UserDefaults.standard.set(smoothing, forKey: "smoothing") }
    }
    @Published var reverseScroll: Bool {
        didSet { engine.configuration.scrollMultiplier = reverseScroll ? -1 : 1; UserDefaults.standard.set(reverseScroll, forKey: "reverseScroll") }
    }
    let camera = CameraService()
    private var watchdog: Timer?
    private var demoTimer: Timer?
    private var demonstration = Demonstration()
    private var demoTime = 0.0
    private var previousFrame: Double?
    private var cameraConnectionStartedAt: Double?
    private var receivedFrames = 0
    private var inferenceLatencies: [Double] = []
    private var transitions: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var localKeys: Any?
    private var reportURL: URL?
    private var handledLaunchArguments = false
    private var terminationSignal: DispatchSourceSignal?

    init() {
        let defaults = UserDefaults.standard
        controlStyle = defaults.string(forKey: "controlStyle").flatMap(ControlStyle.init(rawValue:)) ?? .comfortable
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 1.6
        smoothing = defaults.object(forKey: "smoothing") as? Double ?? 1.5
        reverseScroll = defaults.bool(forKey: "reverseScroll")
        engine.configuration.sensitivity = sensitivity
        engine.configuration.controlStyle = controlStyle
        engine.configuration.smoothing = smoothing
        engine.configuration.scrollMultiplier = reverseScroll ? -1 : 1
        displays = ControlDisplay.current()
        if let saved = defaults.object(forKey: "displayID") as? Int, displays.contains(where: { $0.id == UInt32(saved) }) {
            selectedDisplayID = UInt32(saved)
        }
        if controlDisplay == nil, let display = displays.first { selectedDisplayID = display.id }
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
        systemInput.onFault = { [weak self] generation, message in
            Task { @MainActor in
                guard let self, self.engine.generation == generation, self.isSystemControl else { return }
                self.stop(message: message)
            }
        }
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in self?.physicalInput(event) }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in self?.physicalInput(event); return event }
        emergencyKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isEmergencyKey(event) { self?.emergencyStop() }
        }
        camera.onResult = { [weak self] result in
            DispatchQueue.main.async { self?.receive(result) }
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
                self.apply(self.engine.tick(at: Self.now))
                if let started = self.cameraConnectionStartedAt, self.previousFrame == nil, Self.now - started > 8 {
                    self.stop(message: "카메라 영상이 도착하지 않습니다. 다른 카메라 앱을 닫고 다시 시작해주세요")
                } else if let last = self.previousFrame, Self.now - last > 0.2 {
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
        // A menu-bar app can launch without restoring its window. Diagnostic
        // playback must not depend on ContentView.onAppear being called.
        if args.contains("--demo") {
            DispatchQueue.main.async { [weak self] in self?.handleLaunchArguments() }
        }
    }

    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        if ProcessInfo.processInfo.arguments.contains("--demo") { startDemo() }
        else { showSetup = !UserDefaults.standard.bool(forKey: "setupCompleted.v2") || !permissions.ready }
    }

    func startSelectedMode() { if mode == .system { startSystemControl() } else { startCamera() } }

    func startSystemControl() {
        stop(); permissions.refresh()
        guard canStartSystem, let display = controlDisplay else { showSetup = true; return }
        mode = .system; systemSession = true; isDemo = false; systemEventCount = 0; scene = PracticeScene()
        let location = CGEvent(source: nil)?.location ?? CGPoint(x: display.area.origin.x, y: display.area.origin.y)
        _ = engine.rebase(to: display.area.local(Point(location.x, location.y)), width: display.area.width, height: display.area.height)
        _ = engine.start()
        clearMetrics(); isRunning = true; source = "macOS 전체 제어"
        status = "2초 뒤 시작합니다 · 검지를 펴서 제어하세요"; needsCameraPermission = false
        handoffUntil = Self.now + 2; outputStarted = false
        connectCamera(generation: engine.generation)
    }

    func finishSetup() {
        permissions.refresh()
        guard canStartSystem else { return }
        UserDefaults.standard.set(true, forKey: "setupCompleted.v2")
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
        systemInput.stop(); outputStarted = false
        _ = engine.pause(reason: "마우스에 제어권을 넘겼습니다 · 멈춘 뒤 검지를 펴세요")
        handoffUntil = Self.now + 1.5
    }

    func startCamera() {
        stop()
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
        apply(engine.start()); isRunning = true; isDemo = true; needsCameraPermission = false
        source = "시뮬레이션"; status = "합성 손 좌표로 연습 동작을 재생합니다"
        demonstration = Demonstration(); demoTime = 0
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
        demoTimer?.invalidate(); demoTimer = nil
        systemInput.stop(); outputStarted = false
        apply(engine.stop(reason: message)); camera.stop()
        isRunning = false; joints = [:]; pinchRatio = nil; status = message
        cameraConnectionStartedAt = nil
        fps = 0; latency = 0
        inferenceTime = 0; captureDeliveryTime = 0; uiDeliveryTime = 0
    }

    private func pauseWhenInactive() {
        // Practice has no OS input; preserve camera permission dialogs and the demo.
        guard isRunning, !isDemo, !systemSession, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        apply(engine.stop(reason: "다른 앱으로 이동해 연습을 멈췄습니다"))
        isRunning = false; camera.stop(); joints = [:]
        status = "연습을 다시 시작하려면 카메라 연습을 눌러주세요"
    }

    func resetPractice() {
        stop(message: "기록을 초기화했습니다")
        scene = PracticeScene()
    }

    private func receive(_ result: TrackingResult) {
        guard isRunning, !isDemo, result.generation == engine.generation else { return }
        let now = Self.now
        guard now - result.capturedAt >= 0, now - result.capturedAt < engine.configuration.frameTimeout else {
            staleFrameCount += 1
            status = "영상 처리가 지연되고 있습니다"; return
        }
        joints = result.joints; status = result.message; pinchRatio = result.features?.pinchRatio
        cameraAspectRatio = result.aspectRatio
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
        previousFrame = result.capturedAt; receivedFrames += 1
        if result.features != nil { validHandFrameCount += 1 }
        var trace: [String: Any] = ["sequence": result.sequence, "capturedAt": result.capturedAt,
            "receivedAt": now, "latencyMs": latency, "hands": result.handCount,
            "captureDeliveryMs": captureDeliveryTime, "inferenceMs": inferenceTime, "uiDeliveryMs": uiDeliveryTime,
            "valid": result.features != nil, "stateBefore": engine.state.rawValue,
            "message": result.message, "handoff": systemSession && now < handoffUntil]
        if let hand = result.features {
            trace["features"] = ["indexX": hand.index.x, "indexY": hand.index.y,
                "palmX": hand.palm.x, "palmY": hand.palm.y, "palmScale": hand.palmScale,
                "pinchRatio": hand.pinchRatio, "isPointer": hand.isPointer,
                "isScroll": hand.isScroll, "isOpenPalm": hand.isOpenPalm,
                "isPinchReliable": hand.isPinchReliable,
                "secondaryPinchRatio": hand.secondaryPinchRatio as Any? ?? NSNull()] as [String: Any]
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
        if systemSession {
            guard now >= handoffUntil, let display = controlDisplay else { return }
            if !outputStarted {
                guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
                      !CGEventSource.buttonState(.combinedSessionState, button: .right) else { return }
                let position = CGEvent(source: nil)?.location ?? .zero
                _ = engine.rebase(to: display.area.local(Point(position.x, position.y)), width: display.area.width, height: display.area.height)
                systemInput.begin(generation: engine.generation, area: display.area, position: engine.cursor,
                                  doubleClickInterval: NSEvent.doubleClickInterval)
                outputStarted = true
            }
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

    private func apply(_ intents: [InputIntent]) {
        if systemSession && !isDemo { systemInput.release(intents, generation: engine.generation) }
        else { for intent in intents { scene.apply(intent) } }
    }
    private func recordTransition(_ previous: GestureState) {
        if previous != engine.state {
            transitions.append("\(previous.rawValue) → \(engine.state.rawValue)")
            if transitions.count > 300 { transitions.removeFirst() }
        }
    }
    private func clearMetrics() {
        receivedFrames = 0; previousFrame = nil; inferenceLatencies = []; transitions = []; fps = 0; latency = 0
        validHandFrameCount = 0; staleFrameCount = 0; physicalHandoffCount = 0; frameTrace = []
        activeFrameTrace = []; lastActiveCapture = nil
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

    private func writeReport(to url: URL) throws {
        let sorted = inferenceLatencies.sorted()
        let report: [String: Any] = [
            "schemaVersion": 4, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "source": source == "꺼짐" ? "none" : isDemo ? "synthetic-demo" : "camera",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "frames": receivedFrames, "clicks": scene.clickCount, "drops": scene.dropCount,
            "scrollDistance": scene.scrollDistance, "inputEvents": scene.eventCount,
            "buttonHeld": scene.isPressed, "state": engine.state.rawValue,
            "sensitivity": sensitivity, "minimumCutoff": smoothing, "controlStyle": controlStyle.rawValue,
            "captureToInferenceP95Ms": sorted.isEmpty ? NSNull() : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] as Any,
            "transitions": transitions, "osInputEnabled": systemSession, "systemIntentCount": systemEventCount,
            "cameraPermission": permissions.camera == .authorized, "accessibilityPermission": permissions.accessibility,
            "validHandFrames": validHandFrameCount, "staleFrames": staleFrameCount,
            "physicalHandoffs": physicalHandoffCount, "recentFrames": frameTrace,
            "activeFrames": activeFrameTrace,
            "note": "합성 데모는 카메라 정확도나 실제 OS 제어 검증 결과가 아닙니다. 영상은 저장하지 않습니다."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
