import 'dart:convert';
import 'dart:io';

import 'package:emu/src/hub.dart';
import 'package:emu/src/registry.dart';
import 'package:emu/src/server.dart' show contentTypeFor;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HubServer hub;
  late HttpServer fakeSession; // stands in for a session server
  late List<String> fakeCalls;
  late List<List<String>> ran;
  late String base;
  late List<int> exits;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('emu_hub_');
    fakeCalls = [];
    ran = [];
    exits = [];
    fakeSession = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeSession.listen((req) async {
      fakeCalls.add('${req.method} ${req.uri.path} token=${req.headers.value('x-emu-token')}');
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(req.uri.path == '/api/status' ? {'ok': true, 'state': 'running'} : {'ok': true}));
      await req.response.close();
    });
    final project = Directory('${tmp.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: my_app\n');
    Directory('${project.path}/.emu').createSync();
    File('${project.path}/.emu/server.json')
        .writeAsStringSync(jsonEncode({'port': fakeSession.port, 'pid': pid, 'token': 'session-secret'}));
    final registry = SessionRegistry(dir: Directory('${tmp.path}/sessions'));
    registry.write(SessionEntry(project: project.path, port: fakeSession.port, pid: pid));
    final recent = RecentProjects(file: File('${tmp.path}/projects.json'))
      ..record(project.path, port: fakeSession.port)
      ..record('${tmp.path}/other', port: 4590, name: 'other');
    Directory('${tmp.path}/other').createSync();
    File('${tmp.path}/other/pubspec.yaml').writeAsStringSync('name: other\n');
    hub = HubServer(
      registry: registry,
      recent: recent,
      infoFile: File('${tmp.path}/hub.json'),
      run: (args, {workingDirectory}) async {
        ran.add([...args, if (workingDirectory != null) '@$workingDirectory']);
        return ProcessResult(0, 0, '{"ok":true,"state":"running"}\n', '');
      },
      latestVersion: () async => '99.0.0',
      fetchChangelog: () async => '## [Unreleased]\n\n## [99.0.0] - 2030-01-01\n- big\n\n## [0.0.1] - 2020-01-01\n- old\n',
      exitProcess: exits.add,
    );
    await hub.start(port: 0);
    base = 'http://127.0.0.1:${hub.port}';
  });

  tearDown(() async {
    await hub.close();
    await fakeSession.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Map<String, String> auth() => {'X-Emu-Token': hub.token};

  test('records itself in hub.json, and removes it on close', () async {
    final info = HubInfo.read(File('${tmp.path}/hub.json'))!;
    expect(info.port, hub.port);
    expect(info.pid, pid);
    expect(info.token, hub.token);
    expect(recordedHub(file: File('${tmp.path}/hub.json'))?.port, hub.port);
    expect((await runningHub(file: File('${tmp.path}/hub.json')))?.port, hub.port);
  });

  test('status is open; everything else needs the token', () async {
    final s = await http.get(Uri.parse('$base/api/status'));
    expect(jsonDecode(s.body), containsPair('hub', true));
    expect((await http.get(Uri.parse('$base/api/sessions'))).statusCode, 401);
    expect((await http.post(Uri.parse('$base/api/shutdown'))).statusCode, 401);
    final cross = await http.get(Uri.parse('$base/api/sessions'), headers: {...auth(), 'Origin': 'http://evil.test'});
    expect(cross.statusCode, 403);
  });

  test('page carries the token and refuses frames; session tokens never leave', () async {
    final r = await http.get(Uri.parse('$base/'));
    expect(r.statusCode, 200);
    expect(r.body, contains(hub.token));
    expect(r.headers['content-security-policy'], "frame-ancestors 'none'");
    expect((await http.get(Uri.parse('$base/hub.js'))).statusCode, 200);
    expect((await http.get(Uri.parse('$base/app.js'))).statusCode, 404); // only the hub's own files
    final snap = await http.get(Uri.parse('$base/api/sessions'), headers: auth());
    expect(snap.body, isNot(contains('session-secret')));
  });

  test('sessions: live entries with app state, recent ones not running', () async {
    final m = jsonDecode((await http.get(Uri.parse('$base/api/sessions'), headers: auth())).body) as Map;
    final s = (m['sessions'] as List).single as Map;
    expect(s['name'], 'my_app');
    expect(s['state'], 'running');
    expect(s['dashboard'], 'http://127.0.0.1:${fakeSession.port}');
    expect((m['recent'] as List).map((p) => p['name']), ['other']);
  });

  test('restart is forwarded with the session token, down runs the CLI', () async {
    final id = sessionIdFor('${tmp.path}/app');
    final r = await http.post(Uri.parse('$base/api/sessions/$id/restart'), headers: auth());
    expect(r.statusCode, 200);
    expect(fakeCalls, contains('POST /api/restart token=session-secret'));
    final d = await http.post(Uri.parse('$base/api/sessions/$id/down'), headers: auth());
    expect(d.statusCode, 200);
    expect(ran.single, ['down', '--project', '${tmp.path}/app']);
    final none = await http.post(Uri.parse('$base/api/sessions/000000000000/restart'), headers: auth());
    expect(none.statusCode, 404);
  });

  test('start runs emu up only in a recent project', () async {
    final bad = await http.post(Uri.parse('$base/api/projects/start'),
        headers: auth(), body: jsonEncode({'project': '/etc'}));
    expect(bad.statusCode, 400);
    final running = await http.post(Uri.parse('$base/api/projects/start'),
        headers: auth(), body: jsonEncode({'project': '${tmp.path}/app'}));
    expect(running.statusCode, 409);
    final ok = await http.post(Uri.parse('$base/api/projects/start'),
        headers: auth(), body: jsonEncode({'project': '${tmp.path}/other'}));
    expect(ok.statusCode, 200);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ran.single, ['up', '--json', '@${tmp.path}/other']);
  });

  test('version: reports the latest release; a dev build claims no update', () async {
    final v = jsonDecode((await http.get(Uri.parse('$base/api/version'), headers: auth())).body) as Map;
    expect(v['latest'], '99.0.0');
    // The test binary runs as 0.0.0-dev: not a release, so no update claim.
    expect(v['updateAvailable'], isFalse);
  });

  test('stream pushes a snapshot on connect', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${hub.port}/api/stream?token=${hub.token}');
    final first = jsonDecode(await ws.first as String) as Map;
    expect(first['type'], 'sessions');
    expect((first['sessions'] as List).single['name'], 'my_app');
  });

  group('guard, over every route', () {
    final routes = _hubRoutes();

    test('the route list is read from the code', () {
      expect(routes.length, greaterThan(10));
      expect(routes, containsAll(['/api/status', '/api/sessions', '/api/shutdown', '/api/projects/start', '/api/stream']));
    });

    test('only GET /api/status goes without the token; Host and Origin are checked first', () async {
      for (final path in routes) {
        for (final method in ['GET', 'POST']) {
          final open = path == '/api/status' && method == 'GET';
          final where = '$method $path';
          expect((await _call(hub.port, method, path)).status, open ? 200 : 401, reason: where);
          expect((await _call(hub.port, method, path, headers: {'X-Emu-Token': 'x' * 64})).status, open ? 200 : 401,
              reason: where);
          expect((await _call(hub.port, method, path, host: 'evil.test:${hub.port}', headers: auth())).status, 403,
              reason: where);
          for (final origin in ['http://evil.test', 'http://127.0.0.1:1', 'null']) {
            expect((await _call(hub.port, method, path, headers: {...auth(), 'Origin': origin})).status, 403,
                reason: '$where from $origin');
          }
        }
      }
      expect(fakeCalls, isEmpty);
      expect(ran, isEmpty);
      expect(exits, isEmpty);
    });

    test('static files: the allow list only, without the token, behind the Host check', () async {
      final hubSource = File('lib/src/hub.dart').readAsStringSync();
      final allowed = {
        for (final m in RegExp(r"'(/[a-z.-]*)': '([^']+)'").allMatches(hubSource)) m.group(1)!: m.group(2)!,
      };
      expect(allowed.keys, containsAll(['/', '/hub.js', '/hub.css']));
      for (final MapEntry(key: path, value: rel) in allowed.entries) {
        final r = await _call(hub.port, 'GET', path);
        expect(r.status, 200, reason: path);
        expect(r.type, contentTypeFor(rel).split(';').first, reason: path);
        expect(r.body.contains(hub.token), path == '/', reason: path);
        expect((await _call(hub.port, 'GET', path, host: 'evil.test')).status, 403, reason: path);
      }
      for (final path in ['/index.html', '/app.js', '/hub/index.html', '/hub/hub.js', '/style.css', '/nope']) {
        expect((await _call(hub.port, 'GET', path)).status, 404, reason: path);
      }
    });

    test('an unknown route is a JSON 404 once the token is in', () async {
      final r = await _call(hub.port, 'GET', '/api/nope', headers: auth());
      expect(r.status, 404);
      expect(r.type, 'application/json');
    });

    test('shutdown closes the hub, then exits', () async {
      // The close may cut the answer off; the CLI doesn't wait for it.
      await _call(hub.port, 'POST', '/api/shutdown', headers: auth()).then((r) => expect(r.status, 200),
          onError: (Object e) => expect(e, isA<HttpException>()));
      for (var i = 0; i < 100 && exits.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(exits, [0]);
      expect(File('${tmp.path}/hub.json').existsSync(), isFalse);
    });
  });

  group('hubFrameAncestors', () {
    test('the running hub origin may frame a dashboard', () async {
      expect(frameAncestorsFor(HubInfo(port: 4576, pid: pid)), 'http://127.0.0.1:4576 http://localhost:4576');
      expect(await hubFrameAncestors(file: File('${tmp.path}/hub.json')),
          'http://127.0.0.1:${hub.port} http://localhost:${hub.port}');
    });
    test('a live pid that is not a hub does not count', () async {
      // Our own pid is alive, but nothing answers as a hub on that port.
      final f = File('${tmp.path}/other.json')..writeAsStringSync(jsonEncode({'port': fakeSession.port, 'pid': pid}));
      expect(await hubFrameAncestors(file: f), "'none'");
    });
    test('a dead hub in hub.json does not count', () {
      final f = File('${tmp.path}/dead.json')..writeAsStringSync(jsonEncode({'port': 4576, 'pid': 999999}));
      expect(recordedHub(file: f), isNull);
    });
  });

  test('changelogBetween keeps only the sections in range', () {
    const log = '# Changelog\n\n## [Unreleased]\n- next\n\n## [0.3.0] - x\n- c\n\n## [0.2.0] - x\n- b\n\n'
        '## [0.1.0] - x\n- a\n\n[Unreleased]: https://x\n[0.3.0]: https://y\n';
    expect(changelogBetween(log, '0.1.0', '0.3.0'), '## [0.3.0] - x\n- c\n\n## [0.2.0] - x\n- b');
    expect(changelogBetween(log, '0.2.0', '0.2.0'), '');
  });
}

/// Every `/api/` route the hub answers, read from its dispatch code, with a
/// concrete path for the session actions.
List<String> _hubRoutes() {
  final hub = File('lib/src/hub.dart').readAsStringSync();
  final report = File('lib/src/report_api.dart').readAsStringSync();
  final actions = RegExp(r'/\(([a-z|]+)\)\$').firstMatch(hub)!.group(1)!.split('|');
  return {
    for (final m in RegExp(r"path == '(/api/[^']+)'").allMatches(hub)) m.group(1)!,
    for (final a in actions) '/api/sessions/0123456789ab/$a',
    for (final m in RegExp(r"path == '(/api/report[^']*)'").allMatches(report)) m.group(1)!,
    '/api/nope',
  }.toList()
    ..sort();
}

/// One request with full control of the headers, `Host` included.
Future<({int status, String? type, String body})> _call(int port, String method, String path,
    {String? host, Map<String, String> headers = const {}}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = utf8.decode(await res.expand((b) => b).toList(), allowMalformed: true);
    return (status: res.statusCode, type: res.headers.contentType?.mimeType, body: body);
  } finally {
    client.close(force: true);
  }
}
