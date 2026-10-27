import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/hub.dart';
import 'package:emu/src/registry.dart';
import 'package:emu/src/self_update.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// The hub's Update button (POST /api/update) against a fake git checkout and
/// fake commands: nothing is pulled, built or restarted for real.
void main() {
  late Directory tmp;
  late String repo;
  late HubServer hub;
  late String base;
  late List<String> calls;
  late Completer<void> buildGate;
  late ProcessResult buildResult;
  late String dirty;
  late List<String> restarts;
  late Completer<void> restartDone;
  late String built; // what build.sh "produces"

  Future<ProcessResult> run(String exe, List<String> args, {String? workingDirectory}) async {
    final line = [exe.split('/').last, ...args].join(' ');
    calls.add(line);
    if (line.endsWith('status --porcelain')) return ProcessResult(0, 0, dirty, '');
    if (line == 'bash build.sh') {
      await buildGate.future;
      if (buildResult.exitCode == 0) {
        File('$workingDirectory/emu').writeAsStringSync(built);
        Process.runSync('chmod', ['+x', '$workingDirectory/emu']);
      }
      return buildResult;
    }
    return ProcessResult(0, 0, '', '');
  }

  setUp(() async {
    tmp = Directory(Directory.systemTemp.createTempSync('emu_hub_update_').resolveSymbolicLinksSync());
    repo = '${tmp.path}/emu';
    Directory('$repo/.git').createSync(recursive: true);
    File('$repo/pubspec.yaml').writeAsStringSync('name: emu\n');
    File('$repo/emu').writeAsStringSync('old');
    calls = [];
    buildGate = Completer()..complete();
    buildResult = ProcessResult(0, 0, '', '');
    dirty = '';
    restarts = [];
    restartDone = Completer();
    built = 'new';
    hub = HubServer(
      registry: SessionRegistry(dir: Directory('${tmp.path}/sessions')),
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      infoFile: File('${tmp.path}/hub.json'),
      latestVersion: () async => '0.2.0',
      fetchChangelog: () async => null,
      updater: () => SelfUpdater(
        executable: '$repo/emu',
        currentVersion: '0.1.0',
        environment: {'HOME': tmp.path, 'PATH': ''},
        run: run,
        latestVersion: () async => '0.2.0',
        appInstalled: () => false,
        lockFile: File('${tmp.path}/update.lock'),
      ),
      restart: (exe) async {
        restarts.add(exe);
        await restartDone.future; // a real restart exits here
      },
    );
    await hub.start(port: 0);
    base = 'http://127.0.0.1:${hub.port}';
  });

  tearDown(() async {
    if (!restartDone.isCompleted) restartDone.complete();
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  Map<String, String> auth() => {'X-Emu-Token': hub.token};
  Future<http.Response> post([Object? body]) =>
      http.post(Uri.parse('$base/api/update'), headers: auth(), body: body == null ? null : jsonEncode(body));
  Future<Map?> state() async =>
      (jsonDecode((await http.get(Uri.parse('$base/api/update'), headers: auth())).body) as Map)['update'] as Map?;

  Future<Map> waitFor(String s) async {
    for (var i = 0; i < 100; i++) {
      final u = await state();
      if (u?['state'] == s) return u!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('update never reached $s (now ${await state()})');
  }

  test('needs the token like every other action', () async {
    expect((await http.post(Uri.parse('$base/api/update'))).statusCode, 401);
    expect(calls, isEmpty);
  });

  test('runs the fixed update, streams its steps, then restarts into the new binary', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${hub.port}/api/stream?token=${hub.token}');
    final updates = <Map>[];
    ws.listen((m) {
      final msg = jsonDecode(m as String) as Map;
      if (msg['type'] == 'update') updates.add(msg);
    });
    // Whatever the page sends, the hub runs its own steps.
    final r = await post({'command': 'rm -rf /', 'args': ['--evil']});
    expect(r.statusCode, 202);
    expect((jsonDecode(r.body) as Map)['update'], containsPair('to', '0.2.0'));
    final u = await waitFor('restarting');
    for (var i = 0; i < 50 && restarts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20)); // after the message goes out
    }
    expect(restarts, ['$repo/emu']);
    expect(calls, ['git -C $repo status --porcelain', 'git -C $repo status --porcelain', 'git -C $repo pull --ff-only', 'bash build.sh']);
    expect(u['log'], contains(contains('git pull')));
    expect((u['result'] as Map)['to'], '0.2.0');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(updates.map((m) => m['state']), containsAllInOrder(['running', 'restarting']));
    await ws.close();
  });

  test('a second click while it runs is refused', () async {
    buildGate = Completer();
    expect((await post()).statusCode, 202);
    final again = await post();
    expect(again.statusCode, 409);
    expect((jsonDecode(again.body) as Map)['error'], contains('already running'));
    buildGate.complete();
    await waitFor('restarting');
    expect(calls.where((c) => c.contains('pull')), hasLength(1));
  });

  test('a dirty checkout is refused with the reason, and nothing runs', () async {
    dirty = ' M lib/x.dart\n';
    final r = await post();
    expect(r.statusCode, 409);
    expect((jsonDecode(r.body) as Map)['error'], contains('uncommitted changes'));
    expect(await state(), isNull);
    expect(calls.where((c) => c.contains('pull')), isEmpty);
  });

  test('a failed build is shown, and Update can be tried again', () async {
    buildResult = ProcessResult(0, 1, '', 'compile error');
    expect((await post()).statusCode, 202);
    final u = await waitFor('failed');
    expect(u['error'], contains('compile error'));
    expect(restarts, isEmpty);
    buildResult = ProcessResult(0, 0, '', '');
    expect((await post()).statusCode, 202);
    await waitFor('restarting');
  });

  test('if the new hub does not come up, this one keeps serving and says so', () async {
    expect((await post()).statusCode, 202);
    await waitFor('restarting');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    restartDone.complete();
    final u = await waitFor('failed');
    expect(u['error'], contains('new hub did not start'));
  });

  test('a check that breaks answers an error and leaves no update running', () async {
    final h = HubServer(
      registry: SessionRegistry(dir: Directory('${tmp.path}/sessions')),
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      infoFile: File('${tmp.path}/hub3.json'),
      updater: () => SelfUpdater(
          executable: '$repo/emu',
          currentVersion: '0.1.0',
          run: (exe, args, {workingDirectory}) async => throw const ProcessException('git', [], 'no git'),
          latestVersion: () async => '0.2.0'),
    );
    await h.start(port: 0);
    addTearDown(h.close);
    Future<http.Response> click() =>
        http.post(Uri.parse('http://127.0.0.1:${h.port}/api/update'), headers: {'X-Emu-Token': h.token});
    final r = await click();
    expect(r.statusCode, 500);
    expect((jsonDecode(r.body) as Map)['error'], contains('no git'));
    final again = await click();
    expect((jsonDecode(again.body) as Map)['error'], isNot(contains('already running')));
  });

  test('up to date: refused, nothing runs', () async {
    final h = HubServer(
      registry: SessionRegistry(dir: Directory('${tmp.path}/sessions')),
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      infoFile: File('${tmp.path}/hub2.json'),
      updater: () => SelfUpdater(
          executable: '$repo/emu', currentVersion: '0.2.0', run: run, latestVersion: () async => '0.2.0'),
    );
    await h.start(port: 0);
    addTearDown(h.close);
    final r = await http.post(Uri.parse('http://127.0.0.1:${h.port}/api/update'), headers: {'X-Emu-Token': h.token});
    expect(r.statusCode, 409);
    expect((jsonDecode(r.body) as Map)['error'], contains('up to date'));
  });

  test('version tells the page how emu is installed', () async {
    final v = jsonDecode((await http.get(Uri.parse('$base/api/version'), headers: auth())).body) as Map;
    expect(v['install'], 'git');
    expect(v['command'], 'emu update');
  });

  group('the hub replacing itself', () {
    late HubServer self;
    late List<int> exits;

    Future<void> startSelf() async {
      exits = [];
      self = HubServer(
        registry: SessionRegistry(dir: Directory('${tmp.path}/sessions')),
        recent: RecentProjects(file: File('${tmp.path}/projects.json')),
        infoFile: File('${tmp.path}/self.json'),
        updater: () => SelfUpdater(
          executable: '$repo/emu',
          currentVersion: '0.1.0',
          environment: {'HOME': tmp.path, 'PATH': ''},
          run: run,
          latestVersion: () async => '0.2.0',
          appInstalled: () => false,
          lockFile: File('${tmp.path}/update.lock'),
        ),
        exitProcess: exits.add,
      );
      await self.start(port: 0);
      addTearDown(self.close);
    }

    Future<Map?> selfState(int port, String token) async {
      try {
        final r = await http.get(Uri.parse('http://127.0.0.1:$port/api/update'), headers: {'X-Emu-Token': token});
        return (jsonDecode(r.body) as Map)['update'] as Map?;
      } catch (_) {
        return null; // between servers
      }
    }

    test('hands its port to the new hub, then exits', () async {
      await startSelf();
      final port = self.port;
      // The "new binary": a stand-in hub that takes the port it is given and records itself.
      final server = File('${tmp.path}/fake_hub.py')..writeAsStringSync(r'''
import http.server, json, os, sys
port, info = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok": true, "hub": true}')
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('127.0.0.1', port), H)
json.dump({'port': port, 'pid': os.getpid(), 'token': 'new'}, open(info, 'w'))
srv.serve_forever()
''');
      // build.sh "produces" a binary that runs the stand-in, as `emu __hub --port <port>` would.
      built = '#!/bin/sh\nexec python3 ${server.path} "\$3" ${tmp.path}/self.json\n';
      addTearDown(() {
        final info = HubInfo.read(File('${tmp.path}/self.json'));
        if (info != null && info.pid != pid) Process.killPid(info.pid);
      });
      final r = await http.post(Uri.parse('http://127.0.0.1:$port/api/update'), headers: {'X-Emu-Token': self.token});
      expect(r.statusCode, 202);
      for (var i = 0; i < 100 && exits.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(exits, [0]);
      final info = HubInfo.read(File('${tmp.path}/self.json'))!;
      expect(info.port, port, reason: 'the new hub took the same port');
      expect(info.pid, isNot(pid));
      final status = await http.get(Uri.parse('http://127.0.0.1:$port/api/status'));
      expect(jsonDecode(status.body), containsPair('hub', true));
    }, testOn: '!windows');

    test('if the new binary cannot start, it serves again on the same port', () async {
      await startSelf();
      final port = self.port;
      // build.sh "produces" a program that cannot start.
      built = '#!/nonexistent/interpreter\n';
      expect((await http.post(Uri.parse('http://127.0.0.1:$port/api/update'), headers: {'X-Emu-Token': self.token}))
          .statusCode, 202);
      Map? u;
      for (var i = 0; i < 100 && u?['state'] != 'failed'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        u = await selfState(port, self.token);
      }
      expect(u?['error'], contains('new hub did not start'));
      expect(exits, isEmpty);
      expect(self.port, port);
      expect(HubInfo.read(File('${tmp.path}/self.json'))?.pid, pid, reason: 'it recorded itself again');
    });
  });
}
