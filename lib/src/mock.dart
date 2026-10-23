/// `emu mock` — canned API responses for an app under emu, without touching
/// its base URLs.
///
/// Requests reach this server one of two ways:
///
/// - **hook** (`mocks.hosts`): the app's `emu_hook` (enabled by the
///   `EMU_MOCK` dart-define `emu up` passes) connects requests for those
///   hosts here as plain HTTP with their original `Host` header — `https://`
///   origins on [MockServer.port], `http://` ones on port + 1.
/// - **base URL** (`mocks.upstream` + `mocks.define`): an app that takes its
///   API base URL from a dart-define gets `http://127.0.0.1:<port>` for it,
///   and talks to this server directly; `upstream` says where those requests
///   were meant to go.
///
/// The active scenario's first matching rule answers a request; anything
/// else goes on to the real server and its answer comes back untouched.
///
/// ```yaml
/// mocks:
///   hosts: [api.example.com]          # hook mode, and/or:
///   upstream: https://api.example.com # base-URL mode …
///   define: API_BASE_URL              # … emu sets this dart-define to the mock server
///   scenarios:
///     empty-list:
///       - match: { method: GET, path: /v1/items* }
///         respond: { status: 200, body: { items: [] } }
///     server-error:
///       - match: { path: /v1/payments* }
///         respond: { status: 500, file: mocks/error.json, delay: 800 }
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'project_config.dart';

/// One canned answer: when [matches], respond with [status], [headers] and
/// [body] (inline) or [file] (project-relative), after [delay].
class MockRule {
  MockRule({
    this.method,
    this.path,
    this.url,
    this.status = 200,
    this.headers = const {},
    this.body,
    this.file,
    this.delay = Duration.zero,
  });

  final String? method;

  /// Glob over the path (`*` is any run of characters); with a `?` in it,
  /// over path and query.
  final String? path;

  /// Glob over the whole URL, `https://host/path?query`.
  final String? url;
  final int status;
  final Map<String, String> headers;
  final Object? body;
  final String? file;
  final Duration delay;

  /// What a rule answers: two rules with the same key replace each other
  /// (`emu mock set`, "mock this").
  String get key => '${method?.toUpperCase() ?? '*'} ${url ?? path}';

  bool matches(String method, Uri uri) {
    if (this.method != null && this.method!.toUpperCase() != method.toUpperCase()) return false;
    final path = this.path;
    if (path != null) {
      final target = path.contains('?') ? '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}' : uri.path;
      if (!globMatch(path, target)) return false;
    }
    final url = this.url;
    if (url != null && !globMatch(url, '$uri')) return false;
    return true;
  }

  String get describe => [
        method ?? '*',
        url ?? path ?? '*',
        '→ $status',
        if (file != null) file!,
        if (delay > Duration.zero) '+${delay.inMilliseconds}ms',
      ].join(' ');

  /// The rule as written in emu.yaml or a scenario file.
  Map<String, dynamic> toJson() => {
        'match': {'method': ?method, 'path': ?path, 'url': ?url},
        'respond': {
          'status': status,
          if (headers.isNotEmpty) 'headers': headers,
          'body': ?body,
          'file': ?file,
          if (delay > Duration.zero) 'delay': delay.inMilliseconds,
        },
      };
}

/// `*` matches any run of characters (`/` included); everything else is literal.
bool globMatch(String pattern, String text) =>
    RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$').hasMatch(text);

/// Whether [host] is one of [patterns] (`*.example.com` matches subdomains).
bool mockHostMatches(String host, List<String> patterns) {
  final h = host.toLowerCase();
  return patterns.any((p) => p == h || (p.startsWith('*.') && h.endsWith(p.substring(1))));
}

/// The `mocks:` section of emu.yaml.
class MockConfig {
  MockConfig({
    this.hosts = const [],
    this.upstream,
    this.define,
    this.port,
    this.dir = 'mocks',
    this.scenarios = const {},
    this.sources = const {},
    this.problems = const [],
  });

