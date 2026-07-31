// Bundles web/ into lib/src/web_assets.g.dart as base64, so the compiled
// `emu` binary serves the dashboard with no external files.
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
}
