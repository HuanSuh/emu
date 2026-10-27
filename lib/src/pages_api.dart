/// Runs the items and blocks of dashboard pages (`pages.dart`) and serves them
/// under `/api/pages` — for the dashboard and for `emu pages`/`run`/`block`.
///
/// - `GET  /api/pages`                              pages, config problems, last run per page
/// - `GET  /api/pages/<page>/state/<item>`          a toggle's state (runs its `state` command)
/// - `POST /api/pages/<page>/run/<item>`            run a toolbar item
/// - `POST /api/pages/<page>/rows/<list>/<action>`  run a list's row button
/// - `POST /api/pages/<page>/forms/<form>/<action>` run a form's button
/// - `POST /api/pages/<page>/frames/<html>/<action>` run an html block's own action
/// - `GET  /api/pages/<page>/blocks/<block>`        a list's rows, a diff's patch, an html block's data
/// - `GET  /api/pages/<page>/frames/<block>`        an html block's file
/// - `POST /api/pages/<page>/auto/<item>`           switch an `auto:` action on or off: `{"on": bool}`
/// - `POST /api/pages/<page>/asks/<ask>`            answer what a running command asks: `{"value": …}`
///
/// Runs take `{"confirmed": bool, "on": bool, "selected": {…}, "row": {…}, "input": {…},
/// "checked": […] | {"<list>": […]}}` — checked rows as objects, or as their
/// keys (looked up in the list); an unconfirmed run of a `confirm:` action
/// answers 428 with the dialog — `command`, `confirm: {title, message?, danger,
/// button}` and the `preview` output, if it has one — and runs nothing but that
/// preview. GETs take `selected.<col>=…` and `seg=…`. Those values only fill the
/// placeholders of commands from the config. A run's answer carries `data`
/// too when its stdout is JSON, for an html block's `emu.run`.
///
/// A run may also carry `"asker"`: the dashboard tab or `emu run` that
/// starts it, connected to `/api/stream?asker=<id>`. What an `interactive:`
/// action asks while it runs (`page_ask.dart`) goes to that asker alone, as
/// `{"type": "ext", "event": "ask", askId, page, item, from: {page, action},
/// ask, timeoutMs}`, then `ask-done` once it is answered, timed out or the
/// command ended. While a question waits, the run's `timeout:` doesn't run.
///
/// An `auto:` action also runs from here when files it watches change
/// ([filesChanged]), while switched on — the switch is kept per project.
///
/// The config is re-read on every request, so editing `emu.yaml` needs no
/// restart. Every run is reported to dashboards over the WebSocket
/// (`{"type": "ext", "event": …}`: `started`, its output as it comes —
/// `output` with the new `chunk`, at most every 100ms — then `finished`) and
/// logged with an `[ext]` prefix.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'models.dart';
import 'page_ask.dart';
import 'pages.dart';
import 'project_config.dart';

/// Output kept per run (the tail, if a command prints more).
const _outputLimit = 256 * 1024;

/// Rows a list block sends at most — a dashboard table, not a data export.
const _rowLimit = 2000;

/// Largest html block file served.
const _frameLimit = 2 * 1024 * 1024;

/// How often a running command's new output goes to dashboards.
const _outputEvery = Duration(milliseconds: 100);

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
    this.waited = Duration.zero,
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

  /// Of [elapsed], the time its questions waited for answers — not counted
  /// against its timeout.
  final Duration waited;

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
          ? 'timed out after ${(elapsed - waited).inSeconds}s'
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
        if (waited > Duration.zero) 'waitedMs': waited.inMilliseconds,
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

final _patchStart = RegExp(r'^(diff --git |--- \S.*\n\+\+\+ |@@ -\d)', multiLine: true);

/// Whether [text] reads as a unified diff (`diff --git`, a `---`/`+++` pair
/// or a hunk header at a line start).
bool looksLikePatch(String text) => _patchStart.hasMatch(text);
/// [stdout] as a JSON value, or null when it is empty or not JSON.
Object? stdoutJson(String stdout) {
  final t = stdout.trim();
  if (t.isEmpty) return null;
  try {
    return jsonDecode(t);
  } on FormatException {
    return null;
  }
}

/// Placeholder values carried by a request: `selected`/`row`/`input` maps and
/// `seg` in a JSON body, or `selected.<col>=…`/`seg=…` in a query.
Map<String, String> placeholderValues({Map? body, Map<String, String>? query}) {
  final out = <String, String>{};
  for (final kind in ['selected', 'row', 'input']) {
    final m = body?[kind];
    if (m is! Map) continue;
    _stringMap(m).forEach((k, v) => out['$kind.$k'] = v);
  }
  final seg = _str(body?['seg']);
  if (seg != null) out['seg'] = seg;
  query?.forEach((k, v) {
    if (k.startsWith('selected.') || k == 'seg') out[k] = v;
  });
  return out;
}