  /// Hook mode: hosts the app's emu_hook routes here.
  final List<String> hosts;

  /// Base-URL mode: where requests made straight to this server were meant
  /// to go (`https://api.example.com`, optionally with a base path).
  final Uri? upstream;

  /// Base-URL mode: the dart-define `emu up` sets to this server's URL.
  final String? define;
  final int? port;

  /// Project-relative folder of scenario files (`<name>.json`, a list of
  /// rules) — what the dashboard edits. emu.yaml's own scenarios are read-only there.
  final String dir;
  final Map<String, List<MockRule>> scenarios;

  /// Scenario → where it's defined: `emu.yaml`, or its file (`mocks/x.json`).
  final Map<String, String> sources;
  final List<String> problems;

  /// Whether `emu up` should start the mock server.
  bool get enabled => hosts.isNotEmpty || upstream != null;

  /// Whether `emu up` should turn the app's emu_hook on.
  bool get hook => hosts.isNotEmpty;

  /// The mock server's port: `mocks.port`, else 13 above the emu server's.
  int portFor(int serverPort) => port ?? serverPort + 13;

  Map<String, dynamic> toJson() => {
        'hosts': hosts,
        if (upstream != null) 'upstream': '$upstream',
        'define': ?define,
        'dir': dir,
        'scenarios': {
          for (final e in scenarios.entries) e.key: [for (final r in e.value) r.toJson()],
        },
        'sources': sources,
        'problems': problems,
      };
}

MockConfig parseMocks(Object? raw) {
  if (raw == null) return MockConfig();
  final problems = <String>[];
  if (raw is! Map) return MockConfig(problems: ['mocks: expected a map with hosts and scenarios']);
  final hosts = <String>[];
  final rawHosts = raw['hosts'];
  for (final h in rawHosts is List ? rawHosts : (rawHosts == null ? const [] : [rawHosts])) {
    final host = '$h'.trim().toLowerCase();
    if (host.isEmpty || host.contains('/') || host.contains(':')) {
      problems.add('mocks.hosts: "$h" should be a host name like api.example.com or *.example.com');
    } else {
      hosts.add(host);
    }
  }
  Uri? upstream;
  final rawUpstream = raw['upstream'];
  if (rawUpstream != null) {
    final u = Uri.tryParse('$rawUpstream');
    if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty || u.hasQuery) {
      problems.add('mocks.upstream: expected the real API base URL, like https://api.example.com');
    } else {
      upstream = u;
    }
  }
  final define = raw['define'];
  if (define != null && (define is! String || !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(define))) {
    problems.add('mocks.define: expected a dart-define name like API_BASE_URL');
  } else if (define != null && rawUpstream == null) {
    problems.add('mocks.define: also give mocks.upstream — where requests to the mock server go');
  }
  if (hosts.isEmpty && rawUpstream == null) {
    problems.add('mocks: list hosts (for emu_hook) or give upstream + define (for a dart-define base URL)');
  }
  final port = raw['port'];
  if (port != null && (port is! int || port <= 0 || port > 65534)) problems.add('mocks.port: expected a port number');
  var dir = 'mocks';
  final rawDir = raw['dir'];
  if (rawDir != null) {
    if (rawDir is! String || rawDir.isEmpty || p.isAbsolute(rawDir) || p.split(rawDir).contains('..')) {
      problems.add('mocks.dir: expected a project-relative folder');
    } else {
      dir = p.normalize(rawDir);
    }
  }

  final scenarios = <String, List<MockRule>>{};
  final rawScenarios = raw['scenarios'];
  if (rawScenarios != null && rawScenarios is! Map) problems.add('mocks.scenarios: expected a map of name → rules');
  if (rawScenarios is Map) {
    for (final e in rawScenarios.entries) {
      final name = '${e.key}';
      final at = 'mocks.scenarios.$name';
      if (!_scenarioName.hasMatch(name)) {
        problems.add('$at: names are letters, digits, - and _');
        continue;
      }
      final rules = <MockRule>[];
      final list = e.value;
      if (list is! List) {
        problems.add('$at: expected a list of rules');
        continue;
      }
      for (var i = 0; i < list.length; i++) {
        final rule = _parseRule(list[i], '$at[$i]', problems);
        if (rule != null) rules.add(rule);
      }
      scenarios[name] = rules;
    }
  }
  return MockConfig(
    hosts: hosts,
    upstream: upstream,
    define: define is String && upstream != null ? define : null,
    port: port is int ? port : null,
    dir: dir,
    scenarios: scenarios,
    sources: {for (final name in scenarios.keys) name: 'emu.yaml'},
    problems: problems,
  );
}

