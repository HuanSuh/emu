<p align="center">
  <img src="docs/assets/emu_icon.png" alt="emu" width="140" height="140" />
</p>

<h1 align="center">emu — Flutter 디버그 드라이버</h1>

IDE 없이 Flutter 앱을 디버깅하는 도구. 에뮬레이터/시뮬레이터를 띄우고,
**hot reload / hot restart / cold restart** 를 수행하며, **검색·필터 가능한 디버그 로그**를
**CLI**(Claude Code 같은 에이전트·터미널용)와 **웹 대시보드**(사람용)로 제공한다.

핵심 설계는 **"엔진 하나, 프런트엔드 둘"** — 로컬 서버가 `flutter run --machine` 세션(엔진)을
단독 소유하고, CLI와 대시보드는 둘 다 그 서버의 HTTP/WebSocket API 클라이언트다.

```
flutter run --machine  ◄─JSON-RPC─►  엔진  ──►  서버 (127.0.0.1:4577)
                                                  ├─ REST + WebSocket API
                                                  ├─ 웹 대시보드  (브라우저)
                                                  └─ CLI          (터미널 / 에이전트)
```

> **이 도구의 자리**: DevTools/IDE/e2e 테스트 도구의 대체재가 아니다. 그들이 못 하는
> **"IDE 없이 에이전트가 비대화형으로 모는 개발/디버그 inner-loop + 로그·변수 관찰"** 이 본질이다.
> 자세한 비교와 한계는 [한계와 비교](#한계와-비교) 참고.

---

## 목차
- [요구 사항](#요구-사항)
- [설치 / 빌드](#설치--빌드)
- [빠른 시작](#빠른-시작)
- [핵심 워크플로: 에이전트 디버그 루프](#핵심-워크플로-에이전트-디버그-루프)
- [명령어 레퍼런스](#명령어-레퍼런스)
- [웹 대시보드](#웹-대시보드)
- [동작 원리](#동작-원리)
- [상태 파일(.emu/)](#상태-파일emu)
- [한계와 비교](#한계와-비교)
- [프로젝트 구조](#프로젝트-구조)
- [개발](#개발)
- [로드맵](#로드맵)

---

## 요구 사항

| 대상 | 필요한 것 |
|------|-----------|
| 공통 | Flutter SDK (`flutter` on PATH) — **필수** |
| Android | Android SDK `adb` + `emulator` (AVD 부팅용) |
| iOS | 전체 Xcode + `xcrun simctl` (macOS 전용) |

설치 상태는 `emu doctor` 로 확인한다.

## 설치 / 빌드

```bash
./build.sh                          # 대시보드 자산 임베드 + 단일 바이너리 컴파일
ln -sf "$PWD/emu" /usr/local/bin/emu   # PATH에 등록
```

빌드 없이 소스에서 바로 실행할 수도 있다(개발용):

```bash
dart run bin/emu.dart <command>
```

## 빠른 시작

Flutter 프로젝트 안에서 실행하면 `pubspec.yaml` 로 루트를 자동 탐지한다.
다른 위치에서 돌리려면 `EMU_PROJECT=/path/to/app` 를 지정한다.

```bash
emu doctor                # 의존성 점검
emu devices               # 연결된 기기 + Android AVD 목록

emu up --android          # 기본 AVD 부팅 → 앱 실행 → 대시보드 기동
emu up -d emulator-5554   # 특정 기기로 실행

emu reload                # hot reload
emu restart               # hot restart
emu logs --grep "Exception" -f   # 로그 실시간 검색
emu status                # 세션/기기/VM Service 상태
emu down                  # 세션 종료
```

모든 명령은 `--json` 을 지원한다(에이전트/스크립트용). `emu logs --json` 은 JSONL(한 줄당 JSON 객체).

## 핵심 워크플로: 에이전트 디버그 루프

emu의 존재 이유. **편집 → 반영 → 검증**을 전부 단발성 CLI 호출로 닫는다.
사람의 키 입력이나 IDE GUI 없이, Claude 같은 에이전트가 그대로 돌릴 수 있다.

```bash
# 1) 앱 기동 — running/failed 확정까지 기다렸다가 실제 결과 반환
emu up -d emulator-5554 --json
# → {"ok":true,"state":"running","dashboard":"http://127.0.0.1:4577","errors":[]}

# 2) 런타임 에러를 로그에서 탐지
emu logs --level error --grep "Exception" --json

# 3) 코드 수정 후 반영 (직후 에러를 같은 호출에 묶어 반환)
emu reload --json
# → {"ok":true,"message":"Reloaded 3 libraries","errors":[]}   # errors 비면 깔끔

# 4) 동작 검증 (로그 단언, 종료코드로 판정)
emu assert --deny "Exception" --expect "checkout done" --timeout 6
# → exit 0 (통과) / exit 1 (실패)

# 5) 변수 레벨로 더 깊게 검수
emu probe lib/cart.dart:42 --capture "total,items.length"
# → ● lib/cart.dart:42   total=12500   items.length=3

# 6) 화면을 직접 구동 — 스크린샷을 보고 좌표를 찍는다
emu shot ui.png                                  # 에이전트가 이미지에서 좌표를 읽고
emu tap 670 436                                  # 필드 포커스 → 입력 → 스크롤
emu text "sunglasses"
emu swipe 670 2500 670 1200
SEQ=$(emu tap 670 1486 --json | jq -r .seq)      # 결제 버튼 탭 (seq = 탭 직전 로그 커서)
emu assert --since "$SEQ" --deny "Exception" --expect "checkout done" --timeout 5
```

이 루프가 에이전트에게 주는 것:
- **단일 호출 판정** — `up`/`reload`/`restart`가 "실제로 됐는지"를 한 번에 알려준다(아래 참고).
- **로그 오라클** — `assert` 로 "이 동작 후 이 로그가 나와야/안 나와야 한다"를 단언.
- **변수 오라클** — `probe` 로 로그에 찍지 않은 변수값을 실행 중에 직접 읽는다.
- **구동 수단** — `shot` + `tap` 으로 앱을 직접 몬다. emu는 좌표를 넣기만 하고 **판단은 에이전트가**,
  검증은 `assert`/`probe`가 한다 — 외부 e2e 엔진 없이 구동→검증이 닫힌다.

## 명령어 레퍼런스

모든 명령에 `--json` 사용 가능.

### 라이프사이클

| 명령 | 설명 |
|------|------|
| `emu doctor` | 의존성 점검 (flutter / adb / emulator / xcrun) |
| `emu devices` | `flutter devices` + Android AVD 목록 |
| `emu configs` | `.vscode/launch.json` 의 실행 구성 목록 (debug만 실행 가능) |
| `emu up [opts]` | 기기 부팅 + 앱 실행 + 대시보드 기동. `running`/`failed` 확정까지 대기 |
| `emu down [--kill-device]` | 세션 종료. `--kill-device` 면 기기 전원도 끔 |
| `emu stop` | 앱만 정지(서버는 유지) |
| `emu status` | 세션/기기/앱 상태 + VM Service URI |
| `emu open` | 대시보드를 브라우저로 열기 |
| `emu shot [path]` | 스크린샷 저장(기본 `.emu/`). 상대 경로는 프로젝트 루트 기준 |
| `emu tap <x> <y>` | 좌표 탭 (물리 픽셀 — `shot`과 같은 좌표계). **Android 전용** |
| `emu swipe <x1> <y1> <x2> <y2>` | 스와이프/스크롤. `--duration <ms>`. **Android 전용** |
| `emu text <string>` | 포커스된 필드에 입력(ASCII만). **Android 전용** |

`emu up` 옵션:

| 옵션 | 설명 |
|------|------|
| `--android` / `--ios` | 해당 플랫폼 기본 기기를 부팅 |
| `-d, --device <id>` | 특정 flutter device id 사용 |
| `--config <name>` | `.vscode/launch.json` 의 구성을 재현 (개별 플래그가 덮어씀) |
| `--flavor <name>` | 빌드 flavor |
| `-t, --target <file>` | 진입점(`lib/main_dev.dart` 등) |
| `--dart-define K=V` | dart-define (반복 가능) |
| `--port <n>` | 대시보드 포트(기본 4577, 사용 중이면 자동 폴백) |
| `--open` | 기동 후 브라우저 열기 |

### configs — `.vscode/launch.json` 재현

IDE 없이도 프로젝트에 이미 설정된 실행 구성(flavor / target / dart-define / device)을
그대로 쓴다. `emu configs` 로 목록을 보고, `emu up --config "<이름>"` 으로 기동한다.

```bash
emu configs                          # 구성 목록 (--json 가능)
emu up --config "myapp (dev)"        # 해당 구성 그대로 실행
emu up --config "myapp (dev)" --flavor staging   # 개별 플래그가 config 값을 덮어씀
```

- `launch.json`(JSONC: 주석·후행 쉼표 허용)을 읽어 `type: "dart"` 구성만 추출한다.
  `flutterMode`·`deviceId`·`program` 및 `args`/`toolArgs` 의 `--flavor`/`-t`/`--dart-define` 를 인식.
- **debug 구성만 실행 가능**: emu 는 hot reload·VM Service(probe) 때문에 debug 빌드만 구동한다.
  `profile`/`release` 구성은 `configs` 에서 `⚠ debug-only` 로 표시되고 `up --config` 는 거부한다(exit 1).
- `--dart-define-from-file` 등 아직 재현하지 못하는 플래그는 목록에서 미지원으로 표시되니
  필요하면 `--dart-define` 으로 직접 넘긴다.

### reload / restart / cold

| 명령 | 의미 |
|------|------|
| `emu reload` | hot reload (`app.restart{fullRestart:false}`) |
| `emu restart` | hot restart (`app.restart{fullRestart:true}`) |
| `emu cold` | cold restart — 프로세스 완전 재기동(네이티브/pubspec 변경 반영) |

`reload`/`restart` 는 실행 **직후 짧은 창(2.5s)** 의 에러 로그를 응답 `errors` 에 포함한다.
→ 에이전트가 "고쳤더니 됐나?"를 **한 번의 호출**로 판정. (한계는 아래 참고)

### logs

```bash
emu logs [opts]
  -g, --grep <regex>   대소문자 무시 정규식 필터
  -l, --level <e|w|i>  최소 레벨 (error/warn/info)
  -n, --lines <N>      마지막 N줄 (기본 200)
  -f, --follow         실시간 스트림
  --clear              로그 버퍼 비우기
```

서버가 꺼져 있어도 `.emu/run.jsonl` 에서 오프라인으로 읽는다.

### assert — 로그 단언 (e2e/CI 오라클)

```bash
emu assert [opts]
  --expect <regex>   반드시 나와야 하는 패턴 (반복 가능)
  --deny <regex>     절대 나오면 안 되는 패턴 (반복 가능)
  --since <seq>      로그 커서(기본: 지금부터)
  --timeout <s>      대기 창 (기본 5초)
```

`--expect` 가 전부 나타나고 `--deny` 가 하나도 안 나타나면 **exit 0**, 아니면 **exit 1**.
`--deny` 는 매칭 즉시 실패, `--expect` 는 timeout 내 등장해야 통과.

```bash
emu assert --deny "FormatException" --expect "parsed value" --timeout 6
```

### tap / swipe / text — 앱 구동 (에이전트용)

```bash
emu shot ui.png                      # 화면을 캡처하고
emu tap 670 1486                     # 에이전트가 이미지에서 읽은 좌표를 그대로 탭
emu swipe 670 2500 670 1200          # 스크롤 (--duration <ms>, 기본 300)
emu text "hello world"               # 포커스된 필드에 입력 — 필드를 먼저 탭할 것
# → ✓ tap 670,1486   (seq 28)
```

**좌표계는 물리 픽셀 하나뿐이다.** 스크린샷(`adb screencap`)과 탭(`adb input tap`)이 같은 공간을
쓰므로 **변환이 필요 없다** — 이미지에서 읽은 픽셀 좌표를 그대로 넘기면 된다.

> ⚠️ **에이전트 주의**: 스크린샷이 축소되어 전달되면(예: 1344×2992 → 898×2000) 이미지에서 읽은
> 좌표에 **축소 배율을 곱해야** 물리 좌표가 된다. 탭이 엉뚱한 곳에 꽂히는 원인 대부분이 이것이다.

`tap` 이 반환하는 `seq` 는 **탭 직전의 로그 커서**다. 이걸 `assert --since` 에 넘기면
"이 탭이 무엇을 유발했는지"를 정확한 창으로 단언할 수 있다:

```bash
SEQ=$(emu tap 670 1486 --json | jq -r .seq)
emu assert --since "$SEQ" --expect "checkout done" --deny "Exception" --timeout 5
```

`--since` 없이 `tap` 다음에 `assert` 를 부르면 **놓친다**: `assert` 의 기본 창은 "지금부터"라
이미 발생한 로그를 보지 못한다.

**입력은 명령이 끝나도 앱에 아직 도달하지 않았을 수 있다.** `adb` 는 이벤트를 큐에 넣고 반환하며,
특히 `text` 는 한 글자씩 들어가 눈에 띄게 느리다(실측: 6자에 ~2초). `sleep` 으로 눈치껏 기다리지 말고
**`assert --since` 로 도달을 확인**하는 게 정확하다. 입력을 연달아 쏘면 서로 경합해 뒤섞인다.

```bash
emu tap 670 436                                  # 필드를 먼저 탭해 포커스
SEQ=$(emu text "hello world" --json | jq -r .seq)
emu assert --since "$SEQ" --expect 'text="hello world"' --timeout 8   # 도달 확인
```

- **`text` 는 ASCII만 가능하다.** `adb shell input text` 는 비ASCII(한글·이모지·악센트)에서
  안드로이드 내부 `NullPointerException` 으로 죽는다(실측). emu는 이를 미리 거르고 명확히 알려준다.
- **`text` 는 포커스된 곳에 칠 뿐** 위젯을 지정하지 않는다. 필드를 먼저 `tap` 할 것.
- **소프트 키보드가 화면을 가린다.** 필드를 탭하면 키보드가 올라와 하단 위젯을 덮으므로,
  이후 좌표는 **다시 `shot` 으로 확인**할 것(키보드는 `adb shell input keyevent 4` 로 닫는다).
- **Android 전용**: `simctl` 에 입력 명령이 없어 iOS 시뮬레이터는 아직 미지원.
- **UI 단언은 하지 않는다**: emu는 입력만 넣고, 판정은 `assert`(로그)/`probe`(변수)가 한다.

### probe — 변수 캡처 (VM Service logpoint)

```bash
emu probe <file:line> [opts]
  -c, --capture <e,e>  히트 시 평가할 표현식 (콤마 구분)
  --count <n>          N회 히트 후 종료 (기본 1)
  --timeout <s>        히트 대기 시간 (기본 10초)
```

`file:line` 에 브레이크포인트를 걸고, 멈춘 프레임에서 capture 표현식을 평가→기록→**자동 resume**.
앱을 (찰나 외에는) 멈추지 않고 변수 상태를 읽는다.

```bash
emu probe lib/cart.dart:42 --capture "total,items.length,coupon" --count 3
# ● lib/cart.dart:42   total=12500   items.length=3   coupon=null
```

> `probe` 는 `final`/필드/일반 지역변수를 읽는다. `const` 지역변수는 컴파일 타임에
> 인라인되어 런타임 슬롯이 없으므로 평가할 수 없다.

## 웹 대시보드

`emu up` 이 `http://127.0.0.1:4577` 에 대시보드를 띄운다:

- 실시간 로그 스트림 — **정규식 검색**, **레벨 필터**(debug/info/warn/error), 매치 하이라이트, copy, clear
- 버튼: **Hot reload / Hot restart / Cold restart / Stop** (`r` / `R` 키도 지원)
- 상태바 — 기기, 앱 상태, DevTools 링크

## 동작 원리

- **제어**: Flutter 데몬 프로토콜(`flutter run --machine`)을 사용. hot reload =
  `app.restart{fullRestart:false}`, hot restart = `{fullRestart:true}`, cold = 프로세스 재기동.
  tmux나 키 입력 시뮬레이션을 쓰지 않는다.
- **로그**: 데몬 이벤트(`app.log`/`daemon.logMessage`/stdout)를 링버퍼에 캡처하고
  `.emu/run.jsonl` 로 영속화. 정규식/레벨/seq 커서로 질의.
- **변수**: 앱의 `vmServiceUri` 에 두 번째 클라이언트로 붙어(`package:vm_service`) 표준
  디버그 프로토콜로 브레이크포인트·표현식 평가를 수행한다.

## 상태 파일(.emu/)

프로젝트의 `.emu/` 디렉토리에 저장되며 자동으로 git-ignore 된다:

| 파일 | 내용 |
|------|------|
| `run.jsonl` | 구조화된 로그(JSONL) |
| `server.json` | 실행 중 서버 좌표(port/pid) |
| `server.log` | 서버 기동 진단 |
| `shot-*.png` | 스크린샷 |

## 한계와 비교

정직하게 짚는다.

**reload/restart의 직후 에러 drain은 best-effort.**
*즉시* 에러(build/initState throw)는 잡지만, *지연·트리거성* 에러(Timer, 탭)는 놓칠 수 있다.
그 경우 `emu assert --deny ... --timeout N` 이 견고한 길(폴링 기반).

**입력은 좌표 탭까지만. UI 단언은 emu의 영역이 아니다.**
`emu tap` 은 좌표를 넣을 뿐, **위젯 트리를 질의하지 않는다** — "이 버튼이 보이나?", "텍스트가 뭐지?"
같은 UI 단언은 emu가 하지 않는다(에이전트가 스크린샷을 보고 판단하거나, `assert`/`probe` 로 검증).
셀렉터 기반의 견고한 UI 단언이 필요하면 `integration_test`(공식)/`patrol`/`maestro` 를 쓰고,
emu는 그 위에서 **로그·변수 검증**을 더하는 게 맞다.
입력(`tap`/`swipe`/`text`)은 **Android 전용**이다 — `simctl` 에 입력 명령이 없어 iOS는 미지원.
`text` 는 ASCII만 가능하다(안드로이드 `input text` 자체의 한계).

**`up` 이 `running` 을 반환해도 첫 프레임 전일 수 있다.**
`up` 직후 곧바로 `tap` 하면 화면이 아직 없어 허공을 칠 수 있다(실측 확인). 기동 직후 탭이 필요하면
`emu assert --expect "<첫 화면의 로그>"` 로 준비를 확인한 뒤 탭하는 게 안전하다.

**e2e 테스트 도구 vs emu.** e2e 도구는 **UI**를 단언하고 emu는 **로그/변수**를 단언한다 —
서로 다른 버그를 잡는다(예: "UI는 통과인데 로그엔 삼켜진 예외"는 emu가 잡는다).
경쟁이 아니라 다른 층위.

**AVD 자동 선택은 단순하다.** `--android` 는 현재 `emulator -list-avds` 의 첫 항목을 고른다.
문제 있는 AVD면 `-d <id>` 로 명시하거나 정상 AVD를 먼저 부팅해 두는 게 안전하다(개선 예정).

**cold-boot 대기.** 콜드부트+첫 빌드가 `up` 의 대기 창보다 길면 `state:starting` 으로 반환될 수 있다.
서버는 백그라운드로 계속 진행하므로 `emu status` 폴링으로 확인한다.

## 프로젝트 구조

```
bin/emu.dart           진입점 (CLI + 숨은 __serve 서브커맨드)
lib/src/
  models.dart          LogEntry / AppStatus / DeviceInfo
  daemon_protocol.dart flutter --machine 메시지 인코드/디코드
  engine.dart          flutter 프로세스 소유 · reload/restart/cold/stop
  log_store.dart       링버퍼 · 영속화 · 필터 질의
  assertions.dart      순수 expect/deny 로그 단언 로직
  probe.dart           VM Service logpoint: 라인에서 변수 캡처
  device_manager.dart  기기 탐색 + 에뮬레이터/시뮬레이터 부팅
  session.dart         프로젝트 탐지 + .emu/ 상태
  server.dart          REST + WebSocket + 정적 대시보드 서빙
  cli.dart             명령 파싱 + 서버 클라이언트
web/                   대시보드 (바닐라 HTML/JS/CSS, 빌드 스텝 없음)
tool/bundle_web.dart   web/ 를 바이너리에 임베드
docs/BACKLOG.md        개선 백로그 + 우선순위
```

## 개발

```bash
dart test                  # 단위 테스트 (프로토콜·로그스토어·기기파싱·단언·probe 헬퍼)
dart analyze               # 린트
EMU_WEB_DIR=web dart run bin/emu.dart up   # 대시보드를 디스크에서 서빙(라이브 편집)
```

환경 변수:

| 변수 | 용도 |
|------|------|
| `EMU_PROJECT` | 프로젝트 루트 지정(기본: `pubspec.yaml` 자동 탐지) |
| `EMU_WEB_DIR` | 대시보드 자산을 이 디렉토리에서 서빙(개발용) |

## 로드맵

진행/예정 항목은 [`docs/BACKLOG.md`](docs/BACKLOG.md) 참고.

- ✅ 에이전트 루프 인체공학(verdict `up`, `reload` 직후 에러, `assert`)
- ✅ `probe` — VM Service 변수 캡처
- ✅ `emu tap` / `swipe` / `text` — 스크린샷 좌표 기반 구동 (Android)
- ⬜ iOS 입력 수단 (`simctl` 에 입력 명령 없음 — 대안 조사 필요)
- 🚫 `emu e2e` — 외부 e2e 엔진 구동: 보류(입력 수단 확보로 전제 소멸, [BACKLOG](docs/BACKLOG.md) 참고)
- ⬜ Tier 2 인터랙티브 디버거(break/inspect/step)
- ⬜ iOS 시뮬레이터 실기 검증
- ⬜ AVD 선택 개선
