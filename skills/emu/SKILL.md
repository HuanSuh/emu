---
name: emu
description: >
  IDE 없이 Flutter 앱을 기동·조작·검증하는 CLI. Flutter 앱을 디버깅하거나,
  에뮬레이터/시뮬레이터 화면을 캡처·탭·입력·스와이프·딥링크로 조작하거나, hot
  reload 후 로그로 검증하거나, 특정 코드 위치의 지역변수를 덤프할 때 사용한다.
  키워드: flutter 디버그, 앱 기동, 스크린샷 탭, hot reload 검증, emu.
---

# emu — IDE-less Flutter driver

로컬 서버가 `flutter run --machine` 을 소유하고, CLI는 그 위의 얇은 클라이언트다.
Claude는 아래 CLI 루프로 Flutter 앱을 직접 기동·조작·검증한다.

## 전제

`emu` 가 PATH에 있어야 한다. 없으면 먼저 `/emu-setup` 을 실행하거나:

```bash
cd <emu-repo> && dart pub get && ./build.sh
ln -sf "$PWD/emu" /usr/local/bin/emu
```

명령은 **Flutter 프로젝트 루트**(또는 그 하위)에서 실행한다. 다른 곳이면
`EMU_PROJECT=/path/to/app` 를 앞에 붙인다. 모든 명령은 `--json` 을 지원한다.

## 핵심 루프 (기동 → 관찰 → 조작 → 검증 → 종료)

1. `emu up [opts]` — 기기 부팅 + 앱 실행. `running` + 첫 프레임까지 대기한다.
   - 반복 실행이면 `emu.yaml`(flavor/target)·`emu.local.yaml`(device)을 만들어
     인자를 생략한다. `emu config` 로 병합 결과를 확인.
   - 주요 옵션: `--android`/`--ios`, `-d/--device <id>`, `--config <name>`
     (`.vscode/launch.json` 재현), `--flavor`, `-t/--target <file>`,
     `--dart-define K=V`(반복), `--dart-define-from-file <path>`(반복),
     `-a/--dart-entrypoint-args <arg>`(반복), `--device-timeout <s>`,
     `--device-connection <both|attached|wireless>`, `--dds-port <n>`,
     `--no-dds`, `--port <n>`(기본 4577), `--timeout <s>`(기본 240), `--open`.
2. `emu shot [path] [--no-settle]` — 스크린샷 저장(**물리 픽셀**, 기본
   `.emu/shot-<ts>.png`). 저장 경로를 Read로 확인해 좌표를 눈으로 산출한다.
   기본적으로 애니메이션/리빌드가 멈추길 먼저 기다린다.
3. 조작 — 좌표계는 `shot` 과 동일:
   - `emu tap <x> <y> [--no-settle]`
   - `emu text <문자열> [--append]` — 포커스된 필드에 입력(유니코드 OK). 먼저 필드를 탭.
   - `emu swipe <x1> <y1> <x2> <y2> [--duration <ms>]` — 스크롤도 이걸로.
   - `emu open-url <url> [--no-settle]` — 딥링크를 연결된 기기로 전송(Android는
     `adb shell am start`, iOS는 `xcrun simctl openurl`을 인자 배열로 호출해
     쉘 이스케이프 문제 없이 안전하게 처리). `&` 등 쿼리스트링 특수문자를
     따로 이스케이프할 필요 없음.
   - `tap`/`shot`/`open-url` 은 기본적으로 결과 전환이 끝날 때까지 settle을
     기다린다. 필요 없으면 `--no-settle` 로 끈다.
4. 검증:
   - `emu reload` / `emu restart` / `emu cold` / `emu stop` — 코드 반영/정지.
   - `emu logs [opts]` — 앱 로그.
     - `-g/--grep <regex>`, `-l/--level <e|w|i>`, `-n/--lines <N>`(기본 200),
       `-f/--follow`(스트리밍), `--clear`(버퍼 비우기).
   - `emu assert [opts]` — e2e/CI 오라클(로그 단언).
     - `--expect <regex>`(반드시 나타나야 함, 반복 가능),
       `--deny <regex>`(나타나면 안 됨, 반복 가능), `--since <seq>`(기본: 지금),
       `--timeout <s>`(기본 5). `tap`/`text` 가 반환하는 `seq` 를 `--since` 에
       넘기면 그 입력이 유발한 로그만 정확히 검증할 수 있다.
   - `emu probe <file:line> --capture "expr,expr" [--count <n>] [--timeout <s>]`
     — VM Service 로그포인트로 그 줄이 실행될 때 표현식을 평가해 값을 찍는다.
     `--count`(기본 1, N번 hit까지 대기), `--timeout`(기본 10s).
   - `emu inspect <file:line> [--timeout <s>]` — 그 줄에서 지역변수 전체 +
     콜스택 덤프 후 자동 resume. 이름을 몰라도 되는 `probe` 대체재.
5. `emu down [--kill-device]` — 세션 종료.

## 기타 명령

- `emu status` — 세션/기기/앱 상태 + VM Service URI.
- `emu open` — 대시보드를 브라우저로 열기.
- `emu settle [--timeout <s>] [--quiet <ms>]` — 애니메이션/리빌드가 멈출 때까지
  대기(`tap`/`shot`/`open-url` 은 이미 기본으로 이걸 하므로, 두 명령 사이에
  독립적으로 끼워 넣거나 기본값보다 세밀하게 조정할 때만 필요).
- `emu devices` — 실행 중인 기기 + Android AVD 목록.
- `emu configs` — `.vscode/launch.json` 재현 가능한 구성 목록.
- `emu config` — `emu.yaml` 계층 병합 결과 + 학습된 메모리.
- `emu doctor` — 의존성 점검(flutter/adb/emulator/xcrun) + 업데이트 여부.
- `emu --version`/`-v`, `emu update [-y]`, `emu uninstall [-y]` — 버전 확인,
  최신 릴리스로 업데이트, PATH 심링크 제거.

## 규칙

- **tap/swipe 전에는 항상 `emu shot` 을 새로 떠서 좌표를 확정한다.** 좌표는
  부팅·화면 전환마다 바뀌므로 이전 좌표를 재사용하지 않는다(`.emu/memory.json` 의
  학습값도 권위가 아니다).
- 좌표는 스크린샷 파일의 픽셀 좌표를 그대로 쓴다(다운스케일된 미리보기 크기가 아님).
- 한 번에 한 앱만 구동한다. 새 세션 전 `emu down` 으로 정리.
- 명령마다 `--json` 이 있어 결과를 파싱할 수 있다.
- `tap`/`text` 로 입력을 넣은 직후 바로 `assert` 로 검증하지 말고, 반환된
  `seq` 를 `--since` 에 넘겨서 그 입력 이후의 로그만 정확히 확인한다.
