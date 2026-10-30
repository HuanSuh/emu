import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/device_lease.dart';
import 'package:emu/src/registry.dart';
import 'package:emu/src/server.dart';
import 'package:emu/src/session.dart';
import 'package:test/test.dart';

/// Every `/api/` route the session server answers, read from the code that
/// dispatches them — a route added there is covered here without editing
/// this list. Subroutes of the delegated families get a concrete path.
List<String> _sessionRoutes() {
  final server = File('lib/src/server.dart').readAsStringSync();
  final mock = RegExp(r"'(/api/mock/[a-z]+/?)'").allMatches(server).map((m) => m.group(1)!);
  final report = File('lib/src/report_api.dart').readAsStringSync();
  final pages = File('lib/src/pages_api.dart').readAsStringSync();
  return {
    for (final m in RegExp(r"case '(/api/[^']+)':").allMatches(server)) m.group(1)!,
    for (final m in RegExp(r"path == '(/api/[^']+)'").allMatches(server)) m.group(1)!,
    for (final p in mock) p.endsWith('/') ? '${p}1' : p,
    for (final m in RegExp(r"path == '(/api/report[^']*)'").allMatches(report)) m.group(1)!,
    '/api/report/image/0/0',
    for (final m in RegExp(r"case \('([a-z]+)', 5\)").allMatches(pages)) '/api/pages/home/${m.group(1)}/x',
    '/api/nope', // unknown routes are refused before they 404
  }.toList()
    ..sort();
}

/// One request with full control of the headers — `Host` included, which
/// is how a DNS-rebinding page arrives.
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