final _scenarioName = RegExp(r'^[A-Za-z0-9_-]+$');

/// [config] plus the scenario files in its `dir` under [projectRoot].
MockConfig withScenarioFiles(MockConfig config, String projectRoot) {
  final folder = Directory(p.join(projectRoot, config.dir));
  if (!folder.existsSync()) return config;
  final scenarios = {...config.scenarios};
  final sources = {...config.sources};
  final problems = [...config.problems];
  final files = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final name = p.basenameWithoutExtension(file.path);
    final rel = p.join(config.dir, p.basename(file.path));
    if (!_scenarioName.hasMatch(name)) continue; // a response body file, not a scenario
    final Object? raw;
    try {
      raw = jsonDecode(file.readAsStringSync());
    } catch (e) {
      problems.add('$rel: not valid JSON ($e)');
      continue;
    }
    if (raw is! List) continue; // e.g. a body file mocks/me.json — scenarios are lists of rules
    if (scenarios.containsKey(name)) {
      problems.add('$rel: scenario "$name" is also in ${sources[name]} — the file wins');
    }
    final rules = <MockRule>[];
    for (var i = 0; i < raw.length; i++) {
      final rule = _parseRule(raw[i], '$rel[$i]', problems);
      if (rule != null) rules.add(rule);
    }
    scenarios[name] = rules;
    sources[name] = rel;
  }
  return MockConfig(
    hosts: config.hosts,
    upstream: config.upstream,
    define: config.define,
    port: config.port,
    dir: config.dir,
    scenarios: scenarios,
    sources: sources,
    problems: problems,
  );
}

/// Write scenario [name] to `<dir>/<name>.json`. Returns the problems with
/// [rules] (nothing is written then), or an empty list.
List<String> writeScenario(MockConfig config, String projectRoot, String name, Object? rules) {
  if (!_scenarioName.hasMatch(name)) return ['scenario names are letters, digits, - and _'];
  if (config.sources[name] == 'emu.yaml') return ['"$name" is defined in emu.yaml — edit it there'];
  if (rules is! List) return ['expected a list of rules'];
  final problems = <String>[];
  for (var i = 0; i < rules.length; i++) {
    _parseRule(rules[i], '$name[$i]', problems);
  }
  if (problems.isNotEmpty) return problems;
  final file = File(p.join(projectRoot, config.dir, '$name.json'))..parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(rules)}\n');
  return const [];
}

/// Remove scenario [name]'s file. False when it isn't a file scenario.
bool deleteScenario(MockConfig config, String projectRoot, String name) {
  final source = config.sources[name];
  if (source == null || source == 'emu.yaml') return false;
  final file = File(p.join(projectRoot, source));
  if (file.existsSync()) file.deleteSync();
  return true;
}

/// One rule from its JSON (`{match, respond}`), or null with [problems] said.
MockRule? parseMockRule(Object? raw, List<String> problems, {String at = 'rule'}) => _parseRule(raw, at, problems);

/// [rules] with [rule] in place of any rule of the same [MockRule.key],
/// or added at the end.
List<Map<String, dynamic>> upsertRule(List<MockRule> rules, MockRule rule) {
  final out = [for (final r in rules) r.toJson()];
  final i = rules.indexWhere((r) => r.key == rule.key);
  if (i >= 0) {
    out[i] = rule.toJson();
  } else {
    out.add(rule.toJson());
  }
  return out;
}