String? _str(Object? v) => v == null ? null : v is String ? v : v is num || v is bool ? '$v' : jsonEncode(v);

/// A row's values as placeholder text; null values are left out.
Map<String, String> _stringMap(Map m) => {
      for (final e in m.entries)
        if (_str(e.value) case final s?) '${e.key}': s,
    };

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
    this.autoStateFile,
    this.askerHere,
    this.sendToAsker,
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

  /// Where the `auto:` switches are kept (`.emu/pages_auto.json`); null: in memory only.
  final File? autoStateFile;

  /// Whether the asker of this id (`/api/stream?asker=`) is connected.
  final bool Function(String asker)? askerHere;

  /// Sends [message] to the asker of this id; false if it isn't connected.
  final bool Function(String asker, Map<String, dynamic> message)? sendToAsker;

  final Set<String> _running = {};

  /// Questions of running commands waiting for an answer, by ask id.
  final Map<String, _PendingAsk> _asks = {};
  final _random = Random.secure();
  final Map<String, PageRun> _last = {};

  /// 'page.item' → an `auto:` switch someone flipped (others are at `auto.on`).
  Map<String, bool>? _autoSwitches;
  final Map<String, _AutoState> _autoStates = {};

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
        'auto': {
          for (final page in config.pages)
            for (final a in page.toolbar.whereType<PageAction>())
              if (a.auto != null) '${page.id}.${a.id}': autoOn(page, a),
        },
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
      case ('asks', 5):
        if (req.method != 'POST') return _json({'ok': false, 'error': 'use POST'}, status: 405);
        Object? value;
        try {
          value = (jsonDecode(await req.readAsString()) as Map)['value'];
        } catch (_) {
          return _json({'ok': false, 'error': 'say {"value": …}'}, status: 400);
        }
        // Looked up once the body is in: an answer that came first has taken it.
        final pending = _asks[parts[4]];
        if (pending == null || pending.page != page.id || pending.answered) {
          return _json({'ok': false, 'error': 'no such question — answered, timed out, or its command ended'}, status: 404);
        }
        final checked = checkAnswer(pending.ask, value);
        pending.finish(checked, null);
        return _json({'ok': true, 'value': checked});
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
      case ('auto', 5):
        final item = page.item(parts[4]);
        if (item is! PageAction || item.auto == null) {
          return _json({'ok': false, 'error': 'no action with auto: "${parts[4]}" on page ${page.id}'}, status: 404);
        }
        if (req.method != 'POST') return _json({'ok': false, 'error': 'use POST'}, status: 405);
        Object? on;
        try {
          on = (jsonDecode(await req.readAsString()) as Map)['on'];
        } catch (_) {
          on = null;
        }
        if (on is! bool) return _json({'ok': false, 'error': 'say {"on": true} or {"on": false}'}, status: 400);
        _setAuto(page, item, on);
        return _json({'ok': true, 'on': on});
      case ('state', 5):
        final item = page.item(parts[4]);
        if (item is! PageToggle) return _json({'ok': false, 'error': 'no toggle "${parts[4]}" on page ${page.id}'}, status: 404);
        return _json(await _state(page, item, placeholderValues(query: query)));
      case ('run', 5) || ('rows', 6) || ('forms', 6) || ('frames', 6):
        if (req.method != 'POST') return _json({'ok': false, 'error': 'use POST'}, status: 405);
        Map body;
        try {
          final text = await req.readAsString();
          body = text.trim().isEmpty ? const {} : jsonDecode(text) as Map;
        } catch (_) {
          return _json({'ok': false, 'error': 'invalid request body'}, status: 400);
        }
        final confirmed = body['confirmed'] == true;
        final asker = switch (body['asker']) { final String a when askerIdPattern.hasMatch(a) => a, _ => null };
        if (parts[3] != 'run') {
          final block = page.block(parts[4]);
          final action = switch (block) {
            ListBlock() when parts[3] == 'rows' => block.rowAction(parts[5]),
            FormBlock() when parts[3] == 'forms' => block.action(parts[5]),
            HtmlBlock() when parts[3] == 'frames' => block.action(parts[5]),
            _ => null,
          };
          if (block is HtmlBlock && body['input'] is Map) {
            // A frame passes only what its block declared in inputs:.
            final input = body['input'] as Map;
            body = {...body, 'input': {for (final k in block.inputs) if (input.containsKey(k)) k: input[k]}};
          }
          final vars = placeholderValues(body: body);
          if (action == null) {
            final what = switch (parts[3]) { 'rows' => 'row action', 'forms' => 'form action', _ => 'html block action' };
            return _json({'ok': false, 'error': 'no $what "${parts[4]}.${parts[5]}" on page ${page.id}'}, status: 404);
          }
          final itemId = '${block!.id}.${action.id}';
          final checked = await _checked(page, action, '${page.id}.$itemId', body['checked'], vars);
          if (checked.$2 case final refusal?) return _json(refusal, status: 400);
          return _run(page, action, itemId: itemId, vars: vars, checked: checked.$1!, confirmed: confirmed, asker: asker);
        }
        final vars = placeholderValues(body: body);
        final item = page.item(parts[4]);
        if (item == null) {
          return _json({
            'ok': false,
            'error': 'no item "${parts[4]}" on page ${page.id} (${page.toolbar.map((i) => i.id).join(', ')})',
          }, status: 404);
        }
        var checked = const <String, List<Map<String, String>>>{};
        if (item is PageAction) {
          final r = await _checked(page, item, '${page.id}.${item.id}', body['checked'], vars);
          if (r.$2 case final refusal?) return _json(refusal, status: 400);
          checked = r.$1!;
        }
        return _run(page, item,
            itemId: item.id, vars: vars, checked: checked, confirmed: confirmed, on: body['on'] as bool?, asker: asker);
      default:
        return _json({'ok': false, 'error': 'not found'}, status: 404);
    }
  }

  /// Blocks to fetch again because these project-relative paths changed:
  /// page id → block ids. [config]: the one just loaded, if the caller has it.
  Map<String, Set<String>> watching(Iterable<String> paths, {PagesConfig? config}) {
    config ??= load();
    final out = <String, Set<String>>{};
    for (final path in paths) {
      config.watching(path).forEach((page, blocks) => out.putIfAbsent(page, () => {}).addAll(blocks));
    }
    return out;
  }

  Future<Response> _run(DashboardPage page, ToolbarItem item,
      {required String itemId,
      required Map<String, String> vars,
      Map<String, List<Map<String, String>>> checked = const {},
      required bool confirmed,
      bool? on,
      String? auto,
      String? asker}) async {
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
      command = declared.fill(vars, checked: checked, checkList: page.checkList);
    } on MissingValue catch (e) {
      return _json(_needs(key, e), status: 400);
    }
    final url = item is PageAction && item.openUrl != null ? command.argv!.single.trim() : null;
    if (url != null && url.isEmpty) return _json({'ok': false, 'needs': 'input', 'error': '$key: the URL is empty'}, status: 400);
    final display = url != null ? 'open-url $url' : command.display;
    final confirm = item is PageAction ? item.confirm : null;
    if (confirm != null && !confirmed) {
      final String? message;
      final String title;
      final PageCommand? preview;
      try {
        String text(String t) => ConfirmSpec.fillText(t, vars, checked: checked, checkList: page.checkList);
        title = text(confirm.title ?? 'Run “${item.label}”?');
        message = confirm.message == null ? null : text(confirm.message!);
        preview = confirm.preview?.fill(vars, checked: checked, checkList: page.checkList);
      } on MissingValue catch (e) {
        return _json(_needs(key, e), status: 400);
      }
      // The exact command, values filled in: what the dialog shows is what runs.
      return _json({
        'ok': false,
        'needsConfirm': true,
        'command': display,
        'confirm': {'title': title, 'message': ?message, 'danger': confirm.danger, 'button': confirm.button ?? 'Run'},
        if (preview != null) 'preview': await _preview(page, itemId, preview, item.timeout, confirm.allowOnPreviewError),
        'error': '$key asks for confirmation first — it runs: $display',
      }, status: 428);
    }
    if (!_running.add(key)) {
      return _json({'ok': false, 'busy': true, 'error': '$key is already running'}, status: 409);
    }
    final PageRun run;
    try {
      broadcast({'type': 'ext', 'event': 'started', 'page': page.id, 'item': itemId, if (auto != null) 'auto': true});
      log('[ext] $key ▸ $display${auto == null ? '' : '   (auto: $auto changed)'}', LogLevel.system);
      final live = LiveOutput(
          (chunk) => broadcast({'type': 'ext', 'event': 'output', 'page': page.id, 'item': itemId, 'chunk': chunk}));
      final interactive = item is PageAction && item.interactive;
      run = url != null
          ? await _openUrl(page.id, itemId, url)
          : await execute(page.id, itemId, command, item.timeout,
              onOutput: live.add,
              ask: interactive ? (q, ended) => _askUser(page, item, itemId, asker, q, ended) : null,
              canAsk: interactive && asker != null && (askerHere?.call(asker) ?? false));
      live.flush(); // all of it before `finished`
      if (run.commandOk && item.then != Then.none) run.then = await followUp(item.then);
      if (item is PageToggle) run.state = await _state(page, item, vars);
    } finally {
      _running.remove(key);
    }
    _last[page.id] = run;
    _logResult(key, run);
    broadcast({
      'type': 'ext',
      'event': 'finished',
      'page': page.id,
      'item': itemId,
      'run': run.toJson(),
      if (auto != null) 'auto': true,
    });
    return _json({...run.toJson(), 'data': ?stdoutJson(run.stdout)});
  }

  // ---- auto: -----------------------------------------------------------------
  // A change to a watched file starts the action once the changes rest
  // (`debounce`). A file changed while it runs makes it run once more right
  // after — and what changes during that once-more doesn't count, so a tool
  // that writes the files it watches runs twice, not forever. Which run a
  // change belongs to goes by the file's modified time, not by when the
  // watcher reports it: reports come late.

  Map<String, bool> get _switches => _autoSwitches ??= _readSwitches();

  Map<String, bool> _readSwitches() {
    try {
      final v = jsonDecode(autoStateFile?.readAsStringSync() ?? '{}');
      return v is Map ? {for (final e in v.entries) if (e.value is bool) '${e.key}': e.value as bool} : {};
    } catch (_) {
      return {}; // none yet, or unreadable: every switch at its auto.on
    }
  }

  /// Whether [action]'s `auto:` is switched on.
  bool autoOn(DashboardPage page, PageAction action) => _switches['${page.id}.${action.id}'] ?? action.auto!.on;

  void _setAuto(DashboardPage page, PageAction action, bool on) {
    final key = '${page.id}.${action.id}';
    _switches[key] = on;
    try {
      autoStateFile?.writeAsStringSync(jsonEncode(_switches));
    } on FileSystemException {
      // Kept for this session only.
    }
    if (!on) _autoStates[key]?.drop(); // what was waiting doesn't run
    log('[ext] $key auto ${on ? 'on' : 'off'}', LogLevel.system);
    broadcast({'type': 'ext-auto', 'page': page.id, 'item': action.id, 'on': on});
  }

  /// Project files that changed (project-relative paths, as the server's
  /// watcher reports them): start the `auto:` actions switched on that watch
  /// them. [config]: the one just loaded, if the caller has it.
  void filesChanged(Iterable<String> paths, {PagesConfig? config}) {
    config ??= load();
    for (final page in config.pages) {
      for (final action in page.toolbar.whereType<PageAction>()) {
        final auto = action.auto;
        if (auto == null || !autoOn(page, action)) continue;
        final hits = paths.where(auto.matches).toList();
        if (hits.isNotEmpty) _autoChanged(page.id, action.id, auto, hits);
      }
    }
  }

  void _autoChanged(String pageId, String itemId, AutoRun auto, List<String> paths) {
    final st = _autoStates.putIfAbsent('$pageId.$itemId', _AutoState.new);
    for (final path in paths) {
      final at = _modified(path);
      final (start, end) = (st.lastStart, st.lastEnd);
      if (st.started case final started?) {
        // During a run: once more after it — unless this run is that once more.
        if (!st.once && !at.isBefore(started)) {
          st.again = true;
          st.note(path);
        }
      } else if (start != null && end != null && !at.isAfter(end)) {
        // Reported after the last run, made before it ended: that run read it
        // (made before it began), or it is the run's own write, or it came
        // during the run — once more, unless the last run was the once more.
        if (at.isBefore(start) || st.lastWasOnce) continue;
        st.note(path);
        st.pendingOnce = true;
      } else {
        st.note(path);
        st.pending = true;
      }
    }
    if (!st.pending && !st.pendingOnce) return;
    st.timer?.cancel();
    st.timer = Timer(auto.debounce, () => _autoFire(pageId, itemId));
  }

  DateTime _modified(String path) {
    final stat = FileStat.statSync(p.join(projectRoot, path));
    return stat.type == FileSystemEntityType.notFound ? DateTime.now() : stat.modified; // removed: now
  }

  Future<void> _autoFire(String pageId, String itemId) async {
    final key = '$pageId.$itemId';
    final st = _autoStates[key]!;
    st.timer = null;
    final page = load().page(pageId);
    final action = page?.item(itemId);
    // emu.yaml changed meanwhile, or it was switched off.
    if (page == null || action is! PageAction || action.auto == null || !autoOn(page, action)) {
      st.drop();
      return;
    }
    if (_running.contains(key)) {
      // Pressed meanwhile: after that run.
      st.timer = Timer(action.auto!.debounce, () => _autoFire(pageId, itemId));
      return;
    }
    final once = st.pendingOnce && !st.pending;
    final because = st.because;
    st.drop();
    st
      ..started = DateTime.now()
      ..once = once;
    try {
      await _run(page, action, itemId: action.id, vars: const {}, confirmed: false, auto: because);
    } finally {
      st
        ..lastStart = st.started
        ..lastEnd = DateTime.now()
        ..lastWasOnce = once
        ..started = null;
    }
    if (!st.again) return;
    st.again = false;
    st.pendingOnce = true;
    st.timer?.cancel();
    st.timer = Timer(Duration.zero, () => _autoFire(pageId, itemId));
  }

  /// Whether [key]'s `auto:` ('page.item') has no run waiting and none in flight.
  bool autoIdle(String key) {
    final st = _autoStates[key];
    return st == null || (st.timer == null && st.started == null);
  }

  /// Stop the `auto:` timers (the server is going down).
  void dispose() {
    for (final st in _autoStates.values) {
      st.timer?.cancel();
    }
  }

  /// A confirm dialog's `preview:` output, read the way blocks read theirs:
  /// a unified diff as `patch`, a JSON array of objects as `rows`, anything
  /// else as `text`. A failed preview `blocks` Run unless [allowError].
  Future<Map<String, dynamic>> _preview(
      DashboardPage page, String itemId, PageCommand command, Duration timeout, bool allowError) async {
    final run = await execute(page.id, itemId, command, timeout);
    final base = {'command': command.display, 'ms': run.elapsed.inMilliseconds};
    if (!run.commandOk) {
      return {'ok': false, ...base, 'error': run.error, 'text': run.output, 'blocks': !allowError};
    }
    final out = run.stdout;
    if (looksLikePatch(out)) return {'ok': true, ...base, 'kind': 'diff', 'patch': out};
    final rows = out.trim().startsWith('[') ? parseListRows(out) : null;
    if (rows != null && rows.isNotEmpty) {
      return {
        'ok': true,
        ...base,
        'kind': 'table',
        'rows': rows.length > _rowLimit ? rows.sublist(0, _rowLimit) : rows,
        if (rows.length > _rowLimit) 'truncated': rows.length,
      };
    }
    return {'ok': true, ...base, 'kind': 'text', 'text': out};
  }

  Map<String, dynamic> _needs(String key, MissingValue e) => {
        'ok': false,
        'needs': e.kind,
        'error': switch (e.kind) {
          'selected' => '$key uses {{${e.key}}} — select a row first',
          'row' => '$key uses {{${e.key}}} — the row has no such column',
          'input' => '$key uses {{${e.key}}} — fill in that field',
          'checked' => '$key uses {{${e.key}}} — a checked row has no such column',
          _ => '$key uses {{${e.key}}} — no value given',
        },
      };

  /// The checked rows of the lists [action] reads or needs, by list id; or
  /// the refusal to answer with. They come from the request — rows from the
  /// dashboard, or keys (`emu run --checked`) looked up in the list's rows —
  /// or, when the tool keeps the state (`check.column`), from the list itself.
  Future<(Map<String, List<Map<String, String>>>?, Map<String, dynamic>?)> _checked(
      DashboardPage page, PageAction action, String key, Object? raw, Map<String, String> vars) async {
    Map<String, dynamic> refuse(String error, [String? needs]) => {'ok': false, 'needs': ?needs, 'error': '$key: $error'};
    final lists = page.checkedListsOf(action);
    if (lists.isEmpty) return (const <String, List<Map<String, String>>>{}, null);
    final given = <String, List>{};
    switch (raw) {
      case null:
        break;
      case List():
        // The page's one list the dashboard keeps checks for (check: true).
        final own = page.checkLists.where((b) => b.check!.column == null).toList();
        if (own.length != 1) return (null, refuse('say which list the checked rows are of: {"<list>": […]}'));
        given[own.single.id] = raw;
      case Map():
        for (final e in raw.entries) {
          if (e.value is! List) return (null, refuse('checked.${e.key}: expected a list of rows or keys'));
          given['${e.key}'] = e.value as List;
        }
      default:
        return (null, refuse('checked: expected a list of rows or keys'));
    }
    final out = <String, List<Map<String, String>>>{};
    for (final id in lists) {
      final list = page.block(id);
      if (list is! ListBlock || list.check == null) return (null, refuse('no list "$id" with check: on page ${page.id}'));
      final items = given[id] ?? const [];
      final column = list.check!.column;
      if (column == null && items.every((e) => e is Map)) {
        out[id] = [for (final e in items) _stringMap(e as Map)];
        continue;
      }
      // Keys to look up, or the tool's own state: the list's rows are needed.
      final (rows, error) = await _listRows(page, list, vars);
      if (rows == null) return (null, refuse(error!));
      if (column != null) {
        out[id] = [for (final r in rows) if (isCheckedValue(r[column])) _stringMap(r)];
        continue;
      }
      final byKey = {for (final r in rows) ?list.rowKey(r): r};
      final picked = <Map<String, String>>[];
      for (final k in items) {
        final row = byKey[_str(k)];
        if (row == null) return (null, refuse('no row "${_str(k)}" in ${list.id}', 'checked'));
        picked.add(_stringMap(row));
      }
      out[id] = picked;
    }
    if (action.needsChecked case final id? when out[id]!.isEmpty) {
      // The tool's own checks change only through its toggle.
      return (page.block(id) as ListBlock).check!.column == null
          ? (null, refuse('check a row in $id first', 'checked'))
          : (null, refuse('check a row in $id first — its toggle: emu run ${page.id}.$id.check --row <col>=<value>'));
    }
    return (out, null);
  }

  /// A list's rows, run as the block would be; or why not.
  Future<(List<Map<String, dynamic>>?, String?)> _listRows(
      DashboardPage page, ListBlock list, Map<String, String> vars) async {
    final PageCommand command;
    try {
      command = list.run.fill(vars);
    } on MissingValue catch (e) {
      return (null, '${_needs('${page.id}.${list.id}', e)['error']}');
    }
    final run = await execute(page.id, list.id, command, defaultTimeout);
    if (!run.commandOk) return (null, '${list.id}: ${run.error}: ${_clip(run.output)}');
    final rows = parseListRows(run.stdout);
    return rows == null ? (null, '${list.id}: the list command should print a JSON array of objects') : (rows, null);
  }

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
      // An optional segment may be none: {{seg}} is then empty.
      final seg = vars['seg'] ??= block.optional ? '' : block.segments.first;
      if (!block.segments.contains(seg) && !(block.optional && seg.isEmpty)) {
        return {
          'ok': false,
          'error': 'seg must be one of ${block.segments.join(', ')}${block.optional ? ', or empty for none' : ''} (got "$seg")',
        };
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
      // The columns that make each row's folder path (`tree:`), so `emu block` shows them first.
      if (block is ListBlock && block.tree != null) 'tree': block.tree!.columns,
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
  /// [timeout]. [onOutput] gets stdout and stderr as they come. Never throws.
  ///
  /// With [ask] (an `interactive:` action) its stdin stays open and its ask
  /// lines go to [ask], one question at a time, the answers back to stdin;
  /// the timeout stands still while a question waits. `EMU_ASK` is `1` when
  /// [canAsk] — someone may answer — and `0` otherwise.
  Future<PageRun> execute(String page, String item, PageCommand command, Duration timeout,
      {void Function(String chunk)? onOutput, AskHandler? ask, bool canAsk = false}) async {
    var (exe, args) = command.invocation;
    // A project script (`./tool/x`, `tool/x`) resolves against the project
    // root, not against wherever the server was started.
    if (exe.contains('/') && !p.isAbsolute(exe)) exe = p.normalize(p.join(projectRoot, exe));
    final at = DateTime.now();
    final clock = Stopwatch()..start();
    final Process proc;
    try {
      proc = await Process.start(exe, args,
          workingDirectory: projectRoot, environment: {...environment(), 'EMU_ASK': ask != null && canAsk ? '1' : '0'});
    } on ProcessException catch (e) {
      return PageRun(page: page, item: item, command: command.display, at: at, startError: e.message);
    }
    if (ask == null) {
      unawaited(proc.stdin.close()); // EOF for anything that prompts
    } else {
      unawaited(proc.stdin.done.then((_) {}, onError: (_) {})); // it may stop reading: a broken pipe is no failure
    }
    final all = _Tail(), out = _Tail();
    void note(String text) {
      all.add(text);
      onOutput?.call(text);
    }

    var timedOut = false;
    final killed = Completer<int>();
    final deadline = _Deadline(timeout, () async {
      timedOut = true;
      await killTree(proc.pid);
      if (!killed.isCompleted) killed.complete(-1);
    });
    final ended = Completer<void>();
    var waited = Duration.zero;
    var asking = Future<void>.value();
    void onAsk(String? json) {
      deadline.hold();
      asking = asking.then((_) async {
        final clock = Stopwatch()..start();
        final q = json == null ? (ask: null, id: null, error: 'the line is over ${askLineLimit ~/ 1024} KB') : parseAsk(json);
        var (value, why) = (null as Object?, q.error);
        if (q.ask case final question?) (value: value, why: why) = await ask!(question, ended.future);
        waited += clock.elapsed;
        if (why != null) note('⚠ emu-ask${q.id == null ? '' : ' ${jsonEncode(q.id)}'}: $why — answered null\n');
        if (ended.isCompleted) return;
        try {
          proc.stdin.writeln(answerLine(q.id, value));
          await proc.stdin.flush();
        } catch (_) {
          // It closed its stdin: no one to tell.
        }
      }).catchError((_) {}).whenComplete(deadline.release);
    }

    final lines = ask == null ? null : AskLines(onAsk);
    const decoder = Utf8Decoder(allowMalformed: true);
    void stdoutText(String s) {
      if (s.isEmpty) return;
      all.add(out.add(s));
      onOutput?.call(s);
    }

    final drained = Future.wait([
      proc.stdout.transform(decoder).forEach((s) => stdoutText(lines == null ? s : lines.add(s))).then((_) {
        if (lines != null) stdoutText(lines.close());
      }),
      proc.stderr.transform(decoder).forEach(note),
    ]);
    var code = await Future.any([proc.exitCode, killed.future]);
    deadline.cancel();
    if (timedOut) code = -1;
    ended.complete();
    await drained.timeout(const Duration(seconds: 2), onTimeout: () => const []);
    await asking.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (ask != null) {
      try {
        await proc.stdin.close();
      } catch (_) {}
    }
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
      waited: waited,
    );
  }

  // ---- asking (interactive:) -------------------------------------------------

  /// Asks [ask] for [action]'s run: in the dashboard tab or terminal that
  /// started it ([asker]), until answered, [PageAction.askTimeout], or the
  /// command ends. [why]: why it went unanswered (null: someone answered).
  Future<({Object? value, String? why})> _askUser(DashboardPage page, PageAction action, String itemId, String? asker,
      Map<String, dynamic> ask, Future<void> ended) async {
    final key = '${page.id}.$itemId';
    final send = sendToAsker;
    if (asker == null || send == null) {
      log('[ext] $key asks “${ask['title']}” — no one to answer', LogLevel.warn);
      return (value: null, why: 'no one to answer — run it from the dashboard, or with emu run on a terminal');
    }
    final askId = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final pending = _asks[askId] = _PendingAsk(asker, page.id, ask);
    final sent = send(asker, {
      'type': 'ext',
      'event': 'ask',
      'askId': askId,
      'page': page.id,
      'item': itemId,
      'from': {'page': page.title, 'action': action.label},
      'ask': ask,
      'timeoutMs': action.askTimeout.inMilliseconds,
    });
    if (!sent) {
      _asks.remove(askId);
      log('[ext] $key asks “${ask['title']}” — no one to answer', LogLevel.warn);
      return (value: null, why: 'no one to answer — the dashboard tab or terminal that started it is gone');
    }
    log('[ext] $key asks “${ask['title']}”', LogLevel.system);
    final timer = Timer(action.askTimeout, () => pending.finish(null, 'no answer in ${action.askTimeout.inSeconds}s'));
    unawaited(ended.then((_) => pending.finish(null, null)));
    final answer = await pending.done;
    timer.cancel();
    _asks.remove(askId);
    send(asker, {'type': 'ext', 'event': 'ask-done', 'askId': askId, 'page': page.id, 'item': itemId});
    return answer;
  }

  /// The asker of this id is gone (its socket closed): its questions are answered null.
  void askerGone(String asker) {
    for (final pending in _asks.values.where((a) => a.asker == asker).toList()) {
      pending.finish(null, 'the dashboard tab or terminal that started it went away');
    }
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

/// What an asker id (`asker` of a run, `/api/stream?asker=`) may be.
final askerIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,100}$');

