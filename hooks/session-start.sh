#!/usr/bin/env bash
# SessionStart: compare the plugin Claude Code loaded with the emu CLI. Only
# compares — no build, no network — and prints one line for Claude when the
# plugin is newer. With EMU_AUTO_UPDATE=1 it also starts `emu update --local`
# detached. Silent for git checkouts, an older plugin (a project scope may pin
# one: never a downgrade) and while an update runs. Never fails the session.
set -u

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
home="${HOME:-}"
[ -n "$home" ] || exit 0
stable="$home/.emu/bin/emu"
record="$home/.emu/bin/emu.json"
lock="$home/.emu/update.lock"
failed="$home/.emu/auto-update.failed"
log="$home/.emu/auto-update.log"

# The "version" of a JSON file with one key per line.
json_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# 0 when $1 is a newer x.y.z than $2.
newer() {
  local IFS=. i
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  for i in 0 1 2; do
    ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
    ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
  done
  return 1
}

# An update is running: an empty lock is being taken right now.
update_running() {
  [ -f "$lock" ] || return 1
  local holder
  holder=$(cat "$lock" 2>/dev/null)
  [ -z "$holder" ] && return 0
  kill -0 "$holder" 2>/dev/null
}

plugin=$(json_version "$root/.claude-plugin/plugin.json")
[ -n "$plugin" ] || exit 0
update_running && exit 0

if [ ! -e "$stable" ]; then
  # Installed before ~/.emu/bin: a PATH link into an older version folder (or
  # one already gone). A link anywhere else is a checkout: leave it.
  IFS=: read -r -a dirs <<<"${PATH:-}"
  for dir in "${dirs[@]}" /usr/local/bin "$home/.local/bin"; do
    [ -L "$dir/emu" ] || continue
    target=$(readlink "$dir/emu")
    case "$target" in
      */plugins/cache/*/emu/*/emu) ;;
      *) continue ;;
    esac
    linked=$(basename "$(dirname "$target")")
    if [ ! -e "$target" ] || newer "$plugin" "$linked"; then
      echo "emu $plugin 준비됨(현재 CLI 는 이전 버전 폴더를 가리킴). /emu-setup 을 실행하면 고정 위치로 옮기고 업데이트합니다."
    fi
    exit 0
  done
  exit 0
fi

[ -f "$record" ] || exit 0
grep -q '"source"[[:space:]]*:[[:space:]]*"git"' "$record" 2>/dev/null && exit 0
current=$(json_version "$record")
[ -n "$current" ] || exit 0
newer "$plugin" "$current" || exit 0

notice="emu $plugin 준비됨(현재 CLI $current). 업데이트: hub 의 업데이트 버튼 또는 emu update"

if [ "${EMU_AUTO_UPDATE:-}" != "1" ] || ! command -v dart >/dev/null 2>&1; then
  echo "$notice"
  exit 0
fi
# Failed for this version before: say so instead of failing every session.
if [ "$(cat "$failed" 2>/dev/null)" = "$plugin" ]; then
  echo "emu $plugin 자동 업데이트 실패(로그: $log). 업데이트: hub 의 업데이트 버튼 또는 emu update"
  exit 0
fi
# Detached, so it outlives this hook (and `claude -p`). A lost lock race is no
# failure: the winner is building the same thing.
nohup bash -c '
  if "$1" update --yes --local >"$2" 2>&1 || grep -q "another emu update" "$2"; then
    rm -f "$3"
  else
    echo "$4" >"$3"
  fi
' emu-auto-update "$stable" "$log" "$failed" "$plugin" </dev/null >/dev/null 2>&1 &
echo "emu $plugin 로 백그라운드 업데이트를 시작했습니다(현재 CLI $current). 실행 중인 세션은 중단되지 않습니다."
exit 0
