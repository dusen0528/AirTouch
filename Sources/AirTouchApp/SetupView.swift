import SwiftUI
import AVFoundation
import AirTouchCore

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionManager
    var body: some View {
        Form {
            Section {
                Text("Mac 제어에 필요한 권한을 확인합니다. 시스템 설정에서 돌아오면 허용 상태가 자동으로 갱신됩니다.")
                    .foregroundStyle(.secondary)
            }
            Section("1. 앱 설치") {
                LabeledContent("응용 프로그램", value: AppInstallation.installed ? "설치됨" : "설치 필요")
                if !AppInstallation.installed {
                    Text("권한을 허용하기 전에 AirTouch를 응용 프로그램 폴더에 설치하세요.").foregroundStyle(.secondary)
                    Button("설치하고 다시 열기") { model.installApp() }
                }
            }
            Section {
                permissionStatus("카메라", ready: permissions.camera == .authorized)
                Text("내장 카메라로 손 위치를 인식합니다. 영상은 Mac 안에서 처리하며 저장하거나 전송하지 않습니다.")
                    .foregroundStyle(.secondary)
                if permissions.camera != .authorized {
                    Text(permissions.cameraDescription).font(.callout).foregroundStyle(.secondary)
                    Button(permissions.camera == .notDetermined ? "카메라 접근 허용…" : "카메라 설정 열기…") { permissions.requestCamera() }
                        .disabled(permissions.requestingCamera || permissions.camera == .restricted)
                }
            } header: { Text("2. 카메라 접근") }
            Section {
                permissionStatus("손쉬운 사용", ready: permissions.accessibility && permissions.postEvents)
                Text("다른 앱에서 커서 이동, 클릭, 드래그, 스크롤을 하려면 허용해야 합니다.").foregroundStyle(.secondary)
                if !permissions.accessibility || !permissions.postEvents {
                    Button("손쉬운 사용 설정 열기…") { permissions.requestAccessibility() }
                    Text("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 AirTouch를 켜세요. 목록에 없으면 +로 앱을 추가하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Finder에서 AirTouch 보기") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Text("목록에서 켜져 있는데도 허용되지 않으면 AirTouch를 완전히 종료한 뒤, 목록의 기존 AirTouch를 −로 제거하고 +로 현재 앱을 다시 추가하세요. 서명이 바뀐 이전 등록은 토글만으로 복구되지 않을 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("3. Mac 제어 허용") }
            Section("4. 긴급 중지") {
                LabeledContent("단축키", value: "⌃⌥⌘Space")
                LabeledContent("등록 상태", value: model.hotKeyReady ? "등록됨" : "등록 실패")
                LabeledContent("입력 확인", value: model.emergencyTested ? "확인됨" : "단축키를 눌러 확인하세요")
                Text("제어 중 언제든 카메라와 입력을 중지합니다. 메뉴 막대에서도 중지할 수 있습니다.").foregroundStyle(.secondary)
                if !model.hotKeyReady {
                    Text("다른 AirTouch 실행 또는 단축키 충돌을 확인하세요.").foregroundStyle(.orange)
                    Button("단축키 다시 등록") { model.retryHotKey() }
                }
            }
            Section {
                HStack {
                    Button("다시 확인") { permissions.refresh() }
                    Spacer()
                    Button("연습부터 하기") { model.showSetup = false; model.mode = .practice; model.destination = .practice }
                    Button("완료") { model.finishSetup() }
                        .buttonStyle(.borderedProminent).disabled(!model.canStartSystem)
                }
            } footer: {
                Text("완료 후 도구 막대의 ‘제어 시작’을 누르면 카메라가 켜집니다.")
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func permissionStatus(_ title: String, ready: Bool) -> some View {
        LabeledContent(title) {
            Label(ready ? "허용됨" : "허용 필요", systemImage: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? Color.green : Color.secondary)
        }
    }
}

struct AirTouchSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TabView {
            Form {
                Section("내 손에 맞추기") {
                    LabeledContent("개인 보정", value: model.calibrationProfile == nil ? "아직 보정하지 않음" : "적용 중")
                    Button("손 보정 열기…") { openWindow(id: "practice"); model.openCalibration() }
                    if model.calibrationProfile != nil {
                        Button("보정 초기화") { model.resetCalibration() }.disabled(model.isRunning)
                    }
                }
                Section("포인터") {
                    ControlStylePicker(model: model)
                    LabeledContent("이동 속도") {
                        Slider(value: $model.sensitivity, in: 0.6...3.2, step: 0.1).frame(width: 200)
                        Text(String(format: "%.1f×", model.sensitivity)).monospacedDigit().frame(width: 42)
                    }
                    LabeledContent("움직임 보정") {
                        Slider(value: $model.smoothing, in: 0.6...3.2, step: 0.1).frame(width: 200)
                        Text(model.smoothing < 1.3 ? "부드럽게" : model.smoothing > 2 ? "빠르게" : "균형")
                            .font(.caption).frame(width: 48)
                    }
                    Text("왼쪽은 떨림을 줄이고, 오른쪽은 손 움직임에 더 빠르게 반응합니다.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isRunning)
                Section("스크롤") {
                    Toggle("스크롤 방향 반전", isOn: $model.reverseScroll)
                }.disabled(model.isRunning)
                Section {
                    Button("기본값 복원") { model.controlStyle = .comfortable; model.sensitivity = 1.6; model.smoothing = 1.5; model.reverseScroll = false; model.resetCalibration() }
                        .disabled(model.isRunning)
                    if model.isRunning { Text("제어를 중지하면 설정을 변경할 수 있습니다.").foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).tabItem { Label("포인터 및 스크롤", systemImage: "cursorarrow") }
            Form {
                Section("권한") {
                    LabeledContent("카메라", value: model.permissions.camera == .authorized ? "허용됨" : "허용 필요")
                    LabeledContent("손쉬운 사용", value: model.permissions.ready ? "허용됨" : "확인 필요")
                    Button("사용 준비 열기…") {
                        model.stop(); openWindow(id: "practice")
                        model.showSetup = true
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                Section("중지") {
                    LabeledContent("긴급 중지", value: "⌃⌥⌘Space")
                    Text("마우스·트랙패드를 사용하면 손동작 입력이 잠시 멈춥니다. 잠자기와 화면 잠금 시 제어가 종료됩니다.")
                        .foregroundStyle(.secondary)
                }
                Section("개인정보") {
                    Text("카메라 영상은 저장·전송하지 않습니다. 인식 상태 기록에는 처리 시간과 손 좌표가 포함되며, 저장 버튼을 누를 때만 파일로 저장됩니다.")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("일반", systemImage: "gearshape") }
        }.frame(width: 560, height: 560)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Text("카메라 연습에서 동작을 시도한 뒤 확인하세요. 어디서 입력이 멈추는지 인식 결과와 처리 시간을 함께 보여줍니다.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("카메라 연습 시작") { model.startCamera() }.disabled(model.isRunning)
                    Button("인식 기록 저장…") { model.exportReport() }
                }
            }
            Section("이번 세션") {
                LabeledContent("입력", value: model.source)
                LabeledContent("macOS 입력", value: model.isSystemControl ? "전송 중" : "꺼짐 · 연습은 앱 안에서만 동작")
                LabeledContent("손쉬운 사용 권한", value: model.permissions.accessibility && model.permissions.postEvents ? "허용됨" : "허용 필요")
                LabeledContent("현재 상태", value: model.engine.state.label)
                LabeledContent("조작 방식", value: model.controlStyle.label)
                LabeledContent("안내", value: model.status)
                LabeledContent("처리한 프레임", value: "\(model.receivedFrameCount)")
                LabeledContent("유효한 손 인식", value: "\(model.validHandFrameCount)")
                LabeledContent("지연으로 제외한 프레임", value: "\(model.staleFrameCount)")
                LabeledContent("손 인식 비율", value: model.handRecognitionRate)
            }
            Section("입력 품질") {
                LabeledContent("초당 프레임", value: String(format: "%.0f fps", model.fps))
                LabeledContent("촬영 → 인식", value: String(format: "%.0f ms", model.latency))
                LabeledContent("카메라 전달", value: String(format: "%.0f ms", model.captureDeliveryTime))
                LabeledContent("Vision 처리", value: String(format: "%.0f ms", model.inferenceTime))
                LabeledContent("UI 전달", value: String(format: "%.0f ms", model.uiDeliveryTime))
                LabeledContent("지연 상위 5% 기준", value: model.latencyP95Description)
                LabeledContent("핀치 간격", value: model.pinchRatio.map { String(format: "%.2f", $0) } ?? "—")
                LabeledContent("시스템 입력 요청", value: "\(model.systemEventCount)")
                LabeledContent("마우스에 양보한 횟수", value: "\(model.physicalHandoffCount)")
            }
            Section("기록 안내") {
                Text("최근 프레임과 마지막 손동작 구간을 별도로 보관합니다. 손을 내린 뒤 저장해도 동작 기록이 남습니다. 기록에는 손 좌표와 처리 시간이 포함되며 영상과 화면 내용은 포함되지 않습니다. 시스템 입력 요청 수는 다른 앱에서 동작이 성공한 횟수를 뜻하지 않습니다.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
