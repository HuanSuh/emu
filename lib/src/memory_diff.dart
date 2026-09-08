/// Heap instance-count snapshots via the VM Service, for `emu memory
/// --diff-across`.
///
/// Same short connect → do the one thing → dispose pattern as `probe.dart`/
/// `locate.dart` — this opens its own client on `vmServiceUri` rather than
/// touching the server's own connection.
library;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'probe.dart' show packageNameFromPubspec;

/// Take a heap snapshot: for each class the VM currently has live instances
/// of, `<library>|<className>` → instance count.
///
/// `gc: true` asks the VM to garbage-collect immediately before sampling, so
/// counts reflect genuinely-live objects rather than not-yet-swept garbage —
/// emu doesn't need to trigger a GC itself.
Future<Map<String, int>> takeHeapSnapshot(String wsUri) async {
  final service = await vmServiceConnectUri(wsUri);
  try {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) throw StateError('no isolate available');
    final isolateId = isolates.first.id!;

    final profile = await service.getAllocationProfile(isolateId, gc: true);
    final out = <String, int>{};
    for (final m in profile.members ?? const <ClassHeapStats>[]) {
      final count = m.instancesCurrent;
      if (count == null || count == 0) continue;
      final classRef = m.classRef;
      if (classRef == null) continue;
      // `library.uri` (e.g. `package:my_app/cart.dart`) is what `--all`
      // filtering matches against — `library.name` is the (often absent)
      // `library` declaration name, not useful for that.
      final lib = classRef.library?.uri ?? '';
      final name = classRef.name ?? '?';
      out['$lib|$name'] = count;
    }
    return out;
  } finally {
    await service.dispose();
  }
}

/// Keep only entries whose class key (`<library>|<className>`, as produced by
/// [takeHeapSnapshot]) belongs to the app's own package — i.e. its library is
/// `package:<appPackage>/...`. Used to hide framework/SDK classes by default.
Map<String, int> filterToAppPackage(Map<String, int> snapshot, String appPackage) {
  final prefix = 'package:$appPackage/';
  return {
    for (final e in snapshot.entries)
      if (libraryOf(e.key).startsWith(prefix)) e.key: e.value,
  };
}

/// The library portion of a key produced by [takeHeapSnapshot] (drops the
/// class name). Public so callers can disambiguate same-named classes from
/// different libraries (e.g. when serializing a diff keyed by class name
/// alone would collide).
String libraryOf(String classKey) {
  final i = classKey.indexOf('|');
  return i < 0 ? classKey : classKey.substring(0, i);
}

/// The class name portion of a key produced by [takeHeapSnapshot] (drops the
/// library), for display.
String classNameOf(String classKey) {
  final i = classKey.indexOf('|');
  return i < 0 ? classKey : classKey.substring(i + 1);
}

/// Extract the app's own package name from its `pubspec.yaml`, for filtering
/// heap snapshots to app classes by default. Thin re-export of the same
/// lookup `probe`/`inspect` use to match a `file:line` to a loaded script.
String? appPackageName(String pubspecContent) => packageNameFromPubspec(pubspecContent);

/// Diff two heap snapshots (as produced by [takeHeapSnapshot]): for each class
/// present in either, `after - before`. Only non-zero diffs are returned — a
/// class with no change is not "interesting" for a leak hunt.
Map<String, int> diffSnapshots(Map<String, int> before, Map<String, int> after) {
  final keys = {...before.keys, ...after.keys};
  final out = <String, int>{};
  for (final k in keys) {
    final delta = (after[k] ?? 0) - (before[k] ?? 0);
    if (delta != 0) out[k] = delta;
  }
  return out;
}
