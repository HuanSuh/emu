/// Reads VS Code `.vscode/launch.json` so `emu` can replay a project's
/// configured run setup (flavor / target / dart-define / device) without an IDE.
///
/// `launch.json` is JSONC (allows `//`, `/* */` comments and trailing commas),
/// so we strip those — string-aware, so URLs and values survive — before
/// decoding. Parsing is pure (no IO except [readLaunchConfigs]) for testability.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A single runnable configuration distilled from a `launch.json` entry.
class LaunchConfig {
  LaunchConfig({
    required this.name,
    this.mode = 'debug',
    this.deviceId,
    this.flavor,
    this.target,
    this.dartDefines = const [],
    this.dartDefineFromFile = const [],
    this.unsupported = const [],
  });

  final String name;

  /// `debug` | `profile` | `release` (from `flutterMode`, default `debug`).
  final String mode;
  final String? deviceId;
  final String? flavor;
  final String? target;
  final List<String> dartDefines;

  /// Paths from `--dart-define-from-file`, resolved to absolute (relative to
  /// the project root) when a project root was available while parsing.
  final List<String> dartDefineFromFile;

  /// Flags we recognized but cannot replay yet, surfaced so the user knows
  /// the replay is incomplete.
  final List<String> unsupported;

  /// emu only drives debug builds (hot reload + VM Service depend on it).
  bool get isDebug => mode == 'debug';

  Map<String, dynamic> toJson() => {
        'name': name,
        'mode': mode,
        if (deviceId != null) 'deviceId': deviceId,
        if (flavor != null) 'flavor': flavor,
        if (target != null) 'target': target,
        'dartDefines': dartDefines,
        'dartDefineFromFile': dartDefineFromFile,
        'unsupported': unsupported,
        'runnable': isDebug,
      };
}

/// Read + parse `<projectRoot>/.vscode/launch.json`. Empty list if missing.
List<LaunchConfig> readLaunchConfigs(String projectRoot) {
  final f = File('$projectRoot/.vscode/launch.json');
  if (!f.existsSync()) return const [];
  return parseLaunchJson(f.readAsStringSync(), projectRoot: projectRoot);
}

/// Parse the text of a `launch.json`, returning Dart/Flutter configs only.
/// [projectRoot], when given, is used to resolve relative
/// `--dart-define-from-file` paths (VS Code resolves them against the
/// workspace root, not `.vscode/`).
List<LaunchConfig> parseLaunchJson(String text, {String? projectRoot}) {
  final decoded = jsonDecode(stripJsonc(text));
  if (decoded is! Map) return const [];
  final configs = decoded['configurations'];
  if (configs is! List) return const [];
  final out = <LaunchConfig>[];
  for (final raw in configs) {
    if (raw is! Map) continue;
    final m = raw.cast<String, dynamic>();
    // Only Flutter/Dart launch configs are meaningful to emu.
    if (m['type'] != 'dart') continue;
    final name = m['name'] as String?;
    if (name == null || name.isEmpty) continue;
    out.add(_fromEntry(name, m, projectRoot: projectRoot));
  }
  return out;
}

LaunchConfig _fromEntry(String name, Map<String, dynamic> m, {String? projectRoot}) {
  final mode = (m['flutterMode'] as String?)?.toLowerCase() ?? 'debug';
  String? target = m['program'] as String?;
  String? flavor;
  final defines = <String>[];
  final defineFiles = <String>[];
  final unsupported = <String>[];

  // The Dart extension accepts run flags in either `args` or `toolArgs`.
  final tokens = <String>[
    ..._stringList(m['toolArgs']),
    ..._stringList(m['args']),
  ];
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    String? inlineValue(String flag) {
      if (t == flag) return (i + 1 < tokens.length) ? tokens[++i] : null;
      if (t.startsWith('$flag=')) return t.substring(flag.length + 1);
      return null;
    }

    final flavorV = inlineValue('--flavor');
    if (flavorV != null) {
      flavor = flavorV;
      continue;
    }
    final targetV = inlineValue('--target') ?? inlineValue('-t');
    if (targetV != null) {
      target = targetV;
      continue;
    }
    final defineFileV = inlineValue('--dart-define-from-file');
    if (defineFileV != null) {
      defineFiles.add(_resolveDefineFilePath(defineFileV, projectRoot));
      continue;
    }
    final defineV = inlineValue('--dart-define');
    if (defineV != null) {
      defines.add(defineV);
      continue;
    }
  }

  return LaunchConfig(
    name: name,
    mode: mode,
    deviceId: m['deviceId'] as String?,
    flavor: flavor,
    target: target,
    dartDefines: defines,
    dartDefineFromFile: defineFiles,
    unsupported: unsupported,
  );
}

/// Resolve a `--dart-define-from-file` path relative to [projectRoot] (VS
/// Code's workspace root), matching how the Dart extension resolves it.
/// Absolute paths, or no known project root, pass through unchanged.
String _resolveDefineFilePath(String path, String? projectRoot) {
  if (projectRoot == null || p.isAbsolute(path)) return path;
  return p.normalize(p.join(projectRoot, path));
}

List<String> _stringList(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

/// Remove `//` line comments, `/* */` block comments, and trailing commas
/// from JSONC text without touching content inside string literals.
String stripJsonc(String src) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    if (inString) {
      out.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      if (i < src.length) out.write('\n');
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i++; // land on the '/'
      continue;
    }
    out.write(c);
  }
  return _stripTrailingCommas(out.toString());
}

/// Drop commas that directly precede a `}` or `]` (string-aware).
String _stripTrailingCommas(String src) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    if (inString) {
      out.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
      continue;
    }
    if (c == ',') {
      var j = i + 1;
      while (j < src.length && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r')) {
        j++;
      }
      if (j < src.length && (src[j] == '}' || src[j] == ']')) {
        continue; // drop the trailing comma
      }
    }
    out.write(c);
  }
  return out.toString();
}
