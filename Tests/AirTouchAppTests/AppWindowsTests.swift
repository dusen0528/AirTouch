import AppKit
import SwiftUI
import XCTest
@testable import AirTouchApp

/// Only creates and closes this test's own unshown window. These tests never
/// request activation, order a window onscreen, start capture, or post input.
final class AppWindowsTests: XCTestCase {
    func testWindowCoordinatorDoesNotCreateAWindowAtInitialization() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let suite = "AirTouch.AppWindowsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(preferences: defaults, runtimeServicesEnabled: false)
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))

            let windows = AppWindows(model: model)

            XCTAssertNil(windows.mainWindowController)
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), before,
                "Constructing the menu-bar window coordinator must not create a control window")
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.camera.session.isRunning)
        }
    }

    func testExplicitPreparationCreatesAnUnshownNonRestoringWindowWithTheSameModel() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let suite = "AirTouch.AppWindowsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(preferences: defaults, runtimeServicesEnabled: false)
            let windows = AppWindows(model: model)

            let window = windows.prepareMainWindow()
            defer { window.close() }
            let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<ContentView>)

            hosting.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            hosting.view.layoutSubtreeIfNeeded()
            let toolbar = try XCTUnwrap(window.toolbar,
                "The manually hosted SwiftUI control view must still produce its native toolbar")
            let toolbarLabels = Set(toolbar.items.map(\.label))
            XCTAssertTrue(toolbar.isVisible)
            XCTAssertTrue(toolbarLabels.contains("제어 시작"))
            XCTAssertTrue(toolbarLabels.contains("설정"))

            XCTAssertTrue(hosting.rootView.model === model,
                "Opening control UI must retain the menu-bar model and its settings")
            XCTAssertTrue(windows.mainWindowController?.window === window)
            XCTAssertEqual(window.identifier?.rawValue, "practice")
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isRestorable,
                "macOS restoration must not bypass menu-bar-first startup")
            XCTAssertFalse(window.isReleasedWhenClosed)
            XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.camera.session.isRunning)
        }
    }

    func testPreparingAgainAfterCloseReusesTheSameRetainedWindowAndModel() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let suite = "AirTouch.AppWindowsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(preferences: defaults, runtimeServicesEnabled: false)
            let windows = AppWindows(model: model)
            let first = windows.prepareMainWindow()
            defer { first.close() }
            let controller = try XCTUnwrap(windows.mainWindowController)

            XCTAssertTrue(windows.prepareMainWindow() === first)
            first.close()
            XCTAssertFalse(first.isVisible)
            model.sensitivity = 2.1
            let preparedAgain = windows.prepareMainWindow()
            let hosting = try XCTUnwrap(preparedAgain.contentViewController as? NSHostingController<ContentView>)

            XCTAssertTrue(preparedAgain === first,
                "Close and subsequent explicit preparation must not accumulate duplicate control windows")
            XCTAssertTrue(windows.mainWindowController === controller)
            XCTAssertTrue(hosting.rootView.model === model)
            XCTAssertEqual(hosting.rootView.model.sensitivity, 2.1)
            XCTAssertFalse(preparedAgain.isVisible)
            XCTAssertFalse(model.isRunning)
            XCTAssertFalse(model.camera.session.isRunning)
        }
    }
}
