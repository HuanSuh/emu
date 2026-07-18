/// Synthetic input via the VM Service — one backend for Android and iOS.
///
/// Rather than shell out to `adb` (Android-only, ASCII-only text) or `simctl`
/// (no input at all), this drives the running Flutter framework directly: it
/// evaluates expressions that dispatch pointer events and update the focused
/// text field, exactly as the engine does for real user input. That makes
/// tap/swipe/text work identically on both platforms, and lets text carry
/// Unicode (한글, emoji) that `adb input text` cannot.
///
/// Coordinates are **physical pixels** — the same space `emu shot` captures in —
/// and are converted to the framework's logical pixels on-device by dividing by
/// the view's devicePixelRatio, so callers never deal with dpr.
library;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class InputException implements Exception {
  InputException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The framework library whose scope resolves WidgetsBinding/PointerEvent/etc.
/// Targeting the framework (not the app) means this never depends on what the
/// user's app happens to import.
const _fwLib = 'package:flutter/src/widgets/binding.dart';

/// editable_text.dart scope resolves EditableTextState/TextEditingValue for text.
const _edLib = 'package:flutter/src/widgets/editable_text.dart';

/// On-device expression for the view's device pixel ratio.
const _dpr = 'WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio';

/// Tap at physical ([x], [y]). Dispatches a down/up pair at the logical point.
Future<void> runTap(String wsUri, int x, int y) async {
  await _withFramework(wsUri, (s, iso, fw) async {
    await _eval(s, iso, fw, tapExpr(x, y));
  });
}

/// Swipe/scroll from physical ([x1],[y1]) to ([x2],[y2]) over [durationMs].
Future<void> runSwipe(String wsUri, int x1, int y1, int x2, int y2,
    {int durationMs = 300}) async {
  await _withFramework(wsUri, (s, iso, fw) async {
    await _eval(s, iso, fw, swipeExpr(x1, y1, x2, y2, durationMs: durationMs));
  });
}

/// Type [text] into the focused text field. Tap the field first — this targets
/// whatever currently holds focus. With [append], the text is added after the
/// field's current contents instead of replacing them.
Future<void> runText(String wsUri, String text, {bool append = false}) async {
  await _withText(wsUri, (s, iso, ed) async {
    if (!await _hasFocusedField(s, iso, ed)) {
      throw InputException('no focused text field — tap a field first');
    }
    final full = append ? (await _focusedText(s, iso, ed)) + text : text;
    final r = await _eval(s, iso, ed, textExpr(full));
    if (r == null) throw InputException('text injection failed');
  });
}

// --- expression builders (pure, unit-tested) --------------------------------

/// Evaluatable expression that dispatches a down/up tap at physical ([x], [y]).
String tapExpr(int x, int y) =>
    'WidgetsBinding.instance'
    '..handlePointerEvent(PointerDownEvent(position: ${_offset(x, y)}))'
    '..handlePointerEvent(PointerUpEvent(position: ${_offset(x, y)}))';

/// Evaluatable expression for a swipe. Move events carry delta + a stable
/// pointer id + timestamps, all of which the scroll gesture recognizer needs —
/// position alone does not scroll.
String swipeExpr(int x1, int y1, int x2, int y2,
    {int durationMs = 300, int steps = 10}) {
  final dxStep = (x2 - x1) / steps;
  final dyStep = (y2 - y1) / steps;
  final tStep = (durationMs / steps).round();
  final moves = StringBuffer();
  for (var i = 1; i <= steps; i++) {
    moves.write(
        '..handlePointerEvent(PointerMoveEvent(pointer: 1, '
        'timeStamp: Duration(milliseconds: ${tStep * i}), '
        'position: ${_offsetD(x1 + dxStep * i, y1 + dyStep * i)}, '
        'delta: ${_offsetD(dxStep, dyStep)}))');
  }
  return 'WidgetsBinding.instance'
      '..handlePointerEvent(PointerDownEvent(pointer: 1, '
      'timeStamp: Duration.zero, position: ${_offset(x1, y1)}))'
      '$moves'
      '..handlePointerEvent(PointerUpEvent(pointer: 1, '
      'timeStamp: Duration(milliseconds: $durationMs), position: ${_offset(x2, y2)}))';
}

/// Evaluatable expression that sets the focused field's value to [full].
/// Cascade (`..`) returns the target so the trailing `.runtimeType` compiles —
/// `updateEditingValue` returns void, so a direct `.toString()` would not.
String textExpr(String full) {
  final lit = dartStringLiteral(full);
  final offset = full.length; // UTF-16 units, matching on-device String.length
  return '(FocusManager.instance.primaryFocus!.context!'
      '.findAncestorStateOfType<EditableTextState>()!'
      '..updateEditingValue(TextEditingValue(text: $lit, '
      'selection: TextSelection.collapsed(offset: $offset)))).runtimeType.toString()';
}

// --- helpers ---------------------------------------------------------------

String _offset(int x, int y) => 'Offset($x / ($_dpr), $y / ($_dpr))';
String _offsetD(double x, double y) => 'Offset($x / ($_dpr), $y / ($_dpr))';

Future<bool> _hasFocusedField(VmService s, String iso, String lib) async {
  final r = await _eval(s, iso, lib,
      '(FocusManager.instance.primaryFocus?.context'
      '?.findAncestorStateOfType<EditableTextState>() != null).toString()');
  return r == 'true';
}

Future<String> _focusedText(VmService s, String iso, String lib) async {
  final r = await _eval(s, iso, lib,
      'FocusManager.instance.primaryFocus!.context!'
      '.findAncestorStateOfType<EditableTextState>()!.textEditingValue.text');
  return r ?? '';
}

/// Connect, resolve the isolate + framework library, run [body], always dispose.
Future<void> _withFramework(
    String wsUri, Future<void> Function(VmService, String iso, String lib) body) async {
  await _connect(wsUri, _fwLib, body);
}

Future<void> _withText(
    String wsUri, Future<void> Function(VmService, String iso, String lib) body) async {
  await _connect(wsUri, _edLib, body);
}

Future<void> _connect(String wsUri, String libUri,
    Future<void> Function(VmService, String iso, String lib) body) async {
  final s = await vmServiceConnectUri(wsUri);
  try {
    final vm = await s.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) throw InputException('no isolate available');
    final isoId = isolates.first.id!;
    final iso = await s.getIsolate(isoId);
    final lib = (iso.libraries ?? const <LibraryRef>[])
        .firstWhere((l) => l.uri == libUri, orElse: () => LibraryRef(id: '', uri: '', name: ''));
    if (lib.id!.isEmpty) {
      throw InputException('framework library not loaded ($libUri)');
    }
    await body(s, isoId, lib.id!);
  } finally {
    await s.dispose();
  }
}

/// Evaluate [expr] in [libId]'s scope; returns the string value or null.
/// Throws [InputException] on a compilation/runtime error from the VM.
Future<String?> _eval(VmService s, String isoId, String libId, String expr) async {
  final r = await s.evaluate(isoId, libId, expr);
  if (r is InstanceRef) return r.valueAsString;
  if (r is ErrorRef) throw InputException('evaluate failed: ${r.message}');
  throw InputException('unexpected evaluate result: ${r.runtimeType}');
}

/// Render [s] as a double-quoted Dart string literal safe to embed in an
/// evaluated expression. Unicode is kept verbatim (the VM accepts UTF-8 source).
/// Pure, so it's unit-tested against injection-prone inputs.
String dartStringLiteral(String s) {
  final b = StringBuffer('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x5C: // backslash
        b.write(r'\\');
      case 0x22: // "
        b.write(r'\"');
      case 0x24: // $
        b.write(r'\$');
      case 0x0A: // newline
        b.write(r'\n');
      case 0x0D: // carriage return
        b.write(r'\r');
      case 0x09: // tab
        b.write(r'\t');
      default:
        b.writeCharCode(rune);
    }
  }
  b.write('"');
  return b.toString();
}
