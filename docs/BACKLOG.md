# emu 개선 백로그

이 문서는 초기 구현 이후 "emu의 가치는 무엇인가"를 검증하며 나온 개선 항목들을 기록한다.

## 정리된 포지셔닝 (판단 기준)

emu의 해자는 **"IDE 없이 에이전트가 모는 개발/디버그 inner-loop + 로그 관찰 가능성"** 이다.
DevTools/IDE/e2e 도구의 경쟁자가 아니라, 그들이 못 하는 *비대화형 에이전트 제어*가 본질.
따라서 우선순위는 **에이전트 루프의 "한 번의 호출로 판정"을 강화하는가**를 1차 기준으로 둔다.

검증된 사실:
- 편집 → reload/restart → 로그 검증 루프가 단발성 CLI + `--json`으로 닫힌다. (가치 체감 ✓)
- `debugPrint` / unhandled exception / logcat이 emu에 캡처된다. (런타임 디버깅 가능 ✓)
- ~~약점: 신뢰할 UI 입력 수단 없음(adb tap이 GestureDetector에 안 먹음)~~ → **반증됨(2026-07-17, 아래 참고).**
  adb tap은 GestureDetector/ElevatedButton에 100% 먹는다. UI 단언은 여전히 emu 영역 밖.</new_string>
</invoke>


## 우선순위 요약

| # | 항목 | 가치 | 노력 | 우선순위 | 상태 |
|---|------|------|------|----------|------|
| 1 | `up`/`reload`/`restart`가 최종 상태·직후 에러까지 한 번에 반환 | 높음 | S | **P0** | ✅ 완료 |
| 2 | `emu assert --log` (로그 패턴 단언 + 종료코드) | 높음 | S | **P0** | ✅ 완료 |
| 3 | `emu probe` (VM Service logpoint — 변수 캡처) | 매우 높음(유니크) | L | **P1** | ✅ 완료 |
| 4 | `emu e2e` (외부 e2e 엔진 구동 + 로그 동시검증) | 중 | M | ~~P1~~ | 🚫 보류 |
| 5 | `emu tap`/`input` 신뢰 가능한 입력 추상화 | **높음** | **S** | **P1** | ✅ 완료(Android) |
| 6 | Tier 2 인터랙티브 디버거(break/inspect/eval/step) | 중~높음 | L | P2 | |
| 7 | iOS 시뮬레이터 실기 검증 | 중 | S | P2 | ✅ 완료 |
| 8 | 대시보드 범위 결정(최소 유지) + 포지셔닝 문서화 | 낮음 | S | P3 | |
| 9 | `bootAndroid` AVD 선택 개선(첫 AVD 맹목 선택 X) + cold-boot 대기 | 중 | S | P2 | 일부 |

### P2-#5 `emu tap` 구현 완료 (2026-07-17)
- ✅ `emu tap <x> <y>` — 물리 픽셀 좌표 탭(Android). 실기 검증: GESTURE/BUTTON 탭 → 로그 확인,
  `assert --since` 루프 3/3 통과. 종료코드 0/1/2 정상.
- ✅ **`tap` 이 `seq`(탭 직전 로그 커서)를 반환**한다. 이게 없으면 자연스러운 `tap` → `assert` 순서가
  **조용히 실패**한다(assert 기본 창이 "지금부터"라 이미 발생한 로그를 놓침). #4가 말하던
  "seq 윈도우 상관" 글루가 여기서 한 줄로 해결됐다.
- ✅ **`emu shot [path]` 버그 수정**: 명시 경로 반영 + 상대 경로는 프로젝트 루트 기준 + 디렉토리 자동 생성.
- ✅ **플랫폼 판별 버그 수정**: `deviceId.startsWith('emulator-')` 는 **실기 Android를 iOS로 오판**했다.
  iOS 시뮬레이터 udid가 UUID인 점을 이용한 `platformForDeviceId()` 순수 함수로 교체 + 유닛테스트 3종.
- ✅ **adb `-s <serial>` 전달**: 여러 기기가 붙어 있을 때 엉뚱한 기기로 가던 문제(screenshot에도 적용).
- ✅ **`up` 의 `running` 은 첫 프레임 보장이 아니다** → **해결됨**(아래 first-frame 항목).
### iOS 입력 조사 (spike) — VM Service 합성 포인터가 답이다 (2026-07-17)

**질문**: iOS는 `simctl` 에 입력 명령이 없다. 무엇으로 구동할 것인가?

