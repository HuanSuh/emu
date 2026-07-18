---
description: emu 바이너리를 빌드하고 PATH에 심링크해 전역에서 쓸 수 있게 한다
---

emu CLI를 이 머신에 설치한다. 플러그인 루트는 `${CLAUDE_PLUGIN_ROOT}` 다.

1. `dart --version` 으로 Dart SDK 설치를 확인한다. 없으면 사용자에게
   Flutter/Dart 설치를 안내하고 중단한다.
2. `${CLAUDE_PLUGIN_ROOT}` 에서 `dart pub get` 후 `./build.sh` 로 `emu` 바이너리를
   빌드한다(build.sh 가 없으면 `dart compile exe bin/emu.dart -o emu`).
3. `${CLAUDE_PLUGIN_ROOT}/emu` 를 PATH의 디렉터리에 심링크한다. 우선순위:
   쓰기 가능한 `/usr/local/bin` → 없으면 `~/.local/bin`(PATH에 없으면 추가 안내).
   `ln -sf "${CLAUDE_PLUGIN_ROOT}/emu" <target>/emu`
4. `emu doctor` 를 실행해 flutter/adb/emulator/xcrun 의존성 상태를 보여주고,
   설치 결과(심링크 경로)를 사용자에게 보고한다.

심링크·PATH 수정은 되돌릴 수 있는 범위지만, 대상 경로를 사용자에게 먼저 알린 뒤
진행한다.
