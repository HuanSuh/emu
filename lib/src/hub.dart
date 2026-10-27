/// The session hub (`emu hub`, see `docs/HUB.md`): one page that lists every
/// running emu session (from `registry.dart`) in a drawer and shows the one
/// picked — its own dashboard, in a frame. Sessions keep their own servers;
/// the hub only lists them and forwards a few actions.
///
/// - `~/.emu/hub.json` — `{port, pid, token, version}` of the running hub.
///   Session servers read it to let the hub frame their dashboard
///   ([hubFrameAncestors]); `emu hub` reads it to reuse a running hub.
/// - Same guard as a session server (`api_guard.dart`): loopback Host, own
///   Origin, a token injected into the page. Session tokens never reach the
///   hub page: actions on a session are made here, server side, with the
///   token from that project's `.emu/server.json` — as the CLI does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_guard.dart';
import 'app_install.dart' show installedAppRev;
import 'changelog_html.dart';
import 'device_lease.dart';
import 'device_manager.dart';
import 'registry.dart';
import 'report.dart';
import 'report_api.dart';
import 'self_update.dart';
import 'server.dart' show readWebAsset, contentTypeFor;
import 'session.dart';
import 'version.dart';

/// The hub's preferred port; the next free one when taken.
const hubDefaultPort = 4576;

File hubInfoFile() => File('${Platform.environment['HOME'] ?? '.'}/.emu/hub.json');

class HubInfo {
  HubInfo({required this.port, required this.pid, this.token, this.version});
  final int port;
  final int pid;
  final String? token;
  final String? version;

  String get url => 'http://127.0.0.1:$port';

