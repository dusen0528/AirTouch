import SwiftUI
import AppKit

@main struct AirTouchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("AirTouch", id: "practice") {
            ContentView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    model.handleLaunchArguments()
                }
        }
        .defaultSize(width: 1040, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("제어") {
                Button("전체 제어 시작") { model.startSystemControl() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("카메라 연습 시작") { model.startCamera() }.keyboardShortcut("r", modifiers: [.command])
                Button("전체 제어 중지") { model.stop() }.keyboardShortcut(".", modifiers: [.command])
                Button("데모 재생") { model.startDemo() }.keyboardShortcut("d", modifiers: [.command])
            }
        }
        Settings { AirTouchSettings(model: model) }
        MenuBarExtra("AirTouch", systemImage: model.isRunning ? "hand.point.up.left.fill" : "hand.point.up.left") {
            MenuContent(model: model)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("AirTouch · \(model.isSystemControl ? "전체 제어" : "대기 / 연습")")
        Text(model.isRunning ? model.engine.state.label : "정지됨")
        Divider()
        Button("제어 화면 열기") { openWindow(id: "practice"); NSApp.activate(ignoringOtherApps: true) }
        Button("전체 제어 시작") {
            if model.canStartSystem { model.startSystemControl() }
            else { openWindow(id: "practice"); NSApp.activate(ignoringOtherApps: true); model.showSetup = true }
        }.disabled(model.isRunning)
        Button("전체 제어 중지  ⌃⌥⌘Space") { model.stop() }
        Button("권한 설정") { model.stop(); openWindow(id: "practice"); NSApp.activate(ignoringOtherApps: true); model.showSetup = true }
        SettingsLink { Text("설정…") }
        Divider()
        Button("AirTouch 종료") { model.stop(); NSApp.terminate(nil) }
    }
}
