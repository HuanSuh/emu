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
      case 'up':
        return await _up(rest);
      case 'reload':
        return await _action(rest, '/api/reload', 'hot reload');
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
      case 'status':
        return await _status(rest);
      case 'shot':
        return await _shot(rest);
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
// up
// --------------------------------------------------------------------------
Future<int> _up(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('android', negatable: false)
    ..addFlag('ios', negatable: false)
    ..addOption('device', abbr: 'd')
    ..addOption('flavor')
    ..addOption('target', abbr: 't')
    ..addMultiOption('dart-define')
    ..addOption('port', defaultsTo: '$_defaultPort')
    ..addFlag('open', negatable: false)
    ..addFlag('json', negatable: false);
  final res = parser.parse(args);
  final session = Session.require();

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
    if (res.option('device') != null) '--device=${res.option('device')}',
    if (res.option('flavor') != null) '--flavor=${res.option('flavor')}',
    if (res.option('target') != null) '--target=${res.option('target')}',
    for (final d in res.multiOption('dart-define')) '--dart-define=$d',
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

  if (res.flag('json')) {
    // Wait for the real launch outcome instead of reporting a premature ok:true.
    final state = await _awaitLaunchState(info);
    final errors = await _errorsSince(info, 0);
    print(jsonEncode({
      'ok': state == 'running',
      'state': state,
      'port': info.port,
      'dashboard': info.baseUrl,
      'errors': errors,
    }));
    return state == 'running' ? 0 : 1;
  }

  print('✓ session up — dashboard: ${info.baseUrl}');
  print('  (streaming startup; Ctrl-C to detach, the app keeps running)');
  await _streamUntilReady(info);
  return 0;
}

/// Poll the server until the app reaches a terminal launch state.
Future<String> _awaitLaunchState(ServerInfo info) async {
  for (var i = 0; i < 600; i++) {
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

Future<void> _streamUntilReady(ServerInfo info) async {
  var sinceSeq = 0;
  for (var i = 0; i < 600; i++) {
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
      return;
    }
    if (state == 'failed') {
      stderr.writeln('✗ launch failed (see logs above)');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

// --------------------------------------------------------------------------
// reload / restart / cold / stop
// --------------------------------------------------------------------------
Future<int> _action(List<String> args, String endpoint, String label,
    {bool drain = true}) async {
  final json = args.contains('--json');
  final info = _requireServer();
  final before = drain ? await _lastSeq(info) : 0;
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
  if (drain) {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    errors = await _errorsSince(info, before);
    res['errors'] = errors;
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
  return ok ? 0 : 1;
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
  final info = _requireServer();
  final res = await _post(info, '/api/screenshot');
  if (res == null || res['ok'] != true) {
    stderr.writeln('✗ screenshot failed: ${res?['error'] ?? 'no response'}');
    return 1;
  }
  print('✓ ${res['path']}');
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
  up [opts]              Boot device + start the app, launch the dashboard
     --android | --ios     Boot a default device of that platform
     -d, --device <id>     Use a specific flutter device id
     --flavor <name>       Build flavor
     -t, --target <file>   Entrypoint (lib/main_dev.dart, …)
     --dart-define K=V     dart-define (repeatable)
     --port <n>            Dashboard port (default 4577)
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
  status                 Show session/app state
  shot                   Save a screenshot
  open                   Open the dashboard in the browser
  down [--kill-device]   Stop the session (optionally power off the device)

ENV
  EMU_PROJECT   Project root override (default: auto-detect via pubspec.yaml)
  EMU_WEB_DIR   Serve dashboard assets from this dir (dev)
''');
}
