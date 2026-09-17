import AppKit
import Combine
import SwiftUI

@MainActor final class AirTouchAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var windows = AppWindows(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        windows.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
}

/// Only user requests and incomplete setup create a control window. This also
/// avoids automatic Window scene restoration on macOS 14.
@MainActor final class AppWindows {
    private let model: AppModel
    private(set) var mainWindowController: NSWindowController?
    private var openSettingsAction: (() -> Void)?
    private var settingsRequested = false
    private var runningSubscription: AnyCancellable?
    private var launched = false

    init(model: AppModel) {
        self.model = model
        runningSubscription = model.$isRunning.dropFirst().sink { [weak self] running in
            guard running else { return }
            // Published values are delivered before the model finishes starting.
            DispatchQueue.main.async {
                guard let self, self.model.isSystemControl else { return }
                self.mainWindowController?.window?.orderOut(nil)
            }
        }
    }

    func launch() {
        guard !launched else { return }
        launched = true
        model.handleLaunchArguments()
        if model.showSetup { showMainWindow() }
    }

    func showMainWindow() {
        let window = prepareMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func registerOpenSettingsAction(_ action: @escaping () -> Void) {
        openSettingsAction = action
        if settingsRequested { showSettings() }
    }

    func showSettings() {
        guard let action = openSettingsAction else { settingsRequested = true; return }
        settingsRequested = false
        NSApp.activate(ignoringOtherApps: true)
        action()
    }

    /// Creating the window separately lets lifecycle tests inspect it offscreen.
    @discardableResult func prepareMainWindow() -> NSWindow {
        if let window = mainWindowController?.window { return window }
        let content = ContentView(model: model, openSettings: { [weak self] in self?.showSettings() })
        let window = ControlWindow(contentViewController: NSHostingController(rootView: content))
        window.command = { [weak self, weak window] key in
            guard let self else { return }
            switch key {
            case "start": self.model.startSystemControl()
            case "r": self.model.startCamera()
            case "d": self.model.startDemo()
            case ".": self.model.stop()
            case ",": self.showSettings()
            case "w": window?.performClose(nil)
            case "q": self.model.stop(); NSApp.terminate(nil)
            default: break
            }
        }
        window.identifier = NSUserInterfaceItemIdentifier("practice")
        window.title = "AirTouch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1040, height: 780))
        window.contentMinSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setFrameAutosaveName("AirTouchControlWindow")
        window.center()
        mainWindowController = NSWindowController(window: window)
        return window
    }
}

/// Accessory windows have no ordinary app menu bar. Keep their existing command
/// keys local to this window, including the standard close/settings shortcuts.
private final class ControlWindow: NSWindow {
    var command: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == [.command, .shift], key == "s" { command?("start"); return true }
        if modifiers == .command, ["r", "d", ".", ",", "w", "q"].contains(key) {
            command?(key); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// SwiftUI Settings remains native; it must not become a launch-time window.
struct NonRestoringSettingsWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SettingsWindowMarker() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.isRestorable = false }

    private final class SettingsWindowMarker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
