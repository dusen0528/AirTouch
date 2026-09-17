# 손 이동 + 얼굴 동작: 네이티브 macOS SDK 검토

확인일: 2026-09-17. 대상: AirTouch의 macOS 14 이상, MacBook 내장 카메라. Apple 공식 문서와 설치된 macOS 26.4 SDK를 대조했다. 앱 소스·설정·권한은 변경하지 않았으며 카메라·사진·시스템 입력을 실행하지 않았다.

## 결론

**손으로 커서를 움직이고 얼굴 동작으로 클릭 등을 보조하는 구현은 공개 macOS API로 시도할 수 있다.** 첫 후보는 Vision의 눈·입 랜드마크다. Core Image에는 웃음과 좌우 눈 감김을 직접 반환하는 API도 있어 비교 후보가 된다. 어느 쪽도 현재 AirTouch에서 인식률, 지연, 피로도를 측정하지 않았으므로 사용감 개선을 확정할 수는 없다.

| 후보 | 네이티브 macOS 지원 | 얻는 값 | 판단 |
| --- | --- | --- | --- |
| `VNDetectFaceLandmarksRequest` | macOS 10.13+ | 눈·눈썹·입술 등의 2D 좌표 | 새 구현의 우선 후보. 동작 판정과 개인별 보정은 앱에서 구현 |
| `VNFaceObservation` 자세 | roll/yaw 10.14+, pitch 12+ | 선택적 라디안 각도 | 고개 방향으로 감지 유효성을 제한하거나 보조 동작을 검토할 수 있음 |
| `CIDetector` + smile/eyeBlink | 검출기 10.7+, 해당 옵션 10.9+ | 웃음, 왼눈 감김, 오른눈 감김 `Bool` | 지원되는 비교 후보. Apple은 새 특징 분석에 Vision을 안내 |
| `ARFaceTrackingConfiguration` / `ARFaceAnchor.blendShapes` | 해당 API의 공식 지원은 iOS/iPadOS | 얼굴 부위별 연속 계수 | 현재 네이티브 MacBook 앱에서 사용할 후보가 아님 |

