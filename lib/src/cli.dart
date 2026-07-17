/// The CLI: thin client over the server (which owns the engine), plus a few
/// in-process commands (doctor, devices). Every command supports `--json`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;

import 'assertions.dart';
import 'device_manager.dart';
import 'launch_config.dart';
import 'models.dart';
import 'server.dart';
import 'session.dart';

const _defaultPort = 4577;

Future<int> runCli(List<String> argv) async {
  if (argv.isEmpty) {
    _printUsage();
    return 0;
  }
  final command = argv.first;
  final rest = argv.sublist(1);
  try {
    switch (command) {
      case 'doctor':
        return await _doctor(rest);
      case 'devices':
        return await _devices(rest);
      case 'configs':
        return await _configs(rest);
      case 'up':
        return await _up(rest);
      case 'reload':
        return await _action(rest, '/api/reload', 'hot reload', reloadHint: true);
      case 'restart':
        return await _action(rest, '/api/restart', 'hot restart');
      case 'cold':
        return await _action(rest, '/api/cold', 'cold restart');
      case 'stop':
        return await _action(rest, '/api/stop', 'stop', drain: false);
      case 'logs':
        return await _logs(rest);
      case 'assert':
        return await _assert(rest);
      case 'probe':
        return await _probe(rest);
      case 'status':
        return await _status(rest);
      case 'shot':
        return await _shot(rest);
      case 'tap':
        return await _tap(rest);
      case 'swipe':
        return await _swipe(rest);
      case 'text':
        return await _text(rest);
      case 'open':
        return await _open(rest);
      case 'down':
        return await _down(rest);
      case 'help':
      case '--help':
      case '-h':
        _printUsage();
        return 0;
      default:
        stderr.writeln('unknown command: $command');
        _printUsage();
        return 1;
    }
  } on StateError catch (e) {
    stderr.writeln('✗ ${e.message}');
    return 1;
  }
}

// --------------------------------------------------------------------------
// doctor
// --------------------------------------------------------------------------
Future<int> _doctor(List<String> args) async {
  final json = args.contains('--json');
  final checks = <String, bool>{};
  for (final tool in ['flutter', 'adb', 'emulator']) {
    checks[tool] = await _hasCommand(tool);
  }
  if (Platform.isMacOS) checks['xcrun'] = await _hasCommand('xcrun');

  final coreOk = checks['flutter'] == true;
  if (json) {
    print(jsonEncode({'checks': checks, 'ok': coreOk}));
    return coreOk ? 0 : 1;
  }
  for (final e in checks.entries) {
    final required = e.key == 'flutter';
    if (e.value) {
      print('✓ ${e.key}');
    } else {
      print('${required ? '✗' : '!'} ${e.key}${required ? '  (required)' : '  (optional)'}');
    }
  }
  if (!coreOk) {
    stderr.writeln('flutter is required and was not found on PATH.');
    return 1;
  }
  print('✓ core dependencies satisfied');
  return 0;
}

// --------------------------------------------------------------------------
// devices
// --------------------------------------------------------------------------
Future<int> _devices(List<String> args) async {
  final json = args.contains('--json');
  final dm = DeviceManager();
  final list = await dm.listDevices();
  final avds = await dm.listAndroidAvds();
  if (json) {
    print(jsonEncode({
      'devices': list.map((d) => d.toJson()).toList(),
      'androidAvds': avds,
    }));
    return 0;
  }
  if (list.isEmpty) {
    print('(no running devices)');
  } else {
    print('Devices:');
    for (final d in list) {
      print('  ${d.id}  ${d.name}  [${d.platform}${d.emulator ? ', emulator' : ''}]');
    }
  }
  if (avds.isNotEmpty) {
    print('\nAndroid AVDs:');
    for (final a in avds) {
      print('  $a');
    }
  }
  return 0;
}

// --------------------------------------------------------------------------
// configs (read .vscode/launch.json)
// --------------------------------------------------------------------------
Future<int> _configs(List<String> args) async {
  final json = args.contains('--json');
  final session = Session.require();
  final configs = readLaunchConfigs(session.projectRoot.path);
  if (json) {
    print(jsonEncode({'configs': configs.map((c) => c.toJson()).toList()}));
    return 0;
  }
  if (configs.isEmpty) {
    print('(no configs — .vscode/launch.json not found or has no dart entries)');
    return 0;
  }
  print('Launch configs (.vscode/launch.json):');
  for (final c in configs) {
    final parts = <String>[
      if (c.flavor != null) 'flavor=${c.flavor}',
      if (c.target != null) 'target=${c.target}',
      if (c.deviceId != null) 'device=${c.deviceId}',
      for (final d in c.dartDefines) 'define=$d',
    ];
    final suffix = parts.isEmpty ? '' : '  (${parts.join(', ')})';
    if (c.isDebug) {
      print('  • ${c.name}$suffix');
    } else {
      print('  ⚠ ${c.name}  [${c.mode}] — debug-only, not runnable by emu$suffix');
    }
    if (c.unsupported.isNotEmpty) {
      print('      note: ${c.unsupported.join(', ')} not replayed by emu');
    }
  }
  print('\nRun one with:  emu up --config "<name>" [--android|--ios]');
  return 0;
}