/// Asks a running command's question; resolves to the answer, or null and why not.
typedef AskHandler = Future<({Object? value, String? why})> Function(Map<String, dynamic> ask, Future<void> ended);

class _PendingAsk {
  _PendingAsk(this.asker, this.page, this.ask);

  final String asker;
  final String page;
  final Map<String, dynamic> ask;
  final _done = Completer<({Object? value, String? why})>();

  Future<({Object? value, String? why})> get done => _done.future;

  /// Answered, timed out or given up — a later answer is refused.
  bool get answered => _done.isCompleted;

  void finish(Object? value, String? why) {
    if (!_done.isCompleted) _done.complete((value: value, why: why));
  }
}

/// A run's timeout that stands still while it is [hold]ed — while a question
/// waits for the person at the dashboard or terminal.
class _Deadline {
  _Deadline(this._left, this._onTimeout) {
    _arm();
  }

  Duration _left;
  final void Function() _onTimeout;
  final _clock = Stopwatch();
  Timer? _timer;
  int _holds = 0;
  bool _over = false;

  void _arm() {
    _clock
      ..reset()
      ..start();
    _timer = Timer(_left, _onTimeout);
  }

  void hold() {
    if (_over || _holds++ > 0) return;
    _timer?.cancel();
    _clock.stop();
    _left -= _clock.elapsed;
    if (_left.isNegative) _left = Duration.zero;
  }

