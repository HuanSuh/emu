/// Asking while a command runs (`interactive: true` actions of dashboard
/// pages): the command prints one stdout line
///
///     ::emu-ask {"id": "force", "kind": "confirm", "title": "Overwrite 2 files?", "danger": true}
///
/// and emu takes it out of the output, asks — in the dashboard tab that
/// started the run, or the terminal of `emu run` — and writes the answer to
/// the command's stdin as one line: `{"id": "force", "value": true}`. No one
/// to answer, no answer in time, or a line emu can't read: `"value": null`.
///
/// What is asked is text only, cut to the sizes below: a question can't run
/// anything the action's own command couldn't, and the dialog says which
/// page and action asks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What starts an ask line.
const askMarker = '::emu-ask ';

/// An ask line longer than this is dropped (and answered null).
const askLineLimit = 64 * 1024;

const askKinds = {'confirm', 'prompt', 'choose'};

String? _clip(Object? v, int n) {
  if (v == null) return null;
  final s = v is String ? v : '$v';
  return s.length > n ? s.substring(0, n) : s;
}

/// The JSON after [askMarker] → (the question, or why it can't be asked).
/// The question holds only what a dialog shows, as text, cut to size:
/// `{id, kind, title, message?, detail?, danger, button, fields?, options?, multiple?}`.
/// [id] is kept even when the rest is unusable, for the null answer.
({Map<String, dynamic>? ask, Object? id, String? error}) parseAsk(String json) {
  Object? v;
  try {
    v = jsonDecode(json);
  } on FormatException {
    return (ask: null, id: null, error: 'not JSON');
  }
  if (v is! Map) return (ask: null, id: null, error: 'expected a JSON object');
  final rawId = v['id'];
  final id = rawId is String ? _clip(rawId, 200) : rawId is num || rawId is bool ? rawId : null;
  final kind = v['kind'];
  if (kind is! String || !askKinds.contains(kind)) {
    return (ask: null, id: id, error: 'kind must be confirm, prompt or choose (got ${jsonEncode(kind)})');
  }
  final ask = <String, dynamic>{
    'id': id,
    'kind': kind,
    'title': _clip(v['title'], 200) ?? switch (kind) { 'confirm' => 'Confirm?', 'prompt' => 'Input', _ => 'Choose' },
    'message': ?_clip(v['message'], 2000),
    'detail': ?_clip(v['detail'], 20000),
    'danger': v['danger'] == true,
    'button': _clip(v['button'], 40) ?? 'OK',
  };
  if (kind == 'prompt') {
    final seen = <String>{};
    final fields = [
      for (final f in (v['fields'] is List ? v['fields'] as List : const []).take(12))
        if (f is Map && f['name'] is String && (f['name'] as String).isNotEmpty && seen.add(_clip(f['name'], 100)!))
          {
            'name': _clip(f['name'], 100),
            'label': _clip(f['label'] ?? f['name'], 100),
            'default': _clip(f['default'], 2000) ?? '',
          },
    ];
    if (fields.isEmpty) return (ask: null, id: id, error: 'prompt needs fields: [{name, label?, default?}]');
    ask['fields'] = fields;
  }
  if (kind == 'choose') {
    final seen = <String>{};
    final options = [
      for (final raw in (v['options'] is List ? v['options'] as List : const []).take(200))
        if (raw is Map ? raw : {'value': raw} case final Map o)
          if (_optionValue(o['value']) case final value? when seen.add(jsonEncode(value)))
            {'value': value, 'label': _clip(o['label'] ?? value, 200)},
    ];
    if (options.isEmpty) return (ask: null, id: id, error: 'choose needs options: [{value, label?}]');
    ask['options'] = options;
    ask['multiple'] = v['multiple'] == true;
  }
  return (ask: ask, id: id, error: null);
}

Object? _optionValue(Object? v) => v is String ? _clip(v, 2000) : v is num || v is bool ? v : null;

/// An answer to [ask] as the command may get it: a confirm's bool, a
/// prompt's declared fields as text, a choose's value(s) among its options.
/// Anything else is null.
Object? checkAnswer(Map<String, dynamic> ask, Object? value) {
  switch (ask['kind']) {
    case 'confirm':
      return value is bool ? value : null;
    case 'prompt':
      if (value is! Map) return null;
      return {
        for (final f in (ask['fields'] as List).cast<Map>())
          '${f['name']}': _clip(value[f['name']], 2000) ?? '',
      };
    case 'choose':
      final allowed = {for (final o in (ask['options'] as List).cast<Map>()) jsonEncode(o['value']): o['value']};
      if (ask['multiple'] == true) {
        if (value is! List) return null;
        final picked = <String>{for (final x in value) if (allowed.containsKey(jsonEncode(x))) jsonEncode(x)};
        return [for (final k in picked) allowed[k]];
      }
      return allowed[jsonEncode(value)];
  }
  return null;
}

