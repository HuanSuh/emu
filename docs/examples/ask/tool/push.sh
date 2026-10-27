#!/bin/sh
# Stand-in for a project's push tool that asks what it can't decide alone.
# One question: print `::emu-ask {json}` as a line of its own (printf, not
# echo — sh's echo turns "\n" in the JSON into a real line break), then read
# one line back: {"id": "<the question's id>", "value": …}. value is null when
# no one answered (cancelled prompt/choose, timed out, no one to ask).
set -u
exec 3>&1 # the real stdout: inside $(ask …) fd 1 is the substitution, not emu

ask() {
  printf '::emu-ask %s\n' "$1" >&3
  IFS= read -r answer || answer='{"value":null}'
  printf '%s' "$answer"
}
# The answer's value — enough for true/false/null and plain words; a real
# tool would read the JSON with its own language.
value() { printf '%s' "$1" | sed -e 's/^.*"value"://' -e 's/}$//' -e 's/^"//' -e 's/"$//'; }

echo "checking the deploy repository…"
others="home/banner.json
event/popup.json"

if [ "${EMU_ASK:-0}" != 1 ]; then
  # Nobody to ask: don't guess.
  echo "2 templates were changed there by someone else — run it from the dashboard or a terminal to decide."
  exit 1
fi

env=$(value "$(ask '{"id":"env","kind":"choose","title":"Push to which branch?","options":[{"value":"stage","label":"stage"},{"value":"dev","label":"dev"}]}')")
[ "$env" = null ] && { echo "no branch picked — nothing pushed"; exit 1; }

detail=$(printf '%s' "$others" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }') # lines joined by \n, for JSON
question=$(printf '{"id":"force","kind":"confirm","title":"Overwrite 2 templates someone else changed on %s?","detail":"%s","danger":true,"button":"overwrite"}' "$env" "$detail")
ok=$(value "$(ask "$question")")
[ "$ok" = true ] || { echo "kept their changes — nothing pushed"; exit 1; }

msg=$(ask '{"id":"msg","kind":"prompt","title":"Commit message","fields":[{"name":"message","label":"message","default":"sync templates"}]}' |
  sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
[ -n "$msg" ] || { echo "no message — nothing pushed"; exit 1; }

echo "pushed 2 templates to $env: $msg"
