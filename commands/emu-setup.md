---
description: emu 바이너리를 빌드하고 PATH에 심링크해 전역에서 쓸 수 있게 한다
---

emu CLI를 이 머신에 설치한다. 플러그인 루트는 `${CLAUDE_PLUGIN_ROOT}` 다.

1. `dart --version` 으로 Dart SDK 설치를 확인한다. 없으면 사용자에게
   Flutter/Dart 설치를 안내하고 중단한다.
2. `${CLAUDE_PLUGIN_ROOT}` 에서 `./build.sh` 로 `emu` 바이너리를 빌드한다.
3. `"${CLAUDE_PLUGIN_ROOT}/emu" install --json` 으로 버전과 무관한 고정 위치
   `~/.emu/bin/emu` 에 설치한다. 실행 중인 hub·세션은 끊기지 않고, 이 바이너리나 사라진
   플러그인 버전 폴더를 가리키던 PATH 링크는 고정 위치로 옮겨진다(결과의 `linked`).
   이미 더 새 버전이 있으면 그대로 둔다.
4. PATH의 디렉터리에 심링크한다. 우선순위: 쓰기 가능한 `/usr/local/bin` → 없으면
   `~/.local/bin`(PATH에 없으면 추가 안내). 기존 `emu` 가 플러그인 버전 폴더를 가리키면
   이 명령으로 바꾸고, 다른 곳(git 체크아웃 등)을 가리키면 사용자에게 먼저 묻는다.
   `ln -sf "$HOME/.emu/bin/emu" <target>/emu`
5. `emu doctor` 를 실행해 flutter/adb/emulator/xcrun 의존성 상태를 보여주고,
   설치 결과(심링크 경로)를 사용자에게 보고한다.

심링크·PATH 수정은 되돌릴 수 있는 범위지만, 대상 경로를 사용자에게 먼저 알린 뒤
진행한다.
