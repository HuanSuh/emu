/// Find a widget on screen by its Semantics/Text/Tooltip label or its
/// `ValueKey`, and resolve it to a tap point — via the VM Service, same as
/// `input.dart`'s coordinate tap. This is what makes `emu tap --text "닫기"`
/// possible instead of requiring a screenshot and hand-measured pixels.
///
/// There's no `ext.flutter.inspector.*` service extension that returns "give
/// me the screen rect for the widget with this label" — the inspector
/// extensions expose diagnostics trees (for DevTools' widget inspector), not
/// hit-testable geometry, and none of them accept a label/key as a query. So
/// this takes the same approach as the rest of `input.dart`: evaluate a
/// expression on-device, in the framework's own library scope, that walks the
/// live `Element` tree (`WidgetsBinding.instance.rootElement`) — the same
/// walk the framework itself performs every frame — and for each match reads
/// its `RenderBox` geometry directly.
///
/// Only the top route's widgets count: a match is kept when every
/// `ModalRoute` around it is current (nested Navigators included), or when
/// no route is around it at all (`MaterialApp.builder`, an `OverlayEntry`).
/// A screen pushed over another, or a dialog over it, hides what's under it —
/// tapping there would land on the top screen instead. `allRoutes` keeps the
/// old whole-tree walk.
library;

import 'dart:collection';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'input.dart' show dartStringLiteral;

class LocateException implements Exception {
  LocateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One widget on screen that matched a `--text`/`--key`/`--type` query: its tap
/// point (physical pixels, the same space `emu tap <x> <y>` and `emu shot` use)
/// plus enough context (size, widget type) to tell matches apart. [dump] holds
/// the widget's `toString()` when the query asked for it, and is null otherwise.
class LocateMatch {
  LocateMatch(this.x, this.y, this.width, this.height, this.widgetType,
      [this.dump, this.partial = false]);
  final int x;
  final int y;
  final double width;
  final double height;
  final String widgetType;
  final String? dump;

  /// A `--text` match found only by the substring fallback (nothing matched
  /// exactly), so the caller can say it wasn't an exact hit.
  final bool partial;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'widgetType': widgetType,
        if (dump != null) 'dump': dump,
        if (partial) 'partial': true,
      };
}

/// What [locate] found: the matches on the top route, plus how many matched
/// only on routes covered by it ([covered], counted only when nothing on top
/// matched — that's when it explains a "no widget matches").
class LocateMatches extends UnmodifiableListView<LocateMatch> {
  LocateMatches(super.source, {this.covered = 0});
  final int covered;
}

/// Find every on-screen widget whose Semantics label, `Text` data (plain or
/// `Text.rich`), or `Tooltip` message equals [text] — or, when none does,
/// contains it, whitespace-normalized (marked [LocateMatch.partial]) — or, when [key] is given instead, whose
/// `ValueKey` renders to that string, or when [type] is given, whose runtime
/// type name equals it — and return each match's tap point.
///
/// Exactly one of [text]/[key]/[type] must be given. With [dump], each match
/// also carries the widget's `toString()`. Only the top route's widgets count
/// unless [allRoutes] (see the library doc).
Future<LocateMatches> locate(String wsUri,
    {String? text, String? key, String? type, bool dump = false, bool allRoutes = false}) async {
  assert(_exactlyOne(text, key, type), 'locate: give exactly one of text/key/type');
  final service = await vmServiceConnectUri(wsUri);
  try {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) throw LocateException('no isolate available');
    final isoId = isolates.first.id!;
    final iso = await service.getIsolate(isoId);
    final lib = (iso.libraries ?? const <LibraryRef>[])
        .firstWhere((l) => l.uri == _fwLib, orElse: () => LibraryRef(id: '', uri: '', name: ''));
    if (lib.id!.isEmpty) throw LocateException('framework library not loaded ($_fwLib)');

    final r = await service.evaluate(
        isoId, lib.id!, locateExpr(text: text, key: key, type: type, dump: dump, allRoutes: allRoutes));
    if (r is ErrorRef) throw LocateException('evaluate failed: ${r.message}');
    if (r is! InstanceRef) throw LocateException('unexpected evaluate result: ${r.runtimeType}');
    var raw = r.valueAsString ?? '';
    if (r.valueAsStringIsTruncated ?? false) {
      // Long match lists can exceed the VM's inline preview length; the full
      // object still holds the whole string.
      final full = await service.getObject(isoId, r.id!);
      if (full is Instance) raw = full.valueAsString ?? raw;
    }
    return parseLocateMatches(raw);
  } finally {
    await service.dispose();
  }
}

