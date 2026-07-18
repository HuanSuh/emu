/// The local server: the single owner of the [FlutterEngine]. It exposes a
/// REST + WebSocket API consumed by both the CLI and the web dashboard, and
/// serves the dashboard's static assets.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_manager.dart';
import 'engine.dart';
import 'frame.dart';
import 'input.dart';
import 'log_store.dart';
import 'models.dart';
import 'probe.dart';
import 'session.dart';
import 'web_assets.g.dart';

/// Options for launching the app, passed from `up`.
class LaunchOptions {
  LaunchOptions({
    this.platform,
    this.deviceId,
    this.flavor,
    this.target,
    this.dartDefines = const [],
    this.extra = const [],
  });

  /// `android`, `ios`, or null (let flutter choose / use deviceId).
  final String? platform;
  final String? deviceId;
  final String? flavor;
  final String? target;
  final List<String> dartDefines;
  final List<String> extra;
}

class EmuServer {
  EmuServer({required this.session});

  final Session session;

  late final LogStore logStore;
  late final FlutterEngine engine;
  final DeviceManager devices = DeviceManager();

  HttpServer? _http;
  final Set<WebSocketChannel> _sockets = {};

  int get port => _http!.port;

  Future<void> start(int requestedPort, LaunchOptions opts) async {
    session.ensureState();
    logStore = LogStore(persistFile: session.logFile..writeAsStringSync(''));
    engine = FlutterEngine(projectRoot: session.projectRoot.path, logStore: logStore);

    // Fan out engine activity to connected dashboards.
    logStore.stream.listen((e) => _broadcast({'type': 'log', 'entry': e.toJson()}));
    engine.statusStream.listen((s) => _broadcast({'type': 'status', 'status': s.toJson()}));

    _http = await _bind(requestedPort);
    session.writeServerInfo(port: _http!.port, pid: pid);
    shelf_io.serveRequests(_http!, _handler());
    logStore.system('emu server listening on http://127.0.0.1:${_http!.port}');

    // Resolve a device and launch.
    await _launch(opts);
  }

  Future<void> _launch(LaunchOptions opts) async {
    String? deviceId = opts.deviceId;
    String? deviceName;
    try {
      if (deviceId == null && opts.platform == 'android') {
        deviceId = await devices.bootAndroid(onProgress: logStore.system);
      } else if (deviceId == null && opts.platform == 'ios') {
        deviceId = await devices.bootIos(onProgress: logStore.system);
      } else if (deviceId != null && platformForDeviceId(deviceId) == 'ios') {
        // An explicit iOS simulator udid isn't visible to `flutter run` until
        // the simulator is booted. `bootIos` is idempotent (a booted device is
        // a no-op), so ensure it here — otherwise `-d <udid>` fails with
        // "No supported devices found" when the sim happens to be shut down.
        deviceId = await devices.bootIos(udid: deviceId, onProgress: logStore.system);
      }
      final args = FlutterEngine.buildRunArgs(
        deviceId: deviceId,
        flavor: opts.flavor,
        target: opts.target,
        dartDefines: opts.dartDefines,
        extra: opts.extra,
      );
      await engine.start(args, deviceName: deviceName ?? deviceId);
    } on DeviceException catch (e) {
      logStore.add('device error: ${e.message}', level: LogLevel.error, source: 'system');
    } catch (e) {
      logStore.add('launch error: $e', level: LogLevel.error, source: 'system');
    }
  }

