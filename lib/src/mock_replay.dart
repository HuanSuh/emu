/// `emu mock use <name> --replay` — a scenario's way back to its screen.
///
/// A scenario file holds rules only, and an older emu rewrites it as a plain
/// list, so what gets the app to the screen lives next to it, in the optional
/// `mocks/<name>.replay.json` (a name older versions skip without a word):
///
/// ```json
/// {
///   "entry": { "url": "myapp://orders/1" },
///   "steps": [
///     { "tap": { "text": "Pay", "index": 0 } },
///     { "tap": { "key": "card-field" } },
///     { "text": "4242", "append": false },
///     { "settle": { "timeoutMs": 10000 } }
///   ]
/// }
/// ```
///
/// [runReplay] walks it through a [ReplayDevice]: the entry link, the steps,
/// a last settle. A `tap` waits for its widget to appear; the first step that
/// fails ends the run.
library;

import 'dart:async';

import 'locate.dart';

sealed class ReplayStep {
  const ReplayStep();
  String get kind;
  Map<String, dynamic> toJson();
}

/// Tap the widget with this label or key; [index] picks one of several.
class ReplayTap extends ReplayStep {
  const ReplayTap({this.text, this.key, this.index});
  final String? text;
  final String? key;
  final int? index;

  @override
  String get kind => 'tap';
  String get query => text != null ? 'text "$text"' : 'key "$key"';

  @override
  Map<String, dynamic> toJson() => {
        'tap': {'text': ?text, 'key': ?key, 'index': ?index}
      };
}

/// Type into the focused field — a `tap` on the field comes first.
class ReplayText extends ReplayStep {
  const ReplayText(this.text, {this.append = false});
  final String text;
  final bool append;

  @override
  String get kind => 'text';

  @override
  Map<String, dynamic> toJson() => {'text': text, if (append) 'append': true};
}

/// Wait for the app to go quiet. An app that never does is not a failure.
class ReplaySettle extends ReplayStep {
  const ReplaySettle({this.timeoutMs});
  final int? timeoutMs;

  /// What `emu settle` waits by default.
  static const defaultTimeout = Duration(seconds: 10);

  /// The longest a file may ask for, so a replay stays bounded.
  static const maxTimeoutMs = 60000;

  Duration get timeout => timeoutMs == null ? defaultTimeout : Duration(milliseconds: timeoutMs!);

  @override
  String get kind => 'settle';

  @override
  Map<String, dynamic> toJson() => {
        'settle': {'timeoutMs': ?timeoutMs}
      };
}

/// A `<name>.replay.json`.
class MockReplay {
  const MockReplay({this.url, this.steps = const []});
  final String? url;
  final List<ReplayStep> steps;

  Map<String, dynamic> toJson() => {
        if (url != null) 'entry': {'url': url},
        'steps': [for (final s in steps) s.toJson()],
      };

  /// One line for `emu mock`.
  String get describe => [url ?? '(no entry)', '${steps.length} step(s)'].join(' + ');
}

/// [raw] as a replay, or null with [problems] said. Anything not understood
/// is a problem: a step this version doesn't know must not be skipped, or
/// the replay would carry on from the wrong screen.
MockReplay? parseReplay(Object? raw, String at, List<String> problems) {
  final before = problems.length;
  if (raw is! Map) {
    problems.add('$at: expected { entry?: {url}, steps?: [...] }');
    return null;
  }
  for (final key in raw.keys) {
    if (key != 'entry' && key != 'steps') problems.add('$at: unknown field "$key"');
  }
  String? url;
  final entry = raw['entry'];
  if (entry != null) {
    final u = entry is Map ? entry['url'] : null;
    if (u is! String || Uri.tryParse(u.trim())?.hasScheme != true) {
      problems.add('$at.entry: expected { url: <deep link like myapp://orders/1> }');
    } else {
      url = u.trim();
    }
  }
  final steps = <ReplayStep>[];
  final rawSteps = raw['steps'];
  if (rawSteps != null && rawSteps is! List) problems.add('$at.steps: expected a list');
  if (rawSteps is List) {
    for (var i = 0; i < rawSteps.length; i++) {
      final step = _parseStep(rawSteps[i], '$at.steps[$i]', problems);
      if (step != null) steps.add(step);
    }
  }
  if (problems.length > before) return null;
  if (url == null && steps.isEmpty) {
    problems.add('$at: give entry.url, steps or both');
    return null;
  }
  return MockReplay(url: url, steps: steps);
}

