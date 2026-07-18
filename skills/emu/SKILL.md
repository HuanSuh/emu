---
name: emu
description: >
  IDE 없이 Flutter 앱을 기동·조작·검증하는 CLI. Flutter 앱을 디버깅하거나,
  에뮬레이터/시뮬레이터 화면을 캡처·탭·입력·스와이프하거나, hot reload 후
  로그로 검증하거나, 특정 코드 위치의 지역변수를 덤프할 때 사용한다.
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
`EMU_PROJECT=/path/to/app` 를 앞에 붙인다.

## 핵심 루프 (기동 → 관찰 → 조작 → 검증 → 종료)

1. `emu up` — 기기 부팅 + 앱 실행. `running` + 첫 프레임까지 대기한다.
   - 반복 실행이면 `emu.yaml`(flavor/target)·`emu.local.yaml`(device)을 만들어
     인자를 생략한다. `emu config` 로 병합 결과를 확인.
2. `emu shot [path]` — 스크린샷 저장(**물리 픽셀**). 저장 경로를 Read로 확인해
   좌표를 눈으로 산출한다.
3. 조작 — 좌표계는 `shot` 과 동일:
   - `emu tap <x> <y>`
   - `emu text <문자열> [--append]` — 포커스된 필드에 입력(유니코드 OK). 먼저 필드를 탭.
   - `emu swipe <x1> <y1> <x2> <y2> [--duration <ms>]` — 스크롤도 이걸로.
4. 검증:
   - `emu reload` / `emu restart` / `emu cold` — 코드 반영.
   - `emu logs [--grep <re>] [--level <lvl>]` — 앱 로그.
   - `emu assert <조건>` — e2e/CI 오라클(로그 단언).
   - `emu inspect <file:line>` — 그 줄에서 지역변수 전체 + 콜스택 덤프 후 자동 resume.
5. `emu down [--kill-device]` — 세션 종료.

기타: `emu status`(상태+VM Service URI), `emu open`(대시보드), `emu devices`,
`emu doctor`(의존성 점검), `emu configs`(`.vscode/launch.json` 재현).

## 규칙

- **tap/swipe 전에는 항상 `emu shot` 을 새로 떠서 좌표를 확정한다.** 좌표는
  부팅·화면 전환마다 바뀌므로 이전 좌표를 재사용하지 않는다(`.emu/memory.json` 의
  학습값도 권위가 아니다).
- 좌표는 스크린샷 파일의 픽셀 좌표를 그대로 쓴다(다운스케일된 미리보기 크기가 아님).
- 한 번에 한 앱만 구동한다. 새 세션 전 `emu down` 으로 정리.
- 명령마다 `--json` 이 있어 결과를 파싱할 수 있다.
