# v0.3.1 사용성 개선 및 검증

작성일: 2026-09-15. 설치 위치 `/Users/inho/Applications/AirTouch.app`, 앱 ID `dev.airtouch.mac` 유지.

## 사용자 기록에서 확인한 사실

원본은 사용자가 제공한 `/Users/inho/Downloads/airtouch-session.json`이며 저장소에 원본 좌표를 복사하지 않았다.

- v0.3.0 카메라 세션, `osInputEnabled=false`, `systemIntentCount=0`, `accessibilityPermission=false`: 연습 모드 기록이다. 사용자의 “되긴 한다”는 설명을 실제 macOS 입력 검증으로 해석하면 안 된다.
- 2,513개 프레임 중 유효 손 1,153개, 지연 제외 80개. 손을 내린 시간도 포함하므로 46%를 인식 정확도라고 단정할 수 없다.
- 촬영→Vision 완료 P95 약 149.5ms. 마지막 600프레임의 촬영→메인 큐 도착 중앙값 142.4ms, P95 160.4ms.
- 보존된 마지막 600개가 모두 손 미검출 구간이라 동작 중 좌표는 재생할 수 없었다. 상태 전이에 이동→대기 반복은 있으나 개별 원인을 분리할 데이터가 부족하다.

## 변경 및 근거

### 반응성과 자세 전환

정규화 좌표를 일정 속도로 움직이는 재생에서 기존 One Euro 필터가 추가하던 지연은 약 103.5ms였다. 정지 시 minimum cutoff 1.5는 유지하고 속도 계수를 정규화 좌표에 맞게 0.15에서 12로 변경했다. 동일 입력에서 약 35.4ms로 줄었다. 이 수치는 **필터 단독 재생 결과**이며 촬영·추론·OS 표시를 포함한 체감 지연 측정이 아니다.

검지 자세가 한 프레임 불확실할 때 즉시 정지하던 경로에 120ms 유예를 적용했다. 유예 동안 커서를 움직이지 않고, 자세가 돌아오면 이동 기준을 다시 잡아 점프 없이 재개한다. 펼친 손, 손 상실, 영상 만료, 권한 철회 등의 중지 조건은 유지한다. 스크롤을 마치고 검지만 펴면 350ms 활성화 대기 없이 포인터로 돌아온다.

### 카메라와 진단

런타임 로그에 카메라 반응 효과의 VFX 오류가 있었다. 앱 Info.plist에 NSCameraReactionEffectsEnabled=false 및 NSCameraReactionEffectGesturesEnabledDefault=false를 설정했다. 이는 앱별 설정이며 다른 앱이나 전역 설정을 변경하지 않는다. 근거: [Apple reactionEffectsEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectsenabled) 및 설치 SDK의 AVCaptureDevice.h. 이 변경으로 실제 추론 지연이 얼마나 줄었는지는 새 실기기 기록이 필요하다.

마지막 손동작 1,800프레임(유효 손 이후 1초 이내 손실 구간 포함)을 최근 600프레임과 별도로 보존한다. 손을 내리고 나중에 내보내도 동작 구간이 사라지지 않는다. 카메라 전달 / Vision 실행 / 메인 큐 전달 시간을 구분해서 저장한다. 영상은 저장하지 않는다. 연습 화면과 인식 상태에는 실제 macOS 입력 여부를 명시했다.

### 개발 서명

이전 설치본의 designated requirement가 cdhash였음을 확인했다. 업데이트 시 바이너리 해시가 바뀌면 이전 권한 식별과 일치하지 않을 수 있다. 이 Mac에 이미 있는 Apple Development 인증서로 서명했고, 새 requirement는 앱 ID + Apple 인증서 조건으로 구성된다. 이후 같은 인증서를 사용하는 빌드는 이 식별 조건을 유지한다. 전환한 첫 실행은 권한 재허용이 필요할 수 있으며 외부 배포용 Developer ID 서명·공증과는 다르다.

정상적인 SIGTERM 종료에서는 출력 해제와 카메라 중지를 수행한 뒤 종료하도록 연결했다. 강제 종료(SIGKILL) 때의 정리를 보장하지 않는다.

## 검증

- 단위 및 통합 테스트 47개 통과. 반응성 테스트 4개 중 3개는 수정 전 실패를 확인했다.
- 일정 속도 필터 지연 103.5→35.4ms. 정지 잡음 억제와 오버슈트 없음도 확인했다.
- 짧은 자세 불확실성 후 재활성화 대기 없음, 스크롤→포인터 복귀 시 점프 없음.
- 기존 클릭·드래그·우클릭·출력 해제·연습 시나리오 회귀 통과.
- Release 빌드, Apple Development 서명, 설치본 서명 검증, 빌드/설치 실행 파일 SHA-256 일치 확인.
- 자동 UI 연결은 여전히 Invalid app: dev.airtouch.mac으로 차단된다. 사용자 기록은 연습 동작이 있었다는 증거이며 실제 macOS 커서 제어·새 버전 체감 개선은 아직 직접 검증하지 못했다.

로그: [테스트](verification/v031-tests.log), [설치](verification/v031-install.log), [수정 전 반응성](verification/v031-responsive-red.log), [수정 후 반응성](verification/v031-responsive-green.log).

이전 구현 및 검증: [v0.3](verification/v03-implementation-status.md), [v0.2](verification/v02-implementation-status.md).