ReplayStep? _parseStep(Object? raw, String at, List<String> problems) {
  const usage = 'expected one of { tap: {text | key, index?} }, { text, append? }, { settle: {timeoutMs?} }';
  if (raw is! Map) {
    problems.add('$at: $usage');
    return null;
  }
  final kinds = raw.keys.where((k) => k != 'append').toList();
  if (kinds.length != 1) {
    problems.add('$at: $usage');
    return null;
  }
  if (raw.containsKey('append') && kinds.single != 'text') {
    problems.add('$at.append: only a text step takes it');
    return null;
  }
  final value = raw[kinds.single];
  switch (kinds.single) {
    case 'tap':
      if (value is! Map || value.keys.any((k) => !const {'text', 'key', 'index'}.contains(k))) {
        problems.add('$at.tap: expected { text | key, index? }');
        return null;
      }
      final text = value['text'], key = value['key'], index = value['index'];
      final given = [text, key].whereType<String>().where((s) => s.isNotEmpty).length;
      if (given != 1 || (text != null && text is! String) || (key != null && key is! String)) {
        problems.add('$at.tap: give text or key, not both');
        return null;
      }
      if (index != null && (index is! int || index < 0)) {
        problems.add('$at.tap.index: expected 0 or more');
        return null;
      }
      return ReplayTap(text: text as String?, key: key as String?, index: index as int?);
    case 'text':
      final append = raw['append'] ?? false;
      if (value is! String || value.isEmpty) {
        problems.add('$at.text: expected the text to type');
        return null;
      }
      if (append is! bool) {
        problems.add('$at.append: expected true or false');
        return null;
      }
      return ReplayText(value, append: append);
    case 'settle':
      final ms = value is Map ? value['timeoutMs'] : null;
      if (value is! Map ||
          value.keys.any((k) => k != 'timeoutMs') ||
          (ms != null && (ms is! int || ms <= 0 || ms > ReplaySettle.maxTimeoutMs))) {
        problems.add('$at.settle: expected { timeoutMs?: 1..${ReplaySettle.maxTimeoutMs} }');
        return null;
      }
      return ReplaySettle(timeoutMs: ms as int?);
    default:
      problems.add('$at: unknown step "${kinds.single}" — $usage');
      return null;
  }
}

/// What a replay does to the app — a seam for tests.
abstract interface class ReplayDevice {
  /// Open the deep link; the reason it couldn't, or null.
  Future<String?> openUrl(String url);
  Future<List<LocateMatch>> locate({String? text, String? key});
  Future<void> tap(int x, int y);
  Future<void> enterText(String text, {required bool append});

  /// Whether the app went quiet within [timeout].
  Future<bool> settle(Duration timeout);
}

/// One line of a run. [step] is its place in the file's `steps`, null for
/// the entry link and the last settle.
class ReplayResult {
  ReplayResult(this.step, this.kind, this.ok, this.detail);
  final int? step;
  final String kind;
  final bool ok;
  final String detail;

  Map<String, dynamic> toJson() => {'i': step, 'kind': kind, 'ok': ok, 'detail': detail};
}

/// The longest a whole run takes before it stops at the next step. The CLI's
/// wait for the answer is longer than this plus one step.
const replayLimit = Duration(minutes: 3);

/// How long a `tap` waits for its widget to appear.
const replayTapWait = Duration(seconds: 10);

/// How long each input waits for the app to go quiet, so the next step sees
/// the new screen rather than the transition. Best effort.
const _afterInput = Duration(seconds: 3);

/// A device call that never answers (a hung VM connection) ends in this.
const _callLimit = Duration(seconds: 30);