  static HubInfo? read([File? file]) {
    try {
      final m = jsonDecode((file ?? hubInfoFile()).readAsStringSync()) as Map<String, dynamic>;
      return HubInfo(
        port: m['port'] as int,
        pid: m['pid'] as int,
        token: m['token'] as String?,
        version: m['version'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The recorded hub, if its process still exists. Cheap (no HTTP), for the
/// session servers' `frame-ancestors` on every dashboard load.
HubInfo? recordedHub({File? file}) {
  final info = HubInfo.read(file);
  if (info == null) return null;
  try {
    return Process.runSync('kill', ['-0', '${info.pid}']).exitCode == 0 ? info : null;
  } catch (_) {
    return null;
  }
}

/// The running hub: recorded, alive, and answering as a hub.
Future<HubInfo?> runningHub({File? file, Duration timeout = const Duration(seconds: 1)}) async {
  final info = recordedHub(file: file);
  if (info == null) return null;
  try {
    final r = await http.get(Uri.parse('${info.url}/api/status')).timeout(timeout);
    return r.statusCode == 200 && (jsonDecode(r.body) as Map)['hub'] == true ? info : null;
  } catch (_) {
    return null;
  }
}

/// `frame-ancestors` for a session dashboard: only the running hub's origin
/// may frame it, nothing when no hub is up. Checks the hub answers as a hub
/// (not just that its pid exists — a recycled pid must not open framing to
/// whatever now listens on that port); bounded, it runs on every page load.
Future<String> hubFrameAncestors({File? file, Duration timeout = const Duration(milliseconds: 400)}) async {
  final h = await runningHub(file: file, timeout: timeout);
  return frameAncestorsFor(h);
}

String frameAncestorsFor(HubInfo? hub) =>
    hub == null ? "'none'" : 'http://127.0.0.1:${hub.port} http://localhost:${hub.port}';

/// Changelog sections newer than [from], up to and including [to].
String changelogBetween(String changelog, String from, String to) {
  final out = StringBuffer();
  var on = false;
  for (final line in const LineSplitter().convert(changelog)) {
    final m = RegExp(r'^## \[(\d+\.\d+\.\d+)\]').firstMatch(line);
    if (m != null) {
      final v = m.group(1)!;
      on = compareSemver(v, from) > 0 && compareSemver(v, to) <= 0;
    } else if (line.startsWith('## ') || RegExp(r'^\[[^\]]+\]: ').hasMatch(line)) {
      on = false;
    }
    if (on) out.writeln(line);
  }
  return out.toString().trim();
}

/// What the hub runs for a session action — a seam for tests.
typedef HubRunner = Future<ProcessResult> Function(List<String> args, {String? workingDirectory});

/// Replaces this hub with one running [exe] (after an update). Returns only
/// when that failed — this hub then serves again. A seam for tests.
typedef HubRestart = Future<void> Function(String exe);

class HubServer {
  HubServer({
    SessionRegistry? registry,
    RecentProjects? recent,
    File? infoFile,
    HubRunner? run,
    Future<String?> Function()? latestVersion,
    Future<String?> Function()? fetchChangelog,
    SelfUpdater Function()? updater,
    HubRestart? restart,
    void Function(int code)? exitProcess,
    this.pollInterval = const Duration(seconds: 3),
  })  : registry = registry ?? SessionRegistry(),
        recent = recent ?? RecentProjects(),
        infoFile = infoFile ?? hubInfoFile(),
        _run = run ?? _runSelf,
        _latestVersion = latestVersion ?? latestReleaseVersion,
        _fetchChangelog = fetchChangelog ?? _githubChangelog {
    _updater = updater ?? () => SelfUpdater(latestVersion: _latestVersion);
    _restart = restart ?? _restartInto;
    _exit = exitProcess ?? exit;
  }

  final SessionRegistry registry;
  final RecentProjects recent;
  final File infoFile;
  final HubRunner _run;
  final Future<String?> Function() _latestVersion;
  final Future<String?> Function() _fetchChangelog;
  final Duration pollInterval;
  late final SelfUpdater Function() _updater;
  late final HubRestart _restart;
  late final void Function(int) _exit;

  final String token = newSessionToken();
  HttpServer? _http;
  int get port => _http!.port;

  final Set<WebSocketChannel> _sockets = {};
  Timer? _poll;
  String _lastSnapshot = '';

  /// Projects being started from the hub (`emu up` still running).
  final Map<String, DateTime> _starting = {};

  ({String? latest, DateTime at})? _latest;

  /// The update the Update button started: `state` running → restarting
  /// (then this process is replaced) or failed / done, with its step lines.
  Map<String, dynamic>? _update;

  Future<void> start({int port = hubDefaultPort}) async {
    _serve(await _bind(port));
  }

  void _serve(HttpServer server) {
    _http = server;
    infoFile.parent.createSync(recursive: true);
    infoFile.writeAsStringSync(jsonEncode({
      'port': port,
      'pid': pid,
      'token': token,
      'version': kEmuVersion,
      'startedAt': DateTime.now().toIso8601String(),
    }));
    shelf_io.serveRequests(_http!, const Pipeline().addMiddleware(apiGuard(token)).addHandler(_route));
    // A failed poll (a registry file vanishing mid-read…) must not take the hub down.
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_push().catchError((_) {})));
  }

  static Future<HttpServer> _bind(int port) async {
    for (var p = port; p < port + 20; p++) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, p);
      } on SocketException {
        continue;
      }
    }
    return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }

