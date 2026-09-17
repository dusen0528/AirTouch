import SwiftUI
import AppKit

@main struct AirTouchApp: App {
    @NSApplicationDelegateAdaptor(AirTouchAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model, windows: delegate.windows)
        } label: {
            MenuBarIcon(model: delegate.model, windows: delegate.windows)
        }
        Settings {
            AirTouchSettings(model: delegate.model, showMainWindow: delegate.windows.showMainWindow)
                .background(NonRestoringSettingsWindow())
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("제어") {
                Button("전체 제어 시작") { delegate.model.startSystemControl() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("카메라 연습 시작") { delegate.windows.showMainWindow(); delegate.model.startCamera() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("전체 제어 중지") { delegate.model.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("데모 재생") { delegate.windows.showMainWindow(); delegate.model.startDemo() }
                    .keyboardShortcut("d", modifiers: [.command])
            }
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    let windows: AppWindows
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.isRunning ? "hand.point.up.left.fill" : "hand.point.up.left")
            .accessibilityLabel("AirTouch")
            .help(model.isSystemControl ? "AirTouch · Mac 제어 중" : "AirTouch · 대기 중")
            .onAppear { windows.registerOpenSettingsAction { openSettings() } }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    let windows: AppWindows
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("AirTouch · \(model.isSystemControl ? "전체 제어" : "대기 / 연습")")
        Text(model.isRunning ? model.engine.state.label : "정지됨")
        Divider()
        Button("전체 제어 시작") {
            model.startSystemControl()
            if !model.isSystemControl, model.showSetup { windows.showMainWindow() }
        }.disabled(model.isRunning)
        Button("전체 제어 중지  ⌃⌥⌘Space") { model.stop() }.disabled(!model.isRunning)
        Divider()
        Button("제어 화면 열기…") { windows.showMainWindow() }
        Button("설정…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
            .keyboardShortcut(",")
        Button("권한 확인…") { model.stop(); model.showSetup = true; windows.showMainWindow() }
        Divider()
        Button("AirTouch 종료") { model.stop(); NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
