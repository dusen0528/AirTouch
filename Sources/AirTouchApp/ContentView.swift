import SwiftUI
import AirTouchCore

private let ink = Color.primary
private let accent = Color.accentColor
private let paper = Color(nsColor: .windowBackgroundColor)

enum AppDestination: String, CaseIterable, Identifiable {
    case control, practice, calibration, permissions, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .control: return "Mac 제어"
        case .practice: return "손동작 연습"
        case .calibration: return "내 손에 맞추기"
        case .permissions: return "사용 준비"
        case .diagnostics: return "인식 상태"
        }
    }
    var symbol: String {
        switch self {
        case .control: return "cursorarrow"
        case .practice: return "hand.draw"
        case .calibration: return "hand.raised.fingers.spread"
        case .permissions: return "checklist"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.destination) {
                Section("AirTouch") {
                    ForEach([AppDestination.control, .practice]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("설정 및 지원") {
                    ForEach([AppDestination.calibration, .permissions, .diagnostics]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.isRunning ? (model.isDemo ? "데모 재생 중" : "카메라 사용 중") : "카메라 꺼짐",
                          systemImage: model.isRunning ? "video.fill" : "video.slash")
                    Text("긴급 중지  ⌃⌥⌘Space").font(.caption).foregroundStyle(.secondary)
                }.font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch model.destination ?? .control {
                case .control: ControlPage(model: model)
                case .practice: practicePage
                case .calibration: CalibrationView(model: model)
                case .permissions: SetupView(model: model, permissions: model.permissions)
                case .diagnostics: DiagnosticsView(model: model)
                }
            }
            .navigationTitle((model.destination ?? .control).title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if model.isRunning { model.stop() }
                        else if model.destination == .calibration { model.startCalibration() }
                        else { model.startSelectedMode() }
                    } label: {
                        Label(model.isRunning ? "중지" : model.destination == .calibration ? "보정 시작" : model.mode == .system ? "제어 시작" : "연습 시작",
                              systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(model.isRunning ? "카메라와 입력을 중지합니다" : "카메라를 켜고 손동작 인식을 시작합니다")
                }
                ToolbarItem {
                    SettingsLink { Label("설정", systemImage: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: model.isRunning ? "circle.fill" : "circle")
                        .foregroundStyle(model.isRunning ? Color.green : Color.secondary)
                        .font(.system(size: 7))
                    Text(model.isCalibrating ? model.calibrationSnapshot.instruction : model.isRunning ? model.engine.reason : model.status).lineLimit(2)
                    Spacer(minLength: 12)
                    if model.isRunning && !model.isDemo {
                        Text(String(format: "%.0f fps · %.0f ms", model.fps, model.latency)).monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .onChange(of: model.destination) { _, value in
            guard let value else { return }
            if model.isCalibrating && value != .calibration { model.cancelCalibration(); model.destination = value }
            let mode: ControlMode? = value == .control ? .system : value == .practice ? .practice : nil
            if let mode, mode != model.mode { model.stop(); model.mode = mode }
        }
        .onChange(of: model.mode) { _, value in
            if !model.isCalibrating && model.destination != .calibration { model.destination = value == .system ? .control : .practice }
        }
        .frame(minWidth: 820, minHeight: 620)
    }

    private var practicePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("연습 커서만 움직입니다. 실제 마우스 조작은 ‘Mac 제어’에서 시작하세요.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("데모 재생") { model.startDemo() }.disabled(model.isRunning && model.isDemo)
                }
                GeometryReader { geometry in
                    let scale = geometry.size.width / 760
                    PracticeView(model: model)
                        .scaleEffect(scale, anchor: .topLeading)
                }.aspectRatio(760 / 440, contentMode: .fit)
                HStack {
                    LabeledContent("클릭", value: "\(model.scene.clickCount)회")
                    Divider().frame(height: 16)
                    LabeledContent("드래그", value: "\(model.scene.dropCount)회")
                    Divider().frame(height: 16)
                    LabeledContent("스크롤", value: "\(Int(model.scene.scrollDistance)) pt")
                }.font(.callout)
                CameraMonitor(model: model).frame(maxWidth: 380).frame(maxWidth: .infinity)
                GestureGuide(style: model.controlStyle, dragLock: model.dragLockEnabled)
            }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
    }
}

struct CameraMonitor: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black
            if model.isRunning && !model.isDemo {
                CameraPreview(session: model.camera.session)
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * model.cameraAspectRatio)
                    let height = width / model.cameraAspectRatio
                    SkeletonOverlay(joints: model.joints).frame(width: width, height: height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 32, weight: .light))
                    Text(model.isDemo ? "데모는 카메라를 사용하지 않습니다" : "시작하면 내장 카메라가 켜집니다").font(.callout)
                }.foregroundStyle(.white.opacity(0.7))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(model.isRunning ? "내장 카메라 미리보기" : "카메라 꺼짐")
    }
}

