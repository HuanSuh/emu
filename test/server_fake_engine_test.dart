import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:emu/src/device_lease.dart';
import 'package:emu/src/engine.dart';
import 'package:emu/src/locate.dart';
import 'package:emu/src/log_store.dart';
import 'package:emu/src/mock.dart';
import 'package:emu/src/mock_replay.dart';
import 'package:emu/src/models.dart';
import 'package:emu/src/registry.dart';
import 'package:emu/src/server.dart';
import 'package:emu/src/session.dart';
import 'package:test/test.dart';

/// An iOS simulator udid: re-attach stops at the missing build outputs
/// instead of calling adb, so nothing on this machine is touched.
const _udid = '00000000-0000-0000-0000-00000000FA4E';

/// An [AppEngine] the test moves by hand: [emit] sets the status (as the
/// daemon would), [hasProcess]/[stoppedDeliberately] are plain fields, and
/// a reload waits on [reloadGate] when one is set.
class FakeEngine implements AppEngine {
  AppStatus _status = AppStatus(state: AppRunState.stopped);
  final _controller = StreamController<AppStatus>.broadcast();

  final List<List<String>> starts = [];
  final List<List<String>> attaches = [];
  final List<String> calls = [];
  Object? startError;
  Completer<ActionResult>? reloadGate;
  bool disposed = false;

  @override
  bool hasProcess = false;
  @override
  bool stoppedDeliberately = false;
  @override
  List<String> lastRunArgs = const [];

  void emit(AppStatus next) {
    _status = next;
    _controller.add(next);
  }

  /// The app reported running on [_udid] with a VM Service.
  void appRunning() => emit(_status.copyWith(
      state: AppRunState.running, appId: 'a1', deviceId: _udid, vmServiceUri: 'ws://127.0.0.1:1/x=/ws'));

  /// `flutter` went away on its own with the app's last state [state].
  void lost({AppRunState state = AppRunState.failed}) {
    hasProcess = false;
    emit(_status.copyWith(state: state, clearVmService: true));
  }

  @override
  AppStatus get status => _status;
  @override
  Stream<AppStatus> get statusStream => _controller.stream;

  @override
  void markFailed(String message) {
    calls.add('markFailed');
    emit(_status.copyWith(state: AppRunState.failed, message: message));
  }

  @override
  Future<void> start(List<String> runArgs, {String? deviceName, bool attaching = false}) async {
    calls.add(attaching ? 'attach' : 'start');
    if (startError != null) throw startError!;
    (attaching ? attaches : starts).add(runArgs);
    if (!attaching) lastRunArgs = runArgs;
    stoppedDeliberately = false;
    hasProcess = true;
    emit(AppStatus(state: AppRunState.starting, deviceName: deviceName, startedAt: DateTime.now()));
  }

  @override
  Future<void> attach(List<String> attachArgs, {String? deviceName}) =>
      start(attachArgs, deviceName: deviceName, attaching: true);

  Future<ActionResult> _restart(String label) async {
    calls.add(label);
    emit(_status.copyWith(state: AppRunState.restarting));
    final gate = reloadGate;
    final r = gate != null ? await gate.future : ActionResult(ok: true, message: '$label complete', code: 0);
    if (_status.state == AppRunState.restarting) emit(_status.copyWith(state: AppRunState.running));
    return r;
  }

  @override
  Future<ActionResult> hotReload() => _restart('hot reload');
  @override
  Future<ActionResult> hotRestart() => _restart('hot restart');

  @override
  Future<ActionResult> coldRestart() async {
    calls.add('cold');
    return ActionResult(ok: true, message: 'cold restart launched');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    stoppedDeliberately = true;
    hasProcess = false;
    emit(_status.copyWith(state: AppRunState.stopped, clearVmService: true));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await stop();
    await _controller.close();
  }
}

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