// --------------------------------------------------------------------------
// up
// --------------------------------------------------------------------------
Future<int> _up(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('android', negatable: false)
    ..addFlag('ios', negatable: false)
    ..addOption('device', abbr: 'd')
    ..addOption('config', help: 'named config from .vscode/launch.json')
    ..addOption('flavor')
    ..addOption('target', abbr: 't')
    ..addMultiOption('dart-define')
    ..addOption('port', defaultsTo: '$_defaultPort')
    ..addOption('timeout', help: 'seconds to wait for running/failed (default 240)')
    ..addFlag('open', negatable: false)
    ..addFlag('json', negatable: false);
  final res = parser.parse(args);
  final session = Session.require();

  // Resolve a named launch.json config (if any). Explicit flags override it.
  LaunchConfig? cfg;
  if (res.option('config') != null) {
    final wanted = res.option('config')!;
    final configs = readLaunchConfigs(session.projectRoot.path);
    for (final c in configs) {
      if (c.name == wanted) {
        cfg = c;
        break;
      }
    }
    if (cfg == null) {
      stderr.writeln('✗ config "$wanted" not found in .vscode/launch.json');
      if (configs.isNotEmpty) {
        stderr.writeln('  available: ${configs.map((c) => '"${c.name}"').join(', ')}');
      }
      return 1;
    }
    if (!cfg.isDebug) {
      stderr.writeln('✗ config "$wanted" is flutterMode=${cfg.mode}; '
          'emu drives debug builds only (hot reload + VM Service).');
      return 1;
    }
    if (cfg.unsupported.isNotEmpty) {
      stderr.writeln('! config "$wanted": ${cfg.unsupported.join(', ')} '
          'not replayed by emu (pass --dart-define manually if needed).');
    }
  }
  // Effective run settings: explicit flag wins, else config value.
  final device = res.option('device') ?? cfg?.deviceId;
  final flavor = res.option('flavor') ?? cfg?.flavor;
  final target = res.option('target') ?? cfg?.target;
  final dartDefines = res.multiOption('dart-define').isNotEmpty
      ? res.multiOption('dart-define')
      : (cfg?.dartDefines ?? const []);

  // Refuse if a healthy server is already running for this project.
  final existing = session.readServerInfo();
  if (existing != null && await _ping(existing)) {
    stderr.writeln('A session is already running for ${session.projectRoot.path}.');
    stderr.writeln('Dashboard: ${existing.baseUrl}   (use `emu down` first)');
    return 1;
  }
  session.clearServerInfo();

  final platform = res.flag('android')
      ? 'android'
      : res.flag('ios')
          ? 'ios'
          : null;

  // Build the __serve invocation, re-using how we were launched.
  final serveArgs = <String>[
    '__serve',
    '--port', res.option('port')!,
    if (platform != null) '--platform=$platform',
    if (device != null) '--device=$device',
    if (flavor != null) '--flavor=$flavor',
    if (target != null) '--target=$target',
    for (final d in dartDefines) '--dart-define=$d',
    '--project=${session.projectRoot.path}',
  ];

  final serverLog = File('${session.stateDir.path}/server.log');
  session.ensureState();
  serverLog.writeAsStringSync('');

  final (exe, prefix) = _selfInvocation();
  final proc = await Process.start(
    exe,
    [...prefix, ...serveArgs],
    mode: ProcessStartMode.detached,
    workingDirectory: session.projectRoot.path,
  );
  // Detached: we cannot read its stdio; the server logs to .emu/run.jsonl itself.

  // Wait for the server to come up (server.json appears after a successful bind).
  ServerInfo? info;
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    info = session.readServerInfo();
    if (info != null && await _ping(info)) break;
    if (i == 8 && serverLog.existsSync() && serverLog.lengthSync() > 0) {
      stderr.writeln(serverLog.readAsStringSync());
    }
  }
  if (info == null || !await _ping(info)) {
    stderr.writeln('✗ server did not start (pid ${proc.pid}). Check ${serverLog.path}');
    return 1;
  }

  if (res.flag('open')) await _openUrl(info.baseUrl);

  // How long to wait for the app to reach running/failed. Cold boot + first
  // build can exceed the default; raise it with --timeout for slow machines.
  final timeoutSec = int.tryParse(res.option('timeout') ?? '') ?? 240;

  if (res.flag('json')) {
    // Wait for the real launch outcome instead of reporting a premature ok:true.
    final state = await _awaitLaunchState(info, timeoutSec);
    // `running` only means the entrypoint started; input before the first frame
    // is silently lost, so report whether the app has actually painted.
    final painted = state == 'running' && await _awaitFirstFrame(info);
    final errors = await _errorsSince(info, 0); // gather before any teardown
    if (state == 'failed') await _teardownFailedServer(session, info);
    print(jsonEncode({
      'ok': state == 'running',
      'state': state,
      'firstFrame': painted,
      'port': info.port,
      'dashboard': info.baseUrl,
      'errors': errors,
    }));
    return state == 'running' ? 0 : 1;
  }

  print('✓ session up — dashboard: ${info.baseUrl}');
  print('  (streaming startup; Ctrl-C to detach, the app keeps running)');
  final state = await _streamUntilReady(info, timeoutSec);
  if (state == 'failed') {
    await _teardownFailedServer(session, info);
    return 1;
  }
  return 0;
}

