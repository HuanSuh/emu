# 세션 재연결(attach) 설계

> 상태: 구현됨(Unreleased). 이슈 [#13](https://github.com/HuanSuh/emu/issues/13) 2번 항목.

## 1. 문제

emu 세션은 `flutter run --machine` 프로세스 하나에 매달려 있다. 여러 worktree의 에이전트가
한 Mac을 같이 쓰면 다른 프로세스가 adb 서버를 죽이거나 재시작하는데, 그러면 `flutter run` 이
`Lost connection to device` 로 끝나고 세션은 `stopped`/`failed` 가 된다. **앱 프로세스는 기기에
그대로 살아 있는데도** hot reload·eval·inspect 가 모두 끊긴다. `ANDROID_ADB_SERVER_PORT` 로
서버를 분리해도 같이 죽어 피할 수 없었다.

## 2. 목표

- G1. `flutter` 프로세스만 사라지고 앱이 살아 있으면, 같은 앱에 다시 붙는다(재빌드·재설치 없음).
- G2. 자동으로 한 번 시도하고, 수동 재시도 `emu attach` 를 둔다.
- G3. 앱 자체가 죽었으면 붙지 않고 `emu cold` 를 안내한다.
- G4. 재시도 루프 금지: 계속 끊기는 앱을 무한히 다시 붙지 않는다.

## 3. 설계

### 3.1 감지 (`server._watchSetup`)

상태 스트림에서 "실행 중이었는데(`running` 이후, 새 기동 `starting` 전) `stopped`/`failed` 가 되었고,
`stop`/`cold` 같은 의도된 정지가 아니며(`engine.stoppedDeliberately == false`), `flutter` 프로세스가
없다(`engine.hasProcess == false`)"를 연결 끊김으로 본다. daemon이 프로세스 종료 전에 `app.stop` 을
보낼 수 있어 "실행 중이었음"은 다음 기동 전까지 유지한다.

### 3.2 재연결 (`server.reattach`)

1. Android면 adb가 기기를 다시 `device` 로 볼 때까지 최대 60초 대기(`adb -s <기기> get-state`).
2. 빌드 산출물에서 앱 id(`applicationId` / bundle id)를 읽는다(`builtAppId`).
3. 앱이 살아 있는지 확인: Android `adb shell pidof <id>`, iOS `simctl spawn … launchctl list`.
   죽었으면 실패 + `emu cold` 안내(G3).
4. `flutter attach --machine -d <기기>` 를 원래 `run` 인자의 `-t`·`--dart-define*`·DDS 옵션과 함께
   실행한다(hot reload가 같은 진입점·define으로 컴파일해야 하므로). VM Service 찾기:
   - Android: 앱이 시작할 때 logcat에 남긴 `The Dart VM service is listening on <기기측 URL>` 의
     마지막 값을 `--debug-url` 로 넘긴다. flutter가 그 기기 포트를 호스트로 다시 포워딩한다.
     adb 재시작으로 기존 포워딩이 사라져도 동작한다.
   - 로그가 없으면(또는 iOS) `--app-id <id>` 로 flutter의 탐색에 맡긴다.
5. 엔진은 attach 프로세스를 run과 똑같이 다룬다(daemon 이벤트 동일). `emu cold` 는 여전히 원래
   `run` 인자로 재기동한다(`_lastRunArgs` 를 attach 인자로 덮어쓰지 않음).

### 3.3 재시도 정책 (G4)

자동 재연결은 1분에 한 번만 시도한다. 그 안에 다시 끊기면 경고만 남기고 `emu attach` 를 안내한다.
`emu attach` 는 flutter가 아직 연결돼 있으면 거부한다.

### 3.4 함께 복구되는 것

- 기기 임대: 서버가 살아 있으므로 그대로 유지된다.
- 포트 연결(`reversePorts`/`forwardPorts`): 15초 watchdog이 다시 건다.
- `onAppStarted` hook: 세션당 처음 한 번만 실행되므로 재연결 때는 다시 돌지 않는다.

## 4. 한계

- adb가 재시작되는 동안 앱이 찍은 로그는 `flutter attach` 이전 분량이 빠질 수 있다.
- 서버 프로세스 자체가 죽은 경우는 대상이 아니다(`emu up` 이 유령 세션을 회수).
- 실기기 검증은 `flutter` 프로세스를 강제 종료해 재현했다. 실제 `adb kill-server` 는 같은 Mac의
  다른 세션까지 끊기 때문에 검증에 쓰지 않았다.