  Future<void> close() async {
    _poll?.cancel();
    final info = HubInfo.read(infoFile);
    if (info?.pid == pid && _http != null && info?.port == port) {
      try {
        infoFile.deleteSync();
      } on FileSystemException {
        // Gone.
      }
    }
    for (final s in _sockets.toList()) {
      await s.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await _http?.close(force: true);
  }

  // ---- data ------------------------------------------------------------------

  /// Every live session with its app state, plus projects being started and
  /// recent ones not running.
  Future<Map<String, dynamic>> snapshot() async {
    final live = await registry.live();
    final states = await Future.wait(live.map(_appState));
    final running = {for (final e in live) e.project};
    _starting.removeWhere((p, at) => running.contains(p) || DateTime.now().difference(at) > const Duration(minutes: 10));
    return {
      'version': kEmuVersion,
      'sessions': [
        for (var i = 0; i < live.length; i++) {...live[i].toJson(), 'state': states[i] ?? 'unknown'},
      ],
      'starting': [..._starting.keys],
      'recent': [
        for (final p in recent.list())
          if (!running.contains(p['project'])) p,
      ],
    };
  }

  static Future<String?> _appState(SessionEntry e) async {
    try {
      final r = await http.get(Uri.parse('${e.dashboard}/api/status')).timeout(const Duration(seconds: 1));
      return (jsonDecode(r.body) as Map)['state'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _push({bool force = false}) async {
    if (_sockets.isEmpty) return;
    final snap = jsonEncode({'type': 'sessions', ...await snapshot()});
    if (!force && snap == _lastSnapshot) return;
    _lastSnapshot = snap;
    _broadcast(snap);
  }

  void _broadcast(String msg) {
    for (final s in _sockets.toList()) {
      s.sink.add(msg);
    }
  }

  Future<Map<String, dynamic>> _version({bool force = false}) async {
    final cached = _latest;
    if (force || cached == null || DateTime.now().difference(cached.at) > const Duration(hours: 1)) {
      _latest = (latest: await _latestVersion(), at: DateTime.now());
    }
    final latest = _latest!.latest;
    final newer = latest != null && kEmuVersion.contains('.') && !kEmuVersion.contains('-')
        ? compareSemver(latest, kEmuVersion) > 0
        : false;
    String? notes;
    if (newer) {
      final log = await _fetchChangelog();
      if (log != null) notes = changelogBetween(log, kEmuVersion, latest);
    }
    return {
      'running': kEmuVersion,
      'latest': latest,
      'updateAvailable': newer,
      'notes': ?notes,
      if (notes != null) 'notesHtml': renderChangelogHtml(notes),
      'install': _updater().kind.name,
      'update': ?_update,
      // The macOS app on disk — the app compares it with its own build.
      'appRev': ?installedAppRev(),
      'command': 'emu update',
    };
  }

  // ---- update ----------------------------------------------------------------

  /// The Update button. The page only asks; what runs is fixed here — the
  /// same steps as `emu update --yes` ([SelfUpdater]). Refusals (dirty
  /// checkout, no `claude` CLI, up to date, already updating) answer 409
  /// before anything changes; the steps then go out on the stream.
  Future<Response> _startUpdate() async {
    final busy = _update?['state'];
    if (busy == 'running' || busy == 'restarting') {
      return _json({'ok': false, 'error': 'an update is already running'}, status: 409);
    }
    // Claimed before the first await: a second click finds it taken.
    _update = {'state': 'running', 'log': <String>[]};
    final up = _updater();
    String latest;
    try {
      await up.preflight();
      final l = await up.latest();
      if (l == null) throw UpdateError('could not reach GitHub to check for updates.', refused: true);
      if (!isNewer(l, up.currentVersion)) throw UpdateError('already up to date (v${up.currentVersion}).', refused: true);
      latest = l;
    } on UpdateError catch (e) {
      _update = null;
      return _json({'ok': false, 'error': e.message}, status: 409);
    } catch (e) {
      _update = null; // never left "running" by a check that broke
      return _json({'ok': false, 'error': 'could not check for an update: $e'}, status: 500);
    }
    _update = {..._update!, 'to': latest, 'install': up.kind.name};
    _pushUpdate();
    unawaited(_runUpdate(up, latest));
    return _json({'ok': true, 'update': _update}, status: 202);
  }

  Future<void> _runUpdate(SelfUpdater up, String latest) async {
    final log = _update!['log'] as List<String>;
    try {
      final r = await up.apply(latest, log: (line) {
        log.add(line);
        _pushUpdate();
      });
      if (!r.updated || r.binary == null) {
        _update = {..._update!, 'state': 'done', 'result': r.toJson()};
        _pushUpdate();
        return;
      }
      _update = {..._update!, 'state': 'restarting', 'result': r.toJson()};
      _pushUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 300)); // let the message out
      await _restart(r.binary!);
      // Still here: the new hub did not come up, and this one serves again.
      _update = {
        ..._update!,
        'state': 'failed',
        'error': 'updated to v$latest, but the new hub did not start — run `emu hub --stop && emu hub`.',
      };
    } catch (e) {
      _update = {..._update!, 'state': 'failed', 'error': e is UpdateError ? e.message : '$e'};
    }
    _pushUpdate();
  }

  void _pushUpdate() => _broadcast(jsonEncode({'type': 'update', ...?_update}));

  /// Hand over to a hub running [exe], on this port: stop serving (the page
  /// sees the stream close and reconnects), start it, and exit once it
  /// answers. If it doesn't, serve again here.
  Future<void> _restartInto(String exe) async {
    final port = this.port;
    _poll?.cancel();
    for (final s in _sockets.toList()) {
      await s.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    _sockets.clear();
    await _http?.close(force: true);
    _http = null;
    try {
      await Process.start(exe, ['__hub', '--port', '$port'], mode: ProcessStartMode.detached);
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final next = HubInfo.read(infoFile);
        if (next != null && next.pid != pid && await runningHub(file: infoFile) != null) return _exit(0);
      }
    } catch (_) {
      // Could not start it: fall through and serve again.
    }
    _serve(await _bind(port));
  }

  // ---- routes ----------------------------------------------------------------

  Future<Response> _route(Request req) async {
    final path = '/${req.url.path}';
    if (path == '/api/stream') {
      return webSocketHandler((WebSocketChannel ws, _) {
        _sockets.add(ws);
        ws.stream.listen((_) {}, onDone: () => _sockets.remove(ws), onError: (_) => _sockets.remove(ws));
        unawaited(_push(force: true));
        if (_update != null) ws.sink.add(jsonEncode({'type': 'update', ..._update!}));
      })(req);
    }
    if (path.startsWith('/api/')) return _api(req, path);
    return _static(path);
  }

  /// `emu report` from the hub: no session, so the environment tail only.
  final _report = ReportApi(ReportSources(from: 'hub', scrubber: () => Scrubber.forProject(null)));

  Future<Response> _api(Request req, String path) async {
    final get = req.method == 'GET' || req.method == 'HEAD';
    if (path == '/api/status' && get) {
      return _json({'ok': true, 'hub': true, 'version': kEmuVersion});
    }
    if (path == '/api/sessions' && get) return _json(await snapshot());
    if (path == '/api/version' && get) {
      return _json(await _version(force: req.url.queryParameters['refresh'] == '1'));
    }
    if (path == '/api/devices' && get) return _json(await _devices());
    if (path == '/api/update' && get) return _json({'ok': true, 'update': _update});
    if (path == '/api/update' && req.method == 'POST') return _startUpdate();
    if (path == '/api/shutdown' && req.method == 'POST') {
      scheduleMicrotask(() async {
        try {
          await close();
        } finally {
          _exit(0);
        }
      });
      return _json({'ok': true});
    }
    final m = RegExp(r'^/api/sessions/([0-9a-f]{12})/(reload|restart|down|reveal)$').firstMatch(path);
    if (m != null && req.method == 'POST') return _sessionAction(m.group(1)!, m.group(2)!);
    if (path == '/api/projects/start' && req.method == 'POST') return _startProject(req);
    if (path == '/api/report' || path.startsWith('/api/report/')) return _report.handle(req, path);
    return _json({'ok': false, 'error': 'not found: ${req.method} $path'}, status: 404);
  }

  Future<Response> _sessionAction(String id, String action) async {
    final e = (await registry.live()).where((e) => e.id == id).firstOrNull;
    if (e == null) return _json({'ok': false, 'error': 'no running session $id'}, status: 404);
    switch (action) {
      case 'down':
        // The CLI's own `down`, so temp devices etc. are handled the same way.
        final r = await _run(['down', '--project', e.project]);
        unawaited(Future.delayed(const Duration(milliseconds: 600), () => _push(force: true)));
        return _json({'ok': r.exitCode == 0, 'output': '${r.stdout}${r.stderr}'.trim()},
            status: r.exitCode == 0 ? 200 : 500);
      case 'reveal':
        if (!Platform.isMacOS) return _json({'ok': false, 'error': 'only on macOS'}, status: 400);
        await Process.run('open', [e.project]);
        return _json({'ok': true});
      default:
        final info = Session(Directory(e.project)).readServerInfo();
        if (info == null) return _json({'ok': false, 'error': 'no .emu/server.json for ${e.project}'}, status: 409);
        try {
          final r = await http
              .post(Uri.parse('${info.baseUrl}/api/$action'), headers: info.headers)
              .timeout(const Duration(seconds: 60));
          return Response(r.statusCode, body: r.body, headers: {'Content-Type': 'application/json'});
        } catch (err) {
          return _json({'ok': false, 'error': '$err'}, status: 502);
        }
    }
  }

  /// Run `emu up` in a recent project. Only projects emu has started before
  /// (`~/.emu/projects.json`): the page can't make the hub run a build in an
  /// arbitrary directory.
  Future<Response> _startProject(Request req) async {
    String? project;
    try {
      project = (jsonDecode(await req.readAsString()) as Map)['project'] as String?;
    } catch (_) {}
    final known = recent.list().any((p) => p['project'] == project);
    if (project == null || !known || !File('$project/pubspec.yaml').existsSync()) {
      return _json({'ok': false, 'error': 'not a recent emu project: $project'}, status: 400);
    }
    if ((await registry.live()).any((e) => e.project == project)) {
      return _json({'ok': false, 'error': 'already running'}, status: 409);
    }
    if (_starting.containsKey(project)) return _json({'ok': false, 'error': 'already starting'}, status: 409);
    _starting[project] = DateTime.now();
    unawaited(_push(force: true));
    final p = project;
    unawaited(() async {
      ProcessResult r;
      try {
        r = await _run(['up', '--json'], workingDirectory: p);
      } catch (err) {
        r = ProcessResult(0, 1, '', '$err');
      }
      _starting.remove(p);
      Map<String, dynamic>? verdict;
      try {
        verdict = jsonDecode('${r.stdout}'.trim().split('\n').last) as Map<String, dynamic>;
      } catch (_) {}
      _broadcast(jsonEncode({
        'type': 'started',
        'project': p,
        'ok': r.exitCode == 0,
        'state': verdict?['state'],
        'output': '${r.stderr}'.trim().split('\n').reversed.take(15).toList().reversed.join('\n'),
      }));
      await _push(force: true);
    }());
    return _json({'ok': true, 'starting': project});
  }

  ({Map<String, dynamic> body, DateTime at})? _devicesCache;

  Future<Map<String, dynamic>> _devices() async {
    final c = _devicesCache;
    if (c != null && DateTime.now().difference(c.at) < const Duration(seconds: 10)) return c.body;
    final dm = DeviceManager();
    final list = await dm.listDevices();
    final leases = DeviceLeases();
    final live = await registry.live();
    final body = {
      'devices': [
        for (final d in list)
          {
            ...d.toJson(),
            'lease': (await leases.liveHolderOf(d.id))?.toJson(),
            'sessions': [
              for (final e in live)
                if (e.deviceId == d.id) e.id,
            ],
          },
      ],
      'androidAvds': await dm.listAndroidAvds(),
    };
    _devicesCache = (body: body, at: DateTime.now());
    return body;
  }

  Response _static(String path) {
    const files = {
      '/': 'hub/index.html',
      '/hub.js': 'hub/hub.js',
      '/hub.css': 'hub/hub.css',
      '/favicon.png': 'favicon.png',
      '/apple-touch-icon.png': 'apple-touch-icon.png',
      '/report.js': 'report.js',
      '/report.css': 'report.css',
    };
    final rel = files[path];
    final bytes = rel == null ? null : readWebAsset(rel);
    if (bytes == null) return Response.notFound('not found: $path');
    if (rel == 'hub/index.html') {
      return Response.ok(injectSessionToken(utf8.decode(bytes), token), headers: {
        'Content-Type': contentTypeFor(rel!),
        'Cache-Control': 'no-store',
        'Content-Security-Policy': "frame-ancestors 'none'",
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
      });
    }
    return Response.ok(bytes, headers: {'Content-Type': contentTypeFor(rel!), 'Cache-Control': 'no-cache'});
  }

  Response _json(Object data, {int status = 200}) =>
      Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});
}

Future<ProcessResult> _runSelf(List<String> args, {String? workingDirectory}) {
  final exe = Platform.resolvedExecutable;
  final prefix = exe.endsWith('dart') ? ['run', Platform.script.toFilePath()] : const <String>[];
  return Process.run(exe, [...prefix, ...args], workingDirectory: workingDirectory);
}

Future<String?> _githubChangelog() async {
  try {
    final r = await http
        .get(Uri.parse('https://raw.githubusercontent.com/HuanSuh/emu/main/CHANGELOG.md'))
        .timeout(const Duration(seconds: 5));
    return r.statusCode == 200 ? r.body : null;
  } catch (_) {
    return null;
  }
}