/// Pick the match to tap: the sole match, or [index] into several. Throws a
/// message with enough detail (count, `--index` hint) to fix the query.
LocateMatch pickMatch(LocateMatches matches, int? index, {required String query}) {
  if (matches.isEmpty) {
    throw LocateException(noMatchMessage(matches, query));
  }
  if (index != null) {
    if (index < 0 || index >= matches.length) {
      throw LocateException(
          '--index $index out of range: $query matched ${matches.length} widget(s) (0..${matches.length - 1})');
    }
    return matches[index];
  }
  if (matches.length > 1) {
    throw LocateException(
        '$query matched ${matches.length} widgets — pick one with --index 0..${matches.length - 1}');
  }
  return matches.single;
}

/// "no widget matches …", saying so when the query did match on covered
/// routes — the usual reason a widget that's "right there" isn't found.
/// [hint] is how to reach them, or null where there's no way (replay).
String noMatchMessage(LocateMatches matches, String query,
    {String? hint = 'use --all-routes'}) {
  final covered = matches.covered;
  if (covered == 0) return 'no widget matches $query';
  return 'no widget matches $query on the top route '
      '($covered on covered routes${hint == null ? '' : ' — $hint'})';
}

// --- expression builder (pure, unit-tested) ---------------------------------

/// The framework library whose scope this evaluates in — the one the
/// timeline's route watch uses (`route_watch.dart`): `binding.dart` doesn't
/// import `routes.dart`, so `ModalRoute` isn't visible there, while
/// `navigator.dart` has it next to `WidgetsBinding`/`Element`/`RenderBox`/
/// `Offset`/`ValueKey`.
const _fwLib = 'package:flutter/src/widgets/navigator.dart';

bool _exactlyOne(String? a, String? b, String? c) =>
    [a, b, c].where((v) => v != null).length == 1;

/// Build the on-device expression that walks the `Element` tree and returns
/// every match as `x|y|width|height|widgetType` records joined by `;` — plus a
/// sixth `|`-delimited field holding the widget's `toString()` when [dump] is
/// set (with `|`, `;` and newlines squashed to spaces so free text can't break
/// the record framing).
///
/// Unless [allRoutes], a match counts only on the top route (see the library
/// doc); when none does, the result is `!<n>` for the n that matched on
/// covered routes (empty when n is 0).
///
/// Built as an immediately-invoked closure — `evaluate` compiles a single
/// expression, not a statement list, and a closure literal called on the spot
/// is itself one expression. String concatenation (not interpolation) is used
/// throughout the on-device body so nothing here collides with this
/// function's own `${...}` host-side interpolation.
String locateExpr(
    {String? text, String? key, String? type, bool dump = false, bool allRoutes = false}) {
  assert(_exactlyOne(text, key, type), 'locateExpr: give exactly one of text/key/type');
  final matchCall = text != null
      ? '_emuMatchText(w, ${dartStringLiteral(text)}, loose)'
      : key != null
          ? '_emuMatchKey(w.key, ${dartStringLiteral(key)})'
          : '_emuMatchType(w, ${dartStringLiteral(type!)})';
  return '(() {'
      // Exact first; [loose] is the fallback pass, run only when the exact
      // pass found nothing: whitespace-normalized substring, so a label
      // inside a longer/merged one (`Row(Checkbox, Text)`, a trailing space,
      // a line break) still resolves.
      'bool _emuMatchText(Widget w, String want, bool loose) {'
      'final d = w as dynamic;'
      'final t = w.runtimeType.toString();'
      'bool hit(Object? s) {'
      'if (s is! String) return false;'
      'if (!loose) return s == want;'
      'String n(String x) => x.replaceAll(RegExp(r"\\s+"), " ").trim();'
      'final nw = n(want);'
      'return nw.isNotEmpty && n(s).contains(nw);'
      '}'
      'try {'
      'if (t == "Text") return d.data == want || hit(d.data ?? d.textSpan?.toPlainText());'
      'if (t == "Semantics") return d.properties.label == want || hit(d.properties.label);'
      'if (t == "Tooltip") return d.message == want || hit(d.message);'
      '} catch (_) {}'
      'return false;'
      '}'
      'bool _emuMatchKey(Key? k, String want) {'
      'return k is ValueKey && k.value.toString() == want;'
      '}'
      'bool _emuMatchType(Widget w, String want) {'
      'return w.runtimeType.toString() == want;'
      '}'
      '${allRoutes ? '' : _onTopSrc}'
      'final out = StringBuffer();'
      'var loose = false;'
      'var hid = 0;'
      'void visit(Element e) {'
      'final w = e.widget;'
      'if ($matchCall) {'
      'final ro = e.renderObject;'
      'if (ro is RenderBox && ro.attached && ro.hasSize) {'
      '${allRoutes ? '' : 'if (!_emuOnTop(e)) { hid++; } else '}'
      'try {'
      'final c = ro.localToGlobal(ro.size.center(Offset.zero));'
      'final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;'
      // Computed before any `out.write` for this match: if `w.toString()`
      // throws, the catch below discards the whole record cleanly instead of
      // leaving a partial write in `out` for a match that never completes.
      '${dump ? _dumpVarSrc : ''}'
      'if (out.isNotEmpty) out.write(";");'
      'out.write((c.dx * dpr).toString());'
      'out.write("|");'
      'out.write((c.dy * dpr).toString());'
      'out.write("|");'
      'out.write(ro.size.width.toString());'
      'out.write("|");'
      'out.write(ro.size.height.toString());'
      'out.write("|");'
      'out.write(w.runtimeType.toString());'
      '${dump ? _dumpFieldSrc : ''}'
      '} catch (_) {}'
      '}'
      '}'
      'e.visitChildren(visit);'
      '}'
      'final root = WidgetsBinding.instance.rootElement;'
      'if (root != null) visit(root);'
      // The loose pass counts its own covered matches, but an exact count
      // from the first pass is the better hint, so it wins.
      '${text != null ? 'if (out.isEmpty && root != null) { final exactHid = hid; hid = 0; loose = true; visit(root); if (out.isNotEmpty) return "~" + out.toString(); if (exactHid > 0) hid = exactHid; }' : ''}'
      'if (out.isEmpty && hid > 0) return "!" + hid.toString();'
      'return out.toString();'
      '})()';
}