  void release() {
    if (_over || --_holds > 0) return;
    _arm();
  }

  void cancel() {
    _over = true;
    _timer?.cancel();
  }
}

/// Where an `auto:` action is: waiting out a burst of changes, running, and
/// what its last run covered.
class _AutoState {
  Timer? timer;

  /// Changes waiting for [timer]: ordinary ones, and ones from during the
  /// last run reported after it ([pendingOnce]).
  bool pending = false;
  bool pendingOnce = false;

  /// What changed, for the log line (up to [_noteLimit] paths kept).
  final Set<String> _paths = {};
  static const _noteLimit = 1000;

  void note(String path) {
    if (_paths.length < _noteLimit) _paths.add(path);
  }

  /// The first few changed paths, by name, and how many more.
  String get because {
    final paths = _paths.toList()..sort();
    final first = paths.take(3).join(', ');
    return paths.length > 3 ? '$first +${paths.length - 3}' : first;
  }

  /// Forget what was waiting, and its timer.
  void drop() {
    timer?.cancel();
    timer = null;
    pending = pendingOnce = false;
    _paths.clear();
  }

  /// The run in flight began; null while none is.
  DateTime? started;

  /// The run in flight is the once-more after a change during a run.
  bool once = false;

  /// A file changed during the run in flight.
  bool again = false;