**확정된 사실**
- ✅ **`simctl` 에 입력이 없다 — 확인.** 전체 서브커맨드를 훑었다. `ui` 는 외관(light/dark),
  `io` 는 스크린샷/녹화일 뿐이다. 우회 불가.
- ✅ **VM Service 합성 포인터 이벤트가 실제로 동작한다 — Android에서 실측.**
  `evaluate` 로 프레임워크에 포인터를 직접 꽂으면 앱이 탭으로 인식한다(`gesture onTap` 확인).
  **이 경로는 adb를 전혀 쓰지 않는다** = Dart VM + Flutter 프레임워크만 쓰므로 **플랫폼 무관**.
  Android는 iOS의 유효한 프록시다(시뮬레이터 부팅 없이 메커니즘 검증 가능).
- ✅ **앱의 import에 의존하지 않는다.** `evaluate` 는 대상 라이브러리 스코프에서 이름을 풀지만,
  **프레임워크 라이브러리를 대상으로 잡으면** 사용자 앱이 무엇을 import하든 무관하다. 실측 확인:
  ```
  target lib: package:flutter/src/widgets/binding.dart
  expr: WidgetsBinding.instance
          ..handlePointerEvent(PointerDownEvent(position: Offset(223, 226)))
          ..handlePointerEvent(PointerUpEvent(position: Offset(223, 226)))
  ```
- 📌 **`evaluate` 는 단일 표현식만 받는다** — 문장/클로저는 `Expression compilation error`.
  그래서 down/up을 **캐스케이드**로 묶는다.
- 📌 **좌표계가 adb와 다르다: 논리 픽셀.** adb는 물리 픽셀인데 이 경로는 프레임워크 좌표(논리)다.
  실측: 논리 (223,226) = 물리 (670,678) ÷ dpr 3.0. **`shot` 좌표를 dpr로 나눠야 한다** —
  emu가 dpr을 알아내 흡수해야 하며, 그러지 않으면 tap과 좌표 규약이 갈려 사용자가 혼란해진다.

**대안 비교**
| 경로 | 비용 | 판단 |
|------|------|------|
| VM Service 합성 이벤트 | 의존성 0, Android/iOS 통합 | **추천** — 이미 probe로 붙어 있는 인프라 재사용 |
| `idb` (Meta) | 미설치(brew+pip 설치 전제), 별도 데몬 | 사용자에게 설치를 강요 → 보류 |
| AppleScript/Simulator.app | `osascript` 는 있으나 창 좌표 매핑 필요 | 취약 → 보류 |

**미해결 / 다음 단계**
- 🚧 **iOS 실기 검증은 이 머신에서 막혔다(환경 문제, emu 무관).** `flutter build ios --debug --simulator`
  가 **emu 없이 단독으로도** 동일 실패: `iOS 26.5 is not installed. Please download and install
  the platform from Xcode > Settings > Components` (Xcode 26.6, 시뮬레이터 런타임·SDK는 설치돼 있음).
  → **Xcode > Settings > Components 에서 iOS 26.5 플랫폼 설치 후 재검증 필요.**
  (2026-06-24 iOS 검증은 통과했었다 → 이후 Xcode 업데이트로 깨진 것으로 보인다.)
- ❓ **`text` 입력은 이 경로로 안 풀린다.** 포인터 이벤트와 달리 텍스트는 `TextInput` 채널을 거쳐야 해
  훨씬 어렵다. iOS 텍스트 입력은 별도 조사 필요.
- ❓ swipe = 포인터 move 이벤트 시퀀스로 가능해 보이나 미검증.

**설계 제안**: `tap`/`swipe` 에 백엔드 2개(adb / vm-service)를 두고 플랫폼으로 자동 선택하되,
**사용자에게는 물리 픽셀 좌표 하나로 통일**해 노출한다(vm-service 백엔드가 내부에서 dpr로 나눈다).
그러면 `shot` → `tap` 규약이 플랫폼과 무관하게 동일해진다.

### first-frame — `up` 이 "탭 가능"을 보장하도록 (2026-07-17)
`up` 이 `running` 을 반환해도 엔진이 아직 아무것도 래스터라이즈하지 않았을 수 있고, 그 창에 넣은
입력은 **조용히 유실**된다. tap 검증 중 실제로 밟은 함정이라 입력 세트와 함께 닫았다.

- ✅ `up --json` 이 `firstFrame` 을 함께 반환하고, 기본적으로 첫 프레임까지 대기한다.
  실측: 예전에 유실되던 "up 직후 즉시 tap"이 이제 정상 등록된다.
