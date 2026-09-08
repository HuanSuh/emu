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
library;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'input.dart' show dartStringLiteral;

class LocateException implements Exception {
  LocateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One widget on screen that matched a `--text`/`--key` query: its tap point
/// (physical pixels, the same space `emu tap <x> <y>` and `emu shot` use) plus
/// enough context (size, widget type) to tell matches apart.
class LocateMatch {
  LocateMatch(this.x, this.y, this.width, this.height, this.widgetType);
  final int x;
  final int y;
  final double width;
  final double height;
  final String widgetType;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'widgetType': widgetType,
      };
}

/// Find every on-screen widget whose Semantics label, `Text` data, or
/// `Tooltip` message equals [text] — or, when [key] is given instead, whose
/// `ValueKey` renders to that string — and return each match's tap point.
///
/// Exactly one of [text]/[key] must be given.
Future<List<LocateMatch>> locate(String wsUri, {String? text, String? key}) async {
  assert((text == null) != (key == null), 'locate: give exactly one of text/key');
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

    final r = await service.evaluate(isoId, lib.id!, locateExpr(text: text, key: key));
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
LocateMatch pickMatch(List<LocateMatch> matches, int? index, {required String query}) {
  if (matches.isEmpty) {
    throw LocateException('no widget matches $query');
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

// --- expression builder (pure, unit-tested) ---------------------------------

/// The framework library whose scope this evaluates in — same one `input.dart`
/// uses for tap/swipe, so `WidgetsBinding`/`Element`/`RenderBox`/`Offset`/
/// `ValueKey` are all already resolvable without extra imports.
const _fwLib = 'package:flutter/src/widgets/binding.dart';

/// Build the on-device expression that walks the `Element` tree and returns
/// every match as `x|y|width|height|widgetType` records joined by `;`.
///
/// Built as an immediately-invoked closure — `evaluate` compiles a single
/// expression, not a statement list, and a closure literal called on the spot
/// is itself one expression. String concatenation (not interpolation) is used
/// throughout the on-device body so nothing here collides with this
/// function's own `${...}` host-side interpolation.
String locateExpr({String? text, String? key}) {
  assert((text == null) != (key == null), 'locateExpr: give exactly one of text/key');
  final matchCall = text != null
      ? '_emuMatchText(w, ${dartStringLiteral(text)})'
      : '_emuMatchKey(w.key, ${dartStringLiteral(key!)})';
  return '(() {'
      'bool _emuMatchText(Widget w, String want) {'
      'final d = w as dynamic;'
      'final t = w.runtimeType.toString();'
      'try {'
      'if (t == "Text") return d.data == want;'
      'if (t == "Semantics") return d.properties.label == want;'
      'if (t == "Tooltip") return d.message == want;'
      '} catch (_) {}'
      'return false;'
      '}'
      'bool _emuMatchKey(Key? k, String want) {'
      'return k is ValueKey && k.value.toString() == want;'
      '}'
      'final out = StringBuffer();'
      'void visit(Element e) {'
      'final w = e.widget;'
      'if ($matchCall) {'
      'final ro = e.renderObject;'
      'if (ro is RenderBox && ro.attached && ro.hasSize) {'
      'try {'
      'final c = ro.localToGlobal(ro.size.center(Offset.zero));'
      'final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;'
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
      '} catch (_) {}'
      '}'
      '}'
      'e.visitChildren(visit);'
      '}'
      'final root = WidgetsBinding.instance.rootElement;'
      'if (root != null) visit(root);'
      'return out.toString();'
      '})()';
}

/// Parse the `x|y|width|height|widgetType` records `locateExpr` returns.
/// Pure, unit-tested against malformed/empty input separately from any live
/// VM Service connection.
List<LocateMatch> parseLocateMatches(String raw) {
  if (raw.isEmpty) return const [];
  final out = <LocateMatch>[];
  for (final rec in raw.split(';')) {
    final f = rec.split('|');
    if (f.length != 5) continue;
    final x = double.tryParse(f[0]);
    final y = double.tryParse(f[1]);
    final w = double.tryParse(f[2]);
    final h = double.tryParse(f[3]);
    if (x == null || y == null || w == null || h == null) continue;
    out.add(LocateMatch(x.round(), y.round(), w, h, f[4]));
  }
  return out;
}