/// `_emuOnTop(e)`: is every `ModalRoute` around [e] current? Starts at the
/// route nearest [e], then the route around that route's Navigator, and so
/// on out — an inner route can be its Navigator's current while the screen
/// holding that Navigator is covered. No route at all (an `OverlayEntry`,
/// `MaterialApp.builder`) is on top.
///
/// Public API only (`ModalRoute.of`, `isCurrent`, `navigator`) — no private
/// widget names. `ModalRoute.of` registers its context as a dependent of the
/// route, so it's asked of the render-object element under the context (the
/// one `Element.renderObject` would find, still inside the same route): when
/// the route later changes, that element just re-applies its own widget to
/// its render object — no user `build()`, no `didChangeDependencies`.
const _onTopSrc = 'bool _emuOnTop(Element e) {'
    'Element? box(Element x) {'
    'Element? f;'
    'void down(Element y) {'
    'if (f != null) return;'
    'if (y is RenderObjectElement) { f = y; return; }'
    'y.visitChildren(down);'
    '}'
    'down(x);'
    'return f;'
    '}'
    'var at = box(e);'
    'while (at != null) {'
    'final r = ModalRoute.of(at);'
    'if (r == null) return true;'
    'if (!r.isCurrent) return false;'
    'final n = r.navigator;'
    'if (n == null || !n.mounted) return true;'
    'at = box(n.context as Element);'
    '}'
    'return true;'
    '}';

/// Evaluates `w.toString()` into a local var, under `--dump`, before any part
/// of the match record is written — so a throwing `toString()` override is
/// caught before `out` holds any partial data for this match (see
/// `_dumpFieldSrc`, which writes this value). `toString()` is free text, so
/// the record/field delimiters (and newlines, which would wreck the
/// one-line-per-match rendering) are squashed to spaces on-device, before
/// they can be mistaken for framing.
const _dumpVarSrc = 'final dumpStr = w.toString()'
    '.replaceAll("|", " ")'
    '.replaceAll(";", " ")'
    '.replaceAll("\\n", " ")'
    '.replaceAll("\\r", " ");';

/// The extra `|<dumpStr>` field appended per match under `--dump`, using the
/// value `_dumpVarSrc` already computed and validated.
const _dumpFieldSrc = 'out.write("|");'
    'out.write(dumpStr);';

/// Parse the `x|y|width|height|widgetType[|dump]` records `locateExpr` returns.
/// Pure, unit-tested against malformed/empty input separately from any live
/// VM Service connection.
/// A leading `~` marks matches from the substring fallback; `!<n>` is no match
/// on the top route but n on covered ones.
LocateMatches parseLocateMatches(String raw) {
  if (raw.startsWith('!')) {
    return LocateMatches(const [], covered: int.tryParse(raw.substring(1)) ?? 0);
  }
  final partial = raw.startsWith('~');
  if (partial) raw = raw.substring(1);
  if (raw.isEmpty) return LocateMatches(const []);
  final out = <LocateMatch>[];
  for (final rec in raw.split(';')) {
    final f = rec.split('|');
    if (f.length != 5 && f.length != 6) continue;
    final x = double.tryParse(f[0]);
    final y = double.tryParse(f[1]);
    final w = double.tryParse(f[2]);
    final h = double.tryParse(f[3]);
    if (x == null || y == null || w == null || h == null) continue;
    out.add(LocateMatch(
        x.round(), y.round(), w, h, f[4], f.length == 6 ? f[5] : null, partial));
  }
  return LocateMatches(out);
}
