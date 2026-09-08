# Changelog

이 파일은 emu의 릴리스 히스토리를 기록한다. 형식은 대략
[Keep a Changelog](https://keepachangelog.com/)를 따르고, 버전은
[Semantic Versioning](https://semver.org/)을 따른다.

## [Unreleased]

### Added
- `emu.yaml`/`emu.local.yaml`에 `profiles:` — 이름 붙은 설정 프리셋을
  `.vscode/launch.json` 없이도 정의(`emu up --profile <name>`,
  `emu config --profile <name>`으로 미리보기, `emu configs`에 목록 추가).
  같은 이름의 profile이 양쪽 파일에 있으면 `emu.local.yaml`이 필드 단위로
  이긴다. `--config`(launch.json)와는 상호 배타.

## [0.5.0] - 2026-09-08

### Added
- `emu find --text <label> | --key <key> | --type <Widget> [--index <n>] [--dump]`
  — `tap --text/--key`가 쓰는 온디바이스 위젯 조회를 탭 없이 노출. `--type`은
  위젯 런타임 타입명 매칭, `--dump`는 각 위젯의 `toString()`도 출력. 매칭
  0개는 에러가 아니라 `(no match)`.
- `emu eval '<dart-expr>'` — 브레이크포인트 없이 앱의 isolate root library
  스코프에서 표현식을 즉시 평가. 그 줄이 실행돼야 값을 주는 `probe`/`inspect`와
  달리 "지금 상태"를 바로 조회한다.
- `emu errors [--since <seq>]` — 로그에 이미 잡히는 Flutter 예외 콘솔 배너
  (`═══╡ ... ╞═══`)를 배너 단위로 묶어 라이브러리/예외 타입/seq 범위로
  구조화. Android는 로그가 logcat 태그를 달고 오므로 그걸 벗기고 매칭한다.
- `emu memory --diff-across "<shell command>" [--all]` — 주어진 커맨드
  실행 전후 힙 인스턴스 수 diff(VM Service `getAllocationProfile(gc:true)`).
  기본은 앱 자신의 패키지 클래스만, `--all`로 프레임워크 클래스까지 포함.

### Fixed
- `up`/`assert`/`probe`/`inspect`/`logs`/`swipe`/`settle`/`tap`이 `--help`나
  잘못된 플래그를 주면 `FormatException` 스택트레이스로 죽던 문제 수정.
  공유 헬퍼(`_parseOrUsage`)로 통일하고 모든 서브커맨드가 `-h`/`--help`를
  지원하도록 함(`find`/`eval`/`errors`/`memory` 포함).
- `emu open-url`이 Android에서 파라미터를 조용히 잃던 문제 수정: `adb shell`은
  argv 경계를 보존하지 않고 인자를 이어붙여 기기의 `/bin/sh`에 다시 넘기므로,
  URL에 `&`가 있으면 거기서 잘렸다. URL을 기기 셸용으로 인용해서 보낸다
  (이슈 리포터 [@Heewookji](https://github.com/Heewookji) 기여, #6).

## [0.4.0] - 2026-09-08

GitHub Issue #2(첫 실사용 후기)에서 나온 제안 중 문서 동기화 1건, 기능 2건,
버그 1건을 하위 워크트리 4개로 나눠 병렬 처리 후 병합.

### Added
- `emu open-url <url> [--no-settle]` — 연결된 기기로 딥링크 전송
  (Android는 `adb shell am start`, iOS는 `xcrun simctl openurl`). 인자를
  항상 argv 배열로 넘겨 쉘 이스케이프/인젝션 문제를 원천 차단. `tap`/`shot`과
  동일하게 기본적으로 전환 settle을 기다린다.
- `emu tap --text <label> | --key <key> [--index <n>]` — 픽셀 좌표 대신
  위젯의 Semantics/Text/Tooltip 라벨이나 `ValueKey`로 탭. VM Service로
  온디바이스 Element 트리를 직접 순회해 좌표를 구한다(적합한 inspector
  서비스 확장이 없어 채택한 접근). 여러 개 매칭 시 `--index`로 선택.

### Fixed
- `emu up`이 서버는 살아있지만 앱 상태가 `stopped`/`failed`인 "유령 세션"을
  만나면 자동으로 정리하고 재기동한다. 실제로 `running`/`starting`/
  `restarting`인 세션은 기존처럼 거부하되, 메시지에 현재 상태를 노출한다.

### Docs
- `skills/emu/SKILL.md`를 `emu` 실제 CLI 명령 전체와 동기화
  (`probe --capture`/`--count`, `shot`/`tap`/`open-url`의 `--no-settle`,
  `logs`의 `--clear`/`--follow`/`--lines`, `assert`의 `--expect`/`--deny`/
  `--since`, `settle`, `stop`, `--version`/`update`/`uninstall` 등 이전에
  누락되어 있던 항목 전부 반영).

## [0.3.0] - 2026-08-11

### Added
- `emu --version` / `-v` — 설치된 버전 + GitHub 최신 태그 대비 업데이트
  가능 여부 표시.
- `emu doctor`에 버전/업데이트 상태 확인 추가.
- `emu update [-y]` — git 체크아웃 기반 설치에서 최신 릴리스로 pull + 재빌드
  (dirty tree 가드, `--json` 지원).
- `emu uninstall [-y]` — 실행 중인 바이너리를 가리키는 PATH 심링크 제거.
- CI: GitHub Actions에 `dart analyze` + `dart test` + 웹 자산 번들 drift
  회귀 검사 추가.

### Fixed
- `tool/bundle_web.dart`가 파일을 정렬 없이 나열해 macOS/Linux 간 생성
  결과가 달라지던 문제 수정(결정적 출력).

## [0.2.0] - 2026-07-20

### Added
- `--dart-define-from-file <path>` 지원(`emu up`, `.vscode/launch.json`
  재현 양쪽 모두).
- `tap`/`shot` 이후 애니메이션/리빌드 settle 대기가 기본 동작으로 전환
  (이전엔 `--settle` 옵션으로 켜야 했음).

## [0.1.0] - 2026-07-20

최초 릴리스. 핵심 루프(기동 → 관찰 → 조작 → 검증 → 종료)와 그 위에 쌓인
초기 기능들을 포함한다.

### Added
- `emu up` / `down` / `stop` / `status` — 세션 생명주기. `up`은 기기 부팅 +
  앱 실행 + `running`/`failed`와 첫 프레임까지 대기.
- `emu reload` / `restart` / `cold` — hot reload/restart/cold restart,
  직후 로그의 에러를 같은 응답에 묶어 반환. reload 후 출력이 멎으면 restart
  힌트 제안.
- `emu logs` / `assert` — 검색 가능한 로그 스트림 + e2e/CI 오라클(로그 단언).
- `emu probe <file:line> --capture <expr>` / `emu inspect <file:line>` —
  VM Service 로그포인트로 변수값 캡처, 또는 그 줄에서 지역변수 전체 +
  콜스택을 덤프.
- `emu shot` / `emu tap` / `emu swipe` / `emu text` — 스크린샷 기반 앱 구동.
  입력 백엔드를 VM Service 합성 포인터로 통일해 Android/iOS 양쪽에서
  동작(유니코드 텍스트 입력 포함).
- `emu configs` / `emu up --config` — `.vscode/launch.json`의 실행 구성
  재현(debug 구성만 실행 가능).
- `emu.yaml`/`emu.local.yaml` 프로젝트별 계층 설정 + `.emu/memory.json`
  학습 메모리.
- `emu devices` — 연결된 기기 + Android AVD 목록.
- 웹 대시보드 — 인터랙티브 스크린샷, DevTools 링크.
- Claude Code 플러그인 패키징(`skills/emu/SKILL.md`, `commands/emu-setup.md`)
  — 셀프 마켓플레이스로 배포.

[Unreleased]: https://github.com/HuanSuh/emu/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/HuanSuh/emu/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/HuanSuh/emu/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/HuanSuh/emu/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/HuanSuh/emu/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/HuanSuh/emu/releases/tag/v0.1.0
