# AirTouch 배포 경로 검토

검토일: 2026-09-17. 대상: 현재 소스와 `~/Applications/AirTouch.app` v0.4.0 build 10. 소스·서명 조회만 수행했고 앱 실행, 권한 변경, 재서명, 스토어 제출은 하지 않았다.

**현재 전역 마우스 제어 구현은 Mac App Store의 App Sandbox 요구와 충돌한다.** 이는 entitlement 파일을 아직 만들지 않은 문제보다 크다. 다만 모든 향후 AirTouch 설계나 Apple이 별도로 인정할 수 있는 경로까지 영구적으로 불가능하다고 단정하는 판단은 아니다. 지금 확인한 공개 문서와 구현으로는 현 기능을 유지한 스토어 배포를 승인 가능한 상태라고 설명할 수 없다.

## 근거

Mac App Store 배포에는 App Sandbox가 필요하다. Apple 개발 문서와 심사 지침 2.4.5(i)가 각각 이를 명시한다. [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility).

Apple의 현재 Sandbox 안내는 보조 앱의 Accessibility API 사용을 호환되지 않는 활동으로 분류한다. Cocoa 접근성 안내도 다른 앱을 제어하는 앱과, 자신의 UI를 VoiceOver 등에 노출하는 앱을 구분한다. 후자는 Sandbox에서 지원하지만 다른 앱을 제어하는 보조 앱은 샌드박싱할 수 없다고 설명한다. [Sandbox 비호환 기능](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [Cocoa 접근성 안내](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXIntro/cocoaAXintro.html).

AirTouch는 [SystemInput.swift](../../Sources/AirTouchApp/SystemInput.swift)의 `CGEvent` 생성과 `.post(tap: .cghidEventTap)`으로 다른 앱에 마우스 이동·클릭·드래그·스크롤을 보낸다. [PermissionManager.swift](../../Sources/AirTouchApp/PermissionManager.swift)는 `AXIsProcessTrusted`, `CGPreflightPostEventAccess`, 권한 요청 API를 사용한다. **코드와 위 문서를 종합하면 현재 핵심 기능이 Sandbox의 다른 앱 제어 제한과 충돌한다.** 사용자에게 손쉬운 사용 권한을 받은 사실은 Sandbox entitlement의 대체물이 아니다. Apple도 entitlement 설정과 사용자의 명시적 승인을 별도 조건으로 설명한다. [Sandbox 구성과 사용자 승인](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

카메라 손 인식 자체가 스토어 배포 금지 사유인 것은 아니다. Apple은 Sandbox 또는 Hardened Runtime에 카메라 entitlement를 추가하는 경로를 제공하며, 카메라 사용자의 동의도 요구한다. 카메라·앱 내부 연습·개인 보정과 다른 앱의 입력 제어는 구분해서 평가해야 한다. [Camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera).

## 현재 산출물 상태

| 확인 항목 | 로컬에서 확인한 상태 |
| --- | --- |
| 빌드·서명 | [build-app.sh](../../scripts/build-app.sh)가 SwiftPM release 빌드 후 Apple Development 인증서로 서명한다. |
| App Sandbox | 설치본 `codesign -d --entitlements -` 출력에 entitlement payload가 없고, 빌드 스크립트에도 `--entitlements`가 없다. |
| Hardened Runtime | 설치본 서명 조회는 `flags=0x0(none)`이다. 빌드 스크립트에 `--options runtime`이 없다. |
| App Store 등록·심사 | 이번 조사에서는 App Store Connect 계정이나 기존 앱 레코드를 확인하지 않았다. 등록·승인·노출 중이라고 추정하지 않는다. |

일반 공개 entitlement를 추가하는 것만으로 현재 전역 제어를 허용하는 경로는 이번 조사에서 확인하지 못했다. 특정 예외나 다른 아키텍처로 스토어 배포를 추진하려면 해당 동작을 명시해 Apple에 기술·배포 가능성을 확인하고, 실제 Sandbox 빌드에서 핵심 동작을 검증해야 한다. 심사를 통과한 기존 유사 앱의 존재만으로 AirTouch가 같은 권한이나 조건을 가진다고 추정하지 않는다.

## 검토 가능한 외부 배포 경로

Apple은 Mac App Store 밖의 배포에 Developer ID 서명과 공증 경로를 제공한다. 공증 준비에는 Developer ID 서명, Hardened Runtime, 보안 타임스탬프 등이 필요하며, 개발 인증서는 공증 제출용 인증서가 아니다. **공증은 App Store 심사와도 다르다.** 현재 개발 설치본이 이 배포 준비를 마쳤다는 의미가 아니다. [Developer ID 배포](https://developer.apple.com/developer-id/), [공증 준비 요건](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

외부 배포는 선택지로만 제시한다. 사용자가 그 경로를 선택했다고 가정하지 않고, 이번 ASO 작업 때문에 제어 기능·권한·번들 ID·기존 개발 인증서를 바꾸지 않는다. 과거 서명 변경으로 권한 재등록이 필요했던 기록도 있으므로 실제 배포 서명 전환과 업데이트 경로는 별도 검증 대상이다. [권한 복구 기록](../implementation-status.md).

ASO 문구·스크린샷 기획은 검토용으로 준비할 수 있다. 실제 배포 경로가 확인되기 전에는 ‘Mac App Store에서 다운로드’, 심사 승인, 검색 순위나 리뷰 성과를 사실처럼 표시하지 않는다. 스토어 메타데이터는 실제 제공 경험과 일치해야 한다. [App Review Guidelines 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).
