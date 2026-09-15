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


## 권한 등록 복구 (2026-09-15)

사용자가 스위치와 앱을 껐다 켜도 ‘허용 필요’가 유지된다고 보고했다. macOS tccd 로그에서 현재 앱 ID에 대해 `Failed to match existing code requirement ... kTCCServiceAccessibility`가 반복됨을 확인했다. 추정이 아니라 기존 서명 요구사항 불일치가 직접 기록되어 있었다.

앱을 정상 종료한 뒤 `tccutil reset Accessibility dev.airtouch.mac`으로 해당 앱의 손쉬운 사용 등록만 초기화했다. 카메라, 다른 앱, 전역 권한은 초기화하지 않았다. 시스템 설정에서 이전 AirTouch 항목이 제거된 것도 확인했다. 안내 문구를 ‘토글’에서 ‘기존 항목 제거 후 현재 앱 다시 추가’로 수정해 개발 서명으로 설치했다.

재등록 단계에서 사용자가 Touch ID 인증을 완료했다. 시스템 설정에서 AirTouch가 다시 표시되고 스위치가 켜진 상태를 확인했다. v0.3.2 설치 후 재시작한 앱의 카메라·손쉬운 사용·입력 이벤트 권한 조회에서 authValue=2 승인 응답을 확인했고, 이전 code requirement 불일치 오류가 이번 실행에는 없었다. 실제 손 기반 마우스 조작 성공과는 별도의 권한 복구 검증이다. [원인 로그](verification/permission-signature-mismatch.log), [재실행 승인 로그](verification/v032-permission-restored.log). 같은 로그의 마이크 조회는 미허용 상태이며 손동작 제어에 마이크는 사용하지 않는다.


## v0.3.2 단일 앱 설치와 Git 이력

- 실행 앱은 `~/Applications/AirTouch.app` 하나다. 동일한 해시의 프로젝트 빌드 복사본과 이전 `.airtouch-backup` 7개를 휴지통으로 옮겼다. 복구 가능하며 다른 앱은 이동하지 않았다.
- 빌드 패키지는 `.build/packaging/AirTouch.app`에 만들고 설치 성공 후 제거한다. 설치 전 버전은 트랜잭션 동안만 보관하며 실패 시 복원한다.
- 기존에 커밋이 없었으므로 실제 확인 가능한 v0.3.1을 최초 기준점으로 기록했다. 이번 권한·설치·개발 규칙 변경은 기능별 한글 커밋으로 분리한다.
- 47개 테스트, Release 설치, 서명, 단일 앱 등록 및 임시 패키지 제거를 검증했다. 이전 버전 기록의 테스트 수와 설치 경로는 당시 증거로 보존한다.

검증 기록: [테스트](verification/v032-tests.log), [설치](verification/v032-install.log), [최종 설치 상태](verification/v032-install-state.txt).


## v0.3.3 커서와 제스처 사용성

손 중심 추적·속도별 이동·클릭 및 스크롤 떨림 보정을 적용했다. 구체적인 재현 조건과 설치 검증은 [v0.3.3 사용성 검증](verification/v033-usability.md)을 참고한다. 기존 손끝 제어도 설정에서 선택할 수 있다.


## v0.3.4 이동 끊김

사용자가 제공한 실제 Mac 제어 기록에서 확인한 지연 중단·우클릭 오인식 경로를 수정했다. 손가락 방향 판정과 진단도 보완했다. [원인, 재생 검증 및 한계](verification/v034-continuity.md).


## v0.3.5 시작 중지와 추종 지연

출력 감시기의 첫 프레임 거부·촬영 시각 기반 종료를 수정하고, 필터 반응과 카메라 영상 형식을 조정했다. [실제 카메라 비교와 검증 범위](verification/v035-startup-latency.md).
