import AppKit
import SwiftUI
import XCTest
@testable import AirTouchApp
import AirTouchCore

/// Renders this app's own SwiftUI tree into an image. It never shows a window,
/// captures the desktop, starts the camera, or simulates user input.
final class CalibrationViewRenderingTests: XCTestCase {
    func testAppModelAppliesReloadsAndResetsCompletedCalibration() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let suite = "AirTouch.CalibrationApplyTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let completed = try completedSession()
            let profile = try XCTUnwrap(completed.profile)
            let model = AppModel(preferences: defaults, runtimeServicesEnabled: false,
                initialCalibration: completed)
            XCTAssertNil(model.calibrationProfile, "Completion still requires the user's Apply action")
            model.applyCalibration()
            XCTAssertEqual(model.calibrationProfile, profile)
            XCTAssertEqual(model.sensitivity, profile.sensitivity)
            XCTAssertEqual(model.smoothing, profile.minimumCutoff)
            XCTAssertEqual(model.engine.configuration.pinchEnter, profile.pinchEnter)
            XCTAssertEqual(model.engine.configuration.pinchExit, profile.pinchExit)
            XCTAssertEqual(model.engine.configuration.calibratedDragTolerance, profile.dragTolerance)
            XCTAssertEqual(model.controlStyle, .comfortable)
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.camera.session.isRunning)

            let reloaded = AppModel(preferences: defaults, runtimeServicesEnabled: false)
            XCTAssertEqual(reloaded.calibrationProfile, profile)
            XCTAssertEqual(reloaded.sensitivity, profile.sensitivity)
            XCTAssertEqual(reloaded.smoothing, profile.minimumCutoff)
            XCTAssertEqual(reloaded.engine.configuration.pinchEnter, profile.pinchEnter)
            XCTAssertEqual(reloaded.engine.configuration.pinchExit, profile.pinchExit)
            XCTAssertEqual(reloaded.engine.configuration.calibratedDragTolerance, profile.dragTolerance)
            reloaded.resetCalibration()
            XCTAssertNil(reloaded.calibrationProfile)
            XCTAssertNil(CalibrationProfileStore(defaults: defaults).load())
            XCTAssertEqual(reloaded.engine.configuration.pinchEnter, GestureConfiguration().pinchEnter)
            XCTAssertEqual(reloaded.engine.configuration.pinchExit, GestureConfiguration().pinchExit)
            XCTAssertNil(reloaded.engine.configuration.calibratedDragTolerance)
            XCTAssertEqual(reloaded.sensitivity, GestureConfiguration().sensitivity)
            XCTAssertEqual(reloaded.smoothing, GestureConfiguration().smoothing)
            let afterReset = AppModel(preferences: defaults, runtimeServicesEnabled: false)
            XCTAssertNil(afterReset.calibrationProfile)
            XCTAssertEqual(afterReset.sensitivity, GestureConfiguration().sensitivity)
            XCTAssertEqual(afterReset.smoothing, GestureConfiguration().smoothing)
            XCTAssertFalse(afterReset.camera.session.isRunning)
        }
    }

    func testCalibrationIntroProgressAndCompletedViewsRenderOffscreen() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let suite = "AirTouch.CalibrationViewRenderingTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var progress = PersonalCalibrationSession()
            progress.start(at: 0)
            for n in 1...30 {
                let time = Double(n) / 30
                progress.update(HandFeatures(index: Point(0.5, 0.35), palm: Point(0.5, 0.5)),
                    capturedAt: time, now: time, confidenceQualified: true)
            }
            var waiting = PersonalCalibrationSession()
            waiting.start(at: 0)
            var missing = waiting
            missing.update(nil, capturedAt: 0.1, now: 0.15, confidenceQualified: false)
            let cases: [(String, PersonalCalibrationSession)] = [
                ("intro", PersonalCalibrationSession()), ("waiting", waiting),
                ("hand-missing", missing), ("progress", progress),
                ("completed", try completedSession())
            ]
            var previousData: Data?
            for (name, calibration) in cases {
                let model = AppModel(preferences: defaults, runtimeServicesEnabled: false,
                    initialCalibration: calibration)
                let view = CalibrationView(model: model)
                    .frame(width: 700, height: 760)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark)
                // ImageRenderer cannot draw AppKit-backed ScrollView content.
                // Cache only our own hosted view in an unshown window instead.
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                XCTAssertFalse(window.isVisible)
                XCTAssertEqual(bitmap.pixelsWide / 700, bitmap.pixelsHigh / 760)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 700)
                window.close()
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 12_000, "Rendered text and controls must be present")
                XCTAssertNotEqual(data, previousData, "Different calibration states must render different content")
                previousData = data
                if let directory = ProcessInfo.processInfo.environment["AIRTOUCH_RENDER_DIRECTORY"] {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let file = root.appendingPathComponent("airtouch-v040-calibration-\(name).png")
                    try data.write(to: file, options: .atomic)
                    print("OWN_VIEW_RENDER \(file.path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                }
                XCTAssertFalse(model.camera.session.isRunning)
                XCTAssertFalse(model.isRunning)
            }
        }
    }

    private func completedSession() throws -> PersonalCalibrationSession {
        var session = PersonalCalibrationSession()
        session.start(at: 0, date: Date(timeIntervalSince1970: 1_800_000_000))
        var time = 0.0
        func feed(_ palm: Point = Point(0.5, 0.5), pinch: Double = 0.8) {
            time += 1 / 30
            session.update(HandFeatures(index: Point(palm.x, palm.y - 0.15), palm: palm,
                pinchRatio: pinch, isPointer: pinch >= 0.5),
                capturedAt: time, now: time, confidenceQualified: true)
        }
        for _ in 0..<150 where session.stage == .steady { feed() }
        for n in 0..<250 where session.stage == .horizontal { feed(Point(0.5 + sin(Double(n) / 20) * 0.18, 0.5)) }
        for n in 0..<250 where session.stage == .vertical { feed(Point(0.5, 0.5 + sin(Double(n) / 20) * 0.16)) }
        for _ in 0..<30 { feed() }
        for _ in 0..<3 {
            for _ in 0..<20 { feed(pinch: 0.15) }
            for _ in 0..<20 { feed() }
        }
        for _ in 0..<60 where session.stage == .pinch { feed() }
        XCTAssertEqual(session.stage, .completed)
        _ = try XCTUnwrap(session.profile)
        return session
    }
}
