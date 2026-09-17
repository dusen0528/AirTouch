import SwiftUI
import AirTouchCore

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    private var snapshot: PersonalCalibrationSnapshot { model.calibrationSnapshot }
    private var title: String {
        switch snapshot.stage {
        case .steady: return "1. 편한 위치에서 잠시 멈추기"
        case .horizontal: return "2. 좌우로 편하게 움직이기"
        case .vertical: return "3. 위아래로 편하게 움직이기"
        case .pinch: return "4. 엄지와 검지로 세 번 집기"
        case .completed: return "내 손에 맞춘 보정이 준비됐어요"
        case .failed: return "한 번 더 맞춰볼게요"
        case .cancelled: return "보정을 취소했습니다"
        case .idle: return "편하게 움직이는 범위를 알려주세요"
        }
    }

    private var observationLabel: (text: String, symbol: String) {
        switch snapshot.observation {
        case .waitingForCamera: return ("카메라 연결을 기다리고 있어요", "video")
        case .searchingHand: return ("손을 찾고 있어요", "hand.raised")
        case .adjustHand: return ("손 위치를 조금 조정해주세요", "viewfinder")
        case .pointIndex: return ("검지만 펴주세요", "hand.point.up")
        case .showThumb: return ("엄지와 검지 끝을 보여주세요", "hand.pinch")
        case .staleFrame: return ("최신 영상을 기다리고 있어요", "video.badge.ellipsis")
        case .collecting: return ("손을 인식하고 있어요", "checkmark.circle.fill")
        }
    }

    private var recoveryInstruction: String? {
        switch snapshot.retryReason {
        case .insufficientSamples: return "손을 다시 보여주면 이 단계부터 이어서 맞춥니다."
        case .handWasMoving: return "편한 위치에서 잠시 멈춰주세요. 정지 단계만 다시 확인할게요."
        case .insufficientHorizontalRange: return "좌우로 조금 더 넓게 움직여주세요. 앞에서 맞춘 손 위치는 유지됩니다."
        case .insufficientVerticalRange: return "위아래로 조금 더 넓게 움직여주세요. 앞에서 맞춘 범위는 유지됩니다."
        case .indistinctPinches: return "엄지와 검지를 천천히 모았다 벌려주세요. 집기 단계만 다시 확인할게요."
        case nil: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.title2.weight(.semibold))
                Text(snapshot.stage == .pinch
                     ? "편한 위치에서 엄지와 검지를 모았다 벌려주세요. 안내가 바뀌면 다음 동작으로 이어가면 됩니다."
                     : "검지만 편 손을 카메라에 보여주세요. 약 30초 동안 손 떨림, 이동 범위, 집는 간격을 맞춥니다.")
                    .foregroundStyle(.secondary)
                if model.isCalibrating {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(observationLabel.text, systemImage: observationLabel.symbol)
                            .foregroundStyle(snapshot.observation == .collecting ? Color.green : Color.secondary)
                            .font(.callout.weight(.medium))
                        Text(snapshot.instruction).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        if let recoveryInstruction {
                            Label(recoveryInstruction, systemImage: "arrow.clockwise")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if snapshot.stage == .pinch && snapshot.pinchCount < 3 {
                            ProgressView("현재 손 모양 확인", value: snapshot.pinchHoldProgress)
                                .font(.caption).tint(.green)
                                .accessibilityLabel("집기 동작 확인 진행률")
                            Text("잠깐 놓쳐도 이어서 확인해요. 안내가 바뀔 때까지 손 모양을 유지해주세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: snapshot.stageProgress).accessibilityLabel("현재 단계 진행률")
                        HStack {
                            Text("현재 단계 \(Int(snapshot.stageProgress * 100))%")
                            Spacer()
                            Text("전체 \(Int(snapshot.progress * 100))%")
                            if snapshot.stage == .pinch { Text("집기 \(snapshot.pinchCount) / 3회") }
                        }.font(.callout).monospacedDigit()
                    }
                    CameraMonitor(model: model).frame(maxWidth: 440).frame(maxWidth: .infinity)
                    Text(snapshot.stage == .pinch
                         ? "지금은 엄지와 검지 끝이 모두 보여야 집는 간격을 확인할 수 있어요."
                         : "검지와 손바닥이 보이면 진행됩니다. 엄지는 편하게 두세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("보정 취소") { model.cancelCalibration() }
                } else if snapshot.stage == .completed, let profile = model.calibration.profile {
                    GroupBox("보정 결과") {
                        VStack(spacing: 12) {
                            LabeledContent("이동 속도", value: String(format: "%.1f×", profile.sensitivity))
                            LabeledContent("집기 확인", value: "3회 완료")
                            LabeledContent("움직임 보정", value: profile.minimumCutoff >= 1.8 ? "빠른 반응" : "떨림 안정")
                            Text("보정값은 이 Mac에 저장됩니다. 설정에서 다시 맞추거나 초기화할 수 있습니다.")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(10)
                    }
                    HStack {
                        Button("보정 적용") { model.applyCalibration() }.buttonStyle(.borderedProminent)
                        Button("다시 맞추기") { model.startCalibration() }
                    }
                } else {
                    if let failure = snapshot.failure {
                        Label(failure.message, systemImage: "hand.raised.slash")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    GroupBox("네 단계로 맞춥니다") {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("검지를 펴고 편한 위치에서 잠시 멈추기", systemImage: "1.circle")
                            Label("편한 범위 안에서 좌우로 움직이기", systemImage: "2.circle")
                            Label("편한 범위 안에서 위아래로 움직이기", systemImage: "3.circle")
                            Label("안내에 맞춰 엄지와 검지를 세 번 모았다 펴기", systemImage: "4.circle")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(snapshot.stage == .idle ? "손 보정 시작" : "보정 다시 시작") { model.startCalibration() }
                        .buttonStyle(.borderedProminent)
                }
                Text("보정 중에는 Mac의 실제 마우스를 조작하지 않습니다. 영상과 손 좌표는 저장하지 않고, 보정값만 저장합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }
}
