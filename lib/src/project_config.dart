/// Layered project configuration so repeated runs don't re-specify device,
/// flavor, or launch flags every time.
///
/// Precedence, highest wins:
///   1. explicit CLI flags        (handled by the caller, not here)
///   2. `--config` launch.json    (handled by the caller, not here)
///   3. `<root>/emu.local.yaml`   machine-specific, git-ignored
///   4. `<root>/emu.yaml`         shared, committed
///   5. `~/.emu/config.yaml`      user defaults across all projects
///   6. built-in defaults         (in code)
///
/// The split is by *commit boundary*: a value true across machines and time
/// (flavor, dart-defines) belongs in the committed layer; a value that is only
/// true on this machine right now (a specific running device id) belongs in the
/// local layer. Parsing is pure ([mergeConfigMaps]/[EmuConfig.fromMap]) so the
/// merge order is unit-testable without touching the filesystem.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// A resolved config. Every field is nullable — absence means "no opinion,
/// fall through to the next-lower layer or the built-in default".
class EmuConfig {
  const EmuConfig({
    this.deviceId,
    this.flavor,
    this.target,
    this.dartDefines = const [],
    this.timeoutSec,
    this.port,
    this.platform,
  });

  final String? deviceId;
  final String? flavor;
  final String? target;
  final List<String> dartDefines;
  final int? timeoutSec;
  final int? port;

  /// `android` | `ios`, or null to let device selection decide.
  final String? platform;

  static const empty = EmuConfig();

  factory EmuConfig.fromMap(Map<String, dynamic> m) {
    List<String> defines() {
      final v = m['dartDefines'] ?? m['dart-defines'] ?? m['dartDefine'];
      if (v is List) return v.map((e) => '$e').toList();
      if (v is String && v.isNotEmpty) return [v];
      return const [];
    }

    int? asInt(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);

    return EmuConfig(
      deviceId: m['device'] as String?,
      flavor: m['flavor'] as String?,
      target: (m['target'] ?? m['entry']) as String?,
      dartDefines: defines(),
      timeoutSec: asInt(m['timeout']),
      port: asInt(m['port']),
      platform: m['platform'] as String?,
    );
  }
}

/// Merge raw config maps in ascending precedence (index 0 lowest, last highest).
/// A later layer's non-null scalar replaces earlier ones; a later layer's
/// non-empty list replaces earlier ones wholesale (no concat — replacement is
/// less surprising than silently accumulating stale dart-defines).
Map<String, dynamic> mergeConfigMaps(List<Map<String, dynamic>> layers) {
  final out = <String, dynamic>{};
  for (final layer in layers) {
    layer.forEach((k, v) {
      if (v == null) return;
      if (v is List && v.isEmpty) return;
      if (v is String && v.isEmpty) return;
      out[k] = v;
    });
  }
  return out;
}

/// Load and merge the three file layers for [projectRoot]. Missing or malformed
/// files are skipped (a broken config should not brick `up`); [onWarn] is called
/// with a human-readable note for each file that failed to parse.
EmuConfig loadProjectConfig(
  String projectRoot, {
  String? home,
  void Function(String warning)? onWarn,
}) {
  final homeDir = home ?? Platform.environment['HOME'] ?? '';
  final layers = <Map<String, dynamic>>[];
  for (final path in [
    if (homeDir.isNotEmpty) '$homeDir/.emu/config.yaml',
    '$projectRoot/emu.yaml',
    '$projectRoot/emu.local.yaml',
  ]) {
    final m = _readYamlMap(path, onWarn);
    if (m != null) layers.add(m);
  }
  return EmuConfig.fromMap(mergeConfigMaps(layers));
}

/// If `<root>/emu.local.yaml` exists, make sure the project `.gitignore` ignores
/// it — machine-specific values (a running device id) must never be committed
/// (invariant B4). Idempotent: does nothing if the file is absent or already
/// ignored. Returns true only when it just added the entry (so the caller can
/// tell the user once). Best-effort — a write failure is swallowed, never fatal.
bool ensureLocalConfigIgnored(String projectRoot) {
  const entry = 'emu.local.yaml';
  final local = File('$projectRoot/$entry');
  if (!local.existsSync()) return false;
  final gi = File('$projectRoot/.gitignore');
  try {
    final lines = gi.existsSync() ? gi.readAsLinesSync() : const <String>[];
    // Match a bare line for the file (ignore comments / inline whitespace).
    final already = lines.any((l) {
      final t = l.trim();
      return t == entry || t == '/$entry';
    });
    if (already) return false;
    final existing = gi.existsSync() ? gi.readAsStringSync() : '';
    final needsNl = existing.isNotEmpty && !existing.endsWith('\n');
    gi.writeAsStringSync(
      '${needsNl ? '\n' : ''}# emu machine-specific config (do not commit)\n$entry\n',
      mode: FileMode.append,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic>? _readYamlMap(String path, void Function(String)? onWarn) {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    final doc = loadYaml(f.readAsStringSync());
    if (doc is YamlMap) {
      return doc.map((k, v) => MapEntry('$k', _plain(v)));
    }
    onWarn?.call('$path: expected a top-level map, ignoring');
    return null;
  } catch (e) {
    onWarn?.call('$path: $e');
    return null;
  }
}

/// Convert YAML nodes to plain Dart (YamlList/YamlMap → List/Map).
Object? _plain(Object? v) {
  if (v is YamlList) return v.map(_plain).toList();
  if (v is YamlMap) return v.map((k, x) => MapEntry('$k', _plain(x)));
  return v;
}