struct ControlPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.canStartSystem {
                    HStack {
                        Label("Mac 제어를 시작하려면 사용 준비를 완료하세요.", systemImage: "lock")
                        Spacer()
                        Button("사용 준비") { model.showSetup = true }
                    }.font(.callout)
                }
                GroupBox {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.calibrationProfile == nil ? "먼저 내 손에 맞춰보세요" : "내 손에 맞춘 보정 사용 중").font(.headline)
                            Text("편한 이동 범위와 손 떨림, 집는 간격을 약 30초 동안 맞춥니다.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.calibrationProfile == nil ? "손 보정 시작" : "다시 보정") { model.openCalibration() }
                    }.padding(8)
                }
                GroupBox("조작 방식") {
                    VStack(alignment: .leading, spacing: 12) {
                        ControlStylePicker(model: model)
                        Toggle("드래그 잠금", isOn: $model.dragLockEnabled).disabled(model.isRunning)
                        Text("끌기 시작 후에는 계속 집고 있지 않아도 됩니다. 다시 집으면 놓습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                CameraMonitor(model: model)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.isRunning ? model.engine.state.label : "검지를 펴고 시작하세요").font(.title3.weight(.semibold))
                        Text(model.isRunning ? model.status : "손 전체가 카메라에 보이도록 들어주세요.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    if model.engine.progress > 0 {
                        ProgressView(value: model.engine.progress).frame(width: 90).padding(.top, 8)
                    }
                }
                Divider()
                Picker("제어할 화면", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { Text($0.name).tag($0.id) }
                }.disabled(model.isRunning)
                GestureGuide(style: model.controlStyle, dragLock: model.dragLockEnabled)
                Text("마우스나 트랙패드를 사용하면 손동작 제어가 잠시 멈춥니다. 손을 움직이지 않고 1.5초 기다린 뒤 검지를 펴면 이어서 제어합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("이 창을 닫아도 제어는 계속됩니다. 메뉴 막대의 AirTouch 또는 ⌃⌥⌘Space로 중지하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 750).frame(maxWidth: .infinity)
        }
    }
}