Future<void> _until(FutureOr<bool> Function() done, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Let stream listeners (the server's status watchers) run.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late Directory tmp;
  late Directory project;
  late FakeEngine engine;
  EmuServer? server;

  setUp(() {
    _client = HttpClient();
    tmp = Directory.systemTemp.createTempSync('emu_server_fake_');
    project = Directory('${tmp.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
    engine = FakeEngine();
  });

  tearDown(() async {
    await server?.dispose();
    server = null;
    _client.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  ReplayDevice? device;

  Future<EmuServer> start({LaunchOptions? opts, void Function(String root, LogStore logs)? onCreate}) async {
    final s = server = EmuServer(
      session: Session(project),
      leases: DeviceLeases(dir: Directory('${tmp.path}/devices')),
      registry: SessionRegistry(dir: Directory('${tmp.path}/sessions')),
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      flutterExecutable: '${tmp.path}/no-flutter',
      exitProcess: (_) {},
      engineFactory: (root, logs) {
        onCreate?.call(root, logs);
        return engine;
      },
      replayDevice: (_) => device!,
    );
    await s.start(0, opts ?? LaunchOptions());
    return s;
  }

  List<String> logs(EmuServer s) => [for (final e in s.logStore.query(limit: 1 << 20)) e.text];

  group('seam', () {
    test('the factory gets the project root and log store; the server launches through it', () async {
      String? root;
      LogStore? store;
      final s = await start(onCreate: (r, l) => (root, store) = (r, l));
      expect(s.engine, same(engine));
      expect(root, project.path);
      expect(store, same(s.logStore));
      expect(engine.starts, [
        ['run', '--machine']
      ]);
    });

    test('dispose disposes the engine', () async {
      final s = await start();
      await s.dispose();
      server = null;
      expect(engine.disposed, isTrue);
    });
  });

  group('markFailed', () {
    test('an engine that fails to start marks a launch error', () async {
      engine.startError = StateError('boom');
      final s = await start();
      expect(engine.calls, ['start', 'markFailed']);
      expect(engine.status.state, AppRunState.failed);
      expect(engine.status.message, 'launch error: Bad state: boom');
      expect(logs(s), contains('launch error: Bad state: boom'));
    });

    test('a device error before flutter starts marks a device error', () async {
      final s = await start(opts: LaunchOptions(tempDevice: true));
      expect(engine.calls, ['markFailed']);
      expect(engine.status.message, 'device error: --temp-device needs --android or --ios');
      expect(logs(s), contains('device error: --temp-device needs --android or --ios'));
      final st = (await _call(s, 'GET', '/api/status')).body['status'] as Map;
      expect(st['state'], 'failed');
    });
  });

  group('restart vs state (#78)', () {
    test('status answers while a reload is in flight, and a failure then is not overwritten', () async {
      final s = await start();
      engine.appRunning();
      engine.reloadGate = Completer();
      final reload = _call(s, 'POST', '/api/reload');
      await _until(() => engine.status.state == AppRunState.restarting);
      expect(((await _call(s, 'GET', '/api/status')).body['status'] as Map)['state'], 'restarting');
      // flutter died while the reload waited.
      engine.lost();
      engine.reloadGate!.complete(ActionResult(ok: false, message: 'hot reload failed: process exited'));
      final r = await reload;
      expect(r.body, {'ok': false, 'message': 'hot reload failed: process exited', 'code': null});
      expect(((await _call(s, 'GET', '/api/status')).body['status'] as Map)['state'], 'failed');
    });

    test("the engine's result passes through as is", () async {
      final s = await start();
      engine.appRunning();
      engine.reloadGate = Completer()..complete(ActionResult(ok: false, message: 'compile error', code: 1));
      expect((await _call(s, 'POST', '/api/restart')).body, {'ok': false, 'message': 'compile error', 'code': 1});
      expect((await _call(s, 'POST', '/api/cold')).body, {'ok': true, 'message': 'cold restart launched', 'code': null});
      expect(engine.calls, containsAllInOrder(['hot restart', 'cold']));
    });

    test('/api/attach mid-restart is refused with the state', () async {
      final s = await start();
      engine.appRunning();
      engine.reloadGate = Completer();
      final reload = _call(s, 'POST', '/api/reload');
      await _until(() => engine.status.state == AppRunState.restarting);
      expect((await _call(s, 'POST', '/api/attach')).body,
          {'ok': false, 'message': 'flutter is still connected (state: restarting)', 'code': null});
      engine.reloadGate!.complete(ActionResult(ok: true, message: 'hot reload complete', code: 0));
      await reload;
      expect(engine.attaches, isEmpty);
    });
  });

  group('auto re-attach', () {
    const tried = 'flutter lost the connection to the app — trying to re-attach';

    test('flutter gone under a running app: tried once', () async {
      final s = await start();
      engine.appRunning();
      engine.lost();
      await _until(() => logs(s).any((l) => l.startsWith('re-attach failed')));
      expect(logs(s), containsAllInOrder([tried, 're-attach failed: cannot tell the app id from the build outputs']));
    });

    test('a deliberate stop is not re-attached', () async {
      final s = await start();
      engine.appRunning();
      await _call(s, 'POST', '/api/stop');
      await _settle();
      expect(engine.stoppedDeliberately, isTrue);
      expect(logs(s), isNot(contains(tried)));
    });

    test('app.stop while flutter is still up waits for the process to go', () async {
      final s = await start();
      engine.appRunning();
      engine.emit(engine.status.copyWith(state: AppRunState.stopped)); // daemon said app.stop
      await _settle();
      expect(logs(s), isNot(contains(tried)));
      engine.lost(state: AppRunState.stopped); // then the process exits
      await _until(() => logs(s).contains(tried));
    });

    test('a launch that never ran is not re-attached', () async {
      final s = await start();
      engine.lost();
      await _settle();
      expect(logs(s), isNot(contains(tried)));
    });

    test('lost again within a minute: not retried', () async {
      final s = await start();
      engine.appRunning();
      engine.lost();
      await _until(() => logs(s).any((l) => l.startsWith('re-attach failed')));
      await engine.start(['run', '--machine']);
      engine.appRunning();
      engine.lost();
      await _until(() => logs(s).any((l) => l.startsWith('flutter lost the app again within a minute')));
      expect(logs(s).where((l) => l == tried), hasLength(1));
    });

    test('/api/attach after flutter died before naming a device', () async {
      final s = await start();
      engine.lost();
      expect((await _call(s, 'POST', '/api/attach')).body,
          {'ok': false, 'message': 'no device known for this session', 'code': null});
    });
  });

  group('guards follow the VM Service, not the state', () {
    test('running without a VM Service: tap and probe are 409', () async {
      final s = await start();
      engine.emit(engine.status.copyWith(state: AppRunState.running, deviceId: _udid));
      final tap = await _call(s, 'POST', '/api/tap?x=1&y=2');
      expect(tap.status, 409);
      expect(tap.body, {'ok': false, 'error': 'app is not running (no VM service)'});
      final probe = await _call(s, 'POST', '/api/probe', body: '{}');
      expect(probe.status, 409);
      expect(probe.body, {'error': 'app is not running (no VM service)'});
    });

    test('the app gone: tap and probe are 409, attach still goes by the device', () async {
      final s = await start();
      engine.appRunning();
      engine.lost();
      await _until(() => logs(s).any((l) => l.startsWith('re-attach failed')));
      expect(engine.status.deviceId, _udid);
      expect(engine.status.appId, 'a1');
      final tap = await _call(s, 'POST', '/api/tap?x=1&y=2');
      expect(tap.status, 409);
      expect(tap.body, {'ok': false, 'error': 'app is not running (no VM service)'});
      final probe = await _call(s, 'POST', '/api/probe', body: '{}');
      expect(probe.status, 409);
      expect(probe.body, {'error': 'app is not running (no VM service)'});
      // Not 'no device known for this session': the device outlived the VM Service.
      expect((await _call(s, 'POST', '/api/attach')).body,
          {'ok': false, 'message': 'cannot tell the app id from the build outputs', 'code': null});
    });

    test('bad tap arguments are checked only once there is a VM Service', () async {
      final s = await start();
      expect((await _call(s, 'POST', '/api/tap')).status, 409);
      engine.appRunning();
      final r = await _call(s, 'POST', '/api/tap');
      expect(r.status, 400);
      expect(r.body, {'ok': false, 'error': 'x and y are required integers'});
    });
  });

  group('timeline', () {
    /// One entry of each kind, the action right inside an exception banner.
    void mixed(LogStore store) {
      store.add('app line');
      store.add('[mock] GET /a → 200', source: 'mock', kind: LogKind.request);
      store.add('═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞═══════════════');
      store.add('The following StateError was thrown building Pay:');
      store.add('[action] tap --text "Login"', level: LogLevel.system, source: 'action', kind: LogKind.action);
      store.add('[route] /pay', level: LogLevel.system, source: 'route', kind: LogKind.route);
      store.add('════════════════════════════════════════════════════════');
    }

    /// The kinds of the entries [mixed] added, in order — the server may log
    /// its own lines meanwhile.
    List<String> kindsOf(Map<String, dynamic> body) => [
          for (final e in (body['logs'] as List).cast<Map<String, dynamic>>().map(LogEntry.fromJson))
            if (e.source != 'system') e.kindName
        ];

    test('/api/logs answers as before unless asked: no route or action entries', () async {
      final s = await start();
      final from = s.logStore.lastSeq;
      mixed(s.logStore);
      final plain = await _call(s, 'GET', '/api/logs?sinceSeq=$from');
      expect(kindsOf(plain.body), ['log', 'request', 'log', 'log', 'log']);
      expect(plain.body['lastSeq'], s.logStore.lastSeq);
      // `emu assert --expect Login` reads this: the record of the tap is no match.
      expect((await _call(s, 'GET', '/api/logs?sinceSeq=$from&grep=Login')).body['logs'], isEmpty);

      final all = await _call(s, 'GET', '/api/logs?sinceSeq=$from&kinds=all');
      expect(kindsOf(all.body), ['log', 'request', 'log', 'log', 'action', 'route', 'log']);
      final some = await _call(s, 'GET', '/api/logs?sinceSeq=$from&kinds=route,action');
      expect(kindsOf(some.body), ['action', 'route']);
      final limited = await _call(s, 'GET', '/api/logs?sinceSeq=$from&kinds=route,action&limit=1');
      expect(kindsOf(limited.body), ['route']);
    });

    test('/api/logs refuses an unknown kind', () async {
      final s = await start();
      final r = await _call(s, 'GET', '/api/logs?kinds=screens');
      expect(r.status, 400);
      expect(r.body['error'], contains('screens'));
    });

    test('/api/errors keeps route and action entries out of a banner', () async {
      final s = await start();
      mixed(s.logStore);
      final banner = ((await _call(s, 'GET', '/api/errors')).body['errors'] as List).single as Map;
      expect(banner['raw'], isNot(contains('[action]')));
      expect(banner['raw'], isNot(contains('[route]')));
      expect(banner['closed'], isTrue);
    });

    test('a new dashboard socket gets the last entries of every kind', () async {
      final s = await start();
      mixed(s.logStore);
      final socket = await WebSocket.connect('ws://127.0.0.1:${s.port}/api/stream?token=${s.token}');
      addTearDown(socket.close);
      final kinds = <String>[];
      final sub = socket.listen((m) {
        final msg = jsonDecode(m as String) as Map<String, dynamic>;
        if (msg['type'] == 'log') kinds.add(LogEntry.fromJson(msg['entry'] as Map<String, dynamic>).kindName);
      });
      addTearDown(sub.cancel);
      await _until(() => kinds.length >= s.logStore.lastSeq);
      expect(kinds, containsAll(['log', 'request', 'action', 'route']));
    });

    test('a mock request is a request entry with where it started', () async {
      File('${project.path}/emu.yaml').writeAsStringSync('''
mocks:
  hosts: [127.0.0.1]
  scenarios:
    slow:
      - match: { path: /a }
        respond: { status: 201, body: ok, delay: 300 }
''');
      final random = Random();
      var s = await start(opts: LaunchOptions(mockPort: 20000 + random.nextInt(20000)));
      for (var i = 0; s.mock == null && i < 10; i++) {
        await s.dispose();
        s = await start(opts: LaunchOptions(mockPort: 20000 + random.nextInt(20000)));
      }
      final mock = s.mock!..active = 'slow';
      s.logStore
        ..currentRoute = '/before'
        ..currentRouteName = 'before';
      final startSeq = s.logStore.lastSeq;

      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.open('GET', '127.0.0.1', mock.port! + 1, '/a')
        ..headers.host = '127.0.0.1'
        ..headers.port = 9;
      final response = req.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.logStore
        ..currentRoute = '/after'
        ..currentRouteName = 'after';
      final during = s.logStore.add('logged while the request was out');
      expect((await response).statusCode, 201);
      await _until(() => s.logStore.query(kinds: {LogKind.request}).isNotEmpty);

      final e = s.logStore.query(kinds: {LogKind.request}).single;
      expect(e.text, startsWith('[mock] GET http://127.0.0.1:9/a → 201'));
      expect((e.source, e.route, e.routeName), ('mock', '/before', 'before'));
      expect(e.data, {
        'hitId': 1,
        'method': 'GET',
        'url': 'http://127.0.0.1:9/a',
        'status': 201,
        'mocked': 'slow',
        'ms': e.data!['ms'],
        'startSeq': startSeq,
      });
      expect(e.seq, greaterThan(during.seq), reason: 'the entry comes when the request is done');
      expect(during.route, '/after');
    });
  });

  group('mock scenarios', () {
    const rule = {'match': {'path': '/a'}, 'respond': {'status': 200}};

    /// A running server with mocks on, without binding the mock server's ports.
    Future<EmuServer> withMocks() async {
      final s = await start();
      s.mock = MockServer(projectRoot: project.path, home: tmp.path, log: (_) {});
      File('${project.path}/emu.yaml').writeAsStringSync('mocks:\n  hosts: [api.example.com]\n');
      return s;
    }

    test('use switches the scenario; only POST with a known name does', () async {
      final s = await withMocks();
      expect((await _call(s, 'PUT', '/api/mock/scenarios/x', body: jsonEncode({'rules': [rule]}))).status, 200);
      expect(jsonDecode(File('${project.path}/mocks/x.json').readAsStringSync()), [rule]);
      expect((await _call(s, 'POST', '/api/mock', body: jsonEncode({'scenario': 'nope'}))).status, 404);
      expect(s.mock!.active, isNull);
      final r = await _call(s, 'POST', '/api/mock', body: jsonEncode({'scenario': 'x'}));
      expect((r.status, r.body['active']), (200, 'x'));
      expect(s.mock!.active, 'x');
    });

    group('replay', () {
      late _Replay fake;
      setUp(() {
        fake = _Replay();
        device = fake;
      });

      Future<EmuServer> ready({Object? replay = const {'entry': {'url': 'a://b'}, 'steps': [{'tap': {'text': 'Pay'}}]}}) async {
        final s = await withMocks();
        fake.server = s;
        Directory('${project.path}/mocks').createSync();
        File('${project.path}/mocks/x.json').writeAsStringSync(jsonEncode([rule]));
        if (replay != null) File('${project.path}/mocks/x.replay.json').writeAsStringSync(jsonEncode(replay));
        engine.appRunning();
        await _settle();
        return s;
      }

      test('turns the scenario on before opening the link, then runs the steps', () async {
        final s = await ready();
        fake.found = [LocateMatch(1, 2, 10, 10, 'Text')];
        final before = s.logStore.lastSeq;
        final r = await _call(s, 'POST', '/api/mock/replay/x');
        expect(r.status, 200, reason: '${r.body}');
        expect(fake.calls.take(3), ['open a://b with x', 'locate Pay', 'tap 1,2']);
        expect(r.body['ok'], isTrue);
        expect(r.body['scenario'], 'x');
        expect(r.body['seq'], greaterThanOrEqualTo(before));
        expect(r.body['steps'], [
          {'i': null, 'kind': 'entry', 'ok': true, 'detail': 'a://b'},
          {'i': 0, 'kind': 'tap', 'ok': true, 'detail': 'tapped Text at 1,2'},
          {'i': null, 'kind': 'settle', 'ok': true, 'detail': 'settled'},
        ]);
        expect(s.mock!.active, 'x');
      });

      test('a step that fails is a 422 saying where; the scenario stays on', () async {
        final s = await ready(replay: const {'steps': [{'text': 'x'}, {'text': 'y'}]});
        fake.textError = StateError('no focused text field');
        final r = await _call(s, 'POST', '/api/mock/replay/x');
        expect(r.status, 422);
        expect(r.body['ok'], isFalse);
        expect(r.body['error'], contains('steps[0] text'));
        expect(r.body['active'], 'x');
        expect((r.body['steps'] as List).length, 1);
        expect(fake.calls.where((c) => c.startsWith('text')), hasLength(1));
        expect(logs(s).any((l) => l.contains('stopped')), isTrue);
      });

      test('refused without touching the scenario: no VM Service, no replay, a bad one, no scenario', () async {
        var s = await ready();
        engine.lost();
        var r = await _call(s, 'POST', '/api/mock/replay/x');
        expect((r.status, r.body['error']), (409, 'app is not running (no VM service)'));
        engine.appRunning();
        File('${project.path}/mocks/x.replay.json').writeAsStringSync('{"steps":[{"swipe":{}}]}');
        r = await _call(s, 'POST', '/api/mock/replay/x');
        expect(r.status, 400);
        expect(r.body['error'], contains('swipe'));
        File('${project.path}/mocks/x.replay.json').deleteSync();
        r = await _call(s, 'POST', '/api/mock/replay/x');
        expect(r.status, 404);
        expect(r.body['error'], contains('has no replay'));
        r = await _call(s, 'POST', '/api/mock/replay/nope');
        expect(r.status, 404);
        expect(r.body['error'], contains('no scenario'));
        expect(s.mock!.active, isNull);
        expect(fake.calls, isEmpty);
      });

      test('one at a time', () async {
        final s = await ready();
        fake.openGate = Completer();
        final first = _call(s, 'POST', '/api/mock/replay/x');
        await _until(() => fake.calls.isNotEmpty);
        final second = await _call(s, 'POST', '/api/mock/replay/x');
        expect((second.status, second.body['error']), (409, 'a replay is already running'));
        fake.found = [LocateMatch(1, 2, 10, 10, 'Text')];
        fake.openGate!.complete();
        expect((await first).status, 200);
      });

      test('PUT writes the file, is listed, and bad content is a 400', () async {
        final s = await ready(replay: null);
        final r = await _call(s, 'PUT', '/api/mock/replay/x', body: jsonEncode({'entry': {'url': 'a://saved'}}));
        expect(r.status, 200, reason: '${r.body}');
        expect((r.body['replays'] as Map)['x'], {'entry': {'url': 'a://saved'}, 'steps': <Object>[]});
        expect(jsonDecode(File('${project.path}/mocks/x.replay.json').readAsStringSync()),
            {'entry': {'url': 'a://saved'}, 'steps': <Object>[]});
        expect((await _call(s, 'PUT', '/api/mock/replay/x', body: '{"steps":3}')).status, 400);
        expect((await _call(s, 'PUT', '/api/mock/replay/nope', body: '{"entry":{"url":"a://b"}}')).status, 400);
        expect((await _call(s, 'GET', '/api/mock/replay/x')).status, 405);
      });

      test('deleting the scenario removes its replay', () async {
        final s = await ready();
        expect((await _call(s, 'DELETE', '/api/mock/scenarios/x')).status, 200);
        expect(File('${project.path}/mocks/x.replay.json').existsSync(), isFalse);
      });
    });
  });
}

/// A device that notes each call, with which scenario was on for the link.
class _Replay implements ReplayDevice {
  EmuServer? server;
  final calls = <String>[];
  List<LocateMatch> found = const [];
  Object? textError;
  Completer<void>? openGate;

  @override
  Future<String?> openUrl(String url) async {
    calls.add('open $url with ${server!.mock!.active}');
    await openGate?.future;
    return null;
  }

  @override
  Future<List<LocateMatch>> locate({String? text, String? key}) async {
    calls.add('locate ${text ?? key}');
    return found;
  }

  @override
  Future<void> tap(int x, int y) async => calls.add('tap $x,$y');

  @override
  Future<void> enterText(String text, {required bool append}) async {
    calls.add('text $text');
    if (textError != null) throw textError!;
  }

  @override
  Future<bool> settle(Duration timeout) async => true;
}
