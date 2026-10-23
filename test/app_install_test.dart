import 'package:emu/src/app_install.dart';
import 'package:emu/src/macos_sources.g.dart';
import 'package:test/test.dart';

void main() {
  test('the app sources are embedded', () {
    expect(kEmbeddedMacSources.keys,
        containsAll(['main.swift', 'AppDelegate.swift', 'HubWindow.swift', 'Policy.swift', 'AppIcon.png']));
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
}
