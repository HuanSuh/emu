/// Evaluate a Dart expression against the running app *right now*, in the
/// scope of its own root library (`package:<app>/main.dart` — whatever `main()`
/// lives in), via the VM Service.
///
/// This is the immediate-mode sibling of `probe`/`inspect`: those set a
/// breakpoint and can only report once execution actually reaches that line,
/// so they can't answer "what is this singleton holding at this moment?".
/// `evaluate` against a library needs no paused frame, so this answers it now —
/// at the cost of only seeing library-scope names (top-level functions/getters
/// and imported symbols), not any function's locals.
library;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class EvalException implements Exception {
  EvalException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Evaluate [expr] in the root library of the app's first isolate and render
/// the result the way `probe`/`inspect` render values: strings quoted, other
/// primitives bare, non-primitives as `<ClassName>`.
Future<String> evalOnDevice(String wsUri, String expr) async {
  final service = await vmServiceConnectUri(wsUri);
  try {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) throw EvalException('no isolate available');
    final isoId = isolates.first.id!;
    final iso = await service.getIsolate(isoId);
    final rootLib = iso.rootLib;
    if (rootLib?.id == null) throw EvalException('isolate has no root library');

    final r = await service.evaluate(isoId, rootLib!.id!, expr);
    if (r is ErrorRef) throw EvalException('evaluate failed: ${r.message}');
    if (r is Sentinel) return '<${r.valueAsString ?? 'sentinel'}>';
    if (r is! InstanceRef) throw EvalException('unexpected result: ${r.runtimeType}');
    if (r.valueAsString == null) {
      // A real object with no literal form — `probe` the fields you want.
      return '<${r.classRef?.name ?? r.kind ?? 'object'}>';
    }
    var value = r.valueAsString!;
    if (r.valueAsStringIsTruncated ?? false) {
      // Long strings exceed the VM's inline preview; the full object has it all.
      final full = await service.getObject(isoId, r.id!);
      if (full is Instance) value = full.valueAsString ?? value;
    }
    return r.kind == InstanceKind.kString ? '"$value"' : value;
  } finally {
    await service.dispose();
  }
}
