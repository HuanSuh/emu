/// VM Service "logpoint" probe: set a breakpoint at file:line, and each time it
/// hits, evaluate capture expressions in the paused frame, record them, and
/// immediately resume. This reads variable state directly from the running app
/// — a level deeper than logs — without leaving the isolate paused.
///
/// emu already captures the app's `vmServiceUri`; this connects a second client
/// to it (multiple clients are allowed) and drives the standard debug protocol.
library;

import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class ProbeException implements Exception {
  ProbeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One breakpoint hit: the captured expression values at that moment.
class ProbeHit {
  ProbeHit(this.file, this.line, this.values, this.at);
  final String file;
  final int line;
  final Map<String, String> values;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'file': file,
        'line': line,
        'values': values,
        'at': at.toIso8601String(),
      };
}

/// Extract the `name:` field from a pubspec.yaml's contents.
String? packageNameFromPubspec(String content) {
  for (final raw in content.split('\n')) {
    final m = RegExp(r'^name:\s*(\S+)').firstMatch(raw.trim());
    if (m != null) return m.group(1);
  }
  return null;
}

/// Pick the loaded script URI that best matches a user-supplied [file] path.
///
/// App code under `lib/` is loaded as `package:<pkg>/<path-without-lib>`, so we
/// try the exact package URI first, then a path suffix, then the basename.
String? matchScriptUri(List<String> uris, String file, String? packageName) {
  final rel = file.replaceAll('\\', '/');
  if (packageName != null && rel.startsWith('lib/')) {
    final pkgUri = 'package:$packageName/${rel.substring(4)}';
    if (uris.contains(pkgUri)) return pkgUri;
  }
  final afterLib = rel.startsWith('lib/') ? rel.substring(4) : rel;
  for (final u in uris) {
    if (u.endsWith('/$afterLib') || u == afterLib) return u;
  }
  final base = rel.split('/').last;
  for (final u in uris) {
    if (u.endsWith('/$base')) return u;
  }
  return null;
}

/// Set a logpoint at [file]:[line], capture [capture] expressions on each hit,
/// auto-resume, and return up to [count] hits (or whatever arrived before
/// [timeout]). [onHit] is called as each hit is captured (for live streaming).
Future<List<ProbeHit>> runProbe({
  required String wsUri,
  required String pubspecContent,
  required String file,
  required int line,
  required List<String> capture,
  int count = 1,
  Duration timeout = const Duration(seconds: 10),
  void Function(ProbeHit)? onHit,
}) async {
  final service = await vmServiceConnectUri(wsUri);
  try {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const [];
    if (isolates.isEmpty) throw ProbeException('no isolate available');
    final isolateId = isolates.first.id!;

    final pkg = packageNameFromPubspec(pubspecContent);
    final scriptList = await service.getScripts(isolateId);
    final uris = [for (final s in scriptList.scripts ?? <ScriptRef>[]) s.uri!];
    final targetUri = matchScriptUri(uris, file, pkg);
    if (targetUri == null) {
      throw ProbeException('no loaded script matches "$file"');
    }
    final scriptRef = scriptList.scripts!.firstWhere((s) => s.uri == targetUri);

    final Breakpoint bp;
    try {
      bp = await service.addBreakpoint(isolateId, scriptRef.id!, line);
    } catch (e) {
      throw ProbeException('could not set breakpoint at $file:$line ($e)');
    }

    final hits = <ProbeHit>[];
    final done = Completer<void>();
    await service.streamListen(EventStreams.kDebug);
    final sub = service.onDebugEvent.listen((event) async {
      if (event.kind != EventKind.kPauseBreakpoint) return;
      final isOurs = event.pauseBreakpoints?.any((b) => b.id == bp.id) ?? false;
      if (!isOurs) return;
      final iso = event.isolate?.id ?? isolateId;
      final values = <String, String>{};
      for (final expr in capture) {
        values[expr] = await _evaluate(service, iso, expr);
      }
      final hit = ProbeHit(file, line, values, DateTime.now());
      hits.add(hit);
      onHit?.call(hit);
      // Always resume so the app never stays frozen.
      try {
        await service.resume(iso);
      } catch (_) {}
      if (hits.length >= count && !done.isCompleted) done.complete();
    });

    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    try {
      await service.removeBreakpoint(isolateId, bp.id!);
    } catch (_) {}
    return hits;
  } finally {
    await service.dispose();
  }
}

/// One frame of the paused call stack, for `inspect`.
class InspectFrame {
  InspectFrame(this.function, this.location);
  final String function;
  final String location; // "scriptBasename:line" (line omitted if unknown)
  Map<String, dynamic> toJson() => {'function': function, 'location': location};
}