/// A launch that ended in `failed` leaves the detached server holding the port,
/// so the next `up` is rejected with "already running". Shut it down and clear
/// the stale coordinates. `starting` is left alone — it's still building in the
/// background and the user is expected to poll `status`.
Future<void> _teardownFailedServer(Session session, ServerInfo info) async {
  await _post(info, '/api/shutdown');
  session.clearServerInfo();
}

/// Poll the server until the app reaches a terminal launch state.
/// Poll iterations for a wait budget, at the fixed 400ms poll interval.
int _pollIters(int timeoutSec) => (timeoutSec * 1000 / 400).ceil();

Future<String> _awaitLaunchState(ServerInfo info, int timeoutSec) async {
  for (var i = 0; i < _pollIters(timeoutSec); i++) {
    final st = await _get(info, '/api/status');
    final state = (st?['status'] as Map?)?['state'] as String?;
    if (state == 'running' || state == 'failed') return state!;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  return 'starting';
}

/// Error-level log lines with seq greater than [sinceSeq], as {level, text}.
Future<List<Map<String, dynamic>>> _errorsSince(ServerInfo info, int sinceSeq) async {
  final d = await _get(info, '/api/logs?level=error&sinceSeq=$sinceSeq&limit=100');
  if (d == null) return const [];
  return (d['logs'] as List)
      .cast<Map<String, dynamic>>()
      .map((e) => {'level': e['level'], 'text': e['text']})
      .toList();
}

/// The store's current highest seq (a cursor for "logs after now").
Future<int> _lastSeq(ServerInfo info) async {
  final st = await _get(info, '/api/status');
  return (st?['lastSeq'] as int?) ?? 0;
}

/// How to re-invoke ourselves for the detached server.
(String, List<String>) _selfInvocation() {
  final exe = Platform.resolvedExecutable;
  // Compiled exe: resolvedExecutable IS the emu binary.
  if (!exe.endsWith('dart') && !exe.endsWith('dart.exe')) {
    return (exe, const []);
  }
  // JIT/dev: dart run <script>.
  return (exe, ['run', Platform.script.toFilePath()]);
}

/// Streams startup logs until the app is `running`/`failed`. Returns the final
/// state ('starting' if it never settles) so the caller can tear down on failure.
Future<String> _streamUntilReady(ServerInfo info, int timeoutSec) async {
  var sinceSeq = 0;
  for (var i = 0; i < _pollIters(timeoutSec); i++) {
    final data = await _get(info, '/api/logs?sinceSeq=$sinceSeq&limit=200');
    if (data == null) break;
    final logs = (data['logs'] as List).cast<Map<String, dynamic>>();
    for (final raw in logs) {
      final e = LogEntry.fromJson(raw);
      print(_formatLine(e));
      sinceSeq = e.seq;
    }
    final st = await _get(info, '/api/status');
    final state = (st?['status'] as Map?)?['state'];
    if (state == 'running') {
      print('✓ app running');
      return 'running';
    }
    if (state == 'failed') {
      stderr.writeln('✗ launch failed (see logs above)');
      return 'failed';
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  return 'starting';
}

// --------------------------------------------------------------------------
// reload / restart / cold / stop
// --------------------------------------------------------------------------
Future<int> _action(List<String> args, String endpoint, String label,
    {bool drain = true, bool reloadHint = false}) async {
  final json = args.contains('--json');
  final info = _requireServer();
  final before = drain ? await _lastSeq(info) : 0;
  // Was the app actively logging right up to the reload? Captured now, compared
  // to the drain window after — a busy→silent transition is the signal that a
  // running Timer/loop body didn't get swapped.
  final wasActive = reloadHint && await _recentlyActive(info);
  final res = await _post(info, endpoint);
  if (res == null) {
    stderr.writeln('✗ no response from server');
    return 1;
  }
  // Drain a short window so runtime errors from the reloaded code surface in the
  // same call — the agent judges "did it actually work?" without a second query.
  // Best-effort: catches *immediate* errors (build/initState throws). For errors
  // triggered later (timers, taps), use `emu assert --deny ... --timeout N`.
  List<Map<String, dynamic>> errors = const [];
  String? hint;
  if (drain) {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    errors = await _errorsSince(info, before);
    res['errors'] = errors;
    // If the app was busy before the reload but produced nothing after, the
    // reloaded code is likely running inside an already-scheduled Timer/loop
    // whose body hot reload can't swap. Suggest a restart.
    if (reloadHint) {
      final produced = await _appLogCountSince(info, before);
      if (shouldHintRestart(
          ok: res['ok'] == true, wasActiveBefore: wasActive, producedAfter: produced)) {
        hint = "no output after reload — hot reload can't replace a running "
            'Timer/loop body; try `emu restart`';
        res['hint'] = hint;
      }
    }
  }
  final ok = res['ok'] == true && errors.isEmpty;
  if (json) {
    print(jsonEncode(res));
    return ok ? 0 : 1;
  }
  final actionOk = res['ok'] == true;
  print('${actionOk ? '✓' : '✗'} $label: ${res['message'] ?? ''}');
  if (errors.isNotEmpty) {
    stderr.writeln('⚠ ${errors.length} error log(s) after $label:');
    for (final e in errors.take(10)) {
      stderr.writeln('   ${e['text']}');
    }
  }
  if (hint != null) stderr.writeln('↳ $hint');
  return ok ? 0 : 1;
}

/// The reload-went-silent heuristic, pure so it can be unit-tested: hint only
/// when the reload succeeded, the app was logging right before it, and produced
/// nothing after. Requiring "was active" avoids firing on ordinary silent
/// reloads (e.g. a pure UI tweak on an idle screen).
bool shouldHintRestart(
        {required bool ok, required bool wasActiveBefore, required int producedAfter}) =>
    ok && wasActiveBefore && producedAfter == 0;

/// Whether an app/stderr log line landed within the last few seconds — used to
/// tell "the app was busy" from "the app is idle" before a reload.
Future<bool> _recentlyActive(ServerInfo info) async {
  final d = await _get(info, '/api/logs?limit=20');
  final logs = (d?['logs'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  for (final raw in logs.reversed) {
    if (!isAppOutput(raw)) continue; // ignore emu/daemon status lines
    final ts = DateTime.tryParse('${raw['ts']}'); // LogEntry serializes as 'ts'
    if (ts == null) continue;
    return DateTime.now().difference(ts) < const Duration(seconds: 5);
  }
  return false;
}

/// Count of genuine app output after [seq] — excludes emu's own system lines and
/// the daemon's `Reloaded N libraries` report, which arrives as an `app` line on
/// every reload and would otherwise make the app never look silent.
Future<int> _appLogCountSince(ServerInfo info, int seq) async {
  final d = await _get(info, '/api/logs?sinceSeq=$seq&limit=500');
  final logs = (d?['logs'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  return logs.where(isAppOutput).length;
}

/// Whether a log entry is real app output (not an emu/daemon status line).
bool isAppOutput(Map<String, dynamic> entry) {
  if (entry['source'] == 'system') return false;
  final text = '${entry['text']}';
  if (RegExp(r'^Reloaded \d+ librar').hasMatch(text)) return false;
  if (RegExp(r'^Restarted application').hasMatch(text)) return false;
  return true;
}

// --------------------------------------------------------------------------
// assert — log-pattern oracle for e2e/CI ("after X, log Y must/ must not appear")
// --------------------------------------------------------------------------
Future<int> _assert(List<String> args) async {
  final parser = ArgParser()
    ..addMultiOption('expect', help: 'pattern that MUST appear')
    ..addMultiOption('deny', help: 'pattern that must NOT appear')
    ..addOption('since', help: 'seq cursor (default: now)')
    ..addOption('timeout', defaultsTo: '5')
    ..addFlag('json', negatable: false);
  final res = parser.parse(args);
  final expect = res.multiOption('expect');
  final deny = res.multiOption('deny');
  if (expect.isEmpty && deny.isEmpty) {
    stderr.writeln('✗ provide at least one --expect or --deny pattern');
    return 2;
  }
  final info = _requireServer();
  var cursor = int.tryParse(res.option('since') ?? '') ?? await _lastSeq(info);
  final timeout = Duration(seconds: int.tryParse(res.option('timeout')!) ?? 5);
  final deadline = DateTime.now().add(timeout);

  final buffer = <LogEntry>[];
  var outcome = evaluateAssertion(buffer, expect, deny);
  while (true) {
    final d = await _get(info, '/api/logs?sinceSeq=$cursor&limit=500');
    if (d != null) {
      for (final raw in (d['logs'] as List).cast<Map<String, dynamic>>()) {
        final e = LogEntry.fromJson(raw);
        buffer.add(e);
        cursor = e.seq;
      }
    }
    outcome = evaluateAssertion(buffer, expect, deny);
    if (!outcome.denyClean) break; // fail fast: a denied pattern appeared
    if (outcome.expectsMet && deny.isEmpty) break; // pass fast: nothing left to watch
    if (DateTime.now().isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  if (res.flag('json')) {
    print(jsonEncode(outcome.toJson()));
  } else {
    print(outcome.pass ? '✓ assert pass' : '✗ assert fail');
    for (final e in outcome.expected.entries) {
      if (!e.value) stderr.writeln('   missing: ${e.key}');
    }
    for (final e in outcome.denied.entries) {
      for (final m in e.value) {
        stderr.writeln('   denied (${e.key}): $m');
      }
    }
  }
  return outcome.pass ? 0 : 1;
}

// --------------------------------------------------------------------------
// probe — capture variable values at a file:line via the VM Service
// --------------------------------------------------------------------------
Future<int> _probe(List<String> args) async {
  final parser = ArgParser()
    ..addOption('capture', abbr: 'c', help: 'comma-separated expressions to evaluate')
    ..addOption('count', defaultsTo: '1', help: 'stop after N hits')
    ..addOption('timeout', defaultsTo: '10', help: 'seconds to wait for hits')
    ..addFlag('json', negatable: false);
  final res = parser.parse(args);
  if (res.rest.isEmpty) {
    stderr.writeln('usage: emu probe <file:line> --capture "expr,expr"');
    return 2;
  }
  final loc = res.rest.first;
  final colon = loc.lastIndexOf(':');
  final line = colon < 0 ? null : int.tryParse(loc.substring(colon + 1));
  if (colon < 0 || line == null) {
    stderr.writeln('✗ location must be <file:line>, e.g. lib/main.dart:42');
    return 2;
  }
  final file = loc.substring(0, colon);
  final capture = (res.option('capture') ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final count = int.tryParse(res.option('count')!) ?? 1;
  final timeout = int.tryParse(res.option('timeout')!) ?? 10;

  final info = _requireServer();
  final body = jsonEncode({
    'file': file,
    'line': line,
    'capture': capture,
    'count': count,
    'timeoutMs': timeout * 1000,
  });
  // Allow the HTTP call a bit longer than the probe's own timeout.
  final r = await _postJson(info, '/api/probe', body, timeout: Duration(seconds: timeout + 10));
  if (r == null) {
    stderr.writeln('✗ no response from server');
    return 1;
  }
  if (r['error'] != null) {
    stderr.writeln('✗ ${r['error']}');
    return 1;
  }
  final hits = (r['hits'] as List).cast<Map<String, dynamic>>();
  if (res.flag('json')) {
    print(jsonEncode(r));
    return hits.isEmpty ? 1 : 0;
  }
  if (hits.isEmpty) {
    print('✗ no hit within ${timeout}s — was $file:$line reached?');
    return 1;
  }
  for (final h in hits) {
    final vals = (h['values'] as Map)
        .entries
        .map((e) => '${e.key}=${e.value}')
        .join('   ');
    print('● ${h['file']}:${h['line']}   ${vals.isEmpty ? '(reached)' : vals}');
  }
  return 0;
}

// --------------------------------------------------------------------------
// logs
// --------------------------------------------------------------------------
Future<int> _logs(List<String> args) async {
  final parser = ArgParser()
    ..addOption('grep', abbr: 'g')
    ..addOption('level', abbr: 'l')
    ..addOption('lines', abbr: 'n', defaultsTo: '200')
    ..addFlag('follow', abbr: 'f', negatable: false)
    ..addFlag('json', negatable: false)
    ..addFlag('clear', negatable: false);
  final res = parser.parse(args);
  final session = Session.require();
  final info = session.readServerInfo();
  final serverUp = info != null && await _ping(info);

  if (res.flag('clear')) {
    if (serverUp) await _post(info, '/api/logs/clear');
    if (session.logFile.existsSync()) session.logFile.writeAsStringSync('');
    print('✓ logs cleared');
    return 0;
  }

  final query = <String, String>{
    if (res.option('grep') != null) 'grep': res.option('grep')!,
    if (res.option('level') != null) 'level': res.option('level')!,
    'limit': res.option('lines')!,
  };

  // Server down → read the persisted jsonl directly (offline mode).
  if (!serverUp) {
    return _logsFromFile(session, res, query);
  }

  final qs = query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
  final data = await _get(info, '/api/logs?$qs');
  if (data == null) {
    stderr.writeln('✗ failed to read logs');
    return 1;
  }
  var lastSeq = (data['lastSeq'] as int?) ?? 0;
  final logs = (data['logs'] as List).cast<Map<String, dynamic>>().map(LogEntry.fromJson);
  for (final e in logs) {
    print(res.flag('json') ? jsonEncode(e.toJson()) : _formatLine(e));
  }
  if (!res.flag('follow')) return 0;

  // Follow: poll for new entries.
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!await _ping(info)) break;
    final more = await _get(info,
        '/api/logs?$qs&sinceSeq=$lastSeq');
    if (more == null) continue;
    for (final raw in (more['logs'] as List).cast<Map<String, dynamic>>()) {
      final e = LogEntry.fromJson(raw);
      print(res.flag('json') ? jsonEncode(e.toJson()) : _formatLine(e));
      lastSeq = e.seq;
    }
  }
  return 0;
}

int _logsFromFile(Session session, ArgResults res, Map<String, String> query) {
  if (!session.logFile.existsSync()) {
    stderr.writeln('no logs (no session has run). Start one with `emu up`.');
    return 1;
  }
  final lines = session.logFile.readAsLinesSync();
  RegExp? re = query['grep'] != null ? RegExp(query['grep']!, caseSensitive: false) : null;
  final level = query['level'] != null ? LogLevel.fromName(query['level']) : null;
  final limit = int.tryParse(query['limit'] ?? '') ?? 200;
  final matched = <LogEntry>[];
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    try {
      final e = LogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>);
      if (level != null && e.level.rank < level.rank) continue;
      if (re != null && !re.hasMatch(e.text)) continue;
      matched.add(e);
    } catch (_) {}
  }
  final shown = matched.length > limit ? matched.sublist(matched.length - limit) : matched;
  for (final e in shown) {
    print(res.flag('json') ? jsonEncode(e.toJson()) : _formatLine(e));
  }
  return 0;
}

// --------------------------------------------------------------------------
// status
// --------------------------------------------------------------------------
Future<int> _status(List<String> args) async {
  final json = args.contains('--json');
  final session = Session.require();
  final info = session.readServerInfo();
  final up = info != null && await _ping(info);
  if (!up) {
    if (json) {
      print(jsonEncode({'running': false, 'project': session.projectRoot.path}));
    } else {
      print('project: ${session.projectRoot.path}');
      print('! no server running (use `emu up`)');
    }
    return 0;
  }
  final data = await _get(info, '/api/status');
  if (json) {
    print(jsonEncode({'running': true, 'dashboard': info.baseUrl, ...?data}));
    return 0;
  }
  final st = (data?['status'] as Map?)?.cast<String, dynamic>();
  print('project:   ${session.projectRoot.path}');
  print('dashboard: ${info.baseUrl}');
  if (st != null) {
    print('state:     ${st['state']}');
    if (st['deviceName'] != null) print('device:    ${st['deviceName']}');
    if (st['vmServiceUri'] != null) print('vmService: ${st['vmServiceUri']}');
    if (st['lastReloadAt'] != null) print('reloaded:  ${st['lastReloadAt']}');
  }
  return 0;
}

// --------------------------------------------------------------------------
// shot / open / down
// --------------------------------------------------------------------------
Future<int> _shot(List<String> args) async {
  final json = args.contains('--json');
  final out = args.firstWhere((a) => !a.startsWith('-'), orElse: () => '');
  final info = _requireServer();
  final query = out.isEmpty ? '' : '?path=${Uri.encodeQueryComponent(out)}';
  final res = await _post(info, '/api/screenshot$query');
  if (res == null || res['ok'] != true) {
    if (json) {
      print(jsonEncode(res ?? {'ok': false, 'error': 'no response'}));
    } else {
      stderr.writeln('✗ screenshot failed: ${res?['error'] ?? 'no response'}');
    }
    return 1;
  }
  print(json ? jsonEncode(res) : '✓ ${res['path']}');
  return 0;
}

/// `emu tap <x> <y>` — coordinates are **physical pixels**, the same space
/// `emu shot` captures in, so values read straight off a screenshot work as-is.
Future<int> _tap(List<String> args) async {
  final json = args.contains('--json');
  final pos = args.where((a) => !a.startsWith('-')).toList();
  final x = pos.length == 2 ? int.tryParse(pos[0]) : null;
  final y = pos.length == 2 ? int.tryParse(pos[1]) : null;
  if (x == null || y == null) {
    stderr.writeln('usage: emu tap <x> <y>   # physical pixels, as seen in `emu shot`');
    return 2;
  }
  return _inject('/api/tap?x=$x&y=$y', 'tap $x,$y', json: json);
}

/// `emu swipe <x1> <y1> <x2> <y2>` — physical pixels, like `tap`. This is also
/// how you scroll.
Future<int> _swipe(List<String> args) async {
  final parser = ArgParser()
    ..addOption('duration', defaultsTo: '300', help: 'swipe duration in ms')
    ..addFlag('json', negatable: false);
  final res = parser.parse(args);
  final pos = res.rest.map(int.tryParse).toList();
  if (pos.length != 4 || pos.any((v) => v == null)) {
    stderr.writeln('usage: emu swipe <x1> <y1> <x2> <y2> [--duration <ms>]');
    return 2;
  }
  final ms = int.tryParse(res.option('duration')!) ?? 300;
  final q = 'x1=${pos[0]}&y1=${pos[1]}&x2=${pos[2]}&y2=${pos[3]}&durationMs=$ms';
  return _inject('/api/swipe?$q', 'swipe ${pos[0]},${pos[1]} → ${pos[2]},${pos[3]} (${ms}ms)',
      json: res.flag('json'));
}

/// `emu text <string>` — types into whatever currently has focus, so tap the
/// field first. `--append` adds to the field instead of replacing it.
Future<int> _text(List<String> args) async {
  final json = args.contains('--json');
  final append = args.contains('--append');
  final text = args.where((a) => a != '--json' && a != '--append').join(' ');
  if (text.isEmpty) {
    stderr.writeln('usage: emu text <string> [--append]   # types into the focused field');
    return 2;
  }
  final q = 'text=${Uri.encodeQueryComponent(text)}${append ? '&append=true' : ''}';
  return _inject('/api/text?$q', 'text "$text"${append ? ' (append)' : ''}', json: json);
}

/// Block until the app has painted. Returns false on timeout — the app is still
/// running, it just isn't ready for input yet.
Future<bool> _awaitFirstFrame(ServerInfo info, {int timeoutMs = 20000}) async {
  final res = await _post(info, '/api/first-frame?timeoutMs=$timeoutMs');
  return res?['firstFrame'] == true;
}

/// POST an input injection and report it. The response's `seq` is the log
/// cursor from just before the input fired — feed it to `assert --since` to
/// catch what the input caused.
Future<int> _inject(String path, String label, {required bool json}) async {
  final info = _requireServer();
  final res = await _post(info, path);
  if (res == null || res['ok'] != true) {
    if (json) {
      print(jsonEncode(res ?? {'ok': false, 'error': 'no response'}));
    } else {
      stderr.writeln('✗ $label failed: ${res?['error'] ?? 'no response'}');
    }
    return 1;
  }
  print(json ? jsonEncode(res) : '✓ $label   (seq ${res['seq']})');
  return 0;
}

Future<int> _open(List<String> args) async {
  final info = _requireServer();
  await _openUrl(info.baseUrl);
  print(info.baseUrl);
  return 0;
}

Future<int> _down(List<String> args) async {
  final killDevice = args.contains('--kill-device');
  final session = Session.require();
  final info = session.readServerInfo();
  if (info == null || !await _ping(info)) {
    print('! no running session');
    session.clearServerInfo();
    return 0;
  }
  await _post(info, '/api/shutdown');
  if (killDevice) {
    // Best-effort device power-off after the server releases it.
    final dm = DeviceManager();
    await dm.shutdown('android');
    await dm.shutdown('ios');
  }
  print('✓ session stopped');
  return 0;
}

// --------------------------------------------------------------------------
// helpers
// --------------------------------------------------------------------------
ServerInfo _requireServer() {
  final session = Session.require();
  final info = session.readServerInfo();
  if (info == null) {
    throw StateError('no running session for ${session.projectRoot.path}. Start one with `emu up`.');
  }
  return info;
}

Future<bool> _ping(ServerInfo info) async {
  try {
    final r = await http
        .get(Uri.parse('${info.baseUrl}/api/status'))
        .timeout(const Duration(milliseconds: 800));
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>?> _get(ServerInfo info, String path) async {
  try {
    final r = await http.get(Uri.parse('${info.baseUrl}$path')).timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) return null;
    return jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _post(ServerInfo info, String path) async {
  try {
    final r =
        await http.post(Uri.parse('${info.baseUrl}$path')).timeout(const Duration(seconds: 150));
    return jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _postJson(ServerInfo info, String path, String body,
    {Duration timeout = const Duration(seconds: 30)}) async {
  try {
    final r = await http
        .post(Uri.parse('${info.baseUrl}$path'),
            headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(timeout);
    return jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

Future<void> _openUrl(String url) async {
  if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [url]);
  } else if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', url]);
  }
}

Future<bool> _hasCommand(String cmd) async {
  try {
    final r = await Process.run('which', [cmd]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _formatLine(LogEntry e) {
  final t = e.timestamp;
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final ss = t.second.toString().padLeft(2, '0');
  final tag = switch (e.level) {
    LogLevel.error => 'E',
    LogLevel.warn => 'W',
    LogLevel.debug => 'D',
    LogLevel.system => '•',
    LogLevel.info => 'I',
  };
  return '$hh:$mm:$ss $tag  ${e.text}';
}

/// Parse the hidden `__serve` subcommand and run the server (blocking).
Future<int> runServe(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', defaultsTo: '$_defaultPort')
    ..addOption('platform')
    ..addOption('device')
    ..addOption('flavor')
    ..addOption('target')
    ..addOption('project')
    ..addMultiOption('dart-define');
  final res = parser.parse(args);
  final session = Session.require(start: res.option('project'));
  final server = EmuServer(session: session);

  // Surface fatal startup errors to .emu/server.log for `up` to show.
  final serverLog = File('${session.stateDir.path}/server.log');
  try {
    await server.start(
      int.parse(res.option('port')!),
      LaunchOptions(
        platform: res.option('platform'),
        deviceId: res.option('device'),
        flavor: res.option('flavor'),
        target: res.option('target'),
        dartDefines: res.multiOption('dart-define'),
      ),
    );
  } catch (e, st) {
    serverLog.writeAsStringSync('server crashed: $e\n$st\n');
    return 1;
  }
  // Keep the isolate alive; the server runs until /api/shutdown calls exit().
  await Completer<void>().future;
  return 0;
}

void _printUsage() {
  print(r'''
emu — Flutter emulator/simulator debug driver

USAGE
  emu <command> [options]            (every command supports --json)

COMMANDS
  doctor                 Check dependencies (flutter, adb, emulator, xcrun)
  devices                List devices + Android AVDs
  configs                List run configs from .vscode/launch.json
  up [opts]              Boot device + start the app, launch the dashboard
     --android | --ios     Boot a default device of that platform
     -d, --device <id>     Use a specific flutter device id
     --config <name>       Use a config from .vscode/launch.json (flags override)
     --flavor <name>       Build flavor
     -t, --target <file>   Entrypoint (lib/main_dev.dart, …)
     --dart-define K=V     dart-define (repeatable)
     --port <n>            Dashboard port (default 4577)
     --timeout <s>         wait for running/failed before returning (default 240)
     --open                Open the dashboard in the browser
  reload                 Hot reload (reports errors logged just after)
  restart                Hot restart (reports errors logged just after)
  cold                   Cold restart (full relaunch)
  stop                   Stop the app (server stays up)
  logs [opts]            Show/search logs
     -g, --grep <regex>    Filter (case-insensitive)
     -l, --level <e|w|i>   Minimum level
     -n, --lines <N>       Last N lines (default 200)
     -f, --follow          Stream live
     --clear               Clear the log buffer
  assert [opts]          Assert on the log stream (e2e/CI oracle)
     --expect <regex>      pattern that MUST appear (repeatable)
     --deny <regex>        pattern that must NOT appear (repeatable)
     --since <seq>         seq cursor (default: now)
     --timeout <s>         wait window (default 5)
  probe <file:line>      Capture variable values at a line (VM Service logpoint)
     -c, --capture <e,e>   expressions to evaluate when the line is hit
     --count <n>           stop after N hits (default 1)
     --timeout <s>         seconds to wait for a hit (default 10)
  status                 Show session/app state
  shot [path]            Save a screenshot (default: .emu/shot-<ts>.png)
  tap <x> <y>            Tap at physical pixels (same space as `shot`)
  swipe <x1> <y1> <x2> <y2>
                         Swipe/scroll between two points
     --duration <ms>       swipe duration (default 300)
  text <string> [--append]
                         Type into the focused field — tap it first. Unicode OK
  open                   Open the dashboard in the browser
  down [--kill-device]   Stop the session (optionally power off the device)

ENV
  EMU_PROJECT   Project root override (default: auto-detect via pubspec.yaml)
  EMU_WEB_DIR   Serve dashboard assets from this dir (dev)
''');
}
