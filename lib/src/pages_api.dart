/// Runs the items and blocks of dashboard pages (`pages.dart`) and serves them
/// under `/api/pages` — for the dashboard and for `emu pages`/`run`/`block`.
///
/// - `GET  /api/pages`                              pages, config problems, last run per page
/// - `GET  /api/pages/<page>/state/<item>`          a toggle's state (runs its `state` command)
/// - `POST /api/pages/<page>/run/<item>`            run a toolbar item
/// - `POST /api/pages/<page>/rows/<list>/<action>`  run a list's row button
/// - `POST /api/pages/<page>/forms/<form>/<action>` run a form's button
/// - `GET  /api/pages/<page>/blocks/<block>`        a list's rows, a diff's patch, an html block's data
/// - `GET  /api/pages/<page>/frames/<block>`        an html block's file
///
/// Runs take `{"confirmed": bool, "on": bool, "selected": {…}, "row": {…}, "input": {…}}`;
/// GETs take `selected.<col>=…` and `seg=…`. Those values only fill the
/// placeholders of commands from the config.
///
/// The config is re-read on every request, so editing `emu.yaml` needs no
/// restart. Every run is reported to dashboards over the WebSocket
/// (`{"type": "ext", ...}`) and logged with an `[ext]` prefix.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'models.dart';
import 'pages.dart';
import 'project_config.dart';

/// Output kept per run (the tail, if a command prints more).
const _outputLimit = 256 * 1024;

/// Rows a list block sends at most — a dashboard table, not a data export.
const _rowLimit = 2000;

/// Largest html block file served.
const _frameLimit = 2 * 1024 * 1024;

/// One finished run of a page command.
class PageRun {
  PageRun({
    required this.page,
    required this.item,
    required this.command,
    required this.at,
    this.exitCode = -1,
    this.output = '',
    this.stdout = '',
    this.elapsed = Duration.zero,
    this.timedOut = false,
    this.startError,
  });

  final String page;

  /// The toolbar item, or `<list>.<action>` for a row button.
  final String item;
  final String command;
  final DateTime at;
  final int exitCode;

  /// stdout and stderr as they came.
  final String output;

  /// stdout alone — what list and diff blocks read.
  final String stdout;
  final Duration elapsed;
  final bool timedOut;

  /// The command could not be started (missing program, not executable).
  final String? startError;

  /// The follow-up reload/restart (`then:`), if it ran.
  Map<String, dynamic>? then;

  /// A toggle's state after the run.
  Map<String, dynamic>? state;

  bool get commandOk => exitCode == 0 && !timedOut && startError == null;

  /// The command and its follow-up both succeeded.
  bool get ok => commandOk && (then == null || then!['ok'] == true);

  String? get error => startError != null
      ? 'could not start: $startError'
      : timedOut
          ? 'timed out after ${elapsed.inSeconds}s'
          : exitCode != 0
              ? 'exit $exitCode'
              : null;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'page': page,
        'item': item,
        'command': command,
        'exitCode': exitCode,
        if (timedOut) 'timedOut': true,
        'error': ?error,
        'output': output,
        'ms': elapsed.inMilliseconds,
        'at': at.toIso8601String(),
        'then': ?then,
        'state': ?state,
      };
}