/// The snapshot `inspect` returns: every local in the top frame plus the call
/// stack, captured at a line without the caller having to name variables.
class InspectResult {
  InspectResult(this.file, this.line, this.locals, this.stack);
  final String file;
  final int line;
  final Map<String, String> locals; // variable name → rendered value
  final List<InspectFrame> stack;
  Map<String, dynamic> toJson() => {
        'file': file,
        'line': line,
        'locals': locals,
        'stack': [for (final f in stack) f.toJson()],
      };
}

/// Like `probe`, but on the first hit dump *all* locals of the top frame and the
/// call stack, then auto-resume. Non-blocking (the app is paused only for the
/// snapshot) — the interactive break/step/continue variant is deliberately not
/// built: holding the app paused across commands fights emu's single-shot model
/// and stops logs/probes (see docs/BACKLOG.md #6).
Future<InspectResult?> runInspect({
  required String wsUri,
  required String pubspecContent,
  required String file,
  required int line,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final service = await vmServiceConnectUri(wsUri);
  try {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const [];
    if (isolates.isEmpty) throw ProbeException('no isolate available');
    final isolateId = isolates.first.id!;

    final pkg = packageNameFromPubspec(pubspecContent);
    final scriptList = await service.getScripts(isolateId);
    final uris = [for (final s in scriptList.scripts ?? <ScriptRef>[]) s.uri!];
    final targetUri = matchScriptUri(uris, file, pkg);
    if (targetUri == null) throw ProbeException('no loaded script matches "$file"');
    final scriptRef = scriptList.scripts!.firstWhere((s) => s.uri == targetUri);

    final Breakpoint bp;
    try {
      bp = await service.addBreakpoint(isolateId, scriptRef.id!, line);
    } catch (e) {
      throw ProbeException('could not set breakpoint at $file:$line ($e)');
    }

    InspectResult? result;
    final done = Completer<void>();
    await service.streamListen(EventStreams.kDebug);
    final sub = service.onDebugEvent.listen((event) async {
      if (event.kind != EventKind.kPauseBreakpoint) return;
      if (!(event.pauseBreakpoints?.any((b) => b.id == bp.id) ?? false)) return;
      final iso = event.isolate?.id ?? isolateId;
      try {
        result = await _snapshot(service, iso, file, line);
      } finally {
        try {
          await service.resume(iso); // never leave the app frozen
        } catch (_) {}
        if (!done.isCompleted) done.complete();
      }
    });

    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    try {
      await service.removeBreakpoint(isolateId, bp.id!);
    } catch (_) {}
    return result;
  } finally {
    await service.dispose();
  }
}

Future<InspectResult> _snapshot(
    VmService service, String isolateId, String file, int line) async {
  final stack = await service.getStack(isolateId, limit: 16);
  final frames = stack.frames ?? const <Frame>[];
  final locals = <String, String>{};
  if (frames.isNotEmpty) {
    for (final v in frames.first.vars ?? const <BoundVariable>[]) {
      locals[v.name ?? '?'] = _renderValue(v.value);
    }
  }
  final trace = <InspectFrame>[];
  for (final f in frames) {
    final loc = f.location;
    final uri = loc?.script?.uri ?? '';
    final base = uri.isEmpty ? '' : uri.split('/').last;
    final ln = loc?.line;
    trace.add(InspectFrame(
      f.function?.name ?? f.code?.name ?? '<anonymous>',
      ln != null ? '$base:$ln' : base,
    ));
  }
  return InspectResult(file, line, locals, trace);
}

/// Render a frame variable's value (an [InstanceRef]/[Sentinel]) to a short
/// string. Non-primitives show `<ClassName>` — `probe` that field for depth.
String _renderValue(dynamic v) {
  if (v is InstanceRef) {
    if (v.valueAsString != null) {
      return v.kind == InstanceKind.kString ? '"${v.valueAsString}"' : v.valueAsString!;
    }
    return '<${v.classRef?.name ?? v.kind ?? 'object'}>';
  }
  if (v is Sentinel) return '<${v.valueAsString ?? 'sentinel'}>';
  return '$v';
}

/// Evaluate [expr] in the top frame of the paused [isolateId] and render it.
Future<String> _evaluate(VmService service, String isolateId, String expr) async {
  try {
    final r = await service.evaluateInFrame(isolateId, 0, expr);
    if (r is InstanceRef) {
      if (r.valueAsString != null) {
        return r.kind == InstanceKind.kString ? '"${r.valueAsString}"' : r.valueAsString!;
      }
      return '<${r.classRef?.name ?? r.kind ?? 'object'}>';
    }
    if (r is ErrorRef) return 'error: ${r.message}';
    if (r is Sentinel) return '<${r.valueAsString ?? 'sentinel'}>';
    return r.runtimeType.toString();
  } catch (e) {
    return 'eval error: $e';
  }
}