  DateTime? lastStart;
  DateTime? lastEnd;
  bool lastWasOnce = false;
}

/// The most a batch of live output carries. A command that prints faster
/// than this loses the head of the batch on the way to dashboards (the run's
/// own output, at the end, still has its last [_outputLimit]).
const _liveBatchLimit = 64 * 1024;

/// A running command's output for dashboards, sent in batches: what came
/// within [_outputEvery] goes as one chunk — its tail, from a whole line and
/// after a mark on a line of its own, when it is over the limit
/// ([_liveBatchLimit] unless given). What waits for the next batch is held to
/// the tail too, so a command that prints fast can't grow it unbounded.
class LiveOutput {
  LiveOutput(this._send, {int limit = _liveBatchLimit}) : _limit = limit, _tail = _Tail(limit);

  final void Function(String chunk) _send;
  final int _limit;
  _Tail _tail;
  int _added = 0; // characters that came for the next batch, kept or not
  bool _midLine = false; // the last batch sent ended within a line
  Timer? _timer;

  /// Characters held for the next batch: at most twice the limit.
  int get pending => _tail.length;

  void add(String chunk) {
    _tail.add(chunk);
    _added += chunk.length;
    _timer ??= Timer(_outputEvery, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    var text = _tail.text;
    if (text.isEmpty) return;
    var skipped = _added - text.length;
    // Cut within a line: the tail starts at its next one.
    final cut = skipped > 0 && !_tail.atLineStart ? text.indexOf('\n') : -1;
    if (cut >= 0 && cut < text.length - 1) {
      skipped += cut + 1;
      text = text.substring(cut + 1);
    }
    _tail = _Tail(_limit);
    _added = 0;
    final out = skipped > 0 ? '${_midLine ? '\n' : ''}… $skipped characters skipped while streaming …\n$text' : text;
    _midLine = !out.endsWith('\n');
    _send(out);
  }
}

/// The last [_limit] characters of a stream of chunks.
class _Tail {
  _Tail([this._limit = _outputLimit]);

  final int _limit;
  final _buf = StringBuffer();
  String _before = ''; // the last character dropped from the head

  int get length => _buf.length;

  String add(String chunk) {
    _buf.write(chunk);
    if (_buf.length > _limit * 2) {
      final all = _buf.toString();
      _before = all[all.length - _limit - 1];
      _buf
        ..clear()
        ..write(all.substring(all.length - _limit));
    }
    return chunk;
  }

  String get text => _buf.length > _limit ? _buf.toString().substring(_buf.length - _limit) : '$_buf';

  /// [text] starts a line: nothing was cut before it, or what was ended one.
  bool get atLineStart {
    final all = '$_buf';
    final before = all.length > _limit ? all[all.length - _limit - 1] : _before;
    return before.isEmpty || before == '\n';
  }
}

String _clip(String s) {
  final t = s.trim();
  return t.length > 200 ? '${t.substring(0, 200)}…' : t;
}

Response _json(Object data, {int status = 200}) =>
    Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});
