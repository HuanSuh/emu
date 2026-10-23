// Bundles web/ into lib/src/web_assets.g.dart (and macos/Emu/*.swift into
// lib/src/macos_sources.g.dart) as base64, so the compiled `emu` binary
// serves the dashboard and builds the macOS app with no external files.
//
// Run: dart run tool/bundle_web.dart
import 'dart:convert';
import 'dart:io';

void main() {
  final webDir = Directory('web');
  if (!webDir.existsSync()) {
    stderr.writeln('web/ not found; run from the package root.');
    exit(1);
  }
  // Sort by relative path so the generated output is deterministic regardless
  // of filesystem listing order (macOS vs Linux differ) — otherwise CI's
  // regeneration drifts from a locally-generated file.
  final files = webDir.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final entries = <String, String>{};
  for (final f in files) {
    final rel = f.path.substring(webDir.path.length + 1).replaceAll('\\', '/');
    entries[rel] = base64Encode(f.readAsBytesSync());
  }

  final sb = StringBuffer()
    ..writeln('// GENERATED FILE — do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/bundle_web.dart')
    ..writeln('//')
    ..writeln('// Maps each web/ asset path to its base64-encoded bytes so the compiled')
    ..writeln('// `emu` binary is self-contained.')
    ..writeln('library;')
    ..writeln()
    ..writeln('const Map<String, String> kEmbeddedWebAssets = {');
  for (final e in entries.entries) {
    sb.writeln("  '${e.key}': '${e.value}',");
  }
  sb.writeln('};');

  File('lib/src/web_assets.g.dart').writeAsStringSync(sb.toString());
  stdout.writeln('bundled ${entries.length} asset(s) into lib/src/web_assets.g.dart');
  _bundleMacSources();
}

/// macos/Emu/*.swift (+ AppIcon.png) → lib/src/macos_sources.g.dart, so `emu app install`
/// can build the macOS app from the binary alone.
void _bundleMacSources() {
  final dir = Directory('macos/Emu');
  final files = dir.existsSync()
      ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.swift') || f.path.endsWith('.png')).toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  final sb = StringBuffer()
    ..writeln('// GENERATED FILE — do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/bundle_web.dart')
    ..writeln('//')
    ..writeln('// The macOS app sources (macos/Emu/*.swift, AppIcon.png), base64, for `emu app install`.')
    ..writeln('library;')
    ..writeln()
    ..writeln('const Map<String, String> kEmbeddedMacSources = {');
  for (final f in files) {
    sb.writeln("  '${f.uri.pathSegments.last}': '${base64Encode(f.readAsBytesSync())}',");
  }
  sb.writeln('};');
  File('lib/src/macos_sources.g.dart').writeAsStringSync(sb.toString());
  stdout.writeln('bundled ${files.length} macOS source(s) into lib/src/macos_sources.g.dart');
}
