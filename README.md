<p align="center">
  <img src="docs/assets/emu_icon.png" alt="emu" width="140" height="140" />
</p>

<h1 align="center">emu — Flutter debug driver</h1>

<p align="center"><b>English</b> · <a href="README.ko.md">한국어</a></p>

A tool for debugging Flutter apps without an IDE. It boots an emulator/simulator,
performs **hot reload / hot restart / cold restart**, and exposes **searchable,
filterable debug logs** through both a **CLI** (for agents like Claude Code and
the terminal) and a **web dashboard** (for humans).

The core design is **"one engine, two frontends"** — a local server exclusively
owns the `flutter run --machine` session (the engine), and the CLI and dashboard
are both HTTP/WebSocket API clients of that server.

```
flutter run --machine  ◄─JSON-RPC─►  engine  ──►  server (127.0.0.1:4577)
                                                    ├─ REST + WebSocket API
                                                    ├─ web dashboard  (browser)
                                                    └─ CLI            (terminal / agent)
```

> **Where this tool fits**: it is not a replacement for DevTools/IDEs/e2e test
> tools. Its essence is what those can't do — **a non-interactive, agent-driven
> develop/debug inner-loop without an IDE, plus log and variable observation**.
> See [Limitations & comparison](#limitations--comparison) for the details.

---

## Table of contents
- [Requirements](#requirements)
- [Install / build](#install--build)
- [Quick start](#quick-start)
- [Core workflow: the agent debug loop](#core-workflow-the-agent-debug-loop)
- [Command reference](#command-reference)
- [Web dashboard](#web-dashboard)
- [How it works](#how-it-works)
- [State files (.emu/)](#state-files-emu)
- [Limitations & comparison](#limitations--comparison)
- [Project layout](#project-layout)
- [Development](#development)
- [Roadmap](#roadmap)

---

## Requirements

| Target | What you need |
|--------|---------------|
| Common | Flutter SDK (`flutter` on PATH) — **required** |
| Android | Android SDK `adb` + `emulator` (to boot an AVD) |
| iOS | Full Xcode + `xcrun simctl` (macOS only) |

Check your setup with `emu doctor`.

## Install / build

```bash
./build.sh                          # embed dashboard assets + compile a single binary
ln -sf "$PWD/emu" /usr/local/bin/emu   # put it on PATH
```

You can also run straight from source without building (for development):

```bash
dart run bin/emu.dart <command>
```

### Install as a Claude Code plugin (global)

This repo is both a Claude Code plugin and a self-hosted marketplace. Once
installed, Claude can use emu (via a skill) and the `/emu-setup` command in any
project.

```
/plugin marketplace add HuanSuh/emu   # or a local path: /plugin marketplace add <this repo path>
/plugin install emu@emu
/emu-setup                            # automates the binary build + PATH symlink
```

- `skills/emu/SKILL.md` — teaches Claude the boot → observe → drive → verify loop.
- `commands/emu-setup.md` — builds the `emu` binary and symlinks it onto PATH.
- The skill needs the `emu` binary on PATH (`/emu-setup` handles that).

## Quick start

Run it inside a Flutter project and it auto-detects the root via `pubspec.yaml`.
To run from elsewhere, set `EMU_PROJECT=/path/to/app`.

```bash
emu doctor                # check dependencies
emu devices               # connected devices + Android AVD list

emu up --android          # boot a default AVD → launch the app → start the dashboard
emu up -d emulator-5554   # run on a specific device

emu reload                # hot reload
emu restart               # hot restart
emu logs --grep "Exception" -f   # live log search
emu status                # session/device/VM Service status
emu down                  # end the session
```

Every command supports `--json` (for agents/scripts). `emu logs --json` emits
JSONL (one JSON object per line).

## Core workflow: the agent debug loop

emu's reason to exist. It closes **edit → apply → verify** entirely through
one-shot CLI calls. No human keystrokes or IDE GUI — an agent like Claude can
run it as-is.

```bash
# 1) Launch the app — waits for running/failed + first-frame, then returns the real result
emu up -d emulator-5554 --json
# → {"ok":true,"state":"running","firstFrame":true,"dashboard":"http://127.0.0.1:4577","errors":[]}

# 2) Detect runtime errors from the logs
emu logs --level error --grep "Exception" --json

# 3) Apply a code change (errors right after are bundled into the same call)
emu reload --json
# → {"ok":true,"message":"Reloaded 3 libraries","errors":[]}   # empty errors = clean

# 4) Verify behavior (log assertion, judged by exit code)
emu assert --deny "Exception" --expect "checkout done" --timeout 6
# → exit 0 (pass) / exit 1 (fail)

# 5) Inspect deeper at the variable level
emu probe lib/cart.dart:42 --capture "total,items.length"
# → ● lib/cart.dart:42   total=12500   items.length=3

# 6) Drive the screen directly — read coordinates off a screenshot
emu shot ui.png                                  # the agent reads coordinates from the image
emu tap 670 436                                  # focus a field → type → scroll
emu text "sunglasses"
emu swipe 670 2500 670 1200
SEQ=$(emu tap 670 1486 --json | jq -r .seq)      # tap the checkout button (seq = log cursor just before the tap)
emu assert --since "$SEQ" --deny "Exception" --expect "checkout done" --timeout 5
```

What this loop gives an agent:
- **Single-call verdicts** — `up`/`reload`/`restart` tell you whether it
  "actually worked" in one shot (see below).
- **Log oracle** — `assert` states "after this action, this log must / must not appear".
- **Variable oracle** — `probe` reads variable values at runtime that were never logged.
- **A way to drive** — `shot` + `tap` drive the app directly. emu only injects
  coordinates; **the agent decides**, and `assert`/`probe` verify — drive→verify
  closes without an external e2e engine.

## Command reference

`--json` is available on every command.

### Lifecycle

| Command | Description |
|---------|-------------|
| `emu doctor` | Check dependencies (flutter / adb / emulator / xcrun) |
| `emu devices` | `flutter devices` + Android AVD list |
| `emu configs` | List run configs from `.vscode/launch.json` (debug only) |
| `emu config` | Show the merged `emu.yaml` config + learned memory |
| `emu up [opts]` | Boot device + launch app + start dashboard. Waits for `running`/`failed` + first frame |
| `emu down [--kill-device]` | End the session. `--kill-device` also powers the device off |
| `emu stop` | Stop only the app (server stays up) |
| `emu status` | Session/device/app status + VM Service URI |
| `emu open` | Open the dashboard in a browser |
| `emu shot [path]` | Save a screenshot (default `.emu/`). Relative paths resolve to the project root |
| `emu tap <x> <y>` | Tap a coordinate (physical pixels — same space as `shot`). Android & iOS |
| `emu swipe <x1> <y1> <x2> <y2>` | Swipe/scroll. `--duration <ms>`. Android & iOS |
| `emu text <string> [--append]` | Type into the focused field (unicode OK). Android & iOS |

`emu up` options:

| Option | Description |
|--------|-------------|
| `--android` / `--ios` | Boot a default device of that platform |
| `-d, --device <id>` | Use a specific flutter device id. An iOS simulator udid auto-boots even if off |
| `--config <name>` | Replay a `.vscode/launch.json` config (individual flags override it) |
| `--flavor <name>` | Build flavor |
| `-t, --target <file>` | Entry point (e.g. `lib/main_dev.dart`) |
| `--dart-define K=V` | dart-define (repeatable) |
| `--port <n>` | Dashboard port (default 4577, auto-falls back if in use) |
| `--timeout <s>` | Window to wait for `running`/`failed` (default 240). Raise it for long cold boots |
| `--open` | Open a browser after launch |

### configs — replay `.vscode/launch.json`

Reuse the run configs (flavor / target / dart-define / device) a project already
defines, without an IDE. List them with `emu configs`, then launch with
`emu up --config "<name>"`.

```bash
emu configs                          # list configs (--json available)
emu up --config "myapp (dev)"        # run exactly that config
emu up --config "myapp (dev)" --flavor staging   # individual flags override config values
```

- Reads `launch.json` (JSONC: comments and trailing commas allowed) and extracts
  only `type: "dart"` configs. Recognizes `flutterMode`/`deviceId`/`program` and
  `--flavor`/`-t`/`--dart-define` in `args`/`toolArgs`.
- **Debug configs only**: emu drives debug builds only, because of hot reload and
  the VM Service (`probe`). `profile`/`release` configs are shown as `⚠ debug-only`
  in `configs` and `up --config` rejects them (exit 1).
- Flags it can't yet replay (e.g. `--dart-define-from-file`) are marked as
  unsupported in the listing — pass `--dart-define` manually if needed.

### config — per-project layered config + memory

So repeated runs don't re-specify device and flags every time, per-project config
is layered by **commit boundary**. A value that is "true across machines and time"
goes in the committed layer; one that is "only true on this machine right now"
goes in the git-ignored local layer.

Precedence (high → low):

| Layer | File | Nature |
|-------|------|--------|
| explicit flag | `emu up --flavor …` | CLI argument |
| `--config` | `.vscode/launch.json` | named config |
| local | `<root>/emu.local.yaml` | **git-ignored**. This machine only (`device`, etc.) |
| project | `<root>/emu.yaml` | **committed**. Team-shared (`flavor`, `dartDefines`, `target`) |
| user | `~/.emu/config.yaml` | Defaults across all projects (`timeout`, etc.) |
| built-in | code | Final fallback |

```yaml
# emu.yaml  (committed)
flavor: dev
target: lib/main_dev.dart
dartDefines:
  - API_URL=https://staging.example.com
timeout: 300
```
```yaml
# emu.local.yaml  (should be git-ignored)
device: emulator-5554
```
```bash
emu config          # show the merged result + memory (--json available)
emu up              # the values above apply as defaults (flags still override)
```

- Scalars are overridden by higher layers; a list (`dartDefines`) is replaced
  wholesale (no accumulation).
- A malformed layer only warns and is skipped — one bad config file won't kill `up`.
- Add `emu.local.yaml` to your `.gitignore` yourself (it holds machine-specific
  values, so don't commit it).

**Learned memory (`.emu/memory.json`, git-ignored)** — recomputation hints the
tool picks up while running (`lastScreen`, `lastDpr`, `lastInspect`, `seenKeys`).
It is **not authoritative**: a later run does not trust it and skip a screenshot
before tapping. Coordinates rot across boots, so they are not stored here.

### reload / restart / cold

| Command | Meaning |
|---------|---------|
| `emu reload` | hot reload (`app.restart{fullRestart:false}`) |
| `emu restart` | hot restart (`app.restart{fullRestart:true}`) |
| `emu cold` | cold restart — full process restart (picks up native/pubspec changes) |

`reload`/`restart` include error logs from a **short window right after** (2.5s)
in the response's `errors`. → the agent judges "did my fix work?" in **one call**.
(See limitations below.)

### logs

```bash
emu logs [opts]
  -g, --grep <regex>   case-insensitive regex filter
  -l, --level <e|w|i>  minimum level (error/warn/info)
  -n, --lines <N>      last N lines (default 200)
  -f, --follow         live stream
  --clear              clear the log buffer
```

Reads offline from `.emu/run.jsonl` even when the server is down.

### assert — log assertion (e2e/CI oracle)

```bash
emu assert [opts]
  --expect <regex>   pattern that must appear (repeatable)
  --deny <regex>     pattern that must never appear (repeatable)
  --since <seq>      log cursor (default: from now)
  --timeout <s>      wait window (default 5s)
```

If every `--expect` appears and no `--deny` does, **exit 0**, otherwise **exit 1**.
`--deny` fails the moment it matches; `--expect` must appear within the timeout.

```bash
emu assert --deny "FormatException" --expect "parsed value" --timeout 6
```

### tap / swipe / text — drive the app (for agents)

```bash
emu shot ui.png                      # capture the screen, then
emu tap 670 1486                     # tap the coordinate the agent read off the image
emu swipe 670 2500 670 1200          # scroll (--duration <ms>, default 300)
emu text "hello world"               # type into the focused field — tap the field first
# → ✓ tap 670,1486   (seq 28)
```

**There is exactly one coordinate space: physical pixels.** `shot` captures in
physical pixels and input is received in physical pixels (divided by dpr on-device
into framework logical coordinates). Pass the pixel coordinates you read off the
image directly.

> **Implementation**: input goes through **the running app's VM Service**, not
> `adb`/`simctl` — it dispatches synthetic pointer events to the framework and
> updates the focused text field directly (the same infrastructure as `probe`).
> That's why **Android and iOS use the same path**, and why `text` can enter
> **unicode** (Korean, emoji).

> ⚠️ **Agent caution**: if a screenshot reaches you downscaled (e.g. 1344×2992 →
> 898×2000), you must **multiply the coordinates you read off the image by the
> downscale ratio** to get physical coordinates. This is the most common cause of
> taps landing in the wrong place.

The `seq` that `tap` returns is the **log cursor just before the tap**. Pass it to
`assert --since` to assert "what this tap triggered" over the exact window:

```bash
SEQ=$(emu tap 670 1486 --json | jq -r .seq)
emu assert --since "$SEQ" --expect "checkout done" --deny "Exception" --timeout 5
```

Calling `assert` after `tap` without `--since` **misses**: `assert`'s default
window is "from now", so it can't see logs that already happened.

**Input effects are asynchronous.** The dispatch returns immediately, but frame
builds and listener execution come after. Don't guess with `sleep` — confirm
arrival with **`assert --since`**.

```bash
emu tap 670 436                                  # tap the field first to focus it
SEQ=$(emu text "한글 hello 😀" --json | jq -r .seq)
emu assert --since "$SEQ" --expect 'text="한글 hello 😀"' --timeout 8   # confirm arrival
emu text " more" --append                          # append after the current value
```

- **`text` is unicode-OK.** Korean and emoji both work (the VM Service path has
  none of `adb input text`'s ASCII limit). It **replaces** the whole value; use
  `--append` to add on.
- **`text` only types into whatever is focused** — it doesn't target a widget. Tap
  the field first. With no focused text field you get a `no focused text field` error.
- **The soft keyboard covers the screen.** Tapping a field raises the keyboard over
  lower widgets, so re-run `shot` before using later coordinates (on Android, close
  it with `adb shell input keyevent 4`).
- **Flutter widgets only**: input is framework-level, so it doesn't reach native /
  webview text fields (fine, since emu is for driving Flutter apps).
- **It does not assert on UI**: emu only injects input; judgment is done by
  `assert` (logs) / `probe` (variables).

### probe — capture variables (VM Service logpoint)

```bash
emu probe <file:line> [opts]
  -c, --capture <e,e>  expressions to evaluate on hit (comma-separated)
  --count <n>          stop after N hits (default 1)
  --timeout <s>        time to wait for a hit (default 10s)
```

Sets a breakpoint at `file:line`, evaluates the capture expressions at the paused
frame → records → **auto-resumes**. Reads variable state without stopping the app
(beyond a brief instant).

```bash
emu probe lib/cart.dart:42 --capture "total,items.length,coupon" --count 3
# ● lib/cart.dart:42   total=12500   items.length=3   coupon=null
```

> `probe` reads `final` / fields / ordinary locals. A `const` local is inlined at
> compile time and has no runtime slot, so it can't be evaluated.

### inspect — dump all locals + call stack

```bash
emu inspect <file:line> [--timeout <s>]
```

Where `probe` reads expressions you **name**, `inspect` dumps **every local in the
frame plus the call stack** at that line and auto-resumes — you don't need to know
the variable names, so it's great for surveying an unfamiliar spot / crash site.

```bash
emu inspect lib/main.dart:34
# ● lib/main.dart:34
#   this = <_DemoPageState>
#   before = 1
#   next = 2
#   label = "gesture #2"
#   stack:
#     _increment  (main.dart:34)
#     handleTapUp (tap.dart:758)
#     ...
```

- Shows the top frame's locals. A **closure line** like `setState(() => …)` has no
  locals of its own — if the dump is empty, inspect the method's **body statement
  line** instead.
- Non-primitives show as `<ClassName>` — to look deeper, evaluate that field with `probe`.
- Interactive `break`/`step`/`continue` is **intentionally absent**: holding the
  app paused between commands would freeze logs and `probe` and conflict with emu's
  one-shot model. `inspect` just takes a snapshot and resumes immediately.

## Web dashboard

`emu up` serves a dashboard at `http://127.0.0.1:4577`:

- Live log stream — **regex search**, **level filter** (debug/info/warn/error),
  match highlighting, copy, clear.
- Buttons: **Hot reload / Hot restart / Cold restart / Stop** (`r` / `R` keys too).
- **Interactive screenshot panel** — shows the device screen and drives it directly
  with **click = tap / drag = swipe**. The input box at the bottom types into the
  focused field (unicode). Coordinate conversion is handled by the dashboard (the
  screenshot-ratio trap agents hit doesn't exist for humans). Check `auto` to
  refresh periodically.
- Status bar — device, app state, **DevTools link** (a real DevTools served via
  `devtools.serve`).

## How it works

- **Control**: uses the Flutter daemon protocol (`flutter run --machine`). Hot
  reload = `app.restart{fullRestart:false}`, hot restart = `{fullRestart:true}`,
  cold = process restart. No tmux or keystroke simulation.
- **Logs**: captures daemon events (`app.log`/`daemon.logMessage`/stdout) in a ring
  buffer and persists them to `.emu/run.jsonl`. Queried by regex/level/seq cursor.
- **Variables**: attaches as a second client to the app's `vmServiceUri`
  (`package:vm_service`) and uses the standard debug protocol for breakpoints and
  expression evaluation.

## State files (.emu/)

Stored in the project's `.emu/` directory and auto git-ignored:

| File | Contents |
|------|----------|
| `run.jsonl` | Structured logs (JSONL) |
| `server.json` | Running server coordinates (port/pid) |
| `server.log` | Server startup diagnostics |
| `shot-*.png` | Screenshots |
| `memory.json` | Learned recomputation hints (lastScreen, etc.) |

## Limitations & comparison

Stated honestly.

**The post-reload/restart error drain is best-effort.**
It catches *immediate* errors (build/initState throw), but may miss *delayed /
triggered* errors (Timer, a tap). In that case `emu assert --deny ... --timeout N`
is the robust path (polling-based).

**Input goes as far as coordinate taps. UI assertion is not emu's domain.**
`emu tap` only injects a coordinate; it **does not query the widget tree** — UI
assertions like "is this button visible?", "what's the text?" are not emu's job
(the agent judges from a screenshot, or verifies via `assert`/`probe`). If you
need robust selector-based UI assertions, use `integration_test` (official) /
`patrol` / `maestro`, and let emu add **log & variable verification** on top.
Input (`tap`/`swipe`/`text`) is **common to Android and iOS** — injected directly
into the framework via the VM Service, working around `simctl`'s lack of input.
`text` supports unicode too. But it's **Flutter widgets only**.

**`up`'s `firstFrame:false` means you can't tap yet.**
`up --json` also returns whether the app actually **painted** (`firstFrame`) — the
daemon's `running` only means the Dart entry point started, and input sent in
between is silently lost (empirically confirmed). `up` waits for the first frame by
default so you usually needn't care, but if it returned `firstFrame:false` (wait
window exceeded), confirm readiness with `emu status` or `assert` before tapping.

**e2e test tools vs emu.** e2e tools assert on **UI**, emu asserts on
**logs/variables** — they catch different bugs (e.g. "UI passes but a swallowed
exception is in the log" is what emu catches). Different layers, not competitors.

**AVD auto-selection is a heuristic.** `--android` prefers standard Google phone
images (Pixel/gphone/Nexus) and de-prioritizes foldables/tablets/wearables. If
it's still not what you want, name it explicitly with `-d <id>`.

**Cold-boot wait.** If a cold boot + first build takes longer than `up`'s wait
window (default 240s, tunable with `--timeout <s>`), it may return `state:starting`.
The server keeps going in the background, so confirm via `emu status` polling.

## Project layout

```
bin/emu.dart           entry point (CLI + hidden __serve subcommand)
lib/src/
  models.dart          LogEntry / AppStatus / DeviceInfo
  daemon_protocol.dart encode/decode flutter --machine messages
  engine.dart          owns the flutter process · reload/restart/cold/stop
  log_store.dart       ring buffer · persistence · filtered queries
  assertions.dart      pure expect/deny log assertion logic
  probe.dart           VM Service logpoint: capture variables at a line
  project_config.dart  layered config (emu.yaml) merge
  project_memory.dart  learned recomputation hints (.emu/memory.json)
  device_manager.dart  device discovery + emulator/simulator boot
  session.dart         project detection + .emu/ state
  server.dart          serves REST + WebSocket + the static dashboard
  cli.dart             command parsing + server client
web/                   dashboard (vanilla HTML/JS/CSS, no build step)
tool/bundle_web.dart   embeds web/ into the binary
docs/BACKLOG.md        improvement backlog + priorities
```

## Development

```bash
dart test                  # unit tests (protocol, log store, device parsing, assertions, probe helpers)
dart analyze               # lint
EMU_WEB_DIR=web dart run bin/emu.dart up   # serve the dashboard from disk (live editing)
```

Environment variables:

| Variable | Purpose |
|----------|---------|
| `EMU_PROJECT` | Set the project root (default: auto-detect via `pubspec.yaml`) |
| `EMU_WEB_DIR` | Serve dashboard assets from this directory (development) |

## Roadmap

See [`docs/BACKLOG.md`](docs/BACKLOG.md) for in-progress/planned items.

- ✅ Agent-loop ergonomics (verdict `up`, post-`reload` errors, `assert`, `up` first-frame wait)
- ✅ `probe` — VM Service variable capture
- ✅ `emu tap` / `swipe` / `text` (`--append`) — VM Service-based driving (Android & iOS, unicode text)
- ✅ iOS simulator on-device verification (boot + tap/swipe/text)
- ✅ Launch ergonomics — `-d` iOS auto-boot, failed-`up` cleanup, better AVD selection, `up --timeout`, `reload` restart hint
- ✅ Per-project layered config (`emu.yaml`) + learned memory + Claude Code plugin packaging
- 🚫 `emu e2e` — driving an external e2e engine: shelved (premise removed once input landed, see [BACKLOG](docs/BACKLOG.md))
- ⬜ IME bypass for iOS text input (currently focused-Flutter-field only)
- ✅ `emu inspect` — full locals + call-stack snapshot (one-shot, non-blocking)
- ⬜ Interactive `break`/`step`/`continue` — conflicts with emu's one-shot model by holding the app paused; decide on demand