MockRule? _parseRule(Object? raw, String at, List<String> problems) {
  if (raw is! Map || raw['match'] is! Map || raw['respond'] is! Map) {
    problems.add('$at: expected { match: {method?, path | url}, respond: {status?, body | file, headers?, delay?} }');
    return null;
  }
  final match = raw['match'] as Map, respond = raw['respond'] as Map;
  final path = match['path'], url = match['url'], method = match['method'];
  if (path == null && url == null) {
    problems.add('$at.match: give a path (glob like /v1/items*) or a url');
    return null;
  }
  if (path != null && (path is! String || !path.startsWith('/'))) {
    problems.add('$at.match.path: expected a glob starting with /');
    return null;
  }
  final status = respond['status'] ?? 200;
  if (status is! int || status < 100 || status > 599) {
    problems.add('$at.respond.status: expected an HTTP status');
    return null;
  }
  final file = respond['file'];
  if (file != null && (file is! String || p.isAbsolute(file) || p.split(file).contains('..'))) {
    problems.add('$at.respond.file: expected a project-relative path');
    return null;
  }
  if (file != null && respond['body'] != null) {
    problems.add('$at.respond: give body or file, not both');
    return null;
  }
  final delay = respond['delay'] ?? 0;
  if (delay is! int || delay < 0) {
    problems.add('$at.respond.delay: expected milliseconds');
    return null;
  }
  final headers = respond['headers'];
  return MockRule(
    method: method == null ? null : '$method',
    path: path as String?,
    url: url == null ? null : '$url',
    status: status,
    headers: headers is Map ? {for (final h in headers.entries) '${h.key}': '${h.value}'} : const {},
    body: respond['body'],
    file: file as String?,
    delay: Duration(milliseconds: delay),
  );
}

/// One request the mock server saw.
class MockHit {
  MockHit({required this.id, required this.at, required this.method, required this.url});

  final int id;
  final DateTime at;
  final String method;
  final String url;
  int status = 0;

  /// The scenario that answered it, or null when the real server did.
  String? scenario;
  String? error;
  Duration elapsed = Duration.zero;

  /// Bodies as text (the first [MockServer.bodyLimit] bytes), for the
  /// dashboard's traffic view and "mock this response".
  String? requestBody;
  String? responseType;
  String? responseBody;

  Map<String, dynamic> toJson({bool bodies = false}) => {
        'id': id,
        'at': at.toIso8601String(),
        'method': method,
        'url': url,
        'status': status,
        'mocked': ?scenario,
        'error': ?error,
        'ms': elapsed.inMilliseconds,
        'responseType': ?responseType,
        if (bodies) ...{'requestBody': ?requestBody, 'responseBody': ?responseBody},
      };

  String get line => '$method $url → ${error ?? status}'
      '${scenario != null ? ' (mock: $scenario)' : ''} · ${elapsed.inMilliseconds}ms';
}

/// Answers the app's routed requests; see the library docs.
class MockServer {
  MockServer({required this.projectRoot, this.profile, this.home, required this.log});

  final String projectRoot;
  final String? profile;
  final String? home;

  /// A finished request, for the session log.
  final void Function(MockHit hit) log;

  HttpServer? _https, _http;
  final _upstream = HttpClient()..autoUncompress = false;

  /// The active scenario, or null: everything goes to the real server.
  String? active;

  /// `emu mock set` rules: in memory only, checked before the active
  /// scenario (so they work with it off), gone with the session.
  final List<MockRule> overrides = [];

  /// What [MockHit.scenario] says for a request an override answered.
  static const overrideLabel = 'cli';

  /// Add [rule], replacing an override with the same key.
  void setOverride(MockRule rule) {
    final i = overrides.indexWhere((r) => r.key == rule.key);
    if (i >= 0) {
      overrides[i] = rule;
    } else {
      overrides.add(rule);
    }
  }

