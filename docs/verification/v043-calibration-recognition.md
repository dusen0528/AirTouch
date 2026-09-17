# v0.4.3 손 보정 인식

## 재현과 수정

사용자는 손을 올려도 보정이 진행되지 않는다고 보고했다. 현재 사용자의 손 자세를 직접 관찰한 기록은 없으므로, 아래는 코드에서 별도로 재현한 결함이다.

`FeatureExtractor`는 검지와 손바닥을 정상 추적하면 엄지가 가려져도 `isPointer=true`, `isPinchReliable=false`를 반환한다. `AppModel`도 이동 보정에서는 엄지를 필수 관절로 검사하지 않는다. 그러나 `PersonalCalibrationSession`의 공통 조건이 엄지를 요구해 이동 관측까지 전부 버렸다.

합성 관절을 실제 `FeatureExtractor`에 전달하고, 엄지 신뢰도만 1에서 0.1로 바꿔 비교했다. 수정 전 정상 대조군은 좌우 단계에 도달했으나, 엄지 가림 조건은 150프레임 / 5초 뒤에도 정지 단계에 머물렀다. 유효 관측 0, 거절 150이었다. 재현 명령:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CalibrationCameraInputTests
```

- [수정 전 실패](v043-calibration-red.log).
- 정지·좌우·상하 단계에서 엄지 가림을 허용하고 마지막 집기 단계에는 엄지 검사를 유지한다. 필수 검지·손바닥 신뢰도, 자세, 영상 유효 시간과 이동량 검사는 유지한다.
- 카메라 대기, 손 없음, 손 위치 조정, 검지 자세, 엄지 가림, 영상 지연, 정상 수집을 구분해 안내한다.
- 인식 상태와 단계별 진행률을 카메라 미리보기 위에 표시한다.

## 검증 범위

- 관련 보정 테스트 19개 통과. 전체 125개 중 123개 통과, 사용자 원본 기록이 없는 2개 건너뜀, 실패 0개. [전체 테스트 로그](v043-tests.log).
- 보정 소개·카메라 대기·손 없음·수집·완료 화면을 보이지 않는 자체 뷰에서 렌더링했다. [수집 상태](v043-calibration-progress.png), [손 없음](v043-calibration-hand-missing.png). 테스트에서는 카메라를 켜지 않았으므로 미리보기 영역은 꺼짐 상태다.
- 기존 위치에 v0.4.3 build 13을 설치했다. 번들 ID `dev.airtouch.mac`, 동일 designated requirement, strict 서명 검증 성공, accessory 실행 정책과 일반 창 비표시를 확인했다. 실행 프로세스 및 Launch Services 등록 경로는 `~/Applications/AirTouch.app` 하나였고 임시 패키지·설치 백업은 남지 않았다. [설치 상태](v043-install-state.json), [빌드·설치 로그](v043-install.log).

합성 관절 재현과 자체 화면 렌더링은 실제 손 보정 완료를 입증하지 않는다. 저장된 사용자 기록은 v0.3.5 기록이므로 이번 보정 결함의 직접 증거로 사용하지 않았다. 보정 원본 손 좌표나 카메라 영상은 Git에 포함하지 않는다.

네이티브 UI 검사 도구는 `Computer Use server error -10005: timeoutReached`로 연결하지 못했다. 실제 카메라 화면에서 손을 올려 끝까지 보정하는 검증은 남아 있다.
