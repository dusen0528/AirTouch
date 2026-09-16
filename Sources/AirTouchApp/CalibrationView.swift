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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.title2.weight(.semibold))
                Text("카메라에 손 전체가 보이는 편한 자세에서 진행하세요. 약 30초 동안 손 떨림, 이동 범위, 집는 간격을 맞춥니다.")
                    .foregroundStyle(.secondary)
                if model.isCalibrating {
                    CameraMonitor(model: model)
                    Text(snapshot.instruction).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: snapshot.stageProgress).accessibilityLabel("현재 단계 진행률")
                    HStack {
                        Text("전체 \(Int(snapshot.progress * 100))%")
                        Spacer()
                        if snapshot.stage == .pinch { Text("집기 \(snapshot.pinchCount) / 3회") }
                    }.font(.callout).monospacedDigit()
                    Text("손을 놓치면 기다립니다. 움직임을 충분히 확인한 단계만 다음으로 넘어갑니다.")
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
