import 'dart:convert';
import 'dart:io';

import 'package:emu/src/mock.dart';
import 'package:test/test.dart';

void main() {
  group('parseMocks', () {
    test('hosts and scenarios', () {
      final c = parseMocks({
        'hosts': ['API.example.com', '*.cdn.test'],
        'port': 4600,
        'scenarios': {
          'empty': [
            {
              'match': {'method': 'GET', 'path': '/v1/items*'},
              'respond': {'status': 200, 'body': {'items': []}, 'delay': 300},
            },
            {
              'match': {'url': 'https://api.example.com/v1/me'},
              'respond': {'file': 'mocks/me.json', 'headers': {'x-mock': 1}},
            },
          ],
        },
      });
      expect(c.problems, isEmpty);
      expect(c.hosts, ['api.example.com', '*.cdn.test']);
      expect((c.enabled, c.portFor(4577)), (true, 4600));
      final rules = c.scenarios['empty']!;
      expect(rules[0].describe, 'GET /v1/items* → 200 +300ms');
      expect(rules[1].headers, {'x-mock': '1'});
      expect(parseMocks({'hosts': ['a.test']}).portFor(4577), 4590);
    });

    test('nothing configured is off, not an error', () {
      expect(parseMocks(null).enabled, isFalse);
      expect(parseMocks(null).problems, isEmpty);
    });

    test('problems name the entry; bad rules are skipped', () {
      final c = parseMocks({
        'hosts': ['https://api.example.com', 'ok.test'],
        'port': 'x',
        'scenarios': {
          'has space': [],
          's': [
            {'match': {}, 'respond': {}},
            {'match': {'path': 'v1'}, 'respond': {}},
            {'match': {'path': '/a'}, 'respond': {'status': 99}},
            {'match': {'path': '/a'}, 'respond': {'file': '../secret.json'}},
            {'match': {'path': '/a'}, 'respond': {'file': 'a.json', 'body': 'x'}},
            {'match': {'path': '/a'}, 'respond': {'delay': -1}},
            'nope',
            {'match': {'path': '/ok'}, 'respond': {}},
          ],
        },
      });
      final all = c.problems.join('\n');
      for (final want in [
        'mocks.hosts: "https://api.example.com"',
        'mocks.port',
        'mocks.scenarios.has space',
        'mocks.scenarios.s[0].match: give a path',
        'mocks.scenarios.s[1].match.path',
        'mocks.scenarios.s[2].respond.status',
        'mocks.scenarios.s[3].respond.file',
        'mocks.scenarios.s[4].respond: give body or file',
        'mocks.scenarios.s[5].respond.delay',
        'mocks.scenarios.s[6]: expected',
      ]) {
        expect(all, contains(want));
      }
      expect(c.hosts, ['ok.test']);
      expect(c.scenarios['s']!.single.path, '/ok');
      expect(parseMocks({'scenarios': {}}).problems.single, contains('list hosts (for emu_hook) or give upstream'));
    });

    test('base-URL mode: upstream + define, no hosts needed', () {
      final c = parseMocks({'upstream': 'https://api.example.com/v2', 'define': 'API_BASE_URL'});
      expect(c.problems, isEmpty);
      expect((c.enabled, c.hook, c.define, '${c.upstream}'), (true, false, 'API_BASE_URL', 'https://api.example.com/v2'));
      final bad = parseMocks({'hosts': ['a.test'], 'upstream': 'ftp://x', 'define': 'API-URL'}).problems.join('\n');
      expect(bad, allOf(contains('mocks.upstream'), contains('mocks.define')));
      expect(parseMocks({'hosts': ['a.test'], 'define': 'X'}).problems.single, contains('also give mocks.upstream'));
    });
  });

  test('rules match method, path glob (query when the glob has ?), url glob', () {
    final u = Uri.parse('https://api.example.com/v1/items/3?page=2');
    expect(MockRule(path: '/v1/items*').matches('get', u), isTrue);
    expect(MockRule(path: '/v1/items*', method: 'POST').matches('GET', u), isFalse);
    expect(MockRule(path: '/v1/items/*?page=2').matches('GET', u), isTrue);
    expect(MockRule(path: '/v1/items/*?page=1').matches('GET', u), isFalse);
    expect(MockRule(path: '/v1').matches('GET', u), isFalse);
    expect(MockRule(url: 'https://api.example.com/v1/*').matches('GET', u), isTrue);
    expect(MockRule(url: 'http://api.example.com/*').matches('GET', u), isFalse);
    expect(globMatch('/a.b*', '/a.bc'), isTrue);
    expect(globMatch('/a.b*', '/aXbc'), isFalse); // . is literal
    expect(mockHostMatches('img.cdn.test', ['*.cdn.test']), isTrue);
    expect(mockHostMatches('cdn.test', ['*.cdn.test']), isFalse);
  });

  group('MockServer', () {
    late Directory root;
    late HttpServer upstream;
    late MockServer server;
    late List<MockHit> hits;
    late int port;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('emu_mock_test');
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final body = await utf8.decodeStream(req);
        req.response.headers.set('x-upstream', 'yes');
        if (req.uri.path == '/redirect') {
          req.response
            ..statusCode = 302
            ..headers.set('location', '/elsewhere');
        } else {
          req.response.write('real ${req.method} ${req.uri} ${req.headers.value('x-app')} $body');
        }
        await req.response.close();
      });
      File('${root.path}/mocks/me.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"name": "mock"}');
      File('${root.path}/emu.yaml').writeAsStringSync('''
mocks:
  hosts: [127.0.0.1]
  scenarios:
    empty:
      - match: { method: GET, path: /v1/items* }
        respond: { status: 200, body: { items: [] } }
      - match: { path: /v1/me }
        respond: { file: mocks/me.json, headers: { x-mock: "1" } }
      - match: { path: /v1/slow }
        respond: { status: 503, body: busy, delay: 200 }
''');
      hits = [];
      server = MockServer(projectRoot: root.path, home: root.path, log: hits.add);
      for (var i = 0;; i++) {
        try {
          port = 20000 + DateTime.now().microsecond % 20000 + i * 2;
          await server.start(port);
          break;
        } on SocketException {
          if (i > 20) rethrow;
        }
      }
    });
    tearDown(() async {
      await server.close();
      await upstream.close(force: true);
      root.deleteSync(recursive: true);
    });

    /// What emu_hook does for an http:// origin: connect to port + 1, keep Host.
    Future<(int, String, HttpHeaders)> send(String method, String path, {String? body, int? hostPort}) async {
      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.open(method, '127.0.0.1', port + 1, path)
        ..followRedirects = false
        ..headers.host = '127.0.0.1'
        ..headers.port = hostPort ?? upstream.port
        ..headers.set('x-app', 'a1');
      if (body != null) req.write(body);
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res), res.headers);
    }

    test('off: everything goes to the real server, untouched', () async {
      final (code, body, headers) = await send('POST', '/v1/items?x=1', body: 'payload');
      expect(code, 200);
      expect(body, 'real POST /v1/items?x=1 a1 payload');
      expect(headers.value('x-upstream'), 'yes');
      expect(hits.single.scenario, isNull);
      expect(hits.single.url, 'http://127.0.0.1:${upstream.port}/v1/items?x=1');
    });

    test('a scenario answers matching requests; the rest still pass through', () async {
      server.active = 'empty';
      var (code, body, headers) = await send('GET', '/v1/items?page=1');
      expect((code, body, headers.contentType?.mimeType), (200, '{"items":[]}', 'application/json'));
      (code, body, headers) = await send('GET', '/v1/me');
      expect((body, headers.value('x-mock')), ('{"name": "mock"}', '1'));
      (code, body, _) = await send('POST', '/v1/items');
      expect(body, startsWith('real POST')); // GET only
      expect([for (final h in hits) h.scenario], ['empty', 'empty', null]);
    });

    test('CLI overrides: checked before the scenario, even with it off; replace by key; unset/reset', () async {
      MockRule rule(Map<String, dynamic> json) => parseMockRule(json, [])!;
      server.setOverride(rule({'match': {'method': 'get', 'path': '/v1/items*'}, 'respond': {'status': 418, 'body': 'tea'}}));
      var (code, body, _) = await send('GET', '/v1/items');
      expect((code, body, hits.last.scenario), (418, 'tea', 'cli'));
      server.active = 'empty'; // its /v1/items* rule loses to the override
      expect((await send('GET', '/v1/items')).$1, 418);
      server.setOverride(rule({'match': {'method': 'GET', 'path': '/v1/items*'}, 'respond': {'status': 204}}));
      expect(server.overrides, hasLength(1)); // same key: replaced
      expect(server.overrides.single.key, 'GET /v1/items*');
      expect((await send('GET', '/v1/items')).$1, 204);
      expect(server.unsetOverride('GET /v1/nope'), isFalse);
      expect(server.unsetOverride('GET /v1/items*'), isTrue);
      (code, body, _) = await send('GET', '/v1/items');
      expect((code, body), (200, '{"items":[]}')); // back to the scenario
      final problems = <String>[];
      expect(parseMockRule({'match': {}, 'respond': {}}, problems), isNull);
      expect(problems.single, startsWith('rule.match'));
    });

    test('upsertRule replaces the same key or appends', () {
      final a = parseMockRule({'match': {'path': '/a'}, 'respond': {'status': 200}}, [])!;
      final a2 = parseMockRule({'match': {'path': '/a'}, 'respond': {'status': 500}}, [])!;
      final b = parseMockRule({'match': {'method': 'POST', 'path': '/a'}, 'respond': {}}, [])!;
      expect([for (final r in upsertRule([a, b], a2)) r['respond']['status']], [500, 200]);
      expect(upsertRule([a], b), hasLength(2));
    });

    test('a mocked HEAD gets the length, not the body', () async {
      server.active = 'empty';
      final (code, body, headers) = await send('HEAD', '/v1/me');
      expect((code, body, headers.contentLength), (200, '', 16));
    });

    test('delay and a non-200 status', () async {
      server.active = 'empty';
      final sw = Stopwatch()..start();
      final (code, body, _) = await send('GET', '/v1/slow');
      expect((code, body), (503, 'busy'));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200));
    });

    test('redirects come back as they are, for the app to follow', () async {
      final (code, _, headers) = await send('GET', '/redirect');
      expect((code, headers.value('location')), (302, '/elsewhere'));
    });

    test('emu.yaml edits apply to the next request', () async {
      server.active = 'empty';
      File('${root.path}/emu.yaml').writeAsStringSync('''
mocks:
  hosts: [127.0.0.1]
  scenarios:
    empty:
      - match: { path: /v1/items }
        respond: { body: changed }
''');
      expect((await send('GET', '/v1/items')).$2, 'changed');
    });

    test('a host not in mocks.hosts is refused, not proxied', () async {
      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.open('GET', '127.0.0.1', port, '/')..headers.host = 'evil.test';
      final res = await req.close();
      expect(res.statusCode, 421);
      expect(hits.single.error, contains('evil.test is not in mocks.hosts'));
    });

    test('base-URL mode: a request to the mock server itself goes to mocks.upstream', () async {
      File('${root.path}/emu.yaml').writeAsStringSync('''
mocks:
  upstream: http://127.0.0.1:${upstream.port}/api
  define: API_BASE_URL
  scenarios:
    empty:
      - match: { url: "http://127.0.0.1:${upstream.port}/api/v1/items*" }
        respond: { body: mocked }
''');
      // What an app does with API_BASE_URL=http://127.0.0.1:<port>: Host is the mock server.
      var (code, body, _) = await send('GET', '/v1/items?page=1', hostPort: port);
      expect((code, body), (200, 'real GET /api/v1/items?page=1 a1 '));
      expect(hits.last.url, 'http://127.0.0.1:${upstream.port}/api/v1/items?page=1');
      server.active = 'empty';
      (code, body, _) = await send('GET', '/v1/items', hostPort: port + 1);
      expect((code, body), (200, 'mocked'));
    });

    test('without mocks.upstream, a request to the mock server itself is refused', () async {
      final (code, _, _) = await send('GET', '/v1/items', hostPort: port);
      expect(code, 421);
      expect(hits.single.error, contains('needs mocks.upstream'));
    });

    test('scenario files: listed with their source, written and deleted; emu.yaml ones are read-only', () async {
      var config = server.load();
      expect(config.sources, {'empty': 'emu.yaml'});
      final rules = [
        {'match': {'method': 'GET', 'path': '/v2/*'}, 'respond': {'status': 201, 'body': {'ok': true}, 'delay': 5}},
      ];
      expect(writeScenario(config, root.path, 'filed', rules), isEmpty);
      expect(File('${root.path}/mocks/filed.json').readAsStringSync(), contains('"path": "/v2/*"'));
      expect(writeScenario(config, root.path, 'empty', rules).single, contains('emu.yaml'));
      expect(writeScenario(config, root.path, 'bad name', rules).single, contains('letters'));
      expect(writeScenario(config, root.path, 'x', [{'match': {}}]).single, contains('x[0]'));
      config = server.load();
      expect(config.sources['filed'], 'mocks/filed.json');
      expect(config.scenarios['filed']!.single.toJson(), rules.single); // round-trips
      // A body file in the same folder (an object, not a list) is not a scenario.
      expect(config.sources.containsKey('me'), isFalse);
      server.active = 'filed';
      final (code, body, _) = await send('GET', '/v2/thing');
      expect((code, body), (201, '{"ok":true}'));
      expect(deleteScenario(config, root.path, 'filed'), isTrue);
      expect(deleteScenario(config, root.path, 'empty'), isFalse);
      expect(server.load().scenarios.containsKey('filed'), isFalse);
    });

    test('hits keep request and response bodies, mocked or passed through', () async {
      await send('POST', '/v1/echo', body: 'hello');
      server.active = 'empty';
      await send('GET', '/v1/items');
      final [passed, mocked] = hits;
      expect(passed.requestBody, 'hello');
      expect(passed.responseBody, 'real POST /v1/echo a1 hello');
      expect(mocked.responseBody, '{"items":[]}');
      expect(mocked.responseType, 'application/json');
      expect(server.hit(passed.id), same(passed));
      expect(passed.toJson().containsKey('responseBody'), isFalse);
      expect(passed.toJson(bodies: true)['responseBody'], isNotNull);
    });

    test('an unreachable real server is a 502, logged', () async {
      final (code, body, _) = await send('GET', '/v1/x', hostPort: 1);
      expect(code, 502);
      expect(body, startsWith('emu mock:'));
      expect(hits.single.error, isNotNull);
    });
  });
}
