import AppKit
import AVFoundation
import ApplicationServices
import Combine

@MainActor final class PermissionManager: ObservableObject {
    @Published private(set) var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var accessibility = false
    @Published private(set) var postEvents = false
    @Published private(set) var requestingCamera = false
    var onChange: (() -> Void)?
    private var timer: Timer?
    var ready: Bool { camera == .authorized && accessibility && postEvents }
    var cameraDescription: String {
        switch camera {
        case .authorized: return "허용됨"
        case .denied: return "거부됨 · 설정에서 변경해주세요"
        case .restricted: return "관리 정책으로 제한됨"
        default: return requestingCamera ? "권한 창에서 허용을 눌러주세요" : "허용 필요"
        }
    }
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        let newCamera = AVCaptureDevice.authorizationStatus(for: .video)
        let newAX = AXIsProcessTrusted()
        let newPost = CGPreflightPostEventAccess()
        let changed = newCamera != camera || newAX != accessibility || newPost != postEvents
        if changed { camera = newCamera; accessibility = newAX; postEvents = newPost; onChange?() }
    }
    func requestCamera() {
        refresh()
        guard camera == .notDetermined else { if camera != .authorized { openCameraSettings() }; return }
        requestingCamera = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.requestingCamera = false; self?.refresh() }
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
        open("Privacy_Accessibility")
    }
    func openCameraSettings() { open("Privacy_Camera") }
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