/// A toggle's `state` output → `{on, detail?}`, or null when it isn't
/// `{"on": bool, "detail"?: …}`. The whole output is tried first, then its
/// last line, so a tool may log before printing the JSON.
Map<String, dynamic>? parseToggleState(String output) {
  final lines = output.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  for (final candidate in [output.trim(), if (lines.isNotEmpty) lines.last.trim()]) {
    try {
      final v = jsonDecode(candidate);
      if (v is Map && v['on'] is bool) {
        return {'on': v['on'], if (v['detail'] != null) 'detail': '${v['detail']}'};
      }
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// A list command's stdout → rows, or null when it isn't a JSON array of objects.
List<Map<String, dynamic>>? parseListRows(String stdout) {
  try {
    final v = jsonDecode(stdout.trim());
    if (v is List && v.every((e) => e is Map)) {
      return [for (final e in v) (e as Map).map((k, x) => MapEntry('$k', x))];
    }
  } on FormatException {
    // not JSON
  }
  return null;
}

/// Placeholder values carried by a request: `selected`/`row`/`input` maps and
/// `seg` in a JSON body, or `selected.<col>=…`/`seg=…` in a query.
Map<String, String> placeholderValues({Map? body, Map<String, String>? query}) {
  String? str(Object? v) => v == null ? null : v is String ? v : v is num || v is bool ? '$v' : jsonEncode(v);
  final out = <String, String>{};
  for (final kind in ['selected', 'row', 'input']) {
    final m = body?[kind];
    if (m is! Map) continue;
    m.forEach((k, v) {
      final s = str(v);
      if (s != null) out['$kind.$k'] = s;
    });
  }
  final seg = str(body?['seg']);
  if (seg != null) out['seg'] = seg;
  query?.forEach((k, v) {
    if (k.startsWith('selected.') || k == 'seg') out[k] = v;
  });
  return out;
}

class PagesApi {
  PagesApi({
    required this.projectRoot,
    this.profile,
    this.home,
    required this.environment,
    required this.followUp,
    required this.openUrl,
    required this.broadcast,
    required this.log,
  });

  final String projectRoot;

  /// The `emu up --profile` in effect, so a profile's `pages:` apply.
  final String? profile;

  /// Home for `~/.emu/config.yaml` (tests point it elsewhere).
  final String? home;

  /// Variables for every command (`EMU_PROJECT`, `EMU_DEVICE`, …).
  final Map<String, String> Function() environment;

  /// Runs an item's `then:` and reports `{ok, message, …}`.
  final Future<Map<String, dynamic>> Function(Then then) followUp;

  /// Opens a deep link on the device, as `emu open-url` does: `{ok, error?}`.
  final Future<Map<String, dynamic>> Function(String url) openUrl;

  final void Function(Map<String, dynamic> message) broadcast;
  final void Function(String text, LogLevel level) log;

  final Set<String> _running = {};
  final Map<String, PageRun> _last = {};

  /// The current `pages:` of the merged config, with config-file warnings first.
  PagesConfig load() {
    final warnings = <String>[];
    final config = loadProjectConfig(projectRoot, home: home, profile: profile, onWarn: warnings.add);
    final parsed = parsePages(config.pages);
    return PagesConfig(parsed.pages, [...warnings, ...parsed.problems]);
  }

  Future<Response> handle(Request req, String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList(); // api, pages, …
    final config = load();
    if (parts.length == 2) {
      return _json({
        'pages': [for (final page in config.pages) page.toJson()],
        'problems': config.problems,
        'last': {for (final e in _last.entries) e.key: e.value.toJson()},
      });
    }
    if (parts.length < 5 || parts.length > 6) return _json({'ok': false, 'error': 'not found'}, status: 404);
    final page = config.page(parts[2]);
    if (page == null) {
      return _json({
        'ok': false,
        'error': 'no page "${parts[2]}" in emu.yaml (pages: ${config.pages.map((p) => p.id).join(', ')})',
      }, status: 404);
    }
    final query = req.url.queryParameters;
    switch ((parts[3], parts.length)) {
      case ('blocks', 5):
        final block = page.block(parts[4]);
        if (block == null || block is OutputBlock || block is FormBlock) {
          return _json({
            'ok': false,
            'error': 'no list, diff or html block "${parts[4]}" on page ${page.id} '
                '(${page.blocks.where((b) => b is ListBlock || b is DiffBlock || b is HtmlBlock).map((b) => b.id).join(', ')})',
          }, status: 404);
        }
        return _json(await _blockData(page, block, placeholderValues(query: query)));
      case ('frames', 5):
        final block = page.block(parts[4]);
        if (block is! HtmlBlock) return _json({'ok': false, 'error': 'no html block "${parts[4]}" on page ${page.id}'}, status: 404);
        return _json(await _frame(block));
      case ('state', 5):
        final item = page.item(parts[4]);
        if (item is! PageToggle) return _json({'ok': false, 'error': 'no toggle "${parts[4]}" on page ${page.id}'}, status: 404);
        return _json(await _state(page, item, placeholderValues(query: query)));
      case ('run', 5) || ('rows', 6) || ('forms', 6):
        if (req.method != 'POST') return _json({'ok': false, 'error': 'use POST'}, status: 405);
        Map body;
        try {
          final text = await req.readAsString();
          body = text.trim().isEmpty ? const {} : jsonDecode(text) as Map;
        } catch (_) {
          return _json({'ok': false, 'error': 'invalid request body'}, status: 400);
        }
        final vars = placeholderValues(body: body);
        final confirmed = body['confirmed'] == true;
        if (parts[3] == 'rows' || parts[3] == 'forms') {
          final block = page.block(parts[4]);
          final action = switch (block) {
            ListBlock() when parts[3] == 'rows' => block.rowAction(parts[5]),
            FormBlock() when parts[3] == 'forms' => block.action(parts[5]),
            _ => null,
          };
          if (action == null) {
            final what = parts[3] == 'rows' ? 'row action' : 'form action';
            return _json({'ok': false, 'error': 'no $what "${parts[4]}.${parts[5]}" on page ${page.id}'}, status: 404);
          }
          return _run(page, action, itemId: '${block!.id}.${action.id}', vars: vars, confirmed: confirmed);
        }
        final item = page.item(parts[4]);
        if (item == null) {
          return _json({
            'ok': false,
            'error': 'no item "${parts[4]}" on page ${page.id} (${page.toolbar.map((i) => i.id).join(', ')})',
          }, status: 404);
        }
        return _run(page, item, itemId: item.id, vars: vars, confirmed: confirmed, on: body['on'] as bool?);
      default:
        return _json({'ok': false, 'error': 'not found'}, status: 404);
    }
  }

  /// Blocks to fetch again because these project-relative paths changed:
  /// page id → block ids.
  Map<String, Set<String>> watching(Iterable<String> paths) {
    final config = load();
    final out = <String, Set<String>>{};
    for (final path in paths) {
      config.watching(path).forEach((page, blocks) => out.putIfAbsent(page, () => {}).addAll(blocks));
    }
    return out;
  }

  Future<Response> _run(DashboardPage page, ToolbarItem item,
      {required String itemId, required Map<String, String> vars, required bool confirmed, bool? on}) async {
    final key = '${page.id}.$itemId';
    final PageCommand declared;
    switch (item) {
      case PageAction():
        declared = (item.run ?? item.openUrl)!;
      case PageToggle():
        if (on == null) return _json({'ok': false, 'error': '$key is a toggle — say on or off'}, status: 400);
        declared = on ? item.on : item.off;
    }
    final PageCommand command;
    try {
      command = declared.fill(vars);
    } on MissingValue catch (e) {
      return _json(_needs(key, e), status: 400);
    }
    final url = item is PageAction && item.openUrl != null ? command.argv!.single.trim() : null;
    if (url != null && url.isEmpty) return _json({'ok': false, 'needs': 'input', 'error': '$key: the URL is empty'}, status: 400);
    final display = url != null ? 'open-url $url' : command.display;
    if (item is PageAction && item.confirm && !confirmed) {
      // The exact command, values filled in: what the dialog shows is what runs.
      return _json({
        'ok': false,
        'needsConfirm': true,
        'command': display,
        'error': '$key asks for confirmation first — it runs: $display',
      }, status: 428);
    }
    if (!_running.add(key)) {
      return _json({'ok': false, 'busy': true, 'error': '$key is already running'}, status: 409);
    }
    final PageRun run;
    try {
      broadcast({'type': 'ext', 'event': 'started', 'page': page.id, 'item': itemId});
      log('[ext] $key ▸ $display', LogLevel.system);
      run = url != null ? await _openUrl(page.id, itemId, url) : await execute(page.id, itemId, command, item.timeout);
      if (run.commandOk && item.then != Then.none) run.then = await followUp(item.then);
      if (item is PageToggle) run.state = await _state(page, item, vars);
    } finally {
      _running.remove(key);
    }
    _last[page.id] = run;
    _logResult(key, run);
    broadcast({'type': 'ext', 'event': 'finished', 'page': page.id, 'item': itemId, 'run': run.toJson()});
    return _json(run.toJson());
  }

  Map<String, dynamic> _needs(String key, MissingValue e) => {
        'ok': false,
        'needs': e.kind,
        'error': switch (e.kind) {
          'selected' => '$key uses {{${e.key}}} — select a row first',
          'row' => '$key uses {{${e.key}}} — the row has no such column',
          'input' => '$key uses {{${e.key}}} — fill in that field',
          _ => '$key uses {{${e.key}}} — no value given',
        },
      };

  Future<Map<String, dynamic>> _state(DashboardPage page, PageToggle toggle, Map<String, String> vars) async {
    final PageCommand command;
    try {
      command = toggle.state.fill(vars);
    } on MissingValue catch (e) {
      return _needs('${page.id}.${toggle.id}', e);
    }
    final run = await execute(page.id, toggle.id, command, const Duration(seconds: 10));
    if (!run.commandOk) {
      return {'ok': false, 'error': 'state command failed (${run.error}): ${_clip(run.output)}'};
    }
    final state = parseToggleState(run.stdout);
    if (state == null) {
      return {'ok': false, 'error': 'state command should print {"on": true|false}: ${_clip(run.output)}'};
    }
    return {'ok': true, ...state};
  }

  /// A list's rows, a diff's patch or an html block's data. Not a "run":
  /// nothing is logged or broadcast, and a failure only shows in the block.
  Future<Map<String, dynamic>> _blockData(DashboardPage page, PageBlock block, Map<String, String> vars) async {
    final key = '${page.id}.${block.id}';
    final kind = switch (block) { ListBlock() => 'list', DiffBlock() => 'diff', _ => 'html' };
    if (block.command == null) return {'ok': true, 'kind': kind, 'data': null}; // an html block without run
    if (block is DiffBlock && block.segments.isNotEmpty) {
      final seg = vars['seg'] ??= block.segments.first;
      if (!block.segments.contains(seg)) {
        return {'ok': false, 'error': 'seg must be one of ${block.segments.join(', ')} (got "$seg")'};
      }
    }
    final PageCommand command;
    try {
      command = block.command!.fill(vars);
    } on MissingValue catch (e) {
      return _needs(key, e);
    }
    final run = await execute(page.id, block.id, command, defaultTimeout);
    final base = {
      'kind': kind,
      'command': command.display,
      'ms': run.elapsed.inMilliseconds,
      'seg': ?vars['seg'],
    };
    if (!run.commandOk) {
      return {'ok': false, ...base, 'error': '${run.error}: ${_clip(run.output)}'};
    }
    if (block is DiffBlock) return {'ok': true, ...base, 'patch': run.stdout};
    if (block is HtmlBlock) {
      // JSON goes to the frame as a value; anything else as text.
      try {
        return {'ok': true, ...base, 'data': jsonDecode(run.stdout)};
      } on FormatException {
        return {'ok': true, ...base, 'data': null, 'text': run.stdout};
      }
    }
    final rows = parseListRows(run.stdout);
    if (rows == null) {
      return {'ok': false, ...base, 'error': 'list command should print a JSON array of objects: ${_clip(run.stdout)}'};
    }
    return {
      'ok': true,
      ...base,
      'rows': rows.length > _rowLimit ? rows.sublist(0, _rowLimit) : rows,
      if (rows.length > _rowLimit) 'truncated': rows.length,
    };
  }

  /// An `openUrl:` action, reported like a command run.
  Future<PageRun> _openUrl(String page, String item, String url) async {
    final at = DateTime.now();
    final clock = Stopwatch()..start();
    final r = await openUrl(url);
    final ok = r['ok'] == true;
    final text = ok ? 'opened $url' : '${r['error'] ?? 'open-url failed'}';
    return PageRun(
      page: page,
      item: item,
      command: 'open-url $url',
      at: at,
      exitCode: ok ? 0 : 1,
      output: text,
      stdout: text,
      elapsed: clock.elapsed,
    );
  }

  /// An html block's file, for the dashboard to put in its sandboxed frame.
  Future<Map<String, dynamic>> _frame(HtmlBlock block) async {
    try {
      final file = File(p.join(projectRoot, block.src));
      // The config names the file, not the request — but a symlink still
      // must not lead out of the project.
      if (!p.isWithin(Directory(projectRoot).resolveSymbolicLinksSync(), file.resolveSymbolicLinksSync())) {
        return {'ok': false, 'error': '${block.src} leads outside the project'};
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _frameLimit) return {'ok': false, 'error': '${block.src} is over 2 MB'};
      return {'ok': true, 'src': block.src, 'html': utf8.decode(bytes, allowMalformed: true)};
    } on FileSystemException catch (e) {
      return {'ok': false, 'error': 'cannot read ${block.src}: ${e.osError?.message ?? e.message}'};
    }
  }

  /// Run [command] in the project root, output captured, killed after
  /// [timeout]. Never throws.
  Future<PageRun> execute(String page, String item, PageCommand command, Duration timeout) async {
    var (exe, args) = command.invocation;
    // A project script (`./tool/x`, `tool/x`) resolves against the project
    // root, not against wherever the server was started.
    if (exe.contains('/') && !p.isAbsolute(exe)) exe = p.normalize(p.join(projectRoot, exe));
    final at = DateTime.now();
    final clock = Stopwatch()..start();
    final Process proc;
    try {
      proc = await Process.start(exe, args, workingDirectory: projectRoot, environment: environment());
    } on ProcessException catch (e) {
      return PageRun(page: page, item: item, command: command.display, at: at, startError: e.message);
    }
    unawaited(proc.stdin.close()); // EOF for anything that prompts
    final all = _Tail(), out = _Tail();
    const decoder = Utf8Decoder(allowMalformed: true);
    final drained = Future.wait([
      proc.stdout.transform(decoder).forEach((s) => all.add(out.add(s))),
      proc.stderr.transform(decoder).forEach(all.add),
    ]);
    var timedOut = false;
    final code = await proc.exitCode.timeout(timeout, onTimeout: () async {
      timedOut = true;
      await killTree(proc.pid);
      return -1;
    });
    await drained.timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return PageRun(
      page: page,
      item: item,
      command: command.display,
      at: at,
      exitCode: code,
      output: all.text,
      stdout: out.text,
      elapsed: clock.elapsed,
      timedOut: timedOut,
    );
  }

  void _logResult(String key, PageRun run) {
    final secs = (run.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final then = run.then;
    final follow = then == null ? '' : ' · ${then['action']}: ${then['message'] ?? (then['ok'] == true ? 'ok' : 'failed')}';
    if (run.ok) {
      log('[ext] $key ✓ exit 0 · ${secs}s$follow', LogLevel.system);
      return;
    }
    final tail = run.output.trimRight().split('\n');
    final last = tail.length > 20 ? tail.sublist(tail.length - 20) : tail;
    log('[ext] $key ✗ ${run.error ?? 'exit 0'} · ${secs}s$follow${last.join().isEmpty ? '' : '\n${last.join('\n')}'}',
        LogLevel.error);
  }
}

/// SIGKILL [pid] and everything under it. Killing only the direct child
/// would orphan what it spawned (`sh -c 'a | b'`, a script running a build)
/// and those keep running past the timeout. The child shares emu's process
/// group, so a group kill is not an option; descendants are collected first
/// (via `pgrep -P`), since once their parent dies they are reparented away.
Future<void> killTree(int pid) async {
  final all = <int>[pid];
  for (var i = 0; i < all.length; i++) {
    try {
      final r = await Process.run('pgrep', ['-P', '${all[i]}']);
      all.addAll('${r.stdout}'.split('\n').map((l) => int.tryParse(l.trim())).whereType<int>());
    } catch (_) {
      break; // no pgrep — at least the direct child still goes
    }
  }
  for (final p in all) {
    Process.killPid(p, ProcessSignal.sigkill);
  }
}

/// The last [_outputLimit] characters of a stream of chunks.
class _Tail {
  final _buf = StringBuffer();

  String add(String chunk) {
    _buf.write(chunk);
    if (_buf.length > _outputLimit * 2) {
      final keep = _buf.toString().substring(_buf.length - _outputLimit);
      _buf
        ..clear()
        ..write(keep);
    }
    return chunk;
  }

  String get text => _buf.length > _outputLimit ? _buf.toString().substring(_buf.length - _outputLimit) : '$_buf';
}

String _clip(String s) {
  final t = s.trim();
  return t.length > 200 ? '${t.substring(0, 200)}…' : t;
}

Response _json(Object data, {int status = 200}) =>
    Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});
