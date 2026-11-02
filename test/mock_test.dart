import 'dart:convert';
import 'dart:io';

import 'package:emu/src/locate.dart';
import 'package:emu/src/mock.dart';
import 'package:emu/src/mock_replay.dart';
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

    test('the config is read once, and again only when emu.yaml, emu.local.yaml or a scenario file changes', () async {
      // Settled files: written well before now, so their mtimes can be trusted.
      final old = DateTime.now().subtract(const Duration(minutes: 1));
      void settle() {
        for (final f in [root.path, '${root.path}/mocks', ...root.listSync(recursive: true).map((e) => e.path)]) {
          if (FileSystemEntity.isFileSync(f)) File(f).setLastModifiedSync(old);
        }
      }

      settle();
      final first = server.load();
      server.active = 'empty';
      await Future.wait([for (var i = 0; i < 5; i++) send('GET', '/v1/items')]);
      expect(server.load(), same(first)); // not re-read per request

      File('${root.path}/emu.local.yaml').writeAsStringSync('mocks:\n  hosts: [127.0.0.1, local.test]\n');
      expect(server.load().hosts, ['127.0.0.1', 'local.test']);
      settle();
      final second = server.load();
      expect(server.load(), same(second));

      File('${root.path}/mocks/filed.json').writeAsStringSync('[{"match": {"path": "/v2"}, "respond": {"body": "filed"}}]');
      server.active = 'filed';
      expect((await send('GET', '/v2')).$2, 'filed');
      settle();
      final third = server.load();
      expect(server.load(), same(third));

      // An edit that keeps the size and (on a coarse clock) the mtime still shows.
      File('${root.path}/mocks/filed.json').writeAsStringSync('[{"match": {"path": "/v2"}, "respond": {"body": "FILED"}}]');
      expect((await send('GET', '/v2')).$2, 'FILED');
      File('${root.path}/mocks/filed.json').deleteSync();
      expect(server.load().scenarios.containsKey('filed'), isFalse);
    });

    test('a request that fails on the way out does not leave its connection to the real server open', () async {
      final real = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => real.close(force: true));
      real.listen((req) => req.response.close());
      // A header value the client side won't send (not ASCII): it fails after
      // the connection to the real server is already open.
      final app = await Socket.connect(InternetAddress.loopbackIPv4, port + 1);
      addTearDown(app.destroy);
      final answer = StringBuffer();
      app.listen((d) => answer.write(latin1.decode(d)));
      app.add(latin1.encode('GET /v1/x HTTP/1.1\r\nHost: 127.0.0.1:${real.port}\r\nx-name: caf\u00e9\r\n\r\n'));
      for (var i = 0; i < 50 && (hits.isEmpty || real.connectionsInfo().total > 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(answer.toString(), startsWith('HTTP/1.1 502'));
      expect(hits.single.error, contains('Invalid HTTP header field value'));
      expect(real.connectionsInfo().total, 0);
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

  group('scenario files as they are today', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('emu_mock_files_');
      Directory('${root.path}/mocks').createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    const rule = {'match': {'path': '/a'}, 'respond': {'status': 200}};
    void write(String name, Object? json) => File('${root.path}/mocks/$name').writeAsStringSync(jsonEncode(json));

    test('a top-level object is skipped without a problem — it may be a body file', () {
      write('me.json', {'entry': {'url': 'app://x'}, 'rules': [rule]});
      final c = withScenarioFiles(MockConfig(), root.path);
      expect(c.scenarios, isEmpty);
      expect(c.problems, isEmpty);
    });

    test('a name with a dot is never a scenario — what an older emu does with x.replay.json', () {
      write('x.replay.json', [rule]);
      final c = withScenarioFiles(MockConfig(), root.path);
      expect(c.scenarios, isEmpty);
    });

    test('saving always writes a plain list', () {
      expect(writeScenario(MockConfig(), root.path, 'x', [rule]), isEmpty);
      expect(jsonDecode(File('${root.path}/mocks/x.json').readAsStringSync()), [rule]);
      expect(writeScenario(MockConfig(), root.path, 'x', {'rules': []}).single, contains('list'));
    });
  });

  group('replay files', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('emu_mock_replay_');
      Directory('${root.path}/mocks').createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    const rule = {'match': {'path': '/a'}, 'respond': {'status': 200}};
    const good = {
      'entry': {'url': 'myapp://orders/1?a=1&b=2'},
      'steps': [
        {'tap': {'text': 'Pay', 'index': 1}},
        {'tap': {'key': 'card'}},
        {'text': '4242'},
        {'text': '!', 'append': true},
        {'settle': {'timeoutMs': 2000}},
        {'settle': <String, dynamic>{}},
      ],
    };
    void write(String name, Object? json) => File('${root.path}/mocks/$name').writeAsStringSync(jsonEncode(json));
    MockConfig load([MockConfig? base]) => withScenarioFiles(base ?? MockConfig(), root.path);

    test('no file: nothing changes', () {
      write('x.json', [rule]);
      final c = load();
      expect(c.replays, isEmpty);
      expect(c.problems, isEmpty);
      expect(c.toJson()['replays'], isEmpty);
    });

    test('read next to its scenario, which stays a plain list of rules', () {
      write('x.json', [rule]);
      write('x.replay.json', good);
      final c = load();
      expect(c.problems, isEmpty);
      expect(c.scenarios.keys, ['x']);
      expect(c.scenarios['x']!.single.toJson()['match'], rule['match']);
      expect(c.replays['x']!.toJson(), good);
      expect(c.replays['x']!.describe, 'myapp://orders/1?a=1&b=2 + 6 step(s)');
    });

    test('steps alone, or a link alone, is enough; neither is a problem', () {
      expect(parseReplay({'steps': [{'text': 'a'}]}, 'r', [])!.url, isNull);
      expect(parseReplay({'entry': {'url': 'a://b'}}, 'r', [])!.steps, isEmpty);
      final problems = <String>[];
      expect(parseReplay({}, 'r', problems), isNull);
      expect(problems.single, contains('entry.url, steps or both'));
    });

    for (final (label, raw, says) in <(String, Object?, String)>[
      ('not an object', [1], 'expected { entry'),
      ('unknown field', {'entry': {'url': 'a://b'}, 'x': 1}, 'unknown field "x"'),
      ('no scheme', {'entry': {'url': 'orders/1'}}, 'r.entry'),
      ('steps not a list', {'steps': {}}, 'r.steps'),
      ('unknown step', {'steps': [{'swipe': {}}]}, 'unknown step "swipe"'),
      ('two kinds in a step', {'steps': [{'tap': {'text': 'a'}, 'text': 'b'}]}, 'r.steps[0]'),
      ('tap with both', {'steps': [{'tap': {'text': 'a', 'key': 'b'}}]}, 'r.steps[0].tap'),
      ('tap with neither', {'steps': [{'tap': {'index': 0}}]}, 'r.steps[0].tap'),
      ('tap with a coordinate', {'steps': [{'tap': {'text': 'a', 'x': 1}}]}, 'r.steps[0].tap'),
      ('negative index', {'steps': [{'tap': {'text': 'a', 'index': -1}}]}, 'tap.index'),
      ('empty text', {'steps': [{'text': ''}]}, 'r.steps[0].text'),
      ('append on a tap', {'steps': [{'tap': {'text': 'a'}, 'append': true}]}, 'append'),
      ('append not a bool', {'steps': [{'text': 'a', 'append': 'yes'}]}, 'append'),
      ('settle too long', {'steps': [{'settle': {'timeoutMs': 60001}}]}, 'settle'),
      ('settle unknown field', {'steps': [{'settle': {'quietMs': 5}}]}, 'settle'),
    ]) {
      test('rejected: $label', () {
        final problems = <String>[];
        expect(parseReplay(raw, 'r', problems), isNull);
        expect(problems.join('\n'), contains(says));
      });
    }

    test('a broken file is reported, never ignored; the scenario still works', () {
      write('x.json', [rule]);
      write('x.replay.json', {'steps': [{'swipe': {}}]});
      write('y.json', [rule]);
      File('${root.path}/mocks/y.replay.json').writeAsStringSync('{');
      final c = load();
      expect(c.scenarios.keys, ['x', 'y']);
      expect(c.replays, isEmpty);
      expect(c.replayProblems['x']!.single, contains('mocks/x.replay.json.steps[0]'));
      expect(c.replayProblems['y']!.single, contains('not valid JSON'));
      expect(c.problems, hasLength(2));
    });

    test('a file with no scenario, or one for an emu.yaml scenario, is reported', () {
      write('ghost.replay.json', good);
      write('yaml.replay.json', good);
      final c = load(parseMocks({
        'hosts': ['a.test'],
        'scenarios': {'yaml': [rule]},
      }));
      expect(c.replays, isEmpty);
      expect(c.problems.join('\n'), allOf(contains('no scenario "ghost"'), contains('defined in emu.yaml')));
      expect(c.replayProblems.keys, ['yaml']);
    });

    test('saving rules leaves the replay; writing a replay leaves the rules', () {
      write('x.json', [rule]);
      write('x.replay.json', good);
      expect(writeScenario(load(), root.path, 'x', [rule, rule]), isEmpty);
      expect(load().replays['x']!.toJson(), good);
      expect(writeReplay(load(), root.path, 'x', {'entry': {'url': 'a://new'}}), isEmpty);
      expect(jsonDecode(File('${root.path}/mocks/x.replay.json').readAsStringSync()), {
        'entry': {'url': 'a://new'},
        'steps': <Object>[],
      });
      expect(load().scenarios['x'], hasLength(2));
    });

    test('writing is refused without a file scenario, or with bad content', () {
      write('x.json', [rule]);
      final yaml = parseMocks({
        'hosts': ['a.test'],
        'scenarios': {'yaml': [rule]},
      });
      expect(writeReplay(load(), root.path, 'nope', good).single, contains('no scenario'));
      expect(writeReplay(load(yaml), root.path, 'yaml', good).single, contains('emu.yaml'));
      expect(writeReplay(load(), root.path, 'x', {'steps': [{'swipe': {}}]}).single, contains('swipe'));
      expect(File('${root.path}/mocks/x.replay.json').existsSync(), isFalse);
    });

    test('deleting a scenario takes its replay with it', () {
      write('x.json', [rule]);
      write('x.replay.json', good);
      expect(deleteScenario(load(), root.path, 'x'), isTrue);
      expect(Directory('${root.path}/mocks').listSync(), isEmpty);
    });
  });

  group('runReplay', () {
    test('entry, then steps in order, then a settle', () async {
      final d = _Device()..found = [_match()];
      final r = await runReplay(
        const MockReplay(url: 'a://b', steps: [
          ReplayTap(text: 'Pay'),
          ReplayText('42', append: true),
          ReplaySettle(timeoutMs: 500),
        ]),
        d,
      );
      expect(d.calls, [
        'open a://b',
        'locate Pay', 'tap 1,2', 'settle 3000', // each input waits for the next screen
        'text 42 true', 'settle 3000',
        'settle 500',
        'settle 10000',
      ]);
      expect([for (final x in r) (x.step, x.kind, x.ok)], [
        (null, 'entry', true),
        (0, 'tap', true),
        (1, 'text', true),
        (2, 'settle', true),
        (null, 'settle', true),
      ]);
      expect(replayFailure(r), isNull);
    });

    test('a tap waits for its widget to appear', () async {
      final d = _Device();
      var looks = 0;
      d.onLocate = () => ++looks < 3 ? [] : [_match()];
      final r = await runReplay(
        const MockReplay(steps: [ReplayTap(key: 'k')]),
        d,
        retry: Duration.zero,
      );
      expect(looks, 3);
      expect(r.first.ok, isTrue);
      expect(d.calls.where((c) => c.startsWith('tap')), hasLength(1));
    });

    test('a widget that never appears stops the run there and says which', () async {
      final d = _Device();
      final r = await runReplay(
        const MockReplay(url: 'a://b', steps: [ReplayTap(text: 'Gone'), ReplayText('never')]),
        d,
        tapWait: const Duration(milliseconds: 20),
        retry: const Duration(milliseconds: 1),
      );
      expect(r.last.ok, isFalse);
      expect(replayFailure(r), 'steps[0] tap: no widget matches text "Gone" (waited 20ms)');
      expect(d.calls.any((c) => c.startsWith('text')), isFalse);
      expect(d.calls.contains('settle 10000'), isFalse);
    });

    test('an index past the matches waits too; several with no index stops at once', () async {
      var d = _Device()..found = [_match()];
      var r = await runReplay(
        const MockReplay(steps: [ReplayTap(text: 'a', index: 1)]),
        d,
        tapWait: Duration.zero,
      );
      expect(r.single.detail, contains('index 1 out of range'));
      d = _Device()..found = [_match(), _match()];
      r = await runReplay(const MockReplay(steps: [ReplayTap(text: 'a')]), d);
      expect(r.single.detail, contains('matched 2 widgets'));
      expect(d.calls.where((c) => c.startsWith('locate')), hasLength(1));
    });

    test('a locate that errors is retried; a tap that errors is not', () async {
      final d = _Device();
      var looks = 0;
      d.onLocate = () => ++looks < 2 ? throw StateError('restarting') : [_match()];
      d.tapError = StateError('lost');
      final r = await runReplay(const MockReplay(steps: [ReplayTap(text: 'a')]), d, retry: Duration.zero);
      expect(looks, 2);
      expect(d.calls.where((c) => c.startsWith('tap')), hasLength(1));
      expect(r.single.detail, contains('lost'));
    });

    test('a link that fails to open ends it before any step', () async {
      final d = _Device()..openError = 'no device connected';
      final r = await runReplay(const MockReplay(url: 'a://b', steps: [ReplayText('x')]), d);
      expect(replayFailure(r), 'entry: no device connected');
      expect(d.calls, ['open a://b']);
    });

    test('an app that never settles is no failure', () async {
      final d = _Device()..settled = false;
      final r = await runReplay(const MockReplay(steps: [ReplaySettle(timeoutMs: 5)]), d);
      expect(r.map((x) => x.ok), [true, true]);
      expect(r.first.detail, 'still busy after 5ms');
    });

    test('over the limit, it stops at the next step', () async {
      final d = _Device();
      final r = await runReplay(const MockReplay(url: 'a://b'), d, limit: Duration(microseconds: -1));
      expect(r.single.ok, isFalse);
      expect(d.calls, isEmpty);
    });

    test('lines for the CLI name the place in the file', () {
      expect(
        replayLines([
          ReplayResult(null, 'entry', true, 'a://b').toJson(),
          ReplayResult(2, 'tap', false, 'gone').toJson(),
        ]),
        ['✓ entry  a://b', '✗ steps[2] tap  gone'],
      );
    });
  });
}

LocateMatch _match() => LocateMatch(1, 2, 10, 10, 'Text');

class _Device implements ReplayDevice {
  final calls = <String>[];
  List<LocateMatch> found = const [];
  List<LocateMatch> Function()? onLocate;
  String? openError;
  Object? tapError;
  bool settled = true;

  @override
  Future<String?> openUrl(String url) async {
    calls.add('open $url');
    return openError;
  }

  @override
  Future<List<LocateMatch>> locate({String? text, String? key}) async {
    calls.add('locate ${text ?? key}');
    return onLocate?.call() ?? found;
  }

  @override
  Future<void> tap(int x, int y) async {
    calls.add('tap $x,$y');
    if (tapError != null) throw tapError!;
  }

  @override
  Future<void> enterText(String text, {required bool append}) async => calls.add('text $text $append');

  @override
  Future<bool> settle(Duration timeout) async {
    calls.add('settle ${timeout.inMilliseconds}');
    return settled;
  }
}
