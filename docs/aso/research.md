# AirTouch ASO 적용 조사

확인일: 2026-09-17. Apple 공식 문서, Applyra 공식 사이트·공개 소스만 사용했다. 계정 로그인, 유료 API 호출, MCP 설치, 예약 실행, 스토어 메타데이터 변경은 하지 않았다.

현재 프로젝트는 v0.4.0 로컬 개발 서명 설치본이다. 공개 Mac App Store 상품 페이지와 App Store Connect 실적은 이번 조사에서 확인하지 않았다. 따라서 아래는 출시 준비와 측정 설계이며, 이미 색인되거나 순위·설치가 개선됐다는 기록이 아니다. 로컬 배포 상태는 [README](../../README.md)와 [구현 현황](../implementation-status.md)에 근거한다.

## 적용 방향

사용자가 제안한 **검색 의도와 실제 기능의 일치 → 전환 확인 → 경쟁 가능한 검색어 확장** 순서를 채택한다. Apple도 이름·부제·키워드·카테고리의 관련성과 다운로드·평점·리뷰 등의 행동 신호를 검색 요소로 설명한다. 다만 Apple은 필드별 가중치나 ‘상위 10위 진입 확률’ 공식을 공개하지 않는다. AirTouch 후보를 상위 10위 가능성이 검증된 키워드로 표시하지 않는다. [Apple 검색 안내](https://developer.apple.com/app-store/search/)

‘MacBook 카메라로 손동작 마우스 조작’처럼 현재 제품과 직접 맞는 표현부터 시작한다. 눈 추적·음성 제어·원격 제어·모든 트랙패드 제스처·지연 없음 등 다른 기능이나 미확인 성능을 검색어 확보용으로 넣지 않는다. 실제 기능 범위와 검증 한계는 [v0.4.0 검증 기록](../verification/v040-personal-control.md)에 맞춘다.

## 메타데이터와 현지화

| 항목 | 공식 규칙·확인 범위 | AirTouch 적용 |
| --- | --- | --- |
| 이름 | 2–30자, 현지화 가능. 제출 후 변경 가능 시점은 버전·상태에 좌우됨 | 브랜드와 핵심 기능을 한 문장 안에 배치 |
| 부제 | 최대 30자 | 카메라·Mac 조작이라는 사용 조건과 기능 설명 |
| 설명 | 최대 4,000자, 일반 텍스트, 현지화 가능 | 실제 이동·클릭·스크롤 장면과 권한·사용 조건 설명 |
| 키워드 | ASC 필드 문서는 최대 **100바이트**, 검색 가이드는 **100자**라고 표기 | 두 제한을 모두 검사하고 한글은 UTF-8 100바이트 이내로 작성 |
| 카테고리 | 검색 색인 요소. macOS의 ASC 기본 카테고리는 Xcode 설정과 일치해야 함 | 실제 용도에 맞는 카테고리만 선택 |

이름·부제·Mac 카테고리 규칙: [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information). 설명·키워드 규칙: [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information). 100자 표기와 검색 요소: [App Store search](https://developer.apple.com/app-store/search/).

키워드는 쉼표로 구분하고 쉼표 뒤 공백을 낭비하지 않는다. 이름·부제·카테고리에 이미 사용한 단어, 경쟁사 앱 이름, 무관한 용어를 되풀이하지 않는다. Apple은 프로모션 문구가 검색 순위에 영향을 주지 않는다고 명시한다. 따라서 설명·프로모션 문구는 이해와 전환을 위한 카피로 작성하고, 키워드 반복에 따른 검색 순위 상승을 주장하지 않는다. [Apple 검색 안내](https://developer.apple.com/app-store/search/)

한국어와 영어 메타데이터를 별도로 관리할 수 있다. Apple 표에서 한국 스토어의 기본 언어는 Korean, 추가 지원 언어는 English (U.K.)다. 실제 표시 언어는 스토어·기기 언어·추가한 현지화·기본 언어의 영향을 받는다. 이 표는 **표시 언어 지원표**이므로, 다른 언어 필드에 넣은 모든 단어가 한국 검색에 함께 색인된다는 근거로 사용하지 않는다. [App Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations)

## Mac에서 측정할 수 있는 것

App Store Connect의 acquisition 분석은 macOS 앱도 지원한다. 대시보드 문서는 노출·상품 페이지 조회에 macOS 10.14.1 이상, 사용 지표에는 macOS 11 이상을 명시한다. 사용 지표는 분석 공유에 동의한 사용자 데이터다. 로컬 개발 앱 실행 기록을 이 스토어 실적으로 대체할 수 없다. [Analytics 소개](https://developer.apple.com/app-store-connect/analytics/), [대시보드와 제공 범위](https://developer.apple.com/help/app-store-connect-analytics/overview/analytics-dashboard)

| 기록할 지표 | 정확한 해석 |
| --- | --- |
| Impressions (Unique Devices) | 앱을 본 고유 기기 수. 고유 기기 지표를 일별 합산해 주간 고유 기기 수로 만들지 않음 |
| First Time Downloads | 첫 다운로드 수. 신규 획득의 주된 확인값 |
| Total Downloads | 첫 다운로드 + 재다운로드 |
| Conversion Rate | 총 다운로드와 사전 주문을 고유 기기 노출로 나눈 공식 지표. 사전 주문은 후속 다운로드 때 중복 계산하지 않음 |
| Product Page Views | 상품 페이지 방문. 검색 결과에서 직접 다운로드할 수도 있어 모든 다운로드가 이 단계를 거쳤다고 가정하지 않음 |
| Installations | 다운로드 지표와 별개인 실제 설치 usage 지표. 동의한 사용자 범위이며 재설치·다른 기기 설치 등이 포함됨 |

지표 정의와 제공 최소량은 [Metric definitions](https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions)에 따른다. 앱스토어 지표는 적어도 첫 다운로드 또는 사전 주문 5회, 다운로드 지표는 첫 다운로드 5회 이후 제공된다. 사용 지표는 선택 기간의 활성 기기 5대 이상이 필요하다. 조회수 대비 신규 다운로드를 별도로 계산하면 **자체 정의 지표**로 표시하고 Apple의 Conversion Rate와 같은 이름을 쓰지 않는다.

### ‘키워드별 노출 → 설치’는 현재 확보 가능한 실적과 다르다

Apple의 `Source Type = App Store search`는 검색에서의 조회·다운로드를 집계하며, **검색 광고의 조회·다운로드도 포함**한다. 확인한 공개 Analytics 차원은 소스 유형·지역·기기·상품 페이지 등을 제공하지만, 개별 자연 검색어별 노출·다운로드 차원은 명시하지 않는다. 따라서 AirTouch 보고서의 `organic_keyword_installs`는 자료가 실제 확보되기 전까지 `null / 제공 확인 안 됨`으로 두고, 검색 유입 전체를 특정 단어의 성과로 배분하지 않는다. [Acquisition](https://developer.apple.com/help/app-store-connect-analytics/acquisition/acquisition), [Filters and dimensions](https://developer.apple.com/help/app-store-connect-analytics/reference/filters-and-dimensions)

Apple Ads에는 키워드·검색어 성과 보고서가 따로 있다. 이것은 광고 캠페인의 보고 기능이며 자연 검색어 실적의 대체 자료가 아니다. 해당 기능 존재만으로 Mac 전용 앱 광고 운영까지 지원된다고 가정하지 않는다. [Apple Ads 보고서](https://developer.apple.com/documentation/apple-ads-platform-api/apps-reports-endpoints)

실제 운영에서는 **검색어별 순위 관측표**와 **Mac·국가·기간·소스별 ASC 획득표**를 함께 읽는다. 같은 시기에 순위와 다운로드가 올라도 해당 검색어가 설치 증가를 일으켰다고 단정하지 않는다. 이 구분은 위 데이터 범위에 근거한 AirTouch 측정 설계다.

## macOS에서 그대로 쓸 수 없는 상품 페이지 실험

- **Product Page Optimization:** Apple은 iOS/iPadOS 앱과 iOS/iPadOS 15 이상 고객을 대상으로 명시한다. 아이콘·스크린샷·미리보기의 최대 3개 변형을 시험하는 기능이다. 현재 native macOS AirTouch의 실험 도구로 계획하지 않는다. [PPO 공식 지원 범위](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/overview-of-product-page-optimization)
- **Custom Product Pages:** 공식 제공 범위도 iOS/iPadOS 15 이상이다. 키워드를 연결한 맞춤 페이지와 페이지별 분석이 존재하지만 Mac App Store에서도 같은 흐름을 쓸 수 있다는 뜻은 아니다. [CPP 공식 지원 범위](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions)

AirTouch는 출시 후 기본 상품 페이지의 변경 이력과 동일한 국가·기기·기간 기준의 전후 지표를 비교한다. 동시에 여러 요소를 바꾸지 않고, 광고·가격·업데이트 변경도 함께 기록한다. 이것은 무작위 A/B 테스트가 아니므로 결과는 탐색적 비교로 표시한다. 외부 소개 페이지에서 실험하더라도 웹 방문·다운로드 클릭 성과와 Mac App Store 설치 성과를 구별한다.

## Applyra MCP: 존재 확인과 Mac 지원 한계

공식 MCP는 존재한다. 안내 페이지는 [Applyra MCP](https://www.applyra.io/features/mcp-server), 공개 저장소는 [applyra-io/mcp-server](https://github.com/applyra-io/mcp-server)다. 공식 README는 Node.js 20 이상, Unlimited 요금제, Applyra 계정의 API 키를 요구하며 발급 위치는 [계정 API 페이지](https://www.applyra.io/dashboard/api)다. 이번에는 가입·결제·키 발급·설치를 진행하지 않았다. [공식 README](https://github.com/applyra-io/mcp-server/blob/main/README.md)

공개 구현은 `@applyra/mcp-server`를 실행하는 **stdio MCP**다. 원격 MCP 서버 주소가 아니다. 환경 변수 `APPLYRA_API_KEY`를 읽고, 기본 REST 주소 `https://www.applyra.io/api/v1`에 `X-API-Key` 헤더로 요청한다. Apple의 App Store Connect 인증 키와는 다른 자격 증명이다. [공식 서버 소스](https://github.com/applyra-io/mcp-server/blob/main/src/index.ts)

| 기능 | 공개 문서에서 확인된 범위 | AirTouch 판단 |
| --- | --- | --- |
| 키워드 관측 | 순위·이력·경쟁 앱·자동완성·difficulty/traffic 점수 | Mac 지원을 먼저 확인한 뒤 후보 조사에 사용 |
| 스토어 구분 | 공개 스키마는 `ITUNES`, `GPLAY`; 제품 설명은 iOS/Android·mobile apps | native Mac App Store 순위 지원을 확인한 것으로 보지 않음 |
| 플랫폼 선택 | 공개 검색·순위 도구에 macOS/device 선택 인자가 없음 | iPhone 결과를 Mac 결과로 기록하지 않음 |
| 점수 | difficulty/traffic은 0–100 점수, keyword rank는 일별 스냅샷 | 점수를 검색량·실제 노출·설치 수로 변환하지 않음 |
| 메타데이터 게시 | 공개 20개 도구는 조사·추적·계정 사용량 범위 | ASC 키워드 게시·앱 심사 제출·자동 업데이트 도구로 취급하지 않음 |

근거: [Applyra 제품 안내](https://www.applyra.io/)의 iOS/Android 소개, [공개 도구 목록](https://github.com/applyra-io/mcp-server/blob/main/README.md), [플랫폼 스키마와 반환값 설명](https://github.com/applyra-io/mcp-server/blob/main/src/index.ts). 점수·지원 여부의 해석은 해당 공개 범위에 근거한 판단이다. 백엔드의 비공개 기능까지 없다고 단정하지 않는다.

사용 전 필요한 확인은 **Mac 전용 앱 ID를 지정한 결과**, **동일 국가의 Mac App Store 실제 검색 결과와 일치하는지**, **순위 관측 시각과 조회 범위**다. 공급자가 Mac 지원을 확인하기 전에는 도구 도입을 보류하고 후보·의도·메타데이터 매핑을 로컬에서 준비한다. Applyra의 조사 호출 중 `inspect_keyword`, `run_autocomplete`, `run_niche_analysis`는 공개 소스에서 이력 기록이나 할당량 소비가 있는 작업으로 표시돼 있다. 읽기처럼 보인다는 이유로 무료·무변경 호출이라고 취급하지 않는다. [공식 서버 소스](https://github.com/applyra-io/mcp-server/blob/main/src/index.ts)

## AirTouch 실행 기준

1. 현재 기능과 직접 맞는 후보 5개를 **조사 우선순위**로 좁힌다. 순위·검색량·난이도는 미관측 값으로 남긴다. 이름·부제·키워드 필드에 들어간 위치와 언어를 기록한다.
2. Mac 배포 경로와 공개 상품 페이지가 확정되면 국가·Mac 플랫폼·관측 시각을 맞춰 검색 노출을 확인한다. 상위 조회 범위에 없는 결과와 조회 실패를 별도로 기록한다.
3. ASC에서 같은 기간의 검색 소스 고유 노출·첫 다운로드·총 다운로드·공식 전환율을 확보한다. 광고 포함 여부와 데이터 부족을 표시한다.
4. 매주 검토할 경우 순위 변화와 획득 지표를 검토하고 메타데이터 변경 **초안**을 만든다. 충분한 자료가 없으면 변경을 강제하지 않는다. 한 차례의 상승만으로 인기 검색어까지 확장하지 않는다.
5. Applyra Mac 지원·계정 연결·실제 지표 접근을 확인한 뒤에만 연동을 구체화한다. 주간 검토 절차와 실제 예약 작업 생성은 별개이며, 이번 조사에서는 예약 작업을 만들지 않았다.

위 실행 기준은 AirTouch의 제안 운영 규칙이다. Apple·Applyra가 보장하는 순위 상승 공식이나 확인된 시장 수요가 아니다.
