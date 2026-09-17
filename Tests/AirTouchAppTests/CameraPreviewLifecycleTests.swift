import AppKit
import SwiftUI
import XCTest
@testable import AirTouchApp

/// Recreates the preview attachment from the crash stack in an unshown view.
/// No camera access or desktop interaction is needed to test session ownership.
final class CameraPreviewLifecycleTests: XCTestCase {
    func testReplacingPreviewDetachesOnlyTheOldViewAndEventuallyCleansUp() async {
        let queue = DispatchQueue(label: "airtouch.test.preview-replacement")
        let camera = CameraService(sessionQueue: queue)
        let (old, replacement) = await MainActor.run {
            let old = PreviewHost(frame: .zero)
            let replacement = PreviewHost(frame: .zero)
            old.connect(to: camera)
            replacement.connect(to: camera)
            old.disconnect()
            return (old, replacement)
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await MainActor.run {
            XCTAssertNil(old.preview.session)
            XCTAssertTrue(replacement.preview.session === camera.session)
            old.disconnect()
            replacement.disconnect()
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await MainActor.run { XCTAssertNil(replacement.preview.session) }
    }

    func testPreviewTeardownWaitsForSessionWorkToFinish() async {
        let queue = DispatchQueue(label: "airtouch.test.preview-teardown")
        let camera = CameraService(sessionQueue: queue)
        let host = await MainActor.run {
            let host = PreviewHost(frame: .zero)
            host.connect(to: camera)
            return host
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let occupied = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async { occupied.signal(); _ = release.wait(timeout: .now() + 5) }
        XCTAssertEqual(occupied.wait(timeout: .now() + 1), .success)
        await MainActor.run {
            host.disconnect()
            XCTAssertTrue(host.preview.session === camera.session)
        }
        release.signal()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await MainActor.run { XCTAssertNil(host.preview.session) }
    }

    func testPreviewAttachmentWaitsForInFlightSessionWork() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let queue = DispatchQueue(label: "airtouch.test.capture-owner")
            let occupied = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            queue.async {
                occupied.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            XCTAssertEqual(occupied.wait(timeout: .now() + 1), .success)
            defer { release.signal() }
            let camera = CameraService(sessionQueue: queue)
            let hosting = NSHostingView(rootView: CameraPreview(camera: camera))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            func preview(in view: NSView) -> PreviewHost? {
                (view as? PreviewHost) ?? view.subviews.lazy.compactMap { preview(in: $0) }.first
            }
            let host = try XCTUnwrap(preview(in: hosting))
            XCTAssertFalse(window.isVisible)
            XCTAssertNil(host.preview.session,
                "Preview must not mutate the session graph while capture start/stop work owns its queue")
        }
    }
}
