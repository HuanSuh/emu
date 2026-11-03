# 타임라인 설계 메모

> 상태: 설계 확정 중(구현 전). Q4·Q5·Q9·Q11 은 메인테이너가 결정했다(2026-11-03, §11). 이슈 [#89](https://github.com/HuanSuh/emu/issues/89).
> 이 문서는 합의용이다. 여기 적힌 명령·API는 아직 없다.

## 1. 결론 요약

- **저장은 하나로.** 로그·요청·화면 전환·기기 조작을 전부 `LogStore` 의 같은 seq 에 넣고,
  `LogEntry` 에 선택 필드 `kind`/`route`/`data` 를 더한다. 목 트래픽이 이미 이렇게 들어가 있다.
- **기존 소비자는 그대로.** 새 종류(`route`, `action`)는 `/api/logs` 기본 응답에서 빠진다.
  `emu assert --log` 가 `emu tap --text Login` 의 기록에 걸리는 오탐을 막기 위해서다.
- **스파이크 결과: `Flutter.Navigation` 만으로는 부족하다.** 이벤트는 있지만 선언형 Navigator
  (`go_router` 의 `go`/`push`)에서는 나가지 않고, pop 에서는 *닫힌* 라우트를 알려 준다(§3).
- **그래서 라우트 감지는 두 층.** 앱 코드 변경 없는 층(`Flutter.Navigation` + 공개 API 스냅샷)과,
  앱이 `dart:developer` 로 직접 보내는 정확한 층(`Emu.Route` 이벤트)을 함께 둔다(§6).
  `Emu.Route` 는 emu 패키지 의존 없이 쓰는 **이벤트 계약**으로 문서화한다(§6.4).
- **이슈 리포터 피드백을 반영했다(§13).** `go_router` 앱, emu 패키지 의존 불가, 탭이 라우트가 아님,
  실제 경로와 라우트 이름을 함께 원함. 그래서 앱이 보내는 층을 먼저 구현한다(§10).
- **화면 수집은 켜야 동작한다(Q9).** 라우트를 받는 장기 VM Service 연결은 `emu.yaml` 의
  `timeline.routes: true`(제안 이름)로 켤 때만 연다. 기본은 꺼짐이고, 꺼져 있으면 지금과 똑같이 동작하며
  타임라인에는 로그·요청·조작만 나오고 화면 칸은 비어 있다. 비어 있는 이유는 CLI·대시보드가 알려 준다(§6.5).
- **`emu routes` 보류 사유는 해소되지 않았다.** 타임라인은 전체 스택이 필요 없어 그 문제를 피해 갈
  뿐이다(§12).

## 2. 목표와 범위 밖

목표:

- G1. 앱 로그, 목 서버를 지난 요청(목업 여부 포함), 화면 전환을 한 목록에서 시간 순으로 본다.
- G2. 기록마다 그 순간의 화면(라우트 이름 정도)을 붙인다.
- G3. 에이전트가 같은 목록을 `--json` 으로 읽는다.
- G4. 기존 `/api/logs`, `emu logs`, `emu assert`, `/api/errors`, `run.jsonl` 의 동작을 바꾸지 않는다.

범위 밖:

- **`mocks:` 설정이 없는 앱의 요청 캡처.** 지금 요청은 `emu_hook` 또는 base URL 로 emu 를 지난 것만
  보인다. DevTools 의 HTTP 프로파일 같은 별도 수집 경로는 다루지 않는다.
- **전체 Navigator 스택 덤프**(`emu routes`, §12).
- **타임라인 기반 판정.** 조회만 하고 "이 화면이어야 한다" 같은 단언은 넣지 않는다(B1).
- **요청 본문 저장.** 본문은 지금처럼 `MockHit` 에 두고 타임라인은 `hitId` 로 가리킨다.

## 3. 스파이크: `Flutter.Navigation`

소스 읽기로만 확인했다. 앱을 실행하지 않았다. 기준은 Flutter 3.44.4
(`packages/flutter/lib/src/widgets/navigator.dart`, 이하 `navigator.dart`)이고,
3.32.7 도 같은 구조다(`_afterNavigation` 5064행 부근).

### 3.1 확인한 것

| 항목 | 결과 | 근거 |
|---|---|---|
| 이벤트 발행 | `developer.postEvent('Flutter.Navigation', {'route': routeJsonable})` | `navigator.dart:5126` |
| 조건 | `if (!kReleaseMode)` — debug·profile 에서 나가고 release 에서는 안 나간다 | `navigator.dart:5097` |
| payload | `route: {description, settings: {name, arguments?}}`, `route` 자체가 null 일 수 있다 | `navigator.dart:5102-5124` |
| `description` | `TransitionRoute` 면 `debugLabel`(런타임 타입, 예: `MaterialPageRoute<dynamic>`), 아니면 `'$route'` | `navigator.dart:5107-5112`, `routes.dart:642` |
| `arguments` | `jsonEncode` 한 문자열, 인코딩 안 되는 값은 `toString` | `navigator.dart:5117-5122` |
| 받는 쪽 | `Extension` 스트림. 리스너가 없으면 사실상 no-op 이고 재전송도 없다 | `dart-sdk/lib/developer/extension.dart:128-132` |
| 도입 시점 | 이벤트 2018-10-17(#23126), route payload 2019-06-15(#34508), `kReleaseMode` 조건 2019-02-06(#27502) | 로컬 SDK `git log` |

버전 게이트는 필요 없다. 다만 프레임워크 테스트(`packages/flutter/test`)와 `flutter_tools` 에
이 이벤트 이름이 나오지 않아, 코드 주석에 언급된 성능 도구 용도 외에 공개 계약이라고 할 근거는 없다.
이름이나 payload 가 바뀌면 조용히 안 오게 되므로 파서는 관대해야 한다.

### 3.2 호출되는 곳과 안 되는 곳

`_afterNavigation` 호출은 아래 6곳이 전부다.

| 경로 | 위치 | 이벤트의 `route` |
|---|---|---|
| `push` | `navigator.dart:5093` | 새 라우트 |
| `pushReplacement` | `:5233` | 새 라우트 |
| `pushAndRemoveUntil` | `:5335` | 새 라우트 |
| `replace` | `:5417` | 새 라우트(교체 대상이 현재 라우트일 때만) |
| `pop` | `:5634` | **닫힌 라우트** |
| `removeRoute` | `:5709` | 남은 맨 위 라우트, 없으면 null(지운 라우트가 현재 라우트일 때만) |

스파이크로 드러난 제약은 네 가지다.

1. **선언형 경로는 이벤트가 없다.** `pages` 가 바뀌면 `didUpdateWidget` → `_updatePages` →
   `_flushHistoryUpdates` 로 가는데(`navigator.dart:4023`, `:4131`, `:4423`), 이 경로에
   `_afterNavigation` 이 없다. `NavigatorObserver` 는 이 경로에서도 불린다
   (`_NavigatorPushObservation`, `:3219`, `:3278`).
2. **연산 종류가 payload 에 없다.** push 인지 pop 인지 구분할 필드가 없고, pop 이면 지금 화면이 아니라
   닫힌 화면이 온다. `pushAndRemoveUntil` 은 몇 개가 빠졌는지도 알 수 없어, 이벤트만으로 스택을
   따라 만들 수 없다.
3. **어느 Navigator 인지 없다.** 중첩 Navigator 의 이벤트가 구분 없이 섞인다.
4. **첫 화면 이벤트가 없다.** 초기 라우트는 이 6곳을 지나지 않고, 구독 전 이벤트는 사라진다.
   hot restart 뒤에도 다음 전환까지 현재 화면을 모른다.

다이얼로그·바텀시트도 라우트라서 이벤트가 나간다. 이름 없는 `MaterialPageRoute` 는
`settings.name` 이 null 이고 `description` 은 타입 이름뿐이라 화면을 구분하지 못한다.

### 3.3 go_router

`go_router` 16.2.4, 7.0.0 소스 기준(`~/.pub-cache`).

- **페이지 이름**: `name: state.name ?? state.path` (`builder.dart:398`, 7.0.0 은 `:399`).
  `GoRoute(name:)` 이 있으면 그 값이고, 없으면 그 라우트의 **상대 경로 패턴**이다(`details` 또는
  `/user/:id`). 전체 경로(`fullPath`)도, 실제 위치(`/user/42`)도 아니다.
- **인자**: path·query 파라미터가 `arguments` 로 들어간다(`builder.dart:399-402`). 민감한 값이 있을 수
  있어 기본 저장하지 않는다.
- **`go`/`push`/`replace`**: `routeInformationProvider` 값을 바꾸고 → `setNewRoutePath` → `pages` 재빌드로
  이어지는 선언형 경로다(`router.dart:357`, `:401`, `delegate.dart:223`, `:319-320`).
  **`Flutter.Navigation` 이 나가지 않는다.**
- **pop**: `delegate.pop`·`popRoute` 는 `NavigatorState.pop`/`maybePop` 을 부른다(`delegate.dart:60`, `:107`).
  **이벤트가 나가지만 닫힌 라우트다.**
- **탭 전환**: `StatefulShellRoute` 의 `goBranch` 는 `restore`/`go` 로 간다(`route.dart:1493-1501`).
  이벤트가 없고, push 도 아니라 `NavigatorObserver` 로도 잡기 어렵다.
- **observer**: 루트(`GoRouter(observers:)`), `ShellRoute.observers`, `StatefulShellBranch.observers` 에
  각각 넣어야 한다(`route.dart:763`, `:1151`).
- **믿을 만한 현재 위치**: `router.routeInformationProvider.value.uri`, 또는
  `routerDelegate` 리스너. `go`/`restore`/pop 을 모두 지난다(`information_provider.dart:141`, `:161`,
  `delegate.dart:193`, `:320`). `RouteInformationProvider` 는 프레임워크 공개 API 다
  (`router.dart:1465`, `Router.maybeOf` `:507`).

- **라우트가 아닌 탭**: 하단 탭을 `IndexedStack` 같은 화면 내부 상태로 바꾸는 앱도 있다(이슈 리포터의 앱).
  이 경우 라우트 정보가 아예 바뀌지 않으므로 어떤 라우트 기반 방법으로도 잡을 수 없고, 앱이 알려 줘야 한다.

즉 이슈의 "VM Service 로 읽는다"는 Navigator 1.0 앱에서는 대체로 되지만, `go_router` 앱에서는
주요 전환 대부분을 놓친다.

## 4. 데이터 모델

### 4.1 단일 저장소 vs 조회 시 병합

| | 단일 저장소(추천) | 조회 시 병합 |
|---|---|---|
| 순서 | seq 하나로 끝난다 | 소스별 시각을 맞춰야 하고 동률 처리가 필요하다 |
| 수명 | 50k 링버퍼 하나 | `MockHit` 200개와 로그 50k 가 어긋난다 |
| 오프라인 | `run.jsonl` 에 그대로 남는다 | 소스마다 영속화를 따로 만들어야 한다 |
| 실시간 | 기존 WebSocket `log` 메시지 재사용 | 스트림 병합이 필요하다 |
| 호환성 | 기본 필터가 필요하다(§8) | 기존 경로를 건드리지 않는다 |
| 지금 코드 | 목 트래픽이 이미 이 방식(`server.dart:651-655`) | 없음 |

단일 저장소를 택한다. 호환성 비용은 기본 필터 하나로 막을 수 있지만, 병합은 순서·수명·영속화 문제를
매 소비자가 떠안는다.

### 4.2 `LogEntry` 확장

```dart
final String? kind;                // null = 일반 로그, 'request' | 'route' | 'action'
final String? route;               // 기록 시점의 현재 화면. 모르면 null
final Map<String, dynamic>? data;  // kind 별 구조화 데이터
```

`toJson` 은 null 필드를 내보내지 않는다(`'kind': ?kind`). 일반 로그의 JSON 은 라우트를 모르면
지금과 바이트까지 같다. `fromJson` 은 이미 추가 키에 관대하므로(`models.dart:76-82`) 옛 바이너리가 새
`run.jsonl` 을 읽어도 깨지지 않는다.

`LogStore` 에 `String? currentRoute` 를 두고 `add` 가 모든 엔트리에 찍는다. 찍는 지점이 한 곳이면
소스가 늘어도 빠지는 곳이 없다.

| kind | source | text | data |
|---|---|---|---|
| (없음) | 기존 그대로 | 기존 그대로 | 없음 |
| `request` | `mock` | `[mock] GET … → 200 …`(변경 없음) | `{hitId, method, url, status, mocked?, error?, ms, startSeq}` |
| `route` | `route` | `[route] /user/42 · feed` | `{via, location?, name?, detail?, description?}` |
| `action` | `action` | `[action] tap --text "Login"` | `{cmd, x?, y?, text?, key?, widgetType?}` |

`route`·`action` 은 레벨을 `system` 으로 명시한다. `add` 에 맡기면 `inferLevel` 이 `/error` 같은 경로를
에러로 판정한다.

### 4.3 라우트가 없는 상태

모르면 비워 둔다. 추측한 값은 찍지 않는다. `null` 은 "수집 옵션 꺼짐(기본, §6.5)", "이벤트가 아직
없음", "hot restart 직후", "재연결 중" 을 모두 포함한다. 엔트리마다 이유를 적지 않고, 수집 상태는
응답 한 곳에 따로 싣는다(§8.1).

## 5. seq 통합: 요청의 시작과 완료

지금은 요청이 **끝날 때** 엔트리가 생긴다. 응답이 느리면 그 요청이 일으킨 로그가 앞에 찍히고, 화면을
떠난 뒤에 요청이 찍히기도 한다.

| | 시작·완료 2엔트리 | 완료 1엔트리 + 시작 커서(**결정, Q5**) |
|---|---|---|
| 엔트리 수 | 2배 | 지금과 같다 |
| `[mock]` 로그 호환 | 시작 줄이 새로 보이거나 숨겨야 한다 | 변경 없음 |
| 인과 추적 | 목록에서 바로 보인다 | `data.startSeq` 로 구간을 복원한다 |
| 미완료 요청 | 보인다 | 끝날 때까지 안 보인다 |

요청을 받을 때 `startSeq = logStore.lastSeq` 와 그때의 라우트를 `MockHit` 에 보관하고, 완료 엔트리에
싣는다. **`request` 엔트리의 `route` 는 시작 시점 값으로 덮어쓴다.** "어느 화면이 이 요청을
보냈는가" 가 질문이기 때문이다. `MockServer` 는 `LogStore` 를 모르므로 생성자에
`({int seq, String? route}) Function() now` 를 넘긴다. seq 를 예약하지는 않는다. 번호는 계속 하나씩
증가하는 값으로 남겨 둔다. 화면 수집이 꺼져 있으면 시작 라우트도 null 이고, `startSeq` 는 그대로 채운다.

**순서의 한계.** seq 는 emu 서버에 도착한 순서이고 `ts` 도 도착 시각이다. 앱 로그는 데몬·logcat 을
거치고, 목 요청은 HTTP 로, 라우트는 VM Service 로 온다. 경로가 달라 수~수십 ms 앞뒤가 바뀔 수 있다
(수치는 추정이며 PR 0 에서 잰다). 문서에 "대략의 순서이며 정확한 인과가 아니다" 라고 밝힌다.
VM 이벤트의 기기 측 타임스탬프로 재정렬하지는 않는다. 기기·호스트 시계가 다르고 다른 소스에는
같은 시각이 없다.

## 6. 라우트 감지

### 6.1 옵션 비교

(e)는 스파이크에서 추가된 후보다.

| | (a) `Flutter.Navigation` | (b) `NavigatorObserver` | (c) 로그 줄 규약 | (d) private eval | (e) 공개 API eval 스냅샷 | (f) `Emu.Route` 이벤트 |
|---|---|---|---|---|---|---|
| 방식 | `Extension` 스트림 구독 | `emu_hook` observer 를 앱에 등록 | `[emu:route] /x` 줄 인식 | `_history` 등 접근 | `rootElement` 를 걸으며 `ModalRoute.of`·`isCurrent`, `Router.maybeOf` 읽기 | 앱이 `dart:developer` 의 `postEvent('Emu.Route', …)` 를 직접 호출 |
| 앱 코드 변경 | 없음 | 있음(Navigator 마다, emu 패키지 의존) | 있음 | 없음 | 없음 | 있음(한 곳, emu 패키지 의존 없음) |
| Navigator 1.0 | 시점 정확, 값은 pop 에서 부정확 | 정확 | 앱 구현 나름 | 정확 | 정확(추정) | 앱 구현 나름 |
| go_router `go`/`push` | **놓침** | 잡음(이름은 패턴) | 잡음 | 잡음 | 호출될 때만 | 잡음(실제 경로 + 이름) |
| 탭 전환(라우트 아닌 `IndexedStack` 포함) | **놓침** | 놓침 | 앱이 찍으면 잡음 | 놓침 | 놓침 | 앱이 보내면 잡음 |
| 스택 전체 | 불가 | 앱 쪽 추적 시 가능 | 불가 | 가능 | 불가 | 불가 |
| 비용 | 낮음(장기 연결 1개) | `emu_hook` 에 Flutter 의존 추가 | 낮음 | 높음(버전마다 깨짐) | 호출마다 트리 순회 | 낮음(장기 연결 1개) |
| 버전 취약성 | 낮음(비공식 이벤트) | 낮음 | 없음 | **높음** | 낮음(공개 API) | 없음(emu 소유 계약) |
| release 빌드 | 불가 | VM 연결 없이는 전달 불가 | 가능 | 불가 | 불가 | 불가 |
| 다른 로그와의 순서 | 경로가 다름 | 경로가 다름 | 같은 경로 | 경로가 다름 | 경로가 다름 | 경로가 다름 |
| 상태 | 소스로 확인 | 소스로 확인 | 자명 | 기존 보류 사유 | **미검증** | 소스로 확인 |

release 는 VM Service 가 없어 (c) 외에는 쓸 수 없다. emu 의 조작·조회도 VM Service 에 기대므로 큰 손실은 아니다.

### 6.2 추천: 두 층

두 층 모두 장기 VM Service 연결 위에서 동작하므로 **`timeline.routes` 가 켜져 있을 때만** 쓰인다(§6.5).

**1층 — 코드 변경 없음: (a)를 트리거로, (e)를 값으로.** `Flutter.Navigation` 이 오면 짧게 디바운스한 뒤
(e) 스냅샷으로 현재 화면을 읽어 `kind: route` 엔트리를 남긴다. 이벤트의 `settings.name` 은 스냅샷이
실패할 때의 기록용 힌트로만 쓴다. pop 의 닫힌 라우트를 현재 화면으로 착각하지 않기 위해서다.
스냅샷이 실패하면 `currentRoute` 는 null 이다. 같은 값이면 엔트리를 만들지 않는다.

**2층 — 앱이 직접 보냄: (f).** `go_router` 앱이나 라우트가 아닌 탭처럼 1층이 놓치는 경우를 위한
경로다. 앱은 emu 패키지 없이 `dart:developer` 의 `postEvent` 로 §6.4 계약의 이벤트를 보낸다. 전달
경로는 1층과 같은 `Extension` 스트림이라 서버 쪽 구현이 거의 늘지 않는다.

**두 층의 관계(결정, Q11).** 한 isolate 에서 `Emu.Route` 를 한 번이라도 받으면 그 뒤로는 앱이 보낸 값만
`currentRoute` 로 쓰고, 1층은 그 isolate 동안 끈다. hot restart 로 isolate 가 바뀌면 다시 1층부터
시작한다. 두 출처를 섞지 않는 이유는 1층의 pop 이벤트가 열림·닫힘을 구분하지 못해, 앱이 보낸 정확한
값을 틀린 값으로 덮을 수 있기 때문이다. 그래서 `Navigator.push` 로 띄운 모달·바텀시트도 화면에
남기고 싶다면 앱이 보내야 한다(§6.4 의 observer 예시).

(b) 대신 (f) 를 고른 이유:

- 앱이 emu 패키지에 의존하지 않아도 된다. 이슈 리포터의 앱은 외부 저장소 의존을 더할 수 없다(§13).
- `NavigatorObserver` 를 `emu_hook` 에 넣으면 지금 순수 Dart 패키지인 `emu_hook` 에 Flutter 의존이 생긴다
  (`packages/emu_hook/pubspec.yaml`).
- observer 는 Navigator 마다 등록해야 하고, 라우트가 아닌 탭 전환은 원리상 못 잡는다.
- `go_router` 의 페이지 이름은 패턴이지만 (f) 는 실제 경로와 이름을 함께 준다.

**미검증 후보.** 평가식으로 `Router` 의 `routeInformationProvider` 에 리스너를 달아 앱 코드 없이 (f) 를
흉내 낼 수 있을지도 모른다. `binding.dart` 스코프에 `developer` import 가 있어 조건은 맞지만, 평가식
클로저가 살아남는지, hot restart 뒤 다시 달 수 있는지는 실행해 봐야 안다. 된다 해도 라우트가 아닌 탭은
못 잡으므로 (f) 를 대신하지 못한다. 우선순위를 낮춰 PR 0 에서 여유가 있으면 확인한다.

### 6.3 장기 VM Service 연결

`timeline.routes` 가 켜진 세션에서만 서버가 연결 하나를 유지해 `Extension` 을 구독한다(Q9). 지금의
"명령마다 짧게 연결" 과 다르다. 꺼진 세션은 지금처럼 장기 연결이 하나도 없다.

- **불변식**: 서버가 소유하므로 I1 을 지키고, 앱을 멈추지 않으니 I4 도 지킨다(I4 는 명령 사이에 앱을
  멈추지 말라는 것이지 연결 수명 제약이 아니다). `vm_service` 는 이미 의존성이라 I3 도 그대로다.
- **수명**: 옵션이 켜져 있으면 `engine.statusStream` 의 `vmServiceUri` 변화를 따른다. URI 가 바뀌면(reattach) 다시 붙고,
  사라지면 닫는다.
- **실패**: 타임라인은 부가 기능이다. 연결 실패는 경고 한 줄로 끝내고 세션 동작에 영향을 주지 않는다.
- **필터**: 같은 스트림으로 `Flutter.Frame` 같은 다른 이벤트도 오므로 `extensionKind` 로 거른다.
- **hot restart/cold**: `currentRoute` 를 null 로 비운다.
- **공존**: 앱 하나에 VM 클라이언트 여럿이 스트림을 구독하는 것은 가능하다(DevTools 가 이렇게 쓴다).
  다만 emu 의 짧은 연결·DDS 와 함께 쓸 때를 PR 0 에서 실측한다. 기본 꺼짐이라 문제가 나와도 옵션을 켠
  세션에만 영향이 간다.
- **상태**: `off`(옵션 꺼짐) / `connecting` / `on` / `failed` 네 가지를 서버가 들고 있다가 §8.1 처럼 응답에 싣는다.

### 6.4 `Emu.Route` 이벤트 계약 (제안)

앱이 emu 의존 없이 구현할 수 있도록, 이름과 필드를 emu 가 보장하는 계약으로 둔다. 구현 시
README 두 벌에도 같은 내용을 싣는다.

- **전달**: `dart:developer` 의 `postEvent('Emu.Route', data)`. 기본 `Extension` 스트림.
  리스너가 없으면 no-op 이라 emu 없이 돌려도 비용이 거의 없다(§3.1).
- **의미**: 이벤트 하나가 "지금 화면은 이것" 이라는 **상태 보고**다. push/pop 같은 연산이 아니다.
  같은 값이 연달아 오면 emu 가 하나로 합친다.
  emu 는 앞 이벤트의 필드를 이어받지 않는다. 탭 화면으로 돌아올 때도 `detail` 까지 다시 담아 보낸다.
- **보낼 때**: 앱 시작 직후 한 번, 그리고 화면·탭이 바뀔 때마다. 시작 때 보내야 첫 화면과 hot restart
  직후의 화면이 비지 않는다.

| 필드 | 타입 | 필수 | 뜻 | 예 |
|---|---|---|---|---|
| `location` | String | 예 | 실제 경로. 재현할 때 그대로 다시 열 수 있는 값 | `/user/42?tab=posts` |
| `name` | String | 아니오 | 같은 화면끼리 묶는 이름이나 패턴 | `user` 또는 `/user/:id` |
| `detail` | String | 아니오 | 경로로 드러나지 않는 화면 내부 상태(탭, 모달 등) | `feed`, `sheet:filter` |

- **emu 의 처리**: `location` 이 문자열이 아니거나 비어 있으면 무시하고, 세션당 한 번 경고한다.
  모르는 필드는 무시한다(나중에 필드를 더해도 옛 emu 가 깨지지 않음). 각 값은 1KB 에서 자른다.
  값은 **받은 그대로** 저장한다. 민감한 값은 앱이 보내기 전에 거른다.
- **표시**: `LogEntry.route` 는 `location`, `detail` 이 있으면 `location · detail`.
  `name` 과 원래 값은 `route` 엔트리의 `data` 에 둔다.

앱 쪽 예시(`go_router` 16 기준, emu 패키지 없음):

```dart
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

void reportEmuRoute(String location, {String? name, String? detail}) {
  if (!kDebugMode) return;
  developer.postEvent('Emu.Route', {
    'location': location,
    if (name != null) 'name': name,
    if (detail != null) 'detail': detail,
  });
}

// 라우터 이동: go/push/pop, ShellRoute 안의 이동까지 지난다.
void reportCurrent() {
  final s = router.state; // 가장 깊은 leaf 의 상태
  reportEmuRoute(s.uri.toString(), name: s.name ?? s.fullPath);
}
router.routerDelegate.addListener(reportCurrent);
reportCurrent(); // 시작 직후 한 번

// 라우트가 아닌 탭: 탭 인덱스가 바뀌는 곳에서
reportEmuRoute(router.state.uri.toString(), name: router.state.name, detail: 'feed');
```

`router.state` 는 `routerDelegate.state` 이고(`router.dart:271`), 마지막 매치가 `ShellRouteMatch` 면
가장 깊은 leaf 까지 내려간다(`delegate.dart:201`, `match.dart:786-790`). `Navigator.push` 로 띄우는
모달까지 남기려면 루트 Navigator 에 앱 자체 `NavigatorObserver` 를 달아 `didPush`/`didPop` 에서
같은 함수를 부르면 된다. 이것도 Flutter API 만 쓰므로 emu 의존이 생기지 않는다.

### 6.5 수집 옵션 (결정: Q9 = B, 기본 꺼짐)

메인테이너 결정으로 장기 VM 연결은 `emu.yaml` 옵션으로만 켠다. 처음 추천(항상 켬)과 다르다.

**키 이름 제안(Q14, 열린 질문)**: 기존 키가 `mocks:`·`pages:` 처럼 기능 이름 아래 묶이므로 같은 모양을 따른다.

```yaml
timeline:
  routes: true   # 화면 전환 수집(장기 VM Service 연결). 기본 false
```

- `timeline:` 맵으로 두면 나중에 타임라인 관련 설정을 같은 자리에 더할 수 있다. 대안은 최상위 `routes: true`.
- 기존 키처럼 `profiles.<name>` 과 `emu.local.yaml` 에서도 덮어쓸 수 있다(`project_config.dart` 가 같은 맵
  파서로 읽음). 이 PC 에서만 켜는 경우를 위해서다.
- **언제 반영되나**: `mocks:` 와 같이 `emu up` 때 읽는다. 세션 중에 바꾸면 다음 `emu up` 부터 적용한다.
  세션 중 켜도 지난 전환은 얻을 수 없으므로 실익이 작다.

**꺼져 있을 때의 동작**

- 장기 연결을 열지 않는다. `Flutter.Navigation` 도 `Emu.Route` 도 받지 않는다. 앱의 `postEvent` 는
  리스너가 없으니 no-op 이다(§3.1).
- 모든 엔트리의 `route` 가 null 이고 `kind: route` 엔트리가 생기지 않는다. 요청·조작·로그는 그대로 쌓인다.
- 즉 PR 1·2 의 기능은 옵션과 무관하게 동작한다.

**사용자 안내** — 앱이 `Emu.Route` 를 보내고 있어도 emu 가 조용히 버리므로, 이유를 반드시 보여 준다.

| 어디서 | 안내 |
|---|---|
| `emu timeline` (텍스트) | 출력 끝에 한 줄 `routes: off — set timeline.routes: true in emu.yaml and run emu up again`. 기존 `mocks are off …` 안내와 같은 모양 |
| `emu timeline --json` | stdout 은 JSONL 그대로 두고 같은 안내를 stderr 로. 에이전트 파서가 깨지지 않게 |
| `/api/logs` 응답 | `routes: "off" \| "connecting" \| "on" \| "failed"` 필드를 더한다(추가 필드라 기존 소비자 무영향) |
| 대시보드 | route 열을 숨기고 Routes 칩을 비활성으로 두며, 툴팁에 켜는 방법을 적는다 |
| `failed` 일 때 | 연결 실패 경고 한 줄(§6.3)과 같은 이유를 위 자리들에 그대로 보여 준다 |
| README·SKILL.md | `Emu.Route` 계약 절 첫머리에 "emu 쪽에서 `timeline.routes` 를 켜야 받는다" 를 적는다 |

오프라인(`run.jsonl` 직접 읽기)에서는 수집 상태를 알 수 없으므로 안내를 내지 않는다.

## 7. 기기 조작을 action 엔트리로

기록한다. 에이전트에게는 "무엇을 눌렀더니 무엇이 일어났나" 가 타임라인의 핵심이다. 지금은 seq 커서만
돌려받아 조작 자체가 목록에 없다.

- **대상**: `tap`, `swipe`, `text`, `open-url`. 대시보드 클릭도 같은 API 를 지나므로 함께 잡힌다.
  `reload`/`restart` 는 이미 시스템 로그가 있어 제외한다.
- **시점**: 주입 직전에 추가한다. 조작이 일으킨 로그가 그 뒤에 오게 하기 위해서다. 실패하면 `level: error`
  인 `action` 엔트리를 하나 더 남긴다.
- **위치**: 서버의 공용 주입 경로(`_inject`, `server.dart:1337`)와 `_openUrl`(`server.dart:1260`). `--text`/`--key` 는 해석된 좌표와
  `widgetType` 까지 `data` 에 넣는다.
- **민감 정보**: `emu text` 는 입력 내용을 저장하지 않고 글자 수만 남긴다. 비밀번호를 칠 수 있고
  `run.jsonl` 은 파일로 남는다. 응답 형식은 바꾸지 않는다.

## 8. CLI·API·호환성

### 8.1 인터페이스

```
emu timeline [--since <seq>] [-n, --lines <N>] [--kind <list>] [-g, --grep <regex>]
             [-f, --follow] [--json]
```

- 기본은 네 종류 전부. `--json` 은 `emu logs --json` 과 같은 JSONL 이다.
- 서버가 없으면 `emu logs` 처럼 `run.jsonl` 에서 읽는다.
- 텍스트 출력은 `seq 시각 [route] 내용` 한 줄.

API 는 새 경로 없이 `/api/logs` 에 `kinds` 파라미터를 더한다(**결정, Q4**: 새 kind 는 기본 제외). 쿼리·토큰 검사·`limit` 이 같은 기능을
경로만 둘로 만들 이유가 없다. 필터는 `limit` 이 올바로 먹도록 클라이언트가 아니라 `LogStore.query` 에서
처리한다.

```
GET /api/logs                     → kind 없음 + request (지금과 같은 결과)
GET /api/logs?kinds=all           → 전부
GET /api/logs?kinds=route,action  → 그 종류만
```

응답에는 화면 수집 상태 `routes` 필드를 더한다(§6.5). `emu timeline` 은 이 값으로 안내 여부를 정한다.

### 8.2 영향 범위

| 소비자 | 영향 | 조치 |
|---|---|---|
| `/api/logs` 기본 응답 | `route`/`action` 제외로 결과 동일. seq 사이에 빈 번호가 생긴다 | 소비자는 `lastSeq` 커서만 쓰므로 안전 |
| `emu logs`, 오프라인 `run.jsonl` | 파일에는 전부 있다 | 파일 경로에도 같은 기본 필터 적용 |
| `emu report --attach logs` | `run.jsonl` 을 읽어 공개 이슈에 첨부할 수 있다 | 일반 로그만 첨부. 조작·라우트 기록은 빼서 지금과 같게 유지 |
| `emu assert --log` | 조작 기록 오탐 위험 | 기본 필터로 차단, 테스트로 고정 |
| `/api/errors` | `parseErrorBanners` 가 배너 구간의 줄을 합친다. 끼어든 엔트리가 본문에 섞인다 | `route`/`action` 제외하고 조회 |
| WebSocket `log` 메시지 | 새 필드와 새 엔트리가 온다 | 대시보드가 같은 바이너리에 번들되어 동시에 갱신 |
| WebSocket 초기 500줄 | 새 엔트리가 자리를 차지한다 | 영향 작음, 그대로 둠 |
| `mock-hit` 메시지, `/api/mock/*` | 변경 없음 | Debug → Mocks 는 그대로 |
| `emu mock log` | 변경 없음 | |
| 허브 | 로그를 읽지 않는다 | 변경 없음. 세션 대시보드는 그 세션 서버가 그린다 |
| 파일 크기 | 라우트 필드만큼 줄이 는다 | 50k 링버퍼는 그대로. `run.jsonl` 은 기동 때 비워진다 |

## 9. 대시보드

Logs 탭을 확장한다. 새 탭을 만들지 않는다. 같은 스트림과 같은 검색·접기·재생 로직을 쓰고, 탭을
나누면 이슈가 풀려던 "따로 본다" 가 그대로 남는다.

- 툴바에 종류 칩: Logs · Requests · Routes · Actions. 기본값은 지금과 같은 Logs + Requests.
- 행 왼쪽에 route 열. 좁은 화면에서는 숨기고 행 툴팁으로 보여 준다.
- `route` 엔트리는 구분선처럼 그린다.
- `request` 행을 누르면 기존 `/api/mock/hits/<id>` 상세를 연다. 200개를 넘어 지워진 히트는 "본문이 더
  이상 없음" 으로 표시한다.
- 기존 접기(반복 줄 묶기)는 키에 `source` 가 있어(`web/app.js:177`) 새 종류와 섞이지 않는다.

## 10. 단계별 구현 계획

각 PR 은 단독으로 배포 가능하다. 공통 테스트 원칙: 프로세스를 띄우는 `runSync` 를 늘리지 않고
(Linux CI 포트 테스트 간섭), 기존 `FakeEngine` 과 순수 함수로 검증한다. 이벤트 소스는 스트림 seam 뒤에 둬서
서버 테스트에 실제 `VmService` 가 필요 없게 한다.

**PR 0 — 라이브 스파이크(문서만).** 예제 앱에서 옵션을 켠 상태로 잰다. 결과를 이 문서에 반영한다.

- 장기 연결과 DDS·DevTools·emu 의 짧은 연결의 공존 → **PR 3 머지 전** 확인. 기본 꺼짐이라 PR 3 을 막지는
  않지만, 켠 사용자가 처음부터 깨지지 않게 하려는 것이다.
- §6.2 의 스냅샷 평가식 → PR 4 의 범위를 정한다.
- 경로별 순서 편차(§5) → 문서의 "대략의 순서" 설명에 수치를 넣는다.
- 평가식 리스너 후보는 여유가 있으면 본다.
- 기본값(Q9)을 나중에 다시 논의하게 되면 이 실측이 근거 자료가 된다.

PR 1·2 는 옵션과 무관해 PR 0 을 기다리지 않는다.

**PR 1 — 모델 + 요청 + `emu timeline`.** 라우트 없이도 쓸모 있는 첫 단계.

- `LogEntry` 선택 필드, `LogStore.add`/`query(kinds:)`, `/api/logs?kinds=`, `startSeq`, `emu timeline`.
- 테스트: JSON 왕복과 null 생략(옛 형식 파싱 포함), 기본 필터, `limit` 과 필터 순서, `request` 의
  `startSeq`, `run.jsonl` 오프라인, `cli_help`.
- 문서: README 두 벌, SKILL.md, CHANGELOG.

**PR 2 — action 엔트리.**

- `tap`/`swipe`/`text`/`open-url` 기록.
- 테스트: 조작 전후 seq 순서, 실패 시 엔트리, `text` 내용 미저장, **`assert --log` 가 action 에 안 걸림**,
  `/api/errors` 배너에 안 섞임.

**PR 3 — 장기 연결 + `Emu.Route`(2층).** 이슈 리포터 같은 `go_router` 앱이 바로 쓰는 단계라 1층보다 먼저 한다.

- `timeline.routes` 옵션 읽기(프로필·`emu.local.yaml` 포함), 옵션이 켜졌을 때만 장기 연결과 재구독,
  수집 상태(`off`/`connecting`/`on`/`failed`), `/api/logs` 의 `routes` 필드, `emu timeline` 안내.
- `Emu.Route` 파서(§6.4 계약), `currentRoute` 찍기, 같은 값 합치기, 재시작 시 초기화, `request` 의 시작 라우트.
- 테스트: **옵션 꺼짐이면 VM 연결을 열지 않음**(가짜 연결 팩토리 호출 0회)과 응답이 `routes: "off"`,
  켜짐이면 연결과 상태 전이, 프로필 덮어쓰기, 꺼짐일 때 `emu timeline` 의 안내가 텍스트는 stdout 끝·`--json` 은
  stderr 로만 나감, 계약 표(필수 필드 누락·타입 오류·빈 값·모르는 필드·1KB 초과·`detail` 합성), 가짜
  스트림으로 찍기, URI 변경 시 재구독, 연결 실패가 세션에 영향 없음, 경고는 세션당 한 번.
- 문서: README 두 벌에 옵션·계약·`go_router` 예시, SKILL.md(에이전트가 화면이 비었을 때 옵션을 확인하도록),
  `DESIGN.md` 변경 이력.
  `emu_hook` 헬퍼는 만들지 않는다(Q12).

**PR 4 — 1층(`Flutter.Navigation` + 스냅샷).** PR 0 결과에 따라 범위를 정한다.

- `Flutter.Navigation` 파서, 디바운스 뒤 스냅샷, 두 층의 관계(§6.2).
- 같은 `timeline.routes` 옵션 아래에서만 동작한다. 별도 옵션을 두지 않는다.
- 테스트: 파서 표(push/pop/null route/name null/이상한 payload), `Emu.Route` 를 받은 isolate 에서 1층 무시,
  hot restart 뒤 1층 재개, 평가식 빌더의 문자열 테스트.

**PR 5 — 대시보드.**

- 종류 칩, route 열, 구분선, 상세 연결, 수집 꺼짐·실패 안내(§6.5).
- 테스트: `web_logs_test`/`web_render_test` 확장, `bundle_web` 재생성.

## 11. 결정과 열린 질문

### 11.1 결정된 것

| # | 질문 | 선택지 | 결정 |
|---|---|---|---|
| Q1 | 라우트 감지 범위 | A. 1층만 / B. 1층 + `Emu.Route` / C. `NavigatorObserver` 까지 | **B** — 이슈 리포터 답(§13)으로 정함. A 는 `go_router` 앱과 라우트 아닌 탭을 못 잡고, C 는 emu 패키지 의존이 필요하다 |
| Q2 | 이슈 제안의 로그 줄 규약(c)도 받을까 | A. 받지 않음 / B. `Emu.Route` 와 함께 수용 | **A** — 이슈 리포터 답으로 정함. `Emu.Route` 로 충분하다. 쓰기 어려운 앱이 나오면 재검토 |
| Q3 | 화면 표시 값 | A. 이름(패턴)만 / B. 실제 경로만 / C. 실제 경로 + 이름 | **C** — 이슈 리포터 답으로 정함. 실제 경로는 재현용, 이름은 묶어 보기용. 출처는 `data.via` |
| Q4 | `/api/logs` 기본 필터 | A. 새 kind 제외 / B. 전부 포함 / C. 별도 `/api/timeline` | **A — 메인테이너 결정(2026-11-03).** 새 kind 는 `/api/logs` 기본 응답에서 제외(§8) |
| Q5 | 요청 표현 | A. 완료 1엔트리 + `startSeq` / B. 시작·완료 2엔트리 | **A — 메인테이너 결정(2026-11-03).** 완료 1엔트리 + `startSeq`(§5) |
| Q8 | 라우트 값의 민감 정보 | A. 1층 `arguments` 는 저장 안 함, `Emu.Route` 는 받은 그대로 / B. emu 가 쿼리를 걸러 냄 | **A** — 이슈 리포터 답으로 정함. 앱이 보낼 때 거른다. 1층 `arguments` 는 앱이 거를 기회가 없어 저장하지 않는다 |
| Q9 | 장기 VM 연결을 기본으로 켤까 | A. 항상 / B. `emu.yaml` 옵션 / C. 처음 조회 때 | **B — 메인테이너 결정(2026-11-03), 기본 꺼짐.** 처음 추천(A)과 다르다. 꺼짐 동작·안내는 §6.5 |
| Q11 | `Emu.Route` 를 받은 뒤 1층 이벤트 | A. 그 isolate 동안 무시 / B. `currentRoute` 는 안 바꾸고 참고 엔트리로만 기록 | **A — 메인테이너 결정(2026-11-03).** `Emu.Route` 를 받은 isolate 동안 1층 무시(§6.2) |

Q1·Q2·Q3·Q8 은 이슈 리포터의 답을 근거로 확정 표시했다. 메인테이너가 뒤집으면 다시 연다.

### 11.2 열린 질문 (PR 리뷰 때 정함)

| # | 질문 | 선택지 | 추천 | 정할 때 |
|---|---|---|---|---|
| Q6 | 대시보드 배치 | A. Logs 탭 확장 / B. 새 Timeline 탭 | **A** | PR 5 |
| Q7 | `emu text` 내용 저장 | A. 글자 수만 / B. 평문 / C. 설정으로 선택 | **A** | PR 2 |
| Q10 | 타임라인 위에 판정 기능을 얹을까 | A. 조회만 / B. `emu assert --route` 추가 | **A.** 판정 추가는 B1 경계 논의가 먼저다. 실수요가 생기면 별도 이슈 | 별도 이슈 |
| Q12 | `emu_hook` 에 `Emu.Route` 헬퍼를 둘까 | A. 두지 않음(계약 문서만) / B. 둔다 | **A.** 첫 사용자가 의존을 못 넣고, 헬퍼가 하는 일이 `postEvent` 한 줄이다. 요청이 오면 그때 추가 | PR 3 |
| Q13 | 계약 필드 이름 | `location`/`name`/`detail` 그대로 / 다른 이름 | **그대로.** 계약 공개 뒤에는 바꾸기 어려우니 PR 3 리뷰에서 한 번 확정한다 | PR 3 |
| Q14 | 수집 옵션 키 이름(Q9 결정에서 생김) | A. `timeline: {routes: true}` / B. 최상위 `routes: true` | **A.** 기존 `mocks:`·`pages:` 처럼 기능 이름 아래 묶고, 나중에 설정을 더할 자리를 남긴다(§6.5) | PR 3 |

## 12. `emu routes` 보류와의 관계

`docs/DESIGN.md` 와 `docs/BACKLOG.md` 의 보류 사유는 "공개 API 로는 전체 스택을 못 얻고 private
Navigator 내부에 기대야 한다" 이다.

**해소되지 않았다.** 스파이크로 얻은 `Flutter.Navigation` 은 전체 스택을 주지 않는다. push·pop 을
구분할 수 없고 제거된 라우트 수도 없어 이벤트로 스택을 재구성할 수도 없다. 선언형 경로에서는 이벤트
자체가 없다. `emu routes` 는 보류를 유지한다.

**타임라인은 그 문제를 만나지 않는다.** 필요한 것은 스택이 아니라 "지금 화면 이름 하나" 다. 그래서 (d)
private eval 을 쓰지 않고 진행할 수 있고, 위 보류 결정을 뒤집을 필요도 없다.

**새로 알게 된 것.** (e) 가 PR 0 에서 검증되면 현재 화면 하나는 공개 API 로 얻을 수 있다. 그때
`emu routes` 를 "전체 스택" 이 아니라 "현재 화면" 으로 줄여 다시 볼 여지가 있고, 재검토 조건으로
남겨 둔다. `DESIGN.md` 의 변경 이력은 구현 시점(PR 3)에 갱신한다.

## 13. 이슈 리포터 피드백 (2026-11-02)

[이슈 코멘트](https://github.com/HuanSuh/emu/issues/89)에서 받은 답과 반영 내용.

| 받은 답 | 설계에 준 영향 |
|---|---|
| `go_router` 16.2.4, 주로 `goNamed`·`pushNamed`, `ShellRoute` 안에 중첩 Navigator | 1층만으로는 주요 이동을 놓친다는 스파이크 결론과 맞다. 2층(PR 3)을 1층(PR 4)보다 먼저 한다 |
| 모달·바텀시트는 `Navigator.of(context).push` 로 직접 띄움 | 1층에서는 이벤트가 오지만 2층을 쓰면 무시된다. 남기려면 앱이 보낸다(§6.2, §6.4 observer 예시, Q11 결정) |
| 하단 탭은 라우트가 아닌 화면 내부 상태(`IndexedStack` 계열) | 라우트 기반 방법으로는 원리상 못 잡는다(§3.3). 계약에 `detail` 필드를 두었다 |
| 디버그 전용 한 줄은 가능, emu 패키지 의존은 불가 | `Emu.Route` 를 `dart:developer` 만으로 쓰는 계약으로 문서화(§6.4). `emu_hook` 헬퍼는 두지 않는다(Q12) |
| 로그 줄 규약(c)은 필요 없음 | Q2 확정 |
| 실제 경로를 선호하고, 묶어 보기용 이름도 함께 | 계약의 `location`(필수) + `name`(선택), Q3 확정 |
| 민감한 값은 앱이 거르고 emu 는 받은 그대로 | Q8 확정 |
