# 디바이스 임대(Device Lease) 설계

> 상태: v0.7.0 구현. 상위 불변식은 [`DESIGN.md`](DESIGN.md)의 I1(엔진 하나 = 서버 하나)과 I5
> (에이전트 우선 — 판정이 섞이지 않아야 한다).

## 1. 문제

emu의 중복 방지는 **프로젝트 단위**뿐이었다. `emu up`은 `<project>/.emu/server.json`을 보고 같은
프로젝트의 살아 있는 세션만 거부한다. 디바이스는 아무도 소유하지 않았다.

| 시나리오 | 이전 동작 | 결과 |
|---|---|---|
| 다른 프로젝트·다른 worktree에서 `up` | `.emu/`가 달라 서로 못 봄. Android는 `adb devices`의 첫 `emulator-*`, iOS는 첫 Booted 시뮬레이터를 **무조건 재사용**. 포트는 +1/+2/임의로 자동 회피 | 두 세션이 같은 기기에서 탭·스크린샷·설치를 섞음. 같은 bundle id면 앞 세션 앱이 덮어써짐 |
| `emu down --kill-device` | `simctl shutdown all` + `adb emu kill` | **남의 세션 기기까지 전원 차단** |
| `--device`로 남이 쓰는 기기를 지정 | 그대로 진행 | 위와 같음 |

에이전트 여러 개가 worktree마다 병렬 검증을 돌리는 게 emu의 실사용 패턴이라 1행이 가장 흔하다.

## 2. 목표 / 비목표

**목표**
- G1. 한 디바이스는 한 시점에 **한 emu 서버**만 점유한다(기본값). 프로젝트·worktree가 달라도 보인다.
- G2. 자동 선택(`--android`/`--ios`)은 **비어 있는 기기**를 고르고, 다 차 있으면 새로 부팅한다.
  부팅할 것도 없으면 누가 점유 중인지 알려주며 실패한다.
- G3. 명시 지정(`--device`)이 점유 중이면 즉시 실패(`up`이 타임아웃까지 기다리지 않음).
- G4. 죽은 세션의 임대는 자동 회수(수동 정리 불필요).
- G5. `down --kill-device`는 **자기 기기만** 끈다.
- G6. 의도적 공유를 위한 탈출구(`--share-device`).

**비목표**
- 같은 프로젝트 서버를 여러 에이전트가 공유하는 경우(같은 `.emu/`로 `tap`을 동시에 보냄)의
  클라이언트 단위 소유권. 서버가 하나라 I1상 이미 "한 세션"이며, 이를 막으려면 세션 토큰이 필요하다.
  실수요가 확인되면 별도 설계.
- 크로스 머신 조정. 임대는 로컬 파일시스템 기준이다.

## 3. 설계

### 3.1 임대 파일

```
~/.emu/devices/<sanitized-device-id>.json
{"deviceId":"emulator-5554","pid":41231,"port":4578,"project":"/path/to/app","startedAt":"..."}
```

- 전역 위치(`$HOME/.emu/devices/`)라 프로젝트·worktree와 무관하게 공유된다.
- 파일명은 device id에서 `[A-Za-z0-9._-]` 외 문자를 `_`로 치환.
- **소유 주체는 서버 프로세스**(`pid`)다. CLI 명령은 단발성(I4)이라 소유할 수 없다.

### 3.2 획득(acquire)

```
acquire(deviceId, me):
  1. 배타 생성(create exclusive) 성공 → 획득
  2. 이미 있음 → holder 읽기
     a. 파싱 불가              → stale
     b. holder.pid == me.pid    → 획득(멱등)
     c. holder.project == me.project → 같은 프로젝트의 이전 세션(= up이 방금 회수한 ghost) → stale 취급
     d. holder 생존            → 충돌(holder 반환)
     e. 그 외                  → stale
  3. stale → 내용이 그대로인지 재확인 후 삭제, 1로 재시도(최대 10회 — 상대가 막 만들어 아직 비어 있는 파일은 stale로 보지 않고 50ms 대기)
```

**생존 판정** = `kill -0 <pid>` 성공 **그리고** `http://127.0.0.1:<port>/api/status`가 200.
pid만 보면 pid 재사용에, 포트만 보면 다른 emu 서버의 포트 재사용에 속는다. 둘 다 보면 사실상 안전하다.
서버는 bind 직후 `server.json`을 쓰고 그 다음에 디바이스를 고르므로, 임대를 쥔 시점엔 항상 ping에 응답한다.

앱이 `stopped`/`failed`인 ghost 서버도 **점유로 본다**(보수적). 실패한 `up`은 이미 서버를 자동
정리하고, 남는 ghost는 충돌 메시지에 프로젝트 경로·대시보드·상태가 찍히므로 사용자가 `emu down`하면 된다.

3번의 "재확인 후 삭제"는 두 경합자가 동시에 같은 stale 파일을 보고 한쪽이 새로 만든 임대를 다른 쪽이
지우는 창을 좁힌다(완전 원자는 아님 — 같은 기기에 ms 단위로 동시 `up`하는 경우만 해당).

### 3.3 디바이스 선택과의 결합

선택과 획득을 분리하면 "골랐는데 획득 실패" 경합이 생기므로, `DeviceManager`에 **`claim` 콜백**을
넘겨 후보를 순회하며 **획득에 성공한 첫 후보**를 쓴다.