/// Run [replay] on [device]; the result of each thing done, the last one
/// failed when the run stopped early. Never throws.
Future<List<ReplayResult>> runReplay(
  MockReplay replay,
  ReplayDevice device, {
  Duration tapWait = replayTapWait,
  Duration retry = const Duration(milliseconds: 250),
  Duration limit = replayLimit,
}) async {
  final out = <ReplayResult>[];
  final clock = Stopwatch()..start();

  Future<bool> run(int? i, String kind, Future<String> Function() action) async {
    if (clock.elapsed > limit) {
      out.add(ReplayResult(i, kind, false, 'replay stopped: over ${limit.inMinutes} minutes'));
      return false;
    }
    try {
      out.add(ReplayResult(i, kind, true, await action()));
      return true;
    } catch (e) {
      out.add(ReplayResult(i, kind, false, '$e'));
      return false;
    }
  }

  Future<void> quiet() =>
      _settle(device, _afterInput).catchError((Object _) => false).then((_) {});

  final url = replay.url;
  if (url != null) {
    final opened = await run(null, 'entry', () async {
      final error = await device.openUrl(url).timeout(_callLimit);
      if (error != null) throw LocateException(error);
      return url;
    });
    if (!opened) return out;
  }
  for (var i = 0; i < replay.steps.length; i++) {
    final step = replay.steps[i];
    final done = await run(i, step.kind, () async {
      switch (step) {
        case ReplayTap():
          final detail = await _tap(step, device, tapWait, retry);
          await quiet();
          return detail;
        case ReplayText():
          await device.enterText(step.text, append: step.append).timeout(_callLimit);
          await quiet();
          return step.append ? 'appended ${step.text.length} character(s)' : 'typed ${step.text.length} character(s)';
        case ReplaySettle():
          return await _settle(device, step.timeout) ? 'settled' : 'still busy after ${step.timeout.inMilliseconds}ms';
      }
    });
    if (!done) return out;
  }
  await run(null, 'settle', () async {
    const wait = ReplaySettle.defaultTimeout;
    return await _settle(device, wait) ? 'settled' : 'still busy after ${wait.inMilliseconds}ms';
  });
  return out;
}

/// [device]'s settle, with an outer bound: its own timeout only covers the
/// polling, and the first call after a launch can take far longer.
Future<bool> _settle(ReplayDevice device, Duration timeout) =>
    device.settle(timeout).timeout(timeout + const Duration(seconds: 2), onTimeout: () => false);

/// Find the widget, waiting up to [wait] for it to appear, and tap it once.
/// Only finding is retried: a tap that went wrong may still have landed.
Future<String> _tap(ReplayTap step, ReplayDevice device, Duration wait, Duration retry) async {
  final clock = Stopwatch()..start();
  final index = step.index;
  while (true) {
    List<LocateMatch>? matches;
    String why;
    try {
      matches = await device.locate(text: step.text, key: step.key).timeout(_callLimit);
      why = matches.isEmpty
          ? 'no widget matches ${step.query}'
          : 'index $index out of range: ${step.query} matched ${matches.length} widget(s)';
    } catch (e) {
      why = '$e'; // the app may be mid-restart; it counts as not there yet
    }
    if (matches != null && matches.isNotEmpty && (index == null || index < matches.length)) {
      final m = pickMatch(matches, index, query: step.query); // several and no index: the file must say
      await device.tap(m.x, m.y).timeout(_callLimit);
      return 'tapped ${m.widgetType} at ${m.x},${m.y}${m.partial ? ' (partial match)' : ''}';
    }
    if (clock.elapsed >= wait) throw LocateException('$why (waited ${wait.inMilliseconds}ms)');
    await Future<void>.delayed(retry);
  }
}

/// What failed, or null — for the `error` next to the results.
String? replayFailure(List<ReplayResult> results) {
  final r = results.where((r) => !r.ok).firstOrNull;
  return r == null ? null : '${replayLabel(r.step, r.kind)}: ${r.detail}';
}

/// Where a result belongs in the file: `steps[2] tap`, `entry`.
String replayLabel(int? step, String kind) => step == null ? kind : 'steps[$step] $kind';

/// The results (`toJson` shape) as `emu mock use --replay` prints them.
List<String> replayLines(List<Map<String, dynamic>> results) => [
      for (final r in results)
        '${r['ok'] == true ? '✓' : '✗'} ${replayLabel(r['i'] as int?, r['kind'] as String)}  ${r['detail']}',
    ];