- 📝 **신호 선택 근거(실행 중인 앱에 직접 조회해 확인)**: Flutter는
  `ext.flutter.didSendFirstFrameEvent` / `ext.flutter.didSendFirstFrameRasterizedEvent` 를
  등록하며, **일회성 이벤트가 아니라 `enabled` 플래그를 조회할 수 있다.** 덕분에 "이미 지나간 첫
  프레임을 놓치는" 경쟁 조건 없이 폴링으로 안전하게 판정된다. **rasterized** 쪽을 쓴다 — 픽셀이
  실제로 화면에 올라온 시점이라야 탭이 먹기 때문(다른 하나는 프레임 "빌드"까지만 보장).
- 📝 `enabled` 는 Flutter 버전에 따라 문자열/불리언으로 오므로 양쪽을 받는다(`firstFrameSent`, 테스트 포함).
- ⚠️ 실패해도 던지지 않고 `firstFrame:false` 로 강등한다 — 앱은 돌고 있고, 신호를 못 얻었을 뿐이다.

### 입력 프리미티브 완성 — swipe / text (2026-07-17)
`tap` 만으로는 첫 화면에 보이는 것밖에 못 건드린다. 스크롤과 텍스트 입력을 더해 입력 세트를 닫았다.

- ✅ `emu swipe <x1> <y1> <x2> <y2> [--duration ms]` — 스크롤/드래그. tap과 동일한 물리 픽셀 좌표계.
- ✅ `emu text <string>` — 포커스된 필드에 입력. `tap`/`swipe` 와 같은 `seq` 규약 공유.
- ✅ 실측(에뮬레이터): tap/swipe/text → `assert --since` 루프 전부 통과, 종료코드 0/1/2 정상.

**실측으로 확정한 제약 3가지** (전부 처음엔 "버그처럼" 보였으나 아니었다):
- 🔴 **`input text` 는 ASCII 전용 — 실측 확인.** `adb shell input text '한글'` / `'café'` 는 안드로이드
  내부에서 `NullPointerException: Attempt to get length of null array`
  (`InputShellCommand.sendText`)로 죽고 exit 255. KeyCharacterMap이 비ASCII를 매핑 못 함.
  → `nonTypableChars()` 로 미리 걸러 명확한 에러를 준다(Java 스택트레이스 대신).
  IME를 바꾸는 우회(ADBKeyBoard 등)는 앱 설치 전제라 보류.
- ⚠️ **입력은 명령 반환 후에도 앱에 도달 중일 수 있다.** `text` 는 한 글자씩 들어가 느리다(6자 ~2초).
  입력을 연달아 쏘면 **서로 경합해 문자열이 뒤섞인다**("hello" → "hehel"을 실제로 재현).
  → 정답은 `sleep` 이 아니라 `assert --since` 로 도달 확인. README에 명시.
- ⚠️ **소프트 키보드가 좌표를 무효화한다.** 필드를 탭하면 키보드가 올라와 하단을 덮는다.
  swipe가 "안 먹는" 것처럼 보인 원인이 이것이었다(리스트가 키보드에 가려짐). 키보드를 닫으니 정상.
  → 입력 후 좌표는 `shot` 으로 재확인할 것. 키보드 닫기는 `adb shell input keyevent 4`.

> 📌 **교훈**: 이번에도 "안 먹는다"의 원인은 전부 도구가 아니라 **관측 조건**이었다(키보드 가림, 명령 경합,
> 좌표 착오). `adb tap` 미신과 같은 패턴이다. 입력이 안 먹으면 **먼저 `shot` 으로 화면을 보라.**

- ⬜ **남은 것**: iOS 입력 수단 → **조사 완료**(위 spike). VM Service 합성 포인터로 간다.
  구현은 iOS 실기 검증(Xcode 플랫폼 설치)이 풀린 뒤.

### adb tap 실측 — "GestureDetector에 안 먹는다"는 반증됨 (2026-07-17)

P1-#4(`emu e2e`)를 접고 P2-#5(입력 추상화)로 가기 전, 그 판단의 전제였던
**"adb tap이 Flutter GestureDetector에 안 먹는다"** 를 실측으로 검증했다. **결론: 사실이 아니다.**

측정 환경: 신규 `flutter create` 데모 앱(GestureDetector + ElevatedButton, 탭 시 debugPrint),
Pixel_8_Pro_API_34 에뮬레이터, `emu up` → `adb shell input tap` → `emu logs`.