| 경로 | 동작 |
|---|---|
| `--android` (기기 미지정) | 실행 중 에뮬레이터들을 순서대로 claim → 성공하면 재사용. 전부 점유 중이면 **실행 중이 아닌 AVD**(선호도 규칙 `preferredAvd` 적용)를 부팅하고, 부팅 전후 `adb devices` 차집합으로 새 serial을 찾아 claim. 부팅할 AVD가 없으면 실패 |
| `--ios` (기기 미지정) | Booted 시뮬레이터들을 순서대로 claim. 전부 점유 중이면 Shutdown 상태의 iPhone을 **부팅 전에** claim(udid를 미리 앎)한 뒤 부팅. 없으면 실패 |
| `--device <id>` | 부팅/실행 전에 claim. 실패하면 즉시 실패 |
| 플랫폼·기기 모두 미지정 | flutter가 기기를 고르므로 사전 차단 불가. 앱 시작 이벤트로 deviceId를 알게 되면 claim하고, 충돌이면 **error 로그로 경고**(verdict의 `errors`에 실림). 문서에서 `--android`/`--ios`/`--device` 사용을 권장 |

실패는 `DeviceException` → 서버가 엔진 상태를 `failed`로 표시 → `up`이 타임아웃 없이 바로
실패 verdict를 내고 서버를 정리한다(이전엔 기기 오류 시 상태가 `stopped`에 머물러 `up`이 타임아웃까지 대기했다).

충돌 메시지 예:
```
device emulator-5554 is in use by another emu session
  project: /Users/me/wt/feature-b   dashboard: http://127.0.0.1:4578
  → pick another --device, run `emu down` in that project, or pass --share-device
```

### 3.4 해제(release)

- 서버 `dispose()`(= `emu down`, `/api/shutdown`, 실패 up 정리)에서 **holder.pid가 자기 pid일 때만** 삭제.
- `dispose()`는 먼저 disposed 표시를 한다. 그 사이 진행 중이던 사후 claim(3.3 마지막 행)은 획득 직후 스스로 반납해 누수되지 않는다.
- 크래시·`kill -9`로 해제를 못 해도 3.2의 생존 판정이 다음 획득 때 회수한다(G4).

### 3.5 `--share-device`

`emu up --share-device`: 점유 검사를 건너뛰고 **임대를 쓰지도 않는다**(남의 임대를 덮어쓰면 그쪽의
해제 로직과 `--kill-device` 보호가 깨지므로). 남이 쥐고 있으면 warning 로그만 남긴다.
대가로 공유 세션은 보이지 않는다: 임대 보유 세션의 `down --kill-device` 가 기기를 끌 수 있고,
`emu devices` 에도 나타나지 않는다.

### 3.6 `down --kill-device`

1. 종료 전에 `/api/status`로 자기 deviceId를 얻는다.
2. 서버 종료(→ 자기 임대 해제).
3. 그 기기에 **다른 살아 있는 임대**가 있으면 끄지 않고 알린다.
   `--share-device` 세션은 임대를 쓰지 않으므로(3.5) 이 검사로 보호되지 **않는다** — 공유는 자기 책임.
4. 아니면 그 기기만 끈다: iOS `simctl shutdown <udid>`, Android 에뮬레이터 `adb -s <serial> emu kill`.
   물리 기기·deviceId 미상이면 끄지 않고 알린다.

이전의 "전부 끄기"는 emu와 무관한 사용자 기기까지 끄므로 제거한다(동작 변경 — CHANGELOG Changed).

### 3.7 관측

`emu devices`가 임대 정보를 함께 보여준다(`--json`은 기기별 `lease` 필드). 에이전트가 `up` 전에
빈 기기를 확인할 수 있다.

## 4. 코드 배치

| 파일 | 변경 |
|---|---|
| `lib/src/device_lease.dart` (신규) | `DeviceLease` 모델, `DeviceLeases`(acquire/release/holderOf/liveHolderOf), 생존 판정 기본 구현, 파일명 치환 |
| `lib/src/device_manager.dart` | `bootAndroid`/`bootIos`에 `claim` 콜백, 순수 헬퍼 `parseAdbEmulators`/`chooseAvdToBoot`/`parseSimctlDevices`, 단일 기기 `shutdownDevice` |
| `lib/src/engine.dart` | `markFailed(message)` — 기동 전 실패를 `failed`로 |
| `lib/src/server.dart` | `LaunchOptions.shareDevice`, `_launch`에서 claim 결합, 사후 claim, `dispose`에서 release |
| `lib/src/cli.dart` | `up --share-device`, `__serve --share-device`, `down --kill-device` 개편, `devices` 임대 표시 |
| `test/device_lease_test.dart` (신규) | 획득/멱등/같은 프로젝트 회수/충돌/stale 회수/해제 소유 검사/파일명 |
| `test/device_manager_test.dart` | 순수 헬퍼 테스트 |

## 5. 불변식 점검

- I1: 서버가 엔진과 **기기**를 단독 소유하도록 확장. 강화.
- I4: CLI는 여전히 무상태. 소유 주체는 서버 프로세스.
- I5: 섞인 입력으로 판정이 오염되는 것을 막고, 충돌을 즉시 실패 verdict로 돌려준다. 강화.