struct ControlStylePicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("조작 방식", selection: $model.controlStyle) {
                ForEach(ControlStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            .disabled(model.isRunning)
            Text(model.controlStyle.detail).font(.callout).foregroundStyle(.secondary)
            if model.isRunning {
                Text("중지한 뒤 조작 방식을 바꿀 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GestureGuide: View {
    var style: ControlStyle
    var dragLock = false
    var body: some View {
        GroupBox("손동작") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                row("hand.point.up.left", "이동", style == .comfortable ? "검지를 편 채 손 전체를 움직이기 · 목표 근처에서는 천천히" : "검지 끝을 움직이기")
                row("hand.pinch", "클릭", "멈춘 뒤 엄지와 검지를 가볍게 모았다 놓기")
                row("cursorarrow.click", "더블클릭", "같은 자리에서 엄지와 검지를 두 번 모았다 놓기")
                row("hand.draw", "드래그", dragLock ? "집어서 끌기 시작 → 손가락을 풀고 이동 → 다시 집어서 놓기" : "엄지와 검지를 모은 채 손 전체를 움직이기")
                row("cursorarrow.click.2", "우클릭", style == .comfortable ? "검지·중지를 V로 펼친 뒤 엄지와 중지를 모았다 놓기" : "엄지와 중지를 모았다 놓기")
                row("arrow.up.arrow.down", "스크롤", style == .comfortable ? "검지·중지를 펴고 위아래로 · 끊기면 두 손가락을 잠시 펴서 재개" : "검지와 중지를 펴고 위아래로 움직이기")
                row("hand.raised", "잠시 쉬기", "손바닥 펼치기")
            }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        GridRow {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

struct PracticeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor))
            Canvas { context, size in
                for x in stride(from: 20.0, to: size.width, by: 24) {
                    for y in stride(from: 20.0, to: size.height, by: 24) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(ink.opacity(0.09)))
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.motionlines")
                Text("연습 커서").fontWeight(.medium)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(20)

            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(accent.opacity(0.08)).frame(width: 84, height: 84)
                    Circle().stroke(accent.opacity(0.18), lineWidth: 1).frame(width: 84, height: 84)
                    Circle().fill(accent).frame(width: 64, height: 64)
                    Image(systemName: "plus").font(.system(size: 22, weight: .light)).foregroundStyle(.white)
                }
                Text("핀치로 눌러보세요").font(.system(size: 11)).foregroundStyle(.secondary)
            }.position(x: model.scene.target.x, y: model.scene.target.y + 14)

            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .frame(width: 98, height: 78).position(x: model.scene.dropTarget.x, y: model.scene.dropTarget.y)
            Text("여기에 놓기").font(.system(size: 10)).foregroundStyle(accent)
                .position(x: model.scene.dropTarget.x, y: model.scene.dropTarget.y + 55)
            Path { path in
                path.move(to: CGPoint(x: 265, y: 310)); path.addLine(to: CGPoint(x: 460, y: 310))
                path.move(to: CGPoint(x: 455, y: 305)); path.addLine(to: CGPoint(x: 460, y: 310)); path.addLine(to: CGPoint(x: 455, y: 315))
            }.stroke(accent.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))

            VStack(spacing: 5) {
                Image(systemName: "square.on.square").font(.system(size: 16))
                Text("끌어서 이동").font(.system(size: 9, weight: .medium))
            }.foregroundStyle(.white).frame(width: 76, height: 56)
                .background(accent, in: RoundedRectangle(cornerRadius: 11))
                .shadow(color: accent.opacity(0.17), radius: 10, y: 5)
                .position(x: model.scene.box.x, y: model.scene.box.y)

            VStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down").foregroundStyle(accent)
                Text("SCROLL").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6).fill(paper)
                    VStack(spacing: 12) {
                        ForEach(0..<30) { index in
                            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(index % 4 == 0 ? 0.4 : 0.12))
                                .frame(width: index % 3 == 0 ? 28 : 40, height: 4)
                        }
                    }.padding(.top, 12).offset(y: -model.scene.scrollOffset * 0.4)
                }.frame(width: 58, height: 230).clipped()
                Text("두 손가락").font(.system(size: 9)).foregroundStyle(.secondary)
            }.position(x: 696, y: 227)

            HStack(spacing: 6) {
                Text(model.scene.lastEvent).font(.system(size: 9, design: .monospaced))
                Text("·").foregroundStyle(.tertiary)
                Text("ESC로 중지").font(.system(size: 9))
            }.foregroundStyle(.secondary).position(x: 105, y: 416)

            ZStack {
                Circle().fill(model.scene.isPressed ? accent : Color(nsColor: .controlBackgroundColor)).frame(width: 16, height: 16)
                Circle().stroke(accent, lineWidth: 2).frame(width: 16, height: 16)
                Circle().stroke(accent.opacity(0.2), lineWidth: 1).frame(width: 28, height: 28)
                if model.engine.progress > 0 {
                    Circle().trim(from: 0, to: model.engine.progress).stroke(accent, lineWidth: 3)
                        .frame(width: 28, height: 28).rotationEffect(.degrees(-90))
                }
            }.shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .position(x: model.engine.cursor.x, y: model.engine.cursor.y)
                .opacity(model.isRunning ? 1 : 0.35)
                .allowsHitTesting(false)
        }
        .frame(width: 760, height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("손동작 연습 영역. 클릭 \(model.scene.clickCount)회, 드래그 \(model.scene.dropCount)회. \(model.engine.state.label)")
    }
}