  Future<HttpServer> _bind(int requestedPort) async {
    // Try the requested port, then a small range, then an ephemeral port.
    for (final p in [requestedPort, requestedPort + 1, requestedPort + 2, 0]) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, p);
      } on SocketException {
        continue;
      }
    }
    throw StateError('could not bind a local port for the emu server');
  }

  Handler _handler() {
    return const Pipeline().addMiddleware(_cors()).addHandler(_route);
  }

  Middleware _cors() => (Handler inner) => (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final res = await inner(req);
        return res.change(headers: _corsHeaders);
      };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  Future<Response> _route(Request req) async {
    final path = '/${req.url.path}';

    // WebSocket stream.
    if (path == '/api/stream') {
      final ws = webSocketHandler(_onSocket);
      return await ws(req);
    }

    // REST API.
    if (path.startsWith('/api/')) {
      return _api(req, path);
    }

    // Static dashboard.
    return _static(path);
  }

  Future<Response> _api(Request req, String path) async {
    switch (path) {
      case '/api/status':
        return _json({
          'status': engine.status.toJson(),
          'serverPort': port,
          'lastSeq': logStore.lastSeq,
        });
      case '/api/reload':
        return _json((await engine.hotReload()).toJson());
      case '/api/restart':
        return _json((await engine.hotRestart()).toJson());
      case '/api/cold':
        return _json((await engine.coldRestart()).toJson());
      case '/api/stop':
        await engine.stop();
        return _json({'ok': true, 'message': 'stopped'});
      case '/api/devices':
        try {
          final list = await devices.listDevices();
          return _json({'devices': list.map((d) => d.toJson()).toList()});
        } catch (e) {
          return _json({'error': '$e'}, status: 500);
        }
      case '/api/logs':
        final q = req.url.queryParameters;
        final entries = logStore.query(
          grep: q['grep'],
          level: q['level'] != null ? LogLevel.fromName(q['level']) : null,
          sinceSeq: int.tryParse(q['sinceSeq'] ?? ''),
          limit: int.tryParse(q['limit'] ?? '') ?? 1000,
        );
        return _json({'logs': entries.map((e) => e.toJson()).toList(), 'lastSeq': logStore.lastSeq});
      case '/api/logs/clear':
        logStore.clear();
        return _json({'ok': true});
      case '/api/screenshot':
        return _screenshot(req);
      case '/api/tap':
        return _tap(req);
      case '/api/swipe':
        return _swipe(req);
      case '/api/text':
        return _text(req);
      case '/api/first-frame':
        return _firstFrame(req);
      case '/api/probe':
        return _probe(req);
      case '/api/shutdown':
        // Graceful server shutdown (used by `emu down`).
        scheduleMicrotask(() async {
          await dispose();
          exit(0);
        });
        return _json({'ok': true, 'message': 'shutting down'});
      default:
        return _json({'error': 'not found'}, status: 404);
    }
  }

  String get _platform => platformForDeviceId(engine.status.deviceId);

  Future<Response> _screenshot(Request req) async {
    // Inline mode (dashboard): return the PNG bytes directly instead of saving a
    // timestamped file, reusing one temp path so refreshes don't clutter .emu/.
    if (req.url.queryParameters['inline'] == '1') {
      final tmp = '${session.stateDir.path}/_dashboard-shot.png';
      try {
        await devices.screenshot(tmp, platform: _platform, udid: engine.status.deviceId);
        final bytes = await File(tmp).readAsBytes();
        return Response.ok(bytes, headers: {
          'content-type': 'image/png',
          'cache-control': 'no-store',
        });
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 500);
      }
    }
    // An explicit `path` wins; otherwise timestamp into .emu/.
    final requested = req.url.queryParameters['path'];
    final String out;
    if (requested != null && requested.isNotEmpty) {
      // Relative paths resolve against the project root, not the server's cwd.
      final f = File(requested);
      out = f.isAbsolute ? requested : '${session.projectRoot.path}/$requested';
      await File(out).parent.create(recursive: true);
    } else {
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      out = '${session.stateDir.path}/shot-$ts.png';
    }
    try {
      await devices.screenshot(out, platform: _platform, udid: engine.status.deviceId);
      return _json({'ok': true, 'path': out});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  /// The running app's VM Service URI, or null with a 409 response — input goes
  /// through the framework, so it needs a live VM Service (as `probe` does).
  String? _vmOr409(void Function(Response) sink) {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      sink(_json({'ok': false, 'error': 'app is not running (no VM service)'}, status: 409));
    }
    return uri;
  }

  Future<Response> _tap(Request req) async {
    final q = req.url.queryParameters;
    final x = int.tryParse(q['x'] ?? '');
    final y = int.tryParse(q['y'] ?? '');
    if (x == null || y == null) {
      return _json({'ok': false, 'error': 'x and y are required integers'}, status: 400);
    }
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    return _inject(() => runTap(uri, x, y), {'x': x, 'y': y});
  }

  Future<Response> _swipe(Request req) async {
    final q = req.url.queryParameters;
    final c = ['x1', 'y1', 'x2', 'y2'].map((k) => int.tryParse(q[k] ?? '')).toList();
    if (c.any((v) => v == null)) {
      return _json({'ok': false, 'error': 'x1, y1, x2, y2 are required integers'}, status: 400);
    }
    final ms = int.tryParse(q['durationMs'] ?? '') ?? 300;
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    return _inject(
      () => runSwipe(uri, c[0]!, c[1]!, c[2]!, c[3]!, durationMs: ms),
      {'x1': c[0], 'y1': c[1], 'x2': c[2], 'y2': c[3], 'durationMs': ms},
    );
  }

  Future<Response> _text(Request req) async {
    final text = req.url.queryParameters['text'];
    if (text == null || text.isEmpty) {
      return _json({'ok': false, 'error': 'text is required'}, status: 400);
    }
    final append = req.url.queryParameters['append'] == 'true';
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    return _inject(
      () => runText(uri, text, append: append),
      {'text': text, 'append': append},
    );
  }

  /// Whether the app has painted yet — `running` alone doesn't mean tappable.
  Future<Response> _firstFrame(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'ok': false, 'error': 'app is not running (no VM service)'}, status: 409);
    }
    final ms = int.tryParse(req.url.queryParameters['timeoutMs'] ?? '') ?? 20000;
    final painted = await waitForFirstFrame(uri, timeout: Duration(milliseconds: ms));
    return _json({'ok': true, 'firstFrame': painted});
  }

  /// Run an input injection, reporting the log cursor from *before* it fired.
  /// `assert --since <seq>` then sees exactly what the input caused — without
  /// this, the natural `tap` then `assert` order races, because assert's
  /// default window only opens once the effect has already been logged.
  Future<Response> _inject(
      Future<void> Function() action, Map<String, dynamic> detail) async {
    final seq = logStore.lastSeq;
    try {
      await action();
      return _json({'ok': true, ...detail, 'seq': seq});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  Future<Response> _probe(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'error': 'app is not running (no VM service)'}, status: 409);
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'invalid request body'}, status: 400);
    }
    final file = body['file'] as String?;
    final line = (body['line'] as num?)?.toInt();
    if (file == null || line == null) {
      return _json({'error': 'file and line required'}, status: 400);
    }
    final capture = (body['capture'] as List?)?.cast<String>() ?? const [];
    final count = (body['count'] as num?)?.toInt() ?? 1;
    final timeoutMs = (body['timeoutMs'] as num?)?.toInt() ?? 10000;
    final pubspec = File('${session.projectRoot.path}/pubspec.yaml');
    try {
      final hits = await runProbe(
        wsUri: uri,
        pubspecContent: pubspec.existsSync() ? pubspec.readAsStringSync() : '',
        file: file,
        line: line,
        capture: capture,
        count: count,
        timeout: Duration(milliseconds: timeoutMs),
        onHit: (h) => logStore.add(
          '[probe $file:$line] ${h.values.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
          level: LogLevel.system,
          source: 'probe',
        ),
      );
      return _json({'hits': hits.map((h) => h.toJson()).toList()});
    } on ProbeException catch (e) {
      return _json({'error': e.message}, status: 422);
    } catch (e) {
      return _json({'error': '$e'}, status: 500);
    }
  }

  void _onSocket(WebSocketChannel socket, _) {
    _sockets.add(socket);
    // Prime the new client with current status and recent logs.
    socket.sink.add(jsonEncode({'type': 'status', 'status': engine.status.toJson()}));
    for (final e in logStore.query(limit: 500)) {
      socket.sink.add(jsonEncode({'type': 'log', 'entry': e.toJson()}));
    }
    socket.stream.listen(
      (_) {},
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
    );
  }

  void _broadcast(Map<String, dynamic> msg) {
    if (_sockets.isEmpty) return;
    final data = jsonEncode(msg);
    for (final s in _sockets.toList()) {
      try {
        s.sink.add(data);
      } catch (_) {
        _sockets.remove(s);
      }
    }
  }

  Response _static(String path) {
    var rel = path == '/' ? 'index.html' : path.substring(1);
    final bytes = _readWebAsset(rel);
    if (bytes == null) return Response.notFound('not found: $rel');
    return Response.ok(bytes, headers: {'Content-Type': _contentType(rel)});
  }

  Response _json(Object data, {int status = 200}) =>
      Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});

  Future<void> dispose() async {
    session.clearServerInfo();
    for (final s in _sockets) {
      await s.sink.close();
    }
    await engine.dispose();
    await logStore.close();
    await _http?.close(force: true);
  }
}

/// Read a dashboard asset: dev disk first (EMU_WEB_DIR or the tool's web/),
/// then the embedded base64 map.
List<int>? _readWebAsset(String rel) {
  final devDir = Platform.environment['EMU_WEB_DIR'];
  if (devDir != null) {
    final f = File('$devDir/$rel');
    if (f.existsSync()) return f.readAsBytesSync();
  }
  final toolWeb = _toolWebDir();
  if (toolWeb != null) {
    final f = File('$toolWeb/$rel');
    if (f.existsSync()) return f.readAsBytesSync();
  }
  final b64 = kEmbeddedWebAssets[rel];
  if (b64 != null) return base64Decode(b64);
  return null;
}

/// Best-effort resolution of the emu tool's own web/ directory in dev.
String? _toolWebDir() {
  try {
    final script = Platform.script.toFilePath();
    if (script.endsWith('.dart')) {
      // .../emu/bin/emu.dart -> .../emu/web
      final binDir = File(script).parent;
      final web = Directory('${binDir.parent.path}/web');
      if (web.existsSync()) return web.path;
    }
  } catch (_) {}
  return null;
}

String _contentType(String path) {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.png')) return 'image/png';
  return 'application/octet-stream';
}
