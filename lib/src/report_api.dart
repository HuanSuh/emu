/// `emu report` for the dashboard and the hub (`report.dart`), under
/// `/api/report` — behind the same guard (`api_guard.dart`) as every route:
///
/// - `GET  /api/report`                       where it goes, how (gh / browser), what can be attached
/// - `POST /api/report/preview`               `{kind, title, body, attach: {logs: <lines>, errors, shot}}`
///                                            → the issue exactly as it will be sent, and its `digest`
/// - `GET  /api/report/session`               the device kind and app state the tail would show (for the CLI)
/// - `GET  /api/report/image/<digest>/<n>`    a previewed screenshot (`?token=` for `<img>`)
/// - `POST /api/report/send`                  `{digest}` → sends **that** preview, nothing rebuilt
/// - `GET  /api/report/mine`                  the issues this user sent with `emu report`
///
/// A preview is kept here by its digest, so what is sent is what was shown,
/// even if new logs arrived in between.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'models.dart';
import 'report.dart';

/// What a server can put in a report. Null callbacks: not available there
/// (the hub has no logs or screen of its own).
class ReportSources {
  ReportSources({required this.from, required this.scrubber, this.logs, this.screenshot, this.session});

  /// `dashboard` / `hub` — goes in the environment tail.
  final String from;
  final Scrubber Function() scrubber;
  final List<LogEntry> Function()? logs;

  /// Captures the screen to a file and returns its path.
  final Future<String> Function()? screenshot;

  /// The session's device kind and app state, for the tail.
  final Future<({String? device, String? appState})> Function()? session;
}

class ReportApi {
  ReportApi(this.sources, {GitHubReporter? reporter, this.environment = collectEnvironment})
    : reporter = reporter ?? GitHubReporter();

  final ReportSources sources;
  final GitHubReporter reporter;

  /// The tail's rows ([collectEnvironment]; replaced in tests).
  final Future<Map<String, String>> Function({String? device, String? appState, String? from}) environment;

  final _previews = <String, ({BuiltReport report, DateTime at})>{};
  static const _keep = Duration(minutes: 30);

  ({bool ready, DateTime at})? _gh;

  Future<bool> _ghReady() async {
    final cached = _gh;
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 1)) return cached.ready;
    final ready = await reporter.ghReady();
    _gh = (ready: ready, at: DateTime.now());
    return ready;
  }

  Future<Response> handle(Request req, String path) async {
    final get = req.method == 'GET' || req.method == 'HEAD';
    if (path == '/api/report' && get) {
      return _json({
        'ok': true,
        'repo': reportRepo,
        'via': await _ghReady() ? 'gh' : 'browser',
        'attach': {'logs': sources.logs != null, 'errors': sources.logs != null, 'shot': sources.screenshot != null},
        'mineUrl': myIssuesUrl,
      });
    }
    if (path == '/api/report/session' && get) {
      final session = await sources.session?.call();
      return _json({'ok': true, 'device': ?session?.device, 'appState': ?session?.appState});
    }
    if (path == '/api/report/preview' && req.method == 'POST') return _preview(req);
    if (path == '/api/report/send' && req.method == 'POST') return _send(req);
    if (path == '/api/report/mine' && get) {
      final issues = await _ghReady() ? await reporter.mine() : null;
      return _json({'ok': true, 'via': issues == null ? 'browser' : 'gh', 'issues': ?issues, 'url': myIssuesUrl});
    }
    final m = RegExp(r'^/api/report/image/([0-9a-f]{16})/(\d+)$').firstMatch(path);
    if (m != null && get) {
      final images = _previews[m.group(1)]?.report.images ?? const [];
      final i = int.parse(m.group(2)!);
      if (i >= images.length || !File(images[i]).existsSync()) {
        return _json({'ok': false, 'error': 'no such image'}, status: 404);
      }
      return Response.ok(
        await File(images[i]).readAsBytes(),
        headers: {'Content-Type': 'image/png', 'Cache-Control': 'no-store'},
      );
    }
    return _json({'ok': false, 'error': 'not found: ${req.method} $path'}, status: 404);
  }

  Future<Response> _preview(Request req) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'invalid request body'}, status: 400);
    }
    final kind = ReportKind.parse(body['kind'] as String?);
    if (kind == null) return _json({'ok': false, 'error': 'kind must be bug, feature or question'}, status: 400);
    final attach = body['attach'] is Map ? body['attach'] as Map : const {};
    final attachments = <ReportAttachment>[];
    final logs = sources.logs?.call();
    final lines = attach['logs'] is int ? (attach['logs'] as int).clamp(1, 2000) : 0;
    if (logs != null && lines > 0) attachments.add(logsAttachment(logs, lines));
    if (logs != null && attach['errors'] == true) {
      attachments.add(errorsAttachment(logs) ?? ReportAttachment.text('errors', '(no exceptions in the log)'));
    }
    if (attach['shot'] == true && sources.screenshot != null) {
      try {
        attachments.add(ReportAttachment.image('screenshot', await sources.screenshot!()));
      } catch (e) {
        return _json({'ok': false, 'error': 'could not capture the screen: $e'}, status: 409);
      }
    }
    final session = await sources.session?.call();
    final env = await environment(device: session?.device, appState: session?.appState, from: sources.from);
    final BuiltReport built;
    try {
      built = buildReport(
        ReportDraft(
          kind: kind,
          title: '${body['title'] ?? ''}',
          body: '${body['body'] ?? ''}',
          attachments: attachments,
        ),
        env,
        sources.scrubber(),
      );
    } on FormatException catch (e) {
      return _json({'ok': false, 'error': e.message}, status: 400);
    }
    final now = DateTime.now();
    _previews
      ..removeWhere((_, v) => now.difference(v.at) > _keep)
      ..[built.digest] = (report: built, at: now);
    final labels = await reporter.repoLabels();
    return _json({
      'ok': true,
      ...built.toJson(),
      'labeled': labels.contains(kind.label),
      'via': await _ghReady() ? 'gh' : 'browser',
      'repo': reportRepo,
    });
  }

  Future<Response> _send(Request req) async {
    String? digest;
    try {
      digest = (jsonDecode(await req.readAsString()) as Map)['digest'] as String?;
    } catch (_) {}
    final kept = digest == null ? null : _previews[digest];
    if (kept == null) {
      return _json({'ok': false, 'error': 'that preview is gone (kept 30 minutes) — preview again'}, status: 409);
    }
    final r = kept.report;
    final gh = await _ghReady();
    final result = await reporter.send(r, useGh: gh);
    if (!result.ok) return _json(result.toJson(), status: 502);
    var trimmed = false;
    if (result.via == 'browser') trimmed = reporter.newIssueUrl(r).trimmed;
    return _json({
      ...result.toJson(),
      'title': r.title,
      if (trimmed) 'body': r.body,
      if (trimmed) 'trimmed': true,
      'images': [for (var i = 0; i < r.images.length; i++) '/api/report/image/$digest/$i'],
    });
  }

  Response _json(Object data, {int status = 200}) =>
      Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});
}