지원 버전과 기능은 [Vision 얼굴 랜드마크 요청](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest), [얼굴 관찰 결과](https://developer.apple.com/documentation/vision/vnfaceobservation), [Core Image 검출기](https://developer.apple.com/documentation/coreimage/cidetector), [웃음 옵션](https://developer.apple.com/documentation/coreimage/cidetectorsmile), [눈 감김 옵션](https://developer.apple.com/documentation/coreimage/cidetectoreyeblink), [ARKit 얼굴 추적 구성](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration)의 문서와 SDK 선언을 확인했다.

## Vision으로 가능한 범위

`VNDetectFaceLandmarksRequest`는 얼굴을 찾고 각 얼굴의 특징점을 `VNFaceObservation.landmarks`에 채운다. 이미 찾은 얼굴을 `inputFaceObservations`로 제공할 수도 있다. `leftEye`, `rightEye`, `innerLips`, `outerLips` 등을 읽을 수 있으며, 좌표는 **해당 얼굴 경계 상자**에 대해 정규화되고 원점은 왼쪽 아래다. 화면 전체 정규화 좌표나 미리보기의 좌우 반전 좌표로 바로 사용하면 안 된다. [요청 동작](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest), [좌표 정의](https://developer.apple.com/documentation/vision/vnfacelandmarks2d).

이 API가 제공하는 것은 특징점이다. 검토한 공개 속성에는 `smileProbability`나 `eyeBlinkLeft` 같은 표정 점수는 없다. 눈의 세로·가로 비율, 입 벌어짐, 중립 상태 대비 변화로 동작을 추정하려면 별도 판정과 검증이 필요하다. 특정 점 인덱스나 점 개수를 가정하기 전에 요청 revision과 constellation을 고정하고 지원 여부를 확인해야 한다.

macOS 14에서 사용할 수 있는 Revision 3는 65점과 76점 constellation을 지원한다. **요청 클래스 자체는 현재 deprecated가 아니며**, Revision 1 상수가 macOS 13부터 deprecated다. 이번 컴파일 샘플은 Revision 3를 선택하고 `revision(_:supportsConstellation:)`를 확인한 뒤 76점을 요청했다. 이 선택이 실제 인식 정확도나 속도 우위라는 뜻은 아니다. 근거: 설치 SDK의 `Vision.framework/Headers/VNDetectFaceLandmarksRequest.h`.

`roll`, `yaw`, `pitch`는 선택값이다. SDK는 얼굴 사각형 검출 요청이 이 각도를 채우며, 계산하지 않은 경우 `nil`이라고 설명한다. 누락을 0도인 정상 자세로 처리하지 않아야 한다. 랜드마크의 각 영역도 누락될 수 있다. `confidence`나 `faceCaptureQuality`를 웃음·눈 감김 확률로 해석해서도 안 된다. [VNFaceObservation](https://developer.apple.com/documentation/vision/vnfaceobservation).

## Core Image의 직접 표정 신호

`CIDetectorTypeFace` 검출기를 만들고 `features(in:options:)`를 호출할 때 다음 옵션을 켜야 한다.

```swift
[
    CIDetectorSmile: true,
    CIDetectorEyeBlink: true,
    CIDetectorImageOrientation: orientation.rawValue
]
```

결과의 `CIFaceFeature.hasSmile`, `leftEyeClosed`, `rightEyeClosed`는 `Bool`이다. 옵션을 켜지 않은 결과의 `false`를 정상 표정이라는 증거로 사용해서는 안 된다. 검출기 생성 실패, 얼굴 없음, 좌우 눈 감김, 웃음을 구분해야 한다. 또한 한 프레임의 눈 감김은 의도적인 윙크나 클릭 명령과 동일하지 않다. [웃음 옵션](https://developer.apple.com/documentation/coreimage/cidetectorsmile), [눈 감김 옵션](https://developer.apple.com/documentation/coreimage/cidetectoreyeblink), [CIFaceFeature](https://developer.apple.com/documentation/coreimage/cifacefeature).

Apple은 macOS 10.13 이상에서 이미지 특징 분석에 Vision이 이 클래스들을 대체한다고 안내한다. 다만 2026-09-17 확인한 문서의 플랫폼 메타데이터와 macOS 26.4 헤더에서 `CIDetector` 및 해당 smile/eyeBlink 옵션은 **deprecated로 선언되어 있지 않다**. 따라서 “macOS에서 안 된다” 또는 “deprecated라 컴파일할 수 없다”는 결론은 부정확하다. 재사용 가능한 검출기이며 Apple도 인스턴스 재사용을 권한다. 얼굴·표정 검출을 추가하면 처리 비용이 생기므로 기존 손 추적과 병행한 측정이 필요하다. [CIDetector](https://developer.apple.com/documentation/coreimage/cidetector).

## ARKit 예제를 가져오면 안 되는 이유

ARKit의 `blendShapes`는 `eyeBlinkLeft`, `eyeBlinkRight`, `jawOpen` 등 얼굴 부위의 움직임을 중립 0에서 최대 1 사이 계수로 제공한다. 그러나 `ARFaceTrackingConfiguration`와 해당 `blendShapes`의 공식 문서 플랫폼 목록은 iOS/iPadOS다. Apple Neural Engine을 갖춘 iOS 기기에서 TrueDepth 요구가 완화되었다는 설명을 MacBook 내장 카메라 지원으로 확대 해석하면 안 된다. [얼굴 추적 지원 조건](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration), [블렌드셰이프 정의](https://developer.apple.com/documentation/arkit/arfaceanchor/blendshapes).

설치 SDK에는 iOS SDK 및 macOS SDK의 `System/iOSSupport` 계층에 관련 헤더가 있다. **`import ARKit`만 성공하는 것은 얼굴 추적 API를 네이티브 macOS에서 사용할 수 있다는 증거가 아니다.** 실제 macOS 14 대상 검사에서 `ARFaceTrackingConfiguration()`와 `ARFaceAnchor.BlendShapeLocation.eyeBlinkLeft`는 모두 `cannot find ... in scope`로 실패했다. Mac Catalyst나 iPhone 앱 실행 환경을 현재 SwiftUI/AppKit 앱과 혼동하지 않는다.

## AirTouch에 적용하기 전의 판단 기준

다음은 SDK가 보장하는 기능이 아닌 구현·검증 제안이다.

1. 기존 손 이동을 유지하고, 얼굴 신호는 먼저 연습 화면에서만 표시한다. 처음에는 한 가지 보조 동작을 골라 인식 성공·놓침·의도하지 않은 감지를 비교한다.
2. 얼굴의 중립 상태를 보정하고, 동작 유지와 중립 복귀를 각각 확인해 한 번만 명령을 만든다. 자연스러운 양눈 깜박임을 즉시 클릭에 연결하지 않는다. 안경·말하기·웃기·고개 돌리기도 비교한다.
3. 얼굴 결과가 늦거나 사라지면 명령을 만들지 않는다. 명령에 쓸 얼굴 결과의 시각을 손 결과와 별도로 확인하고, 얼굴 검출 대기 때문에 손 이동 입력을 늦추지 않도록 구성한다.
4. 동일한 실제 입력 해상도에서 손만 처리한 경우와 손+Vision, 손+Core Image를 비교한다. 손의 캡처→입력 지연 중앙값/p95, 드롭 수, 얼굴 처리 시간, 의도하지 않은 동작 수, 각 동작 성공률을 함께 본다. 얼굴 신호를 추가한 상태의 성능을 기존 벤치마크로 대신하지 않는다.

얼굴 랜드마크 검출과 macOS에 이미 내장된 얼굴 제스처 기능은 별개다. 이번에 확인한 API는 AirTouch가 자체 영상을 분석하는 수단이며, 시스템의 얼굴 제스처 판정 결과를 구독하는 공개 API를 확인한 것은 아니다.

## 컴파일 검증

macOS 26.4 SDK에서 `arm64-apple-macos14.0` 대상으로 검사했다. 실행 파일은 만들거나 실행하지 않았다.

| 검사 | 결과 |
| --- | --- |
| Vision 요청, Revision 3/76점 지원 확인, 눈·입 좌표, yaw/pitch/roll | `-typecheck -warnings-as-errors` 통과 |
| `CIDetector` 생성, smile/eyeBlink 옵션, 세 개의 `Bool` 속성 | 같은 검사 통과 |
| `import ARKit`만 사용 | 통과. 해당 얼굴 API 지원 검증으로는 불충분 |
| `ARFaceTrackingConfiguration`, `ARFaceAnchor.BlendShapeLocation.eyeBlinkLeft` | 예상대로 native macOS 대상에서 타입을 찾지 못함 |

검사 샘플은 `/tmp/airtouch-face-sdk-typecheck.swift`, 부정 검사는 `/tmp/airtouch-arkit-native-macos-typecheck.swift`에 작성했다. 컴파일 통과는 API 가용성의 증거이며 실제 카메라 인식·동작 정확도·OS 입력 성공의 증거는 아니다.

재현용 최소 샘플을 위 경로에 저장한 뒤 아래 명령으로 검사할 수 있다. 함수는 호출하지 않는다.

```swift
import CoreImage
import CoreVideo
import ImageIO
import Vision

func checkAPIs(_ buffer: CVPixelBuffer,
               orientation: CGImagePropertyOrientation) throws {
    let request = VNDetectFaceLandmarksRequest()
    request.revision = VNDetectFaceLandmarksRequestRevision3
    if VNDetectFaceLandmarksRequest.revision(request.revision,
                                             supportsConstellation: .constellation76Points) {
        request.constellation = .constellation76Points
    }
    try VNImageRequestHandler(cvPixelBuffer: buffer,
                             orientation: orientation).perform([request])
    for face in request.results ?? [] {
        _ = [face.landmarks?.leftEye?.normalizedPoints,
             face.landmarks?.rightEye?.normalizedPoints,
             face.landmarks?.innerLips?.normalizedPoints,
             face.landmarks?.outerLips?.normalizedPoints]
        _ = [face.roll, face.yaw, face.pitch]
    }
    let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
                             options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cvPixelBuffer: buffer), options: [
        CIDetectorSmile: true, CIDetectorEyeBlink: true,
        CIDetectorImageOrientation: orientation.rawValue
    ]) ?? []
    for case let face as CIFaceFeature in features {
        _ = [face.hasSmile, face.leftEyeClosed, face.rightEyeClosed]
    }
}
```

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx swiftc \
  -typecheck -warnings-as-errors -target arm64-apple-macos14.0 \
  /tmp/airtouch-face-sdk-typecheck.swift
```