/// The answer line for the command's stdin.
String answerLine(Object? id, Object? value) => jsonEncode({'id': id, 'value': value});

/// Takes the ask lines out of a command's stdout as it comes. [add] returns
/// what is plain output, now: a line that can't be an ask goes through as
/// soon as that is clear, not when it ends. [onAsk] gets the JSON of each ask
/// line, or null for one over [askLineLimit] (dropped).
class AskLines {
  AskLines(this._onAsk);

  final void Function(String? json) _onAsk;

  /// The start of a line that may still turn out to be an ask.
  String _held = '';

  /// In a line already let through, or one being dropped.
  bool _passing = false, _dropping = false;

  String add(String chunk) {
    final out = StringBuffer();
    var i = 0;
    while (i < chunk.length) {
      final nl = chunk.indexOf('\n', i);
      final end = nl < 0 ? chunk.length : nl + 1;
      if (_passing || _dropping) {
        if (_passing) out.write(chunk.substring(i, end));
        if (nl >= 0) _passing = _dropping = false;
        i = end;
        continue;
      }
      final piece = _held + chunk.substring(i, nl < 0 ? chunk.length : nl);
      _held = '';
      i = end;
      final isAsk = piece.startsWith(askMarker);
      if (nl < 0) {
        if (!isAsk && !askMarker.startsWith(piece)) {
          out.write(piece);
          _passing = true;
        } else if (piece.length > askLineLimit) {
          _dropping = true;
          _onAsk(null);
        } else {
          _held = piece;
        }
      } else if (!isAsk) {
        out.write('$piece\n');
      } else {
        _onAsk(piece.length > askLineLimit ? null : piece.substring(askMarker.length).trimRight());
      }
    }
    return '$out';
  }

  /// What is left once stdout ends: the start of a line held back.
  String close() {
    final rest = _held;
    _held = '';
    return rest;
  }
}

/// Where `emu run` asks: only with someone at both ends — stdin and stderr
/// a terminal. Otherwise it doesn't offer to answer, and the command's
/// questions are answered null.
bool canAskInTerminal({required bool stdinTerminal, required bool stderrTerminal}) => stdinTerminal && stderrTerminal;

/// Asks [ask] on [err], reading answers from [readLine] (null: input ended
/// or the question went away). Resolves to the answer, or null.
Future<Object?> askInTerminal(Map<String, dynamic> ask, Map from,
    {required Future<String?> Function() readLine, required IOSink err}) async {
  final danger = ask['danger'] == true;
  err.writeln('');
  err.writeln('? ${from['page'] ?? ''} · ${from['action'] ?? ''} asks:');
  err.writeln('${danger ? '⚠ ' : ''}${ask['title']}');
  for (final k in ['message', 'detail']) {
    if (ask[k] case final String text when text.isNotEmpty) err.writeln('  ${text.replaceAll('\n', '\n  ')}');
  }
  switch (ask['kind']) {
    case 'confirm':
      err.write('${ask['button']}? [y/N] ');
      final line = await readLine();
      if (line == null) return null;
      return const {'y', 'yes'}.contains(line.trim().toLowerCase());
    case 'prompt':
      final values = <String, String>{};
      for (final f in (ask['fields'] as List).cast<Map>()) {
        final def = '${f['default'] ?? ''}';
        err.write('  ${f['label']}${def.isEmpty ? '' : ' [$def]'}: ');
        final line = await readLine();
        if (line == null) return null;
        values['${f['name']}'] = line.isEmpty ? def : line;
      }
      return values;
    case 'choose':
      final options = (ask['options'] as List).cast<Map>();
      final multiple = ask['multiple'] == true;
      for (final (i, o) in options.indexed) {
        err.writeln('  ${i + 1}) ${o['label']}');
      }
      while (true) {
        err.write(multiple ? 'pick 1-${options.length}, comma-separated (empty: none): ' : 'pick 1-${options.length} (empty: none): ');
        final line = await readLine();
        if (line == null || line.trim().isEmpty) return null;
        final picks = [for (final p in line.split(',')) int.tryParse(p.trim())];
        if (picks.every((n) => n != null && n >= 1 && n <= options.length) && (multiple || picks.length == 1)) {
          final values = [for (final n in picks.toSet()) options[n! - 1]['value']];
          return multiple ? values : values.single;
        }
        err.writeln('  ? not one of the numbers above');
      }
  }
  return null;
}
