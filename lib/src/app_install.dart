/// `emu app` — the macOS app around `emu hub` (docs/HUB.md §3). Built here,
/// on this machine, with `swiftc` from the sources embedded in the binary
/// (`macos_sources.g.dart`): no Xcode project, no signing service, and no
/// quarantine flag, so Gatekeeper lets it run.
library;

import 'dart:convert';
import 'dart:io';

import 'macos_sources.g.dart';
import 'version.dart';

/// `~/Applications/emu.app`.
Directory appBundle() => Directory('${Platform.environment['HOME'] ?? '.'}/Applications/emu.app');

/// Fingerprint of the embedded app sources — recorded in the bundle, so
/// `emu update` rebuilds the app only when they changed.
String appSourcesRev([Map<String, String> sources = kEmbeddedMacSources]) {
  var h = 0xcbf29ce484222325;
  for (final name in sources.keys.toList()..sort()) {
    for (final b in utf8.encode('$name\u0000${sources[name]}\u0000')) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
  }
  return (h >>> 16).toRadixString(16).padLeft(12, '0');
}

/// The rev recorded in an installed bundle, or null.
String? installedAppRev([Directory? bundle]) {
  final f = File('${(bundle ?? appBundle()).path}/Contents/Resources/app.json');
  try {
    return (jsonDecode(f.readAsStringSync()) as Map)['rev'] as String?;
  } catch (_) {
    return null;
  }
}

String infoPlist({required String version, required String rev}) => '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>emu</string>
  <key>CFBundleDisplayName</key><string>emu</string>
  <key>CFBundleIdentifier</key><string>io.github.huansuh.emu</string>
  <key>CFBundleExecutable</key><string>emu</string>
  <key>CFBundleIconFile</key><string>emu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$rev</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
''';

/// The emu binary the app should run: this one when compiled, else the one
/// on PATH (`dart run` in development).
Future<String?> emuExecutable() async {
  final exe = Platform.resolvedExecutable;
  if (!exe.endsWith('dart')) return File(exe).resolveSymbolicLinksSync();
  final r = await Process.run('which', ['emu']);
  final path = '${r.stdout}'.trim();
  return r.exitCode == 0 && path.isNotEmpty ? File(path).resolveSymbolicLinksSync() : null;
}

/// Build the app into [bundle] (default `~/Applications/emu.app`). Returns
/// null on success, else what went wrong.
Future<String?> installApp({Directory? bundle, void Function(String)? log}) async {
  final say = log ?? (_) {};
  if (!Platform.isMacOS) return 'the emu app is macOS only — use `emu hub` in a browser elsewhere';
  final swiftc = await Process.run('xcrun', ['--find', 'swiftc']);
  if (swiftc.exitCode != 0) return 'swiftc not found — install the Xcode command line tools (xcode-select --install)';
  final emu = await emuExecutable();
  if (emu == null) return 'cannot tell where the emu binary is — run this from an installed emu';
  final target = bundle ?? appBundle();
  final tmp = Directory.systemTemp.createTempSync('emu_app_');
  try {
    final src = Directory('${tmp.path}/src')..createSync();
    for (final e in kEmbeddedMacSources.entries) {
      File('${src.path}/${e.key}').writeAsBytesSync(base64Decode(e.value));
    }
    final arch = '${(await Process.run('uname', ['-m'])).stdout}'.trim();
    final app = Directory('${tmp.path}/emu.app');
    final macos = Directory('${app.path}/Contents/MacOS')..createSync(recursive: true);
    final res = Directory('${app.path}/Contents/Resources')..createSync(recursive: true);

    say('» compiling (swiftc, $arch)');
    final build = await Process.run('xcrun', [
      'swiftc', '-swift-version', '5', '-O', '-target', '$arch-apple-macos12',
      '-o', '${macos.path}/emu',
      for (final name in kEmbeddedMacSources.keys)
        if (name.endsWith('.swift')) '${src.path}/$name',
      '-framework', 'Cocoa', '-framework', 'WebKit', '-framework', 'Carbon', '-framework', 'UserNotifications',
    ]);
    if (build.exitCode != 0) return 'swiftc failed:\n${build.stderr}${build.stdout}';
    final test = await Process.run('${macos.path}/emu', ['--self-test']);
    if (test.exitCode != 0) return 'the app self-test failed:\n${test.stdout}';

    final rev = appSourcesRev();
    File('${app.path}/Contents/Info.plist').writeAsStringSync(infoPlist(version: kEmuVersion, rev: rev));
    // Finder-launched apps get a minimal PATH: keep this shell's, so the hub
    // (and the `emu up` it runs) finds flutter, adb and xcrun.
    File('${res.path}/app.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'emu': emu,
      'path': uniquePath(Platform.environment['PATH'] ?? '/usr/bin:/bin'),
      'version': kEmuVersion,
      'rev': rev,
    }));
    // macos/Emu/AppIcon.png (1024², full-bleed yellow) → every size iconutil wants.
    final icon = File('${src.path}/AppIcon.png');
    if (icon.existsSync()) {
      final set = Directory('${tmp.path}/emu.iconset')..createSync();
      for (final size in [16, 32, 128, 256, 512]) {
        for (final scale in [1, 2]) {
          final px = size * scale;
          final name = 'icon_${size}x$size${scale == 2 ? '@2x' : ''}.png';
          await Process.run('sips', ['-z', '$px', '$px', icon.path, '--out', '${set.path}/$name']);
        }
      }
      await Process.run('iconutil', ['-c', 'icns', set.path, '-o', '${res.path}/emu.icns']);
    }
    // Ad-hoc signature: required to run on Apple silicon, and keeps the
    // notification permission tied to the bundle.
    final sign = await Process.run('codesign', ['--force', '--sign', '-', app.path]);
    if (sign.exitCode != 0) return 'codesign failed: ${sign.stderr}';

    say('» installing ${target.path}');
    // Swap, never leave a half bundle: the old one is moved aside first (a
    // running copy keeps working from it until it quits) and removed last.
    target.parent.createSync(recursive: true);
    final old = Directory('${target.path}.old');
    if (old.existsSync()) old.deleteSync(recursive: true);
    if (target.existsSync()) target.renameSync(old.path);
    final mv = await Process.run('mv', [app.path, target.path]);
    if (mv.exitCode != 0) {
      if (old.existsSync() && !target.existsSync()) old.renameSync(target.path);
      return 'could not move the app into place: ${mv.stderr}';
    }
    if (old.existsSync()) old.deleteSync(recursive: true);
    return null;
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// [path] with repeated entries dropped (first one wins, as in a lookup).
String uniquePath(String path) {
  final seen = <String>{};
  return path.split(':').where((p) => p.isNotEmpty && seen.add(p)).join(':');
}

Future<bool> appRunning() async {
  final r = await Process.run('pgrep', ['-f', '${appBundle().path}/Contents/MacOS/emu']);
  return r.exitCode == 0;
}