void main() {
  late Directory tmp;
  late Directory project;
  late SessionRegistry registry;
  late EmuServer server;
  late List<int> exits;

  Future<EmuServer> startServer() async {
    final s = EmuServer(
      session: Session(project),
      leases: DeviceLeases(dir: Directory('${tmp.path}/devices')),
      registry: registry,
      recent: RecentProjects(file: File('${tmp.path}/projects.json')),
      // No flutter, no device: the launch fails at once and the API stays up.
      flutterExecutable: '${tmp.path}/no-flutter',
      exitProcess: exits.add,
    );
    await s.start(0, LaunchOptions());
    return s;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('emu_server_http_');
    project = Directory('${tmp.path}/app')..createSync();
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
    File('${project.path}/emu.yaml').writeAsStringSync('''
pages:
  - id: home
    title: Home
    toolbar:
      - action: { id: hi, run: [echo, hi] }
''');
    registry = SessionRegistry(dir: Directory('${tmp.path}/sessions'));
    exits = [];
    server = await startServer();
  });

  tearDown(() async {
    Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
    try {
      await server.dispose();
    } catch (_) {
      // A test that broke dispose on purpose.
    }
    tmp.deleteSync(recursive: true);
  });

  Map<String, String> auth() => {'X-Emu-Token': server.token};

  group('guard', () {
    final routes = _sessionRoutes();

    test('the route list is read from the code', () {
      expect(routes.length, greaterThan(30));
      expect(routes, containsAll(['/api/status', '/api/logs', '/api/shutdown', '/api/stream', '/api/pages', '/api/report/send']));
    });

    for (final path in routes) {
      for (final method in ['GET', 'POST']) {
        final open = path == '/api/status' && method == 'GET';
        test('$method $path: ${open ? 'open without the token' : 'needs the token'}', () async {
          expect((await _call(server.port, method, path)).status, open ? 200 : 401);
          expect((await _call(server.port, method, path, headers: {'X-Emu-Token': 'x' * 64})).status, open ? 200 : 401);
          // Host and Origin are checked before the token, and with it.
          final rebind = await _call(server.port, method, path, host: 'evil.test:${server.port}', headers: auth());
          expect(rebind.status, 403);
          for (final origin in ['http://evil.test', 'http://127.0.0.1:1', 'null']) {
            expect((await _call(server.port, method, path, headers: {...auth(), 'Origin': origin})).status, 403,
                reason: origin);
          }
        });
      }
    }

    test('HEAD /api/status is open too, like GET (README: the liveness ping)', () async {
      expect((await _call(server.port, 'HEAD', '/api/status')).status, 200);
      expect((await _call(server.port, 'PUT', '/api/status')).status, 401);
    });

    test('without the token, /api/status says only that the server is up', () async {
      final r = await _call(server.port, 'GET', '/api/status');
      expect(r.type, 'application/json');
      expect((jsonDecode(r.body) as Map).keys, unorderedEquals(['ok', 'state', 'serverPort']));
      final full = jsonDecode((await _call(server.port, 'GET', '/api/status', headers: auth())).body) as Map;
      expect(full, contains('status'));
      expect(full['serverPort'], server.port);
    });

    test('the token also comes as ?token= (WebSocket, <img>), and same-origin and localhost pass', () async {
      expect((await _call(server.port, 'GET', '/api/logs?token=${server.token}')).status, 200);
      final self = 'http://127.0.0.1:${server.port}';
      expect((await _call(server.port, 'GET', '/api/logs', headers: {...auth(), 'Origin': self})).status, 200);
      expect((await _call(server.port, 'GET', '/api/logs', host: 'localhost:${server.port}', headers: auth())).status, 200);
    });

    test('refusals are JSON', () async {
      final r = await _call(server.port, 'POST', '/api/reload');
      expect(r.type, 'application/json');
      expect(jsonDecode(r.body), containsPair('ok', false));
    });
  });

  group('static dashboard', () {
    test('served without the token, with the token inside index.html only', () async {
      final page = await _call(server.port, 'GET', '/');
      expect(page.status, 200);
      expect(page.type, 'text/html');
      expect(page.body, contains(server.token));
      for (final (path, type) in [('/app.js', 'application/javascript'), ('/style.css', 'text/css'), ('/favicon.png', 'image/png')]) {
        final r = await _call(server.port, 'GET', path);
        expect(r.status, 200, reason: path);
        expect(r.type, type, reason: path);
        expect(r.body, isNot(contains(server.token)), reason: path);
      }
    });

    test('still behind the Host check (DNS rebinding reads the page and its token)', () async {
      expect((await _call(server.port, 'GET', '/', host: 'evil.test')).status, 403);
      expect((await _call(server.port, 'GET', '/app.js', host: 'evil.test')).status, 403);
    });

    test("the hub's page and unknown files are 404", () async {
      expect((await _call(server.port, 'GET', '/hub/index.html')).status, 404);
      expect((await _call(server.port, 'GET', '/nope.js')).status, 404);
    });
  });

  group('routes', () {
    test('status, logs, errors, session', () async {
      for (final path in ['/api/status', '/api/logs', '/api/logs?grep=listening&limit=5', '/api/errors', '/api/session']) {
        final r = await _call(server.port, 'GET', path, headers: auth());
        expect(r.status, 200, reason: path);
        expect(r.type, 'application/json', reason: path);
      }
      final logs = jsonDecode((await _call(server.port, 'GET', '/api/logs?grep=listening', headers: auth())).body) as Map;
      expect((logs['logs'] as List).single['text'], contains('emu server listening'));
      expect(logs['lastSeq'], isA<int>());
    });

    test('pages: the list, an unknown page, a known one', () async {
      final list = await _call(server.port, 'GET', '/api/pages', headers: auth());
      expect(list.status, 200);
      expect(list.type, 'application/json');
      expect([for (final p in (jsonDecode(list.body) as Map)['pages'] as List) p['id']], contains('home'));
      expect((await _call(server.port, 'GET', '/api/pages/nope/blocks/x', headers: auth())).status, 404);
      expect((await _call(server.port, 'GET', '/api/pages/home/blocks/x', headers: auth())).status, 404);
      expect((await _call(server.port, 'GET', '/api/pages/home/auto/hi', headers: auth())).status, 404);
    });

    test('an unknown route is a JSON 404 once the token is in', () async {
      final r = await _call(server.port, 'GET', '/api/nope', headers: auth());
      expect(r.status, 404);
      expect(r.type, 'application/json');
    });

    test('shutdown answers, disposes and exits', () async {
      await _shutdown(server);
      await _until(() => exits.isNotEmpty);
      expect(exits, [0]);
      expect(Session(project).serverInfoFile.existsSync(), isFalse);
    });
  });

  group('dispose', () {
    test('cleans up the rest when one step fails', () async {
      final port = server.port;
      expect(registry.all(), hasLength(1));
      // .emu/server.json can't be removed — clearServerInfo throws.
      Process.runSync('chmod', ['a-w', Session(project).stateDir.path]);
      await server.dispose();
      expect(registry.all(), isEmpty, reason: 'registry entry left behind');
      expect(await _refusedSoon(port), isTrue, reason: 'HTTP server still listening');
    });

    test('a failed dispose still ends the process on /api/shutdown', () async {
      Process.runSync('chmod', ['a-w', Session(project).stateDir.path]);
      await _shutdown(server);
      await _until(() => exits.isNotEmpty);
      expect(exits, [0]);
    });
  });
}

/// `POST /api/shutdown`. The server closes as it answers, so the answer may
/// be cut off — the CLI doesn't wait for it either.
Future<void> _shutdown(EmuServer server) async {
  try {
    final r = await _call(server.port, 'POST', '/api/shutdown', headers: {'X-Emu-Token': server.token});
    expect(r.status, 200);
  } on HttpException {
    // Closed first.
  }
}

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Whether connections to [port] are refused within [within]. A process
/// that another test file starts holds this process's listening sockets from
/// fork until exec, so a port just closed can still take a connection for a
/// moment — and then drop it unanswered.
Future<bool> _refusedSoon(int port, {Duration within = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(within);
  while (true) {
    try {
      await _call(port, 'GET', '/api/status').timeout(const Duration(milliseconds: 500));
    } on SocketException {
      return true;
    } on HttpException {
      // Taken, then dropped: the socket was still held.
    } on TimeoutException {
      // Taken and not answered: the socket is still held.
    }
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