  /// Remove the override for [key] (`GET /v1/items`, `* /v1/x`); false when none.
  bool unsetOverride(String key) {
    final before = overrides.length;
    overrides.removeWhere((r) => r.key == key);
    return overrides.length < before;
  }

  /// The last [_keep] requests, newest last.
  final List<MockHit> recent = [];
  static const _keep = 200;

  int? get port => _https?.port;

  MockConfig load() {
    final config = loadProjectConfig(projectRoot, home: home, profile: profile);
    return withScenarioFiles(parseMocks(config.mocks), projectRoot);
  }

  /// How much of each body a [MockHit] keeps.
  static const bodyLimit = 64 * 1024;
  var _seq = 0;

  MockHit? hit(int id) => recent.where((h) => h.id == id).firstOrNull;

  /// Listen on [port] (https origins) and port + 1 (http origins).
  Future<void> start(int port) async {
    _https = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    try {
      _http = await HttpServer.bind(InternetAddress.loopbackIPv4, port + 1);
    } catch (_) {
      await _https!.close(force: true);
      _https = null;
      rethrow;
    }
    _https!.listen((r) => _serve(r, 'https'));
    _http!.listen((r) => _serve(r, 'http'));
  }

  Future<void> close() async {
    await _https?.close(force: true);
    await _http?.close(force: true);
    _upstream.close(force: true);
  }

  Future<void> _serve(HttpRequest req, String scheme) async {
    final clock = Stopwatch()..start();
    final host = req.headers.value(HttpHeaders.hostHeader) ?? '';
    final config = load();
    var origin = Uri.parse('$scheme://$host${req.uri}');
    // Addressed to this server itself: the app took it as its base URL.
    final direct = _local.contains(origin.host) && (origin.port == port || origin.port == port! + 1);
    final upstream = config.upstream;
    if (direct && upstream != null) {
      final base = upstream.path.endsWith('/') ? upstream.path.substring(0, upstream.path.length - 1) : upstream.path;
      origin = upstream.replace(path: '$base${req.uri.path}', query: req.uri.hasQuery ? req.uri.query : null);
    }
    final hit = MockHit(id: ++_seq, at: DateTime.now(), method: req.method, url: '$origin');
    final res = req.response;
    try {
      if (direct ? upstream == null : !mockHostMatches(origin.host, config.hosts)) {
        // Only routed hosts should get here; anything else would make this
        // an open proxy to wherever a local process asks.
        hit
          ..status = 421
          ..error = direct
              ? 'a request to the mock server itself needs mocks.upstream (the real base URL)'
              : '${origin.host} is not in mocks.hosts';
        res.statusCode = 421;
        res.write(hit.error);
        await req.drain<void>();
      } else if (_ruleFor(config, req.method, origin) case (final scenario, final rule)?) {
        hit.requestBody = _text(await _collect(req), req.headers.value('content-encoding'));
        await _respond(res, rule, hit, head: req.method == 'HEAD');
        hit
          ..status = rule.status
          ..scenario = scenario;
      } else if (req.headers.value('upgrade') != null) {
        hit
          ..status = 501
          ..error = 'upgrade (WebSocket) is not passed through';
        res.statusCode = 501;
        await req.drain<void>();
      } else {
        hit.status = await _forward(req, origin, hit);
      }
    } catch (e) {
      hit.error = '$e';
      try {
        res.statusCode = 502;
        res.write('emu mock: $e');
      } catch (_) {/* headers already sent */}
    }
    await res.close().catchError((_) {});
    hit.elapsed = clock.elapsed;
    recent.add(hit);
    if (recent.length > _keep) recent.removeAt(0);
    log(hit);
  }

  (String, MockRule)? _ruleFor(MockConfig config, String method, Uri uri) {
    for (final rule in overrides) {
      if (rule.matches(method, uri)) return (overrideLabel, rule);
    }
    final name = active;
    if (name == null) return null;
    for (final rule in config.scenarios[name] ?? const <MockRule>[]) {
      if (rule.matches(method, uri)) return (name, rule);
    }
    return null;
  }

