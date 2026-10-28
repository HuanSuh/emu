import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/device_lease.dart';
import 'package:emu/src/engine.dart';
import 'package:emu/src/log_store.dart';
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
    emit(_status.copyWith(state: state));
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
    emit(_status.copyWith(state: AppRunState.stopped));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await stop();
    await _controller.close();
  }
}

Future<({int status, Map<String, dynamic> body})> _call(EmuServer server, String method, String path,
    {String? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    req.headers.set('X-Emu-Token', server.token);
    if (body != null) req.write(body);
    final res = await req.close();
    final text = utf8.decode(await res.expand((b) => b).toList());
    return (status: res.statusCode, body: jsonDecode(text) as Map<String, dynamic>);
  } finally {
    client.close(force: true);
  }
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
    tmp = Directory.systemTemp.createTempSync('emu_server_fake_');
    project = Directory('${tmp.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
    engine = FakeEngine();
  });

  tearDown(() async {
    await server?.dispose();
    server = null;
    tmp.deleteSync(recursive: true);
  });

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

    test('bad tap arguments are checked only once there is a VM Service', () async {
      final s = await start();
      expect((await _call(s, 'POST', '/api/tap')).status, 409);
      engine.appRunning();
      final r = await _call(s, 'POST', '/api/tap');
      expect(r.status, 400);
      expect(r.body, {'ok': false, 'error': 'x and y are required integers'});
    });
  });
}