- ✅ **GestureDetector·ElevatedButton 양쪽 모두 정상 수신.** 연타 10회 → 10회 전부 반응(유실 0%).
  간헐적 실패도 재현되지 않음.
- ✅ **좌표계 확정 — 변환이 필요 없다.** `adb input tap`과 `adb exec-out screencap` 은 **둘 다 물리 픽셀**
  이라 같은 좌표 공간을 쓴다. 물리 (670,1486) 탭 → Flutter global `Offset(223.3, 495.3)`
  (= dpr 3.0으로 나눈 값), local `Offset(99.3,49.5)` = 200×100 박스의 정중앙.
  → **스크린샷에서 읽은 픽셀 좌표를 그대로 tap에 넘기면 된다.**
- ⚠️ **진짜 함정은 에이전트 쪽 다운스케일이다.** 스크린샷 원본은 1344×2992지만 Claude에 전달될 때
  898×2000으로 축소되어 보인다. 이미지에서 읽은 좌표에 **배율(≈1.4967)을 곱해야** 물리 좌표가 된다.
  초기 세션의 "탭이 안 먹는다"는 관찰은 이 배율 누락으로 엉뚱한 곳을 찍은 것이 원인일 가능성이 높다.
- 📝 **함의**: P2-#5는 VM Service 합성 이벤트 같은 무거운 경로가 불필요하다. `adb input tap` 얇은 래퍼
  (+ iOS는 simctl에 tap이 없어 별도 수단 필요)로 **S 규모**. 노력 M → S 로 하향.

