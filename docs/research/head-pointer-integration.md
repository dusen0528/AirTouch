# AirTouch 손 이동과 macOS 표정 클릭의 조합

확인일: 2026-09-17. 범위: Apple 공개 사용자 가이드와 개발자 문서. 시스템 설정 변경, 카메라 실행, 실제 입력 시험은 이 조사에서 수행하지 않았다.

## 판단

검토할 조합은 **AirTouch가 손으로 포인터를 이동하고, macOS의 ‘대체 포인터 동작’이 표정으로 클릭을 수행하는 방식**이다. ‘헤드 포인터’는 머리로 포인터를 이동하는 별도 기능이다. Apple 가이드는 표정 클릭을 설정할 때 대체 포인터 동작만 켜도록 안내하며, 헤드 포인터 활성화를 요구하지 않는다. 따라서 헤드 포인터를 끈 채 표정 동작을 사용하는 설정은 문서상 독립적으로 구성할 수 있다. 다만 이 조합과 AirTouch의 실제 상호운용은 아직 시험하지 않았다. [Apple: 키보드를 마우스처럼 사용하기](https://support.apple.com/en-lb/guide/mac-help/-mh27469/mac)

## 기능별 역할

| 기능 | 입력과 역할 | AirTouch와 조합할 때의 의미 |
| --- | --- | --- |
| 헤드 포인터 | 내장 또는 연결된 카메라가 얼굴·머리의 움직임을 감지하여 포인터를 이동 | 손 이동을 유지하려면 활성화할 필요가 없음 |
| 대체 포인터 동작 | 키보드 키, 보조 스위치, 얼굴 표정을 클릭 등의 동작에 연결 | 표정으로 클릭을 담당할 후보 |
| 잠시 멈춤(Dwell) | 포인터를 일정 시간 머무르게 하여 선택한 동작 실행 | 스크롤까지 필요한 경우 별도로 검토할 기능 |

헤드 포인터는 마우스·트랙패드로 포인터를 움직이면 잠시 멈추고, 해당 움직임이 끝나면 재개한다고 안내되어 있다. 이 설명을 AirTouch가 생성하는 이벤트에도 그대로 적용되는 보장으로 해석해서는 안 된다. [Apple: 헤드 포인터로 포인터 이동하기](https://support.apple.com/en-ie/guide/mac-help/mchlb2d4782b/mac)

대체 포인터 동작의 공식 동작 목록은 **왼쪽 클릭, 오른쪽 클릭, 두 번 클릭, 드래그 앤 드롭**이다. 미소·입 벌리기 등의 표정을 지정할 수 있다. 드래그 앤 드롭은 표정을 유지하는 방식이 아니라 첫 번째 동작으로 드래그를 시작하고 두 번째 동작으로 놓는 방식이다. 카메라 선택과 표정 강도(약간·기본·과장)를 조정할 수 있으며, 이 두 설정은 헤드 포인터와 공유된다. [Apple: 포인터 제어 설정, macOS Tahoe 26](https://support.apple.com/ko-kr/guide/mac-help/unac899/26/mac/26)

**표정 동작 목록에 스크롤은 명시되어 있지 않다.** 스크롤은 AirTouch의 손 동작으로 남기거나, 손쉬운 사용 키보드의 Dwell을 별도로 검토해야 한다. Dwell의 ‘Scroll Menu’는 스크롤 가능한 내용 위에 머문 뒤 나타난 방향 표시 위에 다시 머물러 스크롤한다. 표정 하나에 스크롤을 지정하는 기능과는 동작 방식이 다르다. [Apple: Dwell로 포인터 제어하기](https://support.apple.com/en-sg/guide/mac-help/mchl437b47b0/mac)

## 사용자 설정 경로

이 경로는 문서에 근거한 안내이며, 이 조사에서 변경하지 않았다.

1. 시스템 설정 → 손쉬운 사용 → 포인터 제어로 이동한다.
2. ‘대체 포인터 동작’을 켜고 정보 버튼에서 표정과 동작을 지정한다.
3. 손으로 이동할 목적이라면 ‘헤드 포인터’는 끈다.
4. 카메라 옵션에서 MacBook 내장 카메라와 편한 표정 강도를 선택한다.
5. 처음에는 표정 왼쪽 클릭 하나로 확인한 뒤 다른 동작을 추가한다. 이는 오작동 원인을 구분하기 위한 AirTouch 검증 제안이다.

설정 명칭·경로와 카메라 옵션의 근거: [Apple 포인터 제어 설정](https://support.apple.com/ko-kr/guide/mac-help/unac899/26/mac/26). AirTouch가 시스템 설정을 자동 변경하거나 설정 완료를 자동으로 확인할 수 있다는 의미는 아니다.

## 공개 SDK로 어디까지 가져올 수 있는가

Apple 사용자 가이드는 시스템 기능의 설정·사용 방법을 제공한다. 이번 공개 문서 검색에서는 **헤드 포인터 또는 대체 포인터 동작의 내부 표정 인식 결과를 앱에서 구독하거나, 해당 인식기를 앱에 넣는 전용 공개 API를 확인하지 못했다.** 이는 검색 범위 내의 미확인 판단이며, 모든 Apple API에 대한 부존재 증명은 아니다. 검색어는 Apple Developer 도메인의 `head pointer`, `headPointer`, `alternate pointer actions`와 Vision의 얼굴 특징 감지 API였다.

공개 SDK를 사용해 AirTouch 자체 표정 인식을 구현하는 경로는 별도로 존재한다. Vision의 `VNDetectFaceLandmarksRequest`는 눈과 입 등의 특징을 찾고 `VNFaceObservation` 결과를 반환하며, 공식 가용성은 macOS 10.13 이상이다. 이 API가 제공하는 것은 얼굴 특징 정보다. 표정별 클릭 판정, 반복 방지, 사용자의 중립 표정 보정, 드래그 상태와 취소 동작은 앱이 설계·검증해야 한다. macOS의 표정 인식기와 같은 결과나 성능을 보장하는 API로 설명하면 안 된다. [Apple: VNDetectFaceLandmarksRequest](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest), [Apple: 공식 Markdown 문서의 가용성 정보](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest.md)

| 경로 | 재사용하는 기능 | 아직 확인하거나 구현할 것 |
| --- | --- | --- |
| macOS 설정과 함께 사용 | macOS의 표정 감지·클릭 실행 | 카메라 동시 사용, 입력 충돌·드래그, 사용자 설정 안내 |
| Vision으로 AirTouch에 내장 | Apple의 얼굴 특징 감지 API | 표정 판정과 개인 보정, 입력 상태 관리, 성능·사용성 검증 |

## 카메라 공유와 실제 조합의 미확인 사항

Apple 문서가 대체 포인터 동작과 헤드 포인터의 동일 카메라 사용을 설명한다고 해서, 제삼자 앱인 AirTouch와의 동시 사용까지 보장하는 것은 아니다. 반대로 카메라가 무조건 한 프로세스에서만 동작한다고 단정할 근거도 없다. AVFoundation은 다른 앱과 카메라 장치를 공유하는 상황을 설명하며, configuration lock을 불필요하게 오래 유지하면 다른 앱의 캡처 품질이 떨어질 수 있다고 명시한다. [Apple: AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice)

`AVCaptureDevice.isInUseByAnotherApplication`은 다른 앱의 장치 사용 여부를 알리는 읽기 전용 상태다. 그 값만으로 AirTouch와 표정 동작의 동시 인식 성공, 프레임 속도 또는 지연을 판단할 수는 없다. [Apple: isInUseByAnotherApplication](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isinusebyanotherapplication)

구현을 진행한다면 다음 결과를 분리해서 확인해야 한다.

- **카메라:** AirTouch 먼저/대체 포인터 동작 먼저의 두 시작 순서에서 손 추적과 표정 인식이 함께 이어지는지, 프레임 지연·정지·오류가 생기는지.
- **클릭:** 표정 클릭이 AirTouch의 사용권 넘김 또는 손 제스처와 충돌하여 커서를 멈추거나 중복 클릭하지 않는지.
- **드래그:** macOS에서 시작한 드래그 중 손 이동이 계속 항목을 끌고 가는지, 두 번째 표정으로 놓이는지. 단순 커서 이동과 드래그 중 이동 이벤트는 구분하여 검증해야 한다.
- **복구:** 손 추적 상실, 카메라 정지, 앱 일시 정지 뒤에도 마우스 버튼이 눌린 상태로 남지 않는지. AirTouch가 시작하지 않은 버튼 상태를 임의로 해제하지 않는지도 확인한다.

이 목록은 검증 계획이다. 현재 조합이 동작한다거나 AirTouch에 이미 구현되었다는 결과가 아니다.

## 예전 macOS에도 있었는가

헤드 포인터는 **macOS Catalina 10.15.4** 업데이트 내용에 이미 포함되어 있다. 따라서 최근 macOS에 처음 추가된 기능으로 소개하면 부정확하다. 해당 Apple 다운로드 페이지의 현재 게시일 표기는 2024-03-08이며, 이 날짜를 기능 최초 출시일로 사용하지 않는다. [Apple: macOS Catalina 10.15.4 업데이트](https://support.apple.com/en-gb/106549)

표정으로 클릭하는 대체 포인터 동작은 적어도 **macOS Monterey 12** 버전의 공식 가이드에 명시되어 있다. 이번 조사로 표정 동작의 정확한 최초 도입 버전까지 확정하지는 않았다. [Apple: macOS 12의 Mouse Keys 가이드](https://support.apple.com/guide/mac-help/control-the-pointer-using-mouse-keys-mh27469/12.0/mac/12.0)
