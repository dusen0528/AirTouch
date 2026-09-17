# v0.4.4 카메라 충돌과 보정 회복

## 실제 충돌

사용자가 보정 실패와 앱 종료를 함께 보고했다. v0.4.3 build 13의 2026-09-18 00:18 충돌 기록에서 두 작업이 겹친 것을 확인했다.

- 메인 스레드: `CameraPreview.makeNSView → addVideoPreviewLayer → commitConfiguration`.
- 카메라 큐: `CameraService.start → startRunning → _setRunning → __NSFastEnumerationMutationHandler`.
- 예외는 `EXC_CRASH / SIGABRT`다. [식별 정보를 제외한 스택 요약](v044-crash-summary.json). 원본 `.ips`는 커밋하지 않았다.

미리보기의 `session` 지정도 세션 연결을 만드는 구성 변경이다. 시작·중지·구성과 미리보기 연결·해제·미러링을 같은 카메라 큐로 모았다. UI는 뷰 배치만 바꾸며, 해제할 레이어는 큐 작업이 끝날 때까지 보유한다. 화면 갱신마다 연결 설정을 다시 변경하던 경로도 제거했다.

## 보정 회복

기존에는 정지 중 손이 움직이거나 이동 폭이 부족하면 전체 세션이 실패했고, 이후 올바른 관측을 공급해도 회복하지 못했다. 카메라 준비가 20초를 넘는 경우에도 측정을 시작하기 전에 실패했다.

- 최초 유효 관측부터 측정 시간을 계산한다. 카메라 대기는 보정 실패로 처리하지 않는다.
- 현재 단계의 표본이 부족하면 해당 단계만 다시 측정하고 앞에서 완료한 손 위치·범위를 보존한다.
- 부족한 이동 폭·떨림·집기 구분의 정확도 기준은 유지한다. 폐기한 시도의 표본과 시간은 최종 보정값에서 제외한다.
- 보정 화면에 현재 단계의 재측정 이유를 표시한다.
- 정상 인식과 인식 누락이 번갈아 올 때 이동 보정 시간이 영구히 0에 머물던 계산도 수정했다. 최신 유효 프레임에 직전 카메라 프레임 간격 중 최대 1/30초만 적립하며, 누락·중복·오래된 프레임과 긴 공백은 적립하지 않는다. 집기 시간과 연속 구분은 기존 기준을 유지한다.
- 30fps에서 50% 인식 누락을 합성한 재현은 수정 전 8.4초에도 진행률 0, 수정 후 4초에 약 50% 및 8.4초에 다음 단계 진입이었다. [수정 전 기록](v044-dropout-red.log). 보수적인 프레임당 상한으로 실제 15fps에서는 정지 관측 4초를 모으는 데 약 8초가 걸린다.

## 재현 명령

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CameraPreviewLifecycleTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CalibrationRecoveryTests
```

[카메라 수정 전 실패](v044-camera-red.log), [보정 수정 전 실패](v044-calibration-red.log).

`CameraPreviewLifecycleTests`는 실제 SwiftUI 미리보기를 보이지 않는 뷰로 생성한다. 카메라 작업 큐가 사용 중일 때 미리보기에서 세션을 즉시 변경하는 경로를 재현한다. 앱을 강제로 충돌시키거나 카메라 권한을 요청하지 않는다. 나머지 테스트는 교체된 뷰만 분리되는지와 해제 작업의 직렬화를 검사한다.

설치본의 `--camera-preview-stress-report` 진단 모드는 실제 내장 카메라와 미리보기 연결을 반복한다. 정상 실행에서는 사용하지 않으며, 영상·손 좌표·OS 입력을 기록하거나 전송하지 않는다. 실제 손 보정의 편안함과 대상 앱 입력 성공은 이 검사와 구분한다.

전체 자동 테스트는 135개 중 133개 통과, 사용자 원본이 필요한 2개 건너뜀, 실패 0개다. [전체 로그](v044-tests.log). 카메라 수명주기 3개와 보정 관련 26개가 포함된다. [보정 재시도 화면](v044-calibration-retry.png)은 자체 뷰의 오프스크린 렌더링으로, 실제 카메라 영상은 포함하지 않는다.

## 설치본 실제 카메라 검사

v0.4.4 build 14를 기존 `~/Applications/AirTouch.app`에 개발 서명으로 설치한 뒤 아래 명령을 실행했다.

```sh
open -W ~/Applications/AirTouch.app --args --camera-preview-stress-report /tmp/airtouch-v044-camera-stress.json
```

10회 모두 성공했으며 총 약 12.0초가 걸렸다. 각 회차에서 미리보기 교체가 끝난 후 촬영된 1280×720 프레임 3개가 200ms 이내로 도착했고 실제 중지 완료를 기다렸다. 최종 `cameraStopped=true`, `osInputEnabled=false`다. [집계 원본](v044-camera-stress.json).

검사 종료 후 일반 모드로 재실행했다. 동일 designated requirement와 strict 서명 검증, accessory 실행 정책, 일반 창 비표시, 실행 앱 하나와 임시 패키지·설치 백업 부재를 확인했다. 휴지통에 남아 있던 이전 앱의 Launch Services 등록만 제거한 뒤 등록 경로도 현재 앱 하나였다. [설치 상태](v044-install-state.json), [빌드·설치 로그](v044-install.log).

이 검사는 실제 카메라 수명주기 검증이다. 손으로 모든 보정 단계를 완료하는 검사나 실제 macOS 클릭·드래그의 성공률 검사가 아니다.