### 부수 확인 (2026-07-17)
- ~~🐞 **`emu shot [path]` 인자 무시 재확인**~~ → ✅ **수정됨**(위 #5 항목 참고).
- 🐞 **실패한 `up` 이 세션을 남긴다**: `state:failed` 로 끝나도 서버가 세션을 붙들고 있어
  다음 `up` 이 "A session is already running" 으로 거부됨 → `down` 을 수동으로 해야 함.
  실패 시 자동 정리하거나 `up` 이 failed 세션을 승계하도록 개선 필요(P2).
- 📝 **환경 메모(emu 문제 아님)**: 이 머신은 `adb` 가 PATH에 없다(`~/Library/Android/sdk/platform-tools/adb`).
  또한 구형 프로젝트(`../hello`: Gradle 7.5/AGP 7.3)는 Flutter가 Android Studio 번들 JBR 21을
  `JAVA_HOME` 보다 우선 선택해 `Unsupported class file major version 65` 로 빌드 실패한다
  (`JAVA_HOME` 로는 우회 불가, `flutter config --jdk-dir` 필요). 실측은 신규 템플릿(Gradle 9.1)으로 진행.

### iOS 검증 + 환경 수정 (2026-06-24)
- ✅ **iOS 시뮬레이터 end-to-end 통과**: `emu up --ios` → simctl로 iPhone 부팅 → `flutter run`
  빌드 → ~144s에 running → hot reload → 스크린샷 확인.
- ✅ **stale SDKROOT 자동 정리(`env.dart`)**: 셸의 `SDKROOT`/`DEVELOPER_DIR`가 삭제된 옛 Xcode
  경로를 가리키면 모든 `xcrun`/`simctl`/`flutter` 빌드가 깨짐("Failed to determine realpath ...
  Xcode_16.4.app"). emu가 자식 프로세스 spawn 시 경로가 없는 해당 변수를 제거하도록 수정
  (engine의 flutter run + device_manager의 xcrun 전부 적용).
- 🐞 **`emu shot [path]` 인자 무시**(신규): CLI가 서버에 경로를 전달하지 않아 항상 `.emu/`에 저장됨.
  → /api/screenshot에 out path 전달하도록 수정 필요(소소, P2).

### P1-#3 `emu probe` 검증 (2026-06-22)
- ✅ `emu probe lib/main.dart:34 --capture "value,doubled,_tick"` → 런타임 변수
  `value=12500, doubled=25000, _tick=7→8`(히트마다 증가) 캡처 + 자동 resume 확인. 표현식 평가(`value*10`)도 동작.
- 📝 **const 지역변수는 캡처 불가**(버그 아님): 컴파일 타임 인라인되어 런타임 슬롯이 없음 →
  `evaluateInFrame` 에러. final/필드/일반 지역변수는 정상. help/README에 명시 권장.
- 📝 probe 히트는 `source:'probe'` 로그로도 흘러 대시보드에서 보임.

### P0 검증에서 발견/처리한 것 (2026-06-22)
- ✅ `up --json` 거짓 성공(ok:true) 수정 → `running`/`failed` 대기 후 실제 상태 반환. 실측 통과.
- ✅ `emu assert --expect/--deny/--timeout` — 데모 앱에서 pass(exit0)/fail(exit1) + FormatException 포착 확인.
- ✅ **에뮬레이터 부팅 버그 수정**: `emulator`를 임의 cwd에서 실행 시 Qt/qemu 경로 오산정으로 부팅 실패
  ("Qt library not found"). `bootAndroid`가 **절대경로 + SDK emulator 디렉토리를 cwd로** 실행하도록 수정.
- ⚠️ **drain 한계(설계상)**: `reload/restart`의 직후 에러 drain(2.5s)은 **즉시 에러**(build/initState throw)만
  잡음. **지연/트리거성 에러**(Timer, 탭)는 놓침 → 그 경우 **`emu assert --deny ... --timeout N`** 가 견고한 길
  (데모에서 timer 2s 지연 예외를 assert가 정확히 잡고 drain은 놓침을 확인).
- ⚠️ **cold-boot 대기**: `up --json`의 launch 대기(240s)가 콜드부트+첫 빌드보다 짧을 수 있음 → "starting" 반환.
  서버는 계속 진행하므로 `status` 폴링으로 확인 가능. → #9에 "대기 시간 옵션화/연장" 포함.
- ⚠️ **AVD 맹목 선택**: `emulator -list-avds` 첫 항목(알파벳순 `Galaxy_Z_Flip`)을 골라 부팅 실패한 사례.
  → Pixel/gphone 계열 우선 또는 설정 가능하게(#9).

---

## P0 — 에이전트 루프 인체공학 (작고 즉시 복리)

이 세 개는 "검증된 가치"를 직접 강화하며 노력 대비 효과가 가장 크다. 먼저 한다.

### 1. 액션 명령이 "최종 상태 + 직후 에러"를 한 번에 반환
- **문제**: `emu up --json`이 서버만 뜨면 `{"ok":true}`를 반환 — 실제 앱 기동 실패(예: 없는 기기)도
  `ok:true`로 나와 에이전트가 실패를 놓친다(실측 확인됨).
- **개선**:
  - `up --wait`(또는 기본값 변경): `running`/`failed` 도달까지 대기 후 최종 상태 반환.
  - `reload`/`restart`/`cold`: 실행 직후 N초 로그를 drain해 **그 구간의 에러 로그를 응답에 포함**.
    `{ok, message, errors:[...], state}` 형태 → 에이전트가 한 번의 호출로 "고쳤나?" 판정.
- **노력**: S. `cli.dart`의 `_action`/`_up` + 서버에 "since-seq drain" 헬퍼 추가.

### 2. `emu assert --log`
- **문제**: e2e/CI에서 "이 동작 후 이 로그가 나와야/안 나와야 한다"를 단언할 표준 수단이 없다.
- **개선**: `emu assert --expect "pat" --deny "Exception|E/flutter" --since <seq> --timeout 5 --json`
  → 패턴 충족 시 exit 0, 아니면 비0 + 위반 목록. #1의 drain 헬퍼를 공유.
- **노력**: S.

## P1 — 차별화 베팅 (둘 중 하나가 emu의 정체성)

P0의 JSON/verdict 규약 위에 얹는다. **여기서 전략적 분기**: 디버거 길(#3) vs 테스트 길(#4).
판단: **#3(probe)이 더 유니크** — 에이전트가 모는 프로그래밍형 디버거는 대체재가 없다.

### 3. `emu probe` — VM Service logpoint (변수 레벨 검수)
- emu가 이미 캡처하는 `vmServiceUri` + `package:vm_service`로 구현.
- `emu probe lib/cart.dart:42 --capture "total,items.length"` → 그 라인 통과 시마다 표현식 평가→
  기록→**자동 resume**(앱 거의 안 멈춤). 변수 이력을 JSON으로.
- 로그 오라클을 **변수 오라클**로 격상. e2e 도구가 못 하는 영역.
- **한계**: 그 지점 *도달*은 별개(결정적 경로/트리거 필요), 객체 직렬화 깊이 상한 필요, async 프레임 제약.
- **노력**: L (신규 디버그 서브시스템).

### 4. `emu e2e` — 외부 e2e 엔진 구동 + 로그 동시검증  → **🚫 보류 (2026-07-17)**
> **보류 사유**: 이 항목의 존재 이유는 "emu에 신뢰할 입력 수단이 없으니 외부 엔진에 위임한다"였다.
> adb tap이 잘 먹는 게 확인되면서(#5) 전제가 사라졌다. maestro 설치를 전제하는 래퍼는 의존성 대비
> 얻는 게 얇고, **스크린샷을 읽고 좌표를 찍는 에이전트 + `shot`/`tap`/`assert`/`probe`** 조합이
> 같은 일을 외부 의존 없이 더 유연하게 한다. 수요가 생기면 모드 B(`integration_test` 러너)만 재검토.
- e2e 도구는 UI를, emu는 로그를 단언 → 서로 다른 버그(삼켜진 예외, 네트워크 에러, jank)를 잡음.
- 모드 A(추천): `emu up`으로 라이브 앱 + maestro 같은 블랙박스가 같은 앱 구동 → emu가 **그 구간 로그 단언**.
  `emu e2e --run "maestro test flow.yaml" --deny-log "Exception" --expect-log "done" --json`.
- 모드 B: `emu test integration_test/...` 러너 — UI 단언(공식) + 로그 단언 합산, 추가 의존성 0.
- seq 윈도우 상관 + 단일 verdict + 스텝 체크포인트가 emu가 더하는 글루.
- **의존**: #2(assert)의 로그 윈도우 단언을 재사용. 모드 A는 maestro 설치 전제.
- **노력**: M (#2 이후).

## P2 — 보강 / 무거움

### 5. `emu tap` / `emu input`  → **P1로 승격 (2026-07-17 실측 근거)**
- 전제 정정: adb tap은 **잘 먹는다**(위 실측). 우회 로직이 필요 없어 `adb input tap` 얇은 래퍼로 충분.
- 방향: 에이전트가 **스크린샷을 보고 좌표를 찍는다**. emu는 판단하지 않고 **입력 프리미티브만** 제공 —
  판단은 Claude가, 단언은 기존 `assert`/`probe`가. 이러면 `shot + tap + assert/probe`로 루프가 닫히고
  외부 e2e 엔진 의존(#4)이 사라진다.
- 설계 노트:
  - 스크린샷과 tap이 **같은 물리 픽셀 공간**이므로 emu가 좌표 변환을 할 필요 없다.
  - 다만 `--logical` 옵션으로 논리 좌표 입력을 받아 dpr을 곱해주면 편의성↑ (dpr은 VM Service나 로그로 획득).
  - iOS: `simctl` 에 tap 명령이 없다 → 별도 수단 필요(별도 조사 항목). **Android 먼저.**
- **노력**: S (Android). iOS는 미정.

### 6. Tier 2 인터랙티브 디버거
- `emu break/inspect/eval/continue/step`. probe(#3)보다 강력하나 명령 간 **앱 정지** → e2e 동시검증과 양립 불가, probe와 기능 중복. probe 이후 수요 보고 결정.
- **노력**: L.

### 7. iOS 시뮬레이터 실기 검증
- 코드 경로(`bootIos`)는 있으나 본 머신은 `simctl` 미설정으로 미검증. Xcode 설정 후 up→reload→down 검증.
- **노력**: S(환경 준비 제외).

## P3 — 포지셔닝 / 정리

### 8. 대시보드 범위 결정
- 사람용 로그뷰어/리로드는 DevTools+IDE에 열위 → **최소 유지**(에이전트 보조 시각화) 또는 정리.
- README/포지셔닝에 "emu ≠ DevTools 대체, = 에이전트 제어 계층" 명시.

## 알려진 동작 메모 (버그 아님)

- **hot reload는 이미 떠 있는 `Timer.periodic`의 콜백 본문을 갈아끼우지 못할 수 있음** → 출력이 멎으면
  `restart`가 답. Flutter 시맨틱. `reload` 후 "출력 0"일 때 emu가 restart를 힌트로 제안하면 UX↑.

---

## 추천 실행 순서

1. **P0(#1, #2)** 먼저 — 작고, 검증된 가치를 직접 강화, 이후 모든 기능의 JSON/verdict 토대.
2. 그다음 **전략 분기 결정**: 디버거 길(#3 probe) ↔ 테스트 길(#4 e2e). 추천은 **#3** (더 유니크).
3. 선택한 베팅 완료 후 나머지(#4 또는 #5/#7)로 확장.