  Future<void> _respond(HttpResponse res, MockRule rule, MockHit hit, {bool head = false}) async {
    if (rule.delay > Duration.zero) await Future<void>.delayed(rule.delay);
    res.statusCode = rule.status;
    final body = rule.body;
    List<int> bytes;
    String? type;
    if (rule.file != null) {
      final file = File(p.join(projectRoot, rule.file));
      bytes = await file.readAsBytes();
      type = switch (p.extension(file.path)) {
        '.json' => 'application/json; charset=utf-8',
        '.html' => 'text/html; charset=utf-8',
        '.txt' => 'text/plain; charset=utf-8',
        _ => 'application/octet-stream',
      };
    } else if (body is String) {
      bytes = utf8.encode(body);
      type = 'text/plain; charset=utf-8';
    } else if (body != null) {
      bytes = utf8.encode(jsonEncode(body));
      type = 'application/json; charset=utf-8';
    } else {
      bytes = const [];
    }
    if (type != null) res.headers.set(HttpHeaders.contentTypeHeader, type);
    rule.headers.forEach(res.headers.set);
    res.contentLength = bytes.length;
    if (!head) res.add(bytes); // HEAD: the length, never the body
    hit
      ..responseType = res.headers.contentType?.mimeType
      ..responseBody = _text(bytes, null);
  }

  static Future<List<int>> _collect(Stream<List<int>> s) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in s) {
      if (out.length < bodyLimit) out.add(chunk);
    }
    return out.takeBytes();
  }

  /// [bytes] as text when they are (gunzipped first), else null.
  static String? _text(List<int> bytes, String? encoding) {
    if (bytes.isEmpty) return null;
    try {
      final raw = encoding == 'gzip' ? gzip.decode(bytes) : bytes;
      final text = utf8.decode(raw.length > bodyLimit ? raw.sublist(0, bodyLimit) : raw, allowMalformed: false);
      return text;
    } catch (_) {
      return null; // binary, or cut mid-character / mid-gzip
    }
  }

  /// How the app addresses this server: the host's loopback, or from the
  /// Android emulator, the host alias (with `adb reverse`, its loopback).
  static const _local = {'127.0.0.1', 'localhost', '10.0.2.2'};

  static const _hopByHop = {
    'connection', 'keep-alive', 'proxy-connection', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'content-length',
  };

  /// Send [req] on to [origin] and stream the answer back as it came.
  Future<int> _forward(HttpRequest req, Uri origin, MockHit hit) async {
    final up = await _upstream.openUrl(req.method, origin);
    up.followRedirects = false; // the app follows them itself (and routes them again)
    req.headers.forEach((name, values) {
      if (_hopByHop.contains(name)) return;
      for (final v in values) {
        up.headers.add(name, v, preserveHeaderCase: true);
      }
    });
    if (req.contentLength >= 0) up.contentLength = req.contentLength;
    final sent = BytesBuilder(copy: false);
    await up.addStream(req.map((chunk) {
      if (sent.length < bodyLimit) sent.add(chunk);
      return chunk;
    }));
    hit.requestBody = _text(sent.takeBytes(), req.headers.value('content-encoding'));
    final answer = await up.close();
    final res = req.response..statusCode = answer.statusCode;
    answer.headers.forEach((name, values) {
      if (_hopByHop.contains(name)) return;
      for (final v in values) {
        res.headers.add(name, v, preserveHeaderCase: true);
      }
    });
    if (answer.contentLength >= 0) res.contentLength = answer.contentLength;
    final got = BytesBuilder(copy: false);
    await res.addStream(answer.map((chunk) {
      if (got.length < bodyLimit) got.add(chunk);
      return chunk;
    }));
    hit
      ..responseType = answer.headers.contentType?.mimeType
      ..responseBody = _text(got.takeBytes(), answer.headers.value('content-encoding'));
    return answer.statusCode;
  }
}
