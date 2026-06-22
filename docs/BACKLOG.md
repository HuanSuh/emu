# emu 개선 백로그

이 문서는 초기 구현 이후 "emu의 가치는 무엇인가"를 검증하며 나온 개선 항목들을 기록한다.

## 정리된 포지셔닝 (판단 기준)

emu의 해자는 **"IDE 없이 에이전트가 모는 개발/디버그 inner-loop + 로그 관찰 가능성"** 이다.
DevTools/IDE/e2e 도구의 경쟁자가 아니라, 그들이 못 하는 *비대화형 에이전트 제어*가 본질.
따라서 우선순위는 **에이전트 루프의 "한 번의 호출로 판정"을 강화하는가**를 1차 기준으로 둔다.

검증된 사실:
- 편집 → reload/restart → 로그 검증 루프가 단발성 CLI + `--json`으로 닫힌다. (가치 체감 ✓)
- `debugPrint` / unhandled exception / logcat이 emu에 캡처된다. (런타임 디버깅 가능 ✓)
- 약점: 신뢰할 UI 입력 수단 없음(adb tap이 GestureDetector에 안 먹음), UI 단언 불가.

## 우선순위 요약

| # | 항목 | 가치 | 노력 | 우선순위 | 상태 |
|---|------|------|------|----------|------|
| 1 | `up`/`reload`/`restart`가 최종 상태·직후 에러까지 한 번에 반환 | 높음 | S | **P0** | ✅ 완료 |
| 2 | `emu assert --log` (로그 패턴 단언 + 종료코드) | 높음 | S | **P0** | ✅ 완료 |
| 3 | `emu probe` (VM Service logpoint — 변수 캡처) | 매우 높음(유니크) | L | **P1** | ✅ 완료 |
| 4 | `emu e2e` (외부 e2e 엔진 구동 + 로그 동시검증) | 높음 | M | **P1** | |
| 5 | `emu tap`/`input` 신뢰 가능한 입력 추상화 | 중 | M | P2 | |
| 6 | Tier 2 인터랙티브 디버거(break/inspect/eval/step) | 중~높음 | L | P2 | |
| 7 | iOS 시뮬레이터 실기 검증 | 중 | S | P2 | |
| 8 | 대시보드 범위 결정(최소 유지) + 포지셔닝 문서화 | 낮음 | S | P3 | |
| 9 | `bootAndroid` AVD 선택 개선(첫 AVD 맹목 선택 X) + cold-boot 대기 | 중 | S | P2 | 일부 |

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

### 4. `emu e2e` — 외부 e2e 엔진 구동 + 로그 동시검증
- e2e 도구는 UI를, emu는 로그를 단언 → 서로 다른 버그(삼켜진 예외, 네트워크 에러, jank)를 잡음.
- 모드 A(추천): `emu up`으로 라이브 앱 + maestro 같은 블랙박스가 같은 앱 구동 → emu가 **그 구간 로그 단언**.
  `emu e2e --run "maestro test flow.yaml" --deny-log "Exception" --expect-log "done" --json`.
- 모드 B: `emu test integration_test/...` 러너 — UI 단언(공식) + 로그 단언 합산, 추가 의존성 0.
- seq 윈도우 상관 + 단일 verdict + 스텝 체크포인트가 emu가 더하는 글루.
- **의존**: #2(assert)의 로그 윈도우 단언을 재사용. 모드 A는 maestro 설치 전제.
- **노력**: M (#2 이후).

## P2 — 보강 / 무거움

### 5. `emu tap` / `emu input`
- `adb shell input tap`이 Flutter GestureDetector에 안 먹는 케이스 우회. 좌표 + 스크린샷 기반 옵션.
- e2e 엔진에 위임하면 우회되므로 우선순위 낮음. emu가 **외부 엔진 없이 자체 구동**하려면 필요.
- **노력**: M.

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
