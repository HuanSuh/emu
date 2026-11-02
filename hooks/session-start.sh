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

# An update is running. Same rule as SelfUpdater._lock: an empty lock is being
# taken right now, unless it is over 5 seconds old (the holder died before
# writing its pid). GNU stat first: BSD rejects -c, but GNU accepts -f.
update_running() {
  [ -f "$lock" ] || return 1
  local holder mtime
  holder=$(cat "$lock" 2>/dev/null)
  if [ -z "$holder" ]; then
    mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null) || return 0
    [ -n "$mtime" ] || return 0
    [ $(($(date +%s) - mtime)) -le 5 ]
    return
  fi
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
    if [ ! -e "$target" ] || newer "$plugin" "$linked" 2>/dev/null; then
      echo "emu $plugin is ready (the CLI still points at an older version folder). Run /emu-setup to move it to ~/.emu/bin and update."
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

notice="emu $plugin is ready (CLI is $current). Update: the hub Update button or \`emu update\`"

if [ "${EMU_AUTO_UPDATE:-}" != "1" ] || ! command -v dart >/dev/null 2>&1; then
  echo "$notice"
  exit 0
fi
# Failed for this version before: say so instead of failing every session.
if [ "$(cat "$failed" 2>/dev/null)" = "$plugin" ]; then
  echo "emu $plugin auto-update failed (log: $log). Update: the hub Update button or \`emu update\`"
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
echo "Updating emu to $plugin in the background (CLI is $current). Running sessions keep running; new sessions use it."
exit 0
