import 'dart:convert';
import 'dart:io';

import 'package:emu/src/app_install.dart';
import 'package:emu/src/macos_sources.g.dart';
import 'package:test/test.dart';

void main() {
  test('the app sources are embedded', () {
    expect(kEmbeddedMacSources.keys,
        containsAll(['main.swift', 'AppDelegate.swift', 'HubWindow.swift', 'Policy.swift', 'AppIcon.png']));
  });

  test('the menu bar icon masks are embedded and go to Resources', () {
    const masks = ['MenuIcon.png', 'MenuIcon@2x.png', 'MenuIconDark.png', 'MenuIconDark@2x.png'];
    expect(kEmbeddedMacSources.keys, containsAll(masks));
    expect(appResourceNames(), masks);
    // AppIcon.png becomes emu.icns; Swift sources are compiled, not copied.
    expect(appResourceNames({'AppIcon.png': '', 'a.swift': '', 'X.png': ''}), ['X.png']);
    expect(appResourceNames({'AppIcon.png': '', 'a.swift': ''}), isEmpty);
  });

  test('rev changes with the sources, not their order', () {
    final a = appSourcesRev({'a.swift': 'x', 'b.swift': 'y'});
    expect(a, matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(appSourcesRev({'b.swift': 'y', 'a.swift': 'x'}), a);
    expect(appSourcesRev({'a.swift': 'x', 'b.swift': 'z'}), isNot(a));
    expect(appSourcesRev(), appSourcesRev(kEmbeddedMacSources));
  });

  test('uniquePath keeps the first of each entry', () {
    expect(uniquePath('/a:/b::/a:/c:/b'), '/a:/b:/c');
  });

  test('Info.plist allows loopback http and names the executable', () {
    final p = infoPlist(version: '1.2.3', rev: 'abc');
    expect(p, contains('<key>NSAllowsLocalNetworking</key><true/>'));
    expect(p, contains('<key>CFBundleExecutable</key><string>emu</string>'));
    expect(p, contains('<string>1.2.3</string>'));
  });

  test('the app is current only with these sources and this binary', () async {
    final tmp = Directory.systemTemp.createTempSync('emu_app_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final bundle = Directory('${tmp.path}/emu.app');
    void record(String rev, String emu) {
      File('${bundle.path}/Contents/Resources/app.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'rev': rev, 'emu': emu}));
    }

    record(appSourcesRev(), '/plugins/cache/emu/emu/0.1.0/emu');
    expect(installedAppEmu(bundle), '/plugins/cache/emu/emu/0.1.0/emu');
    expect(await appIsCurrent(bundle: bundle, emu: '/plugins/cache/emu/emu/0.1.0/emu'), isTrue);
    // An old install moving to ~/.emu/bin changes the path: the app must follow it once.
    expect(await appIsCurrent(bundle: bundle, emu: '/plugins/cache/emu/emu/0.2.0/emu'), isFalse);
    record('000000000000', '/plugins/cache/emu/emu/0.2.0/emu');
    expect(await appIsCurrent(bundle: bundle, emu: '/plugins/cache/emu/emu/0.2.0/emu'), isFalse);
  });
}
