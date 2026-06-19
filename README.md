# emu — Flutter emulator/simulator debug driver

Debug Flutter apps without opening an IDE. `emu` boots a device, runs your app,
performs **hot reload / hot restart / cold restart** on demand, and gives you
**searchable, filterable debug logs** — through both a command line (great for
agents like Claude Code) and a **web dashboard** (great for humans).

One engine, two frontends: a local server owns a `flutter run --machine`
session; the CLI and the dashboard are both clients of its HTTP/WebSocket API.

```
flutter run --machine  ◄─JSON-RPC─►  engine  ──►  server (127.0.0.1:4577)
                                                    ├─ REST + WebSocket API
                                                    ├─ web dashboard  (browser)
                                                    └─ CLI            (terminal / agent)
```

## Requirements

- Flutter SDK (`flutter` on PATH) — required
- Android: Android SDK `adb` + `emulator` (for AVD boot)
- iOS: full Xcode + `xcrun simctl` (macOS only)

Check with `emu doctor`.

## Build / install

```bash
./build.sh                       # bundles the dashboard + compiles a single binary
ln -sf "$PWD/emu" /usr/local/bin/emu
```

During development you can skip the build and run from source:

```bash
dart run bin/emu.dart <command>
```

## Usage

Run inside a Flutter project (auto-detected via `pubspec.yaml`), or set
`EMU_PROJECT=/path/to/app`.

```bash
emu doctor                       # check dependencies
emu devices                      # list devices + Android AVDs

emu up --android                 # boot a default AVD, run the app, open the dashboard
emu up --ios --open              # iOS simulator + open the browser
emu up -d emulator-5554 --flavor dev --dart-define API=staging

emu reload                       # hot reload
emu restart                      # hot restart
emu cold                         # cold restart (full relaunch; picks up native/pubspec changes)
emu stop                         # stop the app (server stays up)

emu logs -n 100                  # last 100 lines
emu logs --grep "Exception" -f   # live-follow, filtered by regex
emu logs --level error           # errors only

emu status                       # session / device / VM Service state
emu shot                         # screenshot to .emu/
emu open                         # open the dashboard
emu down                         # stop the session
emu down --kill-device           # ...and power off the emulator/simulator
```

Every command supports `--json` for scripting and agents; `emu logs --json`
emits one JSON object per line (JSONL).

## Web dashboard

`emu up` starts a dashboard at `http://127.0.0.1:4577`:

- live log stream with **regex search**, **level filters** (debug/info/warn/error),
  match highlighting, copy, and clear
- **Hot reload / Hot restart / Cold restart / Stop** buttons (and `r` / `R` keys)
- status bar with device and a DevTools link

## How it works

- **Control** uses the Flutter daemon protocol (`flutter run --machine`):
  hot reload = `app.restart{fullRestart:false}`, hot restart = `{fullRestart:true}`,
  cold restart = full process relaunch. No tmux, no simulated keystrokes.
- **Logs** are captured from daemon events into a ring buffer, persisted to
  `.emu/run.jsonl`, and queryable by regex / level / recency.
- **State** lives in the project's `.emu/` directory (git-ignored automatically):
  `run.jsonl` (logs), `server.json` (running server coordinates), `server.log`
  (startup diagnostics), screenshots.

## Project layout

```
bin/emu.dart           entrypoint (CLI + hidden __serve subcommand)
lib/src/
  models.dart          LogEntry, AppStatus, DeviceInfo
  daemon_protocol.dart flutter --machine message encode/decode
  engine.dart          owns the flutter process; reload/restart/cold/stop
  log_store.dart       ring buffer, persistence, filtered queries
  device_manager.dart  device discovery + emulator/simulator boot
  session.dart         project detection + .emu/ state
  server.dart          REST + WebSocket + static dashboard
  cli.dart             command parsing + server client
web/                   dashboard (vanilla HTML/JS/CSS, no build step)
tool/bundle_web.dart   embeds web/ into the binary
```

## Development

```bash
dart test                        # unit tests (protocol, log store, device parsing)
dart analyze                     # lints
EMU_WEB_DIR=web dart run bin/emu.dart up   # serve dashboard from disk (live edit)
```
