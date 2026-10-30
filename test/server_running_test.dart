import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/device_lease.dart';
import 'package:emu/src/models.dart';
import 'package:emu/src/registry.dart';
import 'package:emu/src/server.dart';
import 'package:emu/src/session.dart';
import 'package:test/test.dart';

/// The device the fake `flutter run` reports. An iOS simulator udid, so the
/// paths that look at the device (re-attach) stop at the missing build
/// outputs instead of calling adb — nothing on this machine is touched.
const _udid = '00000000-0000-0000-0000-00000000E5E5';
const _vm = 'ws://127.0.0.1:1/x=/ws';

/// A stand-in `flutter run --machine`, run in the project dir: writes its
/// pid to `../flutter.pid`, announces app `a1` on [_udid] with a VM Service,
/// answers `devtools.serve` and `app.restart` with the shell snippets in
/// `../on_devtools` and `../on_restart` (`$id` is the request id) and quits
/// on `app.stop`.
///
/// Builtins only, and written once per file: a child process (sed) cut off
/// by a kill writes `Broken pipe` to stderr, and a process started from this
/// test process — `Process.runSync` most of all — briefly holds the other
/// test files' listening sockets (fork until exec), so their checks that a
/// port is free the moment it closes fail.
Future<String> _fakeFlutter(Directory dir) async {
  final f = File('${dir.path}/flutter');
  f.writeAsStringSync('''#!/bin/sh
echo \$\$ > ../flutter.pid
echo '[{"event":"app.start","params":{"appId":"a1","deviceId":"$_udid"}}]'
echo '[{"event":"app.debugPort","params":{"appId":"a1","port":1,"wsUri":"$_vm"}}]'
echo '[{"event":"app.started","params":{"appId":"a1"}}]'
while IFS= read -r line; do
  id=\${line#*'"id":'}; id=\${id%%[!0-9]*}
  case "\$line" in
    *devtools.serve*) . ../on_devtools ;;
    *app.restart*) . ../on_restart ;;
    *app.stop*) exit 0 ;;
  esac
done
''');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

const _ok = r'echo "[{\"id\":$id,\"result\":{\"code\":0,\"message\":\"\"}}]"';
const _codeOne = r'echo "[{\"id\":$id,\"result\":{\"code\":1,\"message\":\"compile error\"}}]"';
const _error = r'echo "[{\"id\":$id,\"error\":\"boom\"}]"';
const _noDevTools = r'echo "[{\"id\":$id,\"error\":\"no devtools\"}]"';
const _devTools = r'echo "[{\"id\":$id,\"result\":{\"host\":\"127.0.0.1\",\"port\":9}}]"';

/// The `devToolsUri` [_devTools] makes: DevTools pointed at [_vm].
final _devToolsUri = 'http://127.0.0.1:9/?uri=${Uri.encodeQueryComponent(_vm)}';

/// One keep-alive client per test, and waits that look at the server in
/// process: a new connection per call or poll churns through ephemeral
/// ports, which other test files bind (port 0) and expect free once closed.
late HttpClient _client;

Future<({int status, Map<String, dynamic> body})> _call(EmuServer server, String method, String path,
    {String? body}) async {
  final req = await _client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
  req.headers.set('X-Emu-Token', server.token);
  if (body != null) req.write(body);
  final res = await req.close();
  final text = utf8.decode(await res.expand((b) => b).toList());
  return (status: res.statusCode, body: jsonDecode(text) as Map<String, dynamic>);
}

Future<Map<String, dynamic>> _status(EmuServer server) async =>
    (await _call(server, 'GET', '/api/status')).body['status'] as Map<String, dynamic>;

Future<void> _until(FutureOr<bool> Function() done, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A signal, not a `kill -0` process (see [_fakeFlutter]).
bool _alive(int pid) => Process.killPid(pid, ProcessSignal.sigcont);

/// The keys of `AppStatus.toJson` — what `/api/status` and the WebSocket
/// `status` message carry. The hub talks to sessions of other emu versions
/// in this shape: a key renamed or dropped here breaks them.
const _statusKeys = [
  'state',
  'deviceId',
  'deviceName',
  'appId',
  'vmServiceUri',
  'devToolsUri',
  'startedAt',
  'lastReloadAt',
  'message',
];

void main() {
  late Directory bin;
  late String flutter;
  late Directory tmp;
  late Directory project;
  late SessionRegistry registry;
  late DeviceLeases leases;
  EmuServer? server;

  setUpAll(() async {
    bin = Directory.systemTemp.createTempSync('emu_server_running_bin_');
    flutter = await _fakeFlutter(bin);
  });

  tearDownAll(() => bin.deleteSync(recursive: true));

  setUp(() {
    _client = HttpClient();
    tmp = Directory.systemTemp.createTempSync('emu_server_running_');
    project = Directory('${tmp.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
    registry = SessionRegistry(dir: Directory('${tmp.path}/sessions'));
    leases = DeviceLeases(dir: Directory('${tmp.path}/devices'));
  });

  tearDown(() async {
    await server?.dispose();
    server = null;
    _client.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  /// A server whose `flutter run` is the fake one, once the app is running.
  Future<EmuServer> running({String onRestart = _ok, String onDevTools = _noDevTools}) async {
    File('${tmp.path}/on_restart').writeAsStringSync('$onRestart\n');
    File('${tmp.path}/on_devtools').writeAsStringSync('$onDevTools\n');
    final s = server = EmuServer(
      session: Session(project),
      leases: leases,
      registry: registry,
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      flutterExecutable: flutter,
      exitProcess: (_) {},
    );
    await s.start(0, LaunchOptions());
    await _until(() => s.engine.status.state == AppRunState.running);
    return s;
  }

  /// A server whose launch fails at once (no `flutter`): the app never runs.
  Future<EmuServer> notRunning() async {
    final s = server = EmuServer(
      session: Session(project),
      leases: leases,
      registry: registry,
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      flutterExecutable: '${tmp.path}/no-flutter',
      exitProcess: (_) {},
    );
    await s.start(0, LaunchOptions());
    return s;
  }

  int flutterPid() => int.parse(File('${tmp.path}/flutter.pid').readAsStringSync().trim());

  Future<List<String>> logs(EmuServer s) async =>
      [for (final e in (await _call(s, 'GET', '/api/logs')).body['logs'] as List) e['text'] as String];

  /// A running app with a DevTools link, as the dashboard shows it.
  Future<EmuServer> runningWithDevTools({String onRestart = _ok}) async {
    final s = await running(onRestart: onRestart, onDevTools: _devTools);
    await _until(() => s.engine.status.devToolsUri != null);
    expect((await _status(s))['devToolsUri'], _devToolsUri);
    return s;
  }

  /// The app is gone: no VM Service or DevTools link, but the device and app
  /// id stay (re-attach reads them), and VM Service routes say so with a 409.
  Future<void> expectGone(EmuServer s) async {
    final st = await _status(s);
    expect(st.keys, unorderedEquals(_statusKeys));
    expect(st['vmServiceUri'], isNull);
    expect(st['devToolsUri'], isNull);
    expect(st['deviceId'], _udid);
    expect(st['appId'], 'a1');
    expect(st['startedAt'], isA<String>());
    final tap = await _call(s, 'POST', '/api/tap?x=1&y=2');
    expect(tap.status, 409);
    expect(tap.body, {'ok': false, 'error': 'app is not running (no VM service)'});
    final probe = await _call(s, 'POST', '/api/probe', body: '{}');
    expect(probe.status, 409);
    expect(probe.body, {'error': 'app is not running (no VM service)'});
  }

  group('running app', () {
    test('/api/status after app.start: state, device, VM Service', () async {
      final s = await running();
      final st = await _status(s);
      expect(st['state'], 'running');
      expect(st['deviceId'], _udid);
      expect(st['deviceName'], isNull);
      expect(st['appId'], 'a1');
      expect(st['vmServiceUri'], _vm);
      expect(st['devToolsUri'], isNull);
      expect(st['startedAt'], isA<String>());
      expect(st['lastReloadAt'], isNull);
      expect(st['message'], '');
    });

    test('/api/status and its status object keep their keys (hub compatibility)', () async {
      final s = await running();
      final body = (await _call(s, 'GET', '/api/status')).body;
      expect(body.keys, unorderedEquals(['status', 'serverPort', 'lastSeq']));
      expect(body['serverPort'], s.port);
      expect(body['lastSeq'], isA<int>());
      expect((body['status'] as Map).keys, unorderedEquals(_statusKeys));
    });

    test('the WebSocket opens with a status message of the same shape', () async {
      final s = await running();
      final ws = await WebSocket.connect('ws://127.0.0.1:${s.port}/api/stream?token=${s.token}');
      try {
        final first = jsonDecode(await ws.first as String) as Map<String, dynamic>;
        expect(first.keys, unorderedEquals(['type', 'status']));
        expect(first['type'], 'status');
        final st = first['status'] as Map<String, dynamic>;
        expect(st.keys, unorderedEquals(_statusKeys));
        expect(st['state'], 'running');
        expect(st['deviceId'], _udid);
        expect(st['vmServiceUri'], _vm);
      } finally {
        await ws.close();
      }
    });

    test('a reload broadcasts restarting then running over the WebSocket', () async {
      final s = await running();
      final ws = await WebSocket.connect('ws://127.0.0.1:${s.port}/api/stream?token=${s.token}');
      final states = <String>[];
      final sub = ws.listen((m) {
        final msg = jsonDecode(m as String) as Map<String, dynamic>;
        if (msg['type'] == 'status') states.add((msg['status'] as Map)['state'] as String);
      });
      try {
        await _until(() => states.isNotEmpty);
        await _call(s, 'POST', '/api/reload');
        await _until(() => states.length >= 3);
        expect(states.take(3), ['running', 'restarting', 'running']);
      } finally {
        await sub.cancel();
        await ws.close();
      }
    });

    test('/api/reload and /api/restart succeed', () async {
      final s = await running();
      final reload = await _call(s, 'POST', '/api/reload');
      expect(reload.status, 200);
      expect(reload.body, {'ok': true, 'message': 'hot reload complete', 'code': 0});
      final st = await _status(s);
      expect(st['state'], 'running');
      expect(st['lastReloadAt'], isA<String>());
      final restart = await _call(s, 'POST', '/api/restart');
      expect(restart.body, {'ok': true, 'message': 'hot restart complete', 'code': 0});
      expect(await logs(s), containsAllInOrder(['hot reload requested', 'hot reload complete', 'hot restart requested', 'hot restart complete']));
    });

    test('a non-zero restart code is a failure with the daemon message', () async {
      final s = await running(onRestart: _codeOne);
      final r = await _call(s, 'POST', '/api/reload');
      expect(r.status, 200);
      expect(r.body, {'ok': false, 'message': 'compile error', 'code': 1});
      final st = await _status(s);
      expect(st['state'], 'running');
      expect(st['lastReloadAt'], isA<String>());
    });

    test('an error response fails, stays running, no lastReloadAt', () async {
      final s = await running(onRestart: _error);
      final reload = await _call(s, 'POST', '/api/reload');
      expect(reload.status, 200);
      expect(reload.body, {'ok': false, 'message': 'hot reload failed: boom', 'code': null});
      final restart = await _call(s, 'POST', '/api/restart');
      expect(restart.body, {'ok': false, 'message': 'hot restart failed: boom', 'code': null});
      final st = await _status(s);
      expect(st['state'], 'running');
      expect(st['lastReloadAt'], isNull);
    });

    test('flutter dying mid-reload leaves failed; later reloads say not running', () async {
      final s = await running(onRestart: 'exit 3');
      final r = await _call(s, 'POST', '/api/reload');
      expect(r.body, {'ok': false, 'message': 'hot reload failed: process exited', 'code': null});
      final st = await _status(s);
      expect(st['state'], 'failed');
      expect(st['message'], 'flutter exited with code 3');
      expect(st['lastReloadAt'], isNull);
      final again = await _call(s, 'POST', '/api/restart');
      expect(again.body, {'ok': false, 'message': 'hot restart failed: not running', 'code': null});
      expect((await _status(s))['state'], 'failed');
    });

    test('/api/stop stops the app and the process, without re-attaching', () async {
      final s = await runningWithDevTools();
      final pid = flutterPid();
      final r = await _call(s, 'POST', '/api/stop');
      expect(r.body, {'ok': true, 'message': 'stopped'});
      expect((await _status(s))['state'], 'stopped');
      await expectGone(s);
      await _until(() => !_alive(pid));
      // Give a would-be auto re-attach the time to show up.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await logs(s), isNot(contains(contains('re-attach'))));
      expect((await _status(s))['state'], 'stopped');
      final reload = await _call(s, 'POST', '/api/reload');
      expect(reload.body, {'ok': false, 'message': 'hot reload failed: not running', 'code': null});
    });

    test('flutter dying on its own fails the app and tries to re-attach', () async {
      final s = await runningWithDevTools();
      Process.killPid(flutterPid());
      await _until(() => s.engine.status.state == AppRunState.failed);
      final st = await _status(s);
      expect(st['message'], startsWith('flutter exited with code '));
      await expectGone(s);
      // The re-attach got past the device (it read deviceId) to the build outputs.
      await _until(() => s.logStore.query(limit: 1 << 20).any((e) => e.text.startsWith('re-attach failed')));
      expect(
          await logs(s),
          containsAllInOrder([
            'flutter lost the connection to the app — trying to re-attach',
            're-attach failed: cannot tell the app id from the build outputs',
          ]));
    });

    test('app.stop from the daemon drops the VM Service while flutter is still up', () async {
      final s = await runningWithDevTools(onRestart: '''
echo '[{"event":"app.stop","params":{"appId":"a1"}}]'
$_ok''');
      await _call(s, 'POST', '/api/reload');
      expect((await _status(s))['state'], 'stopped');
      expect(_alive(flutterPid()), isTrue);
      await expectGone(s);
    });

    test('/api/attach while flutter is connected is refused', () async {
      final s = await running();
      final r = await _call(s, 'POST', '/api/attach');
      expect(r.body, {'ok': false, 'message': 'flutter is still connected (state: running)', 'code': null});
    });

    test('/api/attach after flutter died stops at the build outputs', () async {
      final s = await running();
      await _call(s, 'POST', '/api/stop');
      expect((await _status(s))['vmServiceUri'], isNull);
      final r = await _call(s, 'POST', '/api/attach');
      expect(r.body, {'ok': false, 'message': 'cannot tell the app id from the build outputs', 'code': null});
    });

    test('dispose stops flutter and releases the lease, registry and server info', () async {
      final s = await running();
      final pid = flutterPid();
      await _until(() => leases.holderOf(_udid) != null);
      expect(registry.all().single.deviceId, _udid);
      await s.dispose();
      server = null;
      await _until(() => !_alive(pid));
      expect(leases.holderOf(_udid), isNull);
      expect(registry.all(), isEmpty);
      expect(Session(project).serverInfoFile.existsSync(), isFalse);
    });
  });

  group('app not running', () {
    test('/api/status says failed with the launch error', () async {
      final s = await notRunning();
      final st = await _status(s);
      expect(st.keys, unorderedEquals(_statusKeys));
      expect(st['state'], 'failed');
      expect(st['message'], startsWith('launch error: '));
      expect(st['vmServiceUri'], isNull);
    });

    test('reload and restart: app not started yet', () async {
      final s = await notRunning();
      for (final path in ['/api/reload', '/api/restart']) {
        final r = await _call(s, 'POST', path);
        expect(r.status, 200, reason: path);
        expect(r.body, {'ok': false, 'message': 'app not started yet', 'code': null}, reason: path);
      }
    });

    test('stop answers ok; attach knows no device', () async {
      final s = await notRunning();
      expect((await _call(s, 'POST', '/api/stop')).body, {'ok': true, 'message': 'stopped'});
      expect((await _call(s, 'POST', '/api/stop')).body, {'ok': true, 'message': 'stopped'});
      expect((await _status(s))['state'], 'stopped');
      expect((await _call(s, 'POST', '/api/attach')).body,
          {'ok': false, 'message': 'no device known for this session', 'code': null});
    });

    test('cold restart fails to launch', () async {
      final s = await notRunning();
      final r = await _call(s, 'POST', '/api/cold');
      expect(r.status, 200);
      expect(r.body['ok'], isFalse);
      expect(r.body['message'], startsWith('cold restart failed: '));
      expect(r.body['code'], isNull);
    });

    test('input and VM Service routes: 409 app is not running', () async {
      final s = await notRunning();
      const noVm = 'app is not running (no VM service)';
      final withOk = {'ok': false, 'error': noVm};
      final cases = <(String, String, String?, Map<String, Object?>)>[
        ('POST', '/api/tap?x=1&y=2', null, withOk),
        ('POST', '/api/tap?text=Hi', null, withOk),
        ('POST', '/api/swipe?x1=1&y1=2&x2=3&y2=4', null, withOk),
        ('POST', '/api/text?text=hi', null, withOk),
        ('GET', '/api/find?text=Hi', null, withOk),
        ('POST', '/api/eval', '{"expr":"1+1"}', withOk),
        ('GET', '/api/first-frame', null, withOk),
        ('GET', '/api/settle', null, withOk),
        ('POST', '/api/probe', '{}', {'error': noVm}),
        ('POST', '/api/inspect', '{}', {'error': noVm}),
        ('POST', '/api/memory/snapshot', '{}', {'error': noVm}),
      ];
      for (final (method, path, body, expected) in cases) {
        final r = await _call(s, method, path, body: body);
        expect(r.status, 409, reason: path);
        expect(r.body, expected, reason: path);
      }
    });
  });
}
