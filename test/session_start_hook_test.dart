import 'dart:io';

import 'package:test/test.dart';

/// hooks/session-start.sh with a fake HOME and a fake plugin root. A fake
/// `emu` records that it ran; nothing real is touched. Stubs are copies of one
/// chmod-ed file and every run is async: repeated runSync breaks the port
/// tests on Linux CI.
void main() {
  late Directory stubs;
  setUpAll(() async {
    stubs = Directory.systemTemp.createTempSync('emu_hook_stub_');
    File('${stubs.path}/stub').writeAsStringSync('#!/bin/sh\necho "\$@" >> "\$HOME/ran"\n. "\$HOME/stub-body"\n');
    await Process.run('chmod', ['+x', '${stubs.path}/stub']);
  });
  tearDownAll(() => stubs.deleteSync(recursive: true));

  late Directory tmp;
  late String home;
  late String root;
  late String bin;
  final script = File('hooks/session-start.sh').absolute.path;

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('emu_hook_').resolveSymbolicLinksSync());
    home = '${tmp.path}/home';
    root = '${tmp.path}/plugin';
    bin = '${tmp.path}/bin';
    Directory('$home/.emu/bin').createSync(recursive: true);
    Directory('$root/.claude-plugin').createSync(recursive: true);
    Directory(bin).createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void plugin(String v) => File('$root/.claude-plugin/plugin.json').writeAsStringSync('{\n  "name": "emu",\n  "version": "$v"\n}\n');

  void installed(String v, {String source = 'plugin', String script = 'exit 0'}) {
    File('${stubs.path}/stub').copySync('$home/.emu/bin/emu');
    File('$home/stub-body').writeAsStringSync('$script\n');
    File('$home/.emu/bin/emu.json').writeAsStringSync('{\n  "version": "$v",\n  "source": "$source"\n}\n');
  }

  Future<ProcessResult> hook({Map<String, String> env = const {}, String? path}) => Process.run(
        '/bin/bash',
        [script],
        environment: {'HOME': home, 'CLAUDE_PLUGIN_ROOT': root, 'PATH': path ?? '$bin:/usr/bin:/bin', ...env},
        includeParentEnvironment: false,
      );

  /// `dart` for the hook's `command -v`, as a stub.
  void dart() {
    File('${stubs.path}/stub').copySync('$bin/dart');
  }

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ok(), isTrue);
  }

  test('a newer plugin: one line, nothing built', () async {
    plugin('0.17.5');
    installed('0.17.4');
    final r = await hook();
    expect(r.exitCode, 0);
    expect(r.stdout, 'emu 0.17.5 준비됨(현재 CLI 0.17.4). 업데이트: hub 의 업데이트 버튼 또는 emu update\n');
    expect(File('$home/ran').existsSync(), isFalse, reason: 'the hook never runs emu by default');
  });

  test('compares numerically', () async {
    plugin('0.10.0');
    installed('0.9.9');
    expect((await hook()).stdout, contains('0.10.0'));
  });

  for (final c in [('same', '0.17.4', '0.17.4'), ('older plugin (a pinned project scope)', '0.17.3', '0.17.4')]) {
    test('silent: ${c.$1}', () async {
      plugin(c.$2);
      installed(c.$3);
      final r = await hook(env: {'EMU_AUTO_UPDATE': '1'});
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
    });
  }

  test('silent: a git checkout behind ~/.emu/bin', () async {
    plugin('0.17.5');
    installed('0.17.4', source: 'git');
    expect((await hook()).stdout, isEmpty);
  });

  test('silent: a running update holds the lock', () async {
    plugin('0.17.5');
    installed('0.17.4');
    File('$home/.emu/update.lock').writeAsStringSync('$pid');
    expect((await hook()).stdout, isEmpty);
  });

  test('a dead lock does not silence it', () async {
    plugin('0.17.5');
    installed('0.17.4');
    File('$home/.emu/update.lock').writeAsStringSync('999999');
    expect((await hook()).stdout, contains('0.17.5'));
  });

  test('no plugin version, or no fixed install and no link: silent, exit 0', () async {
    expect((await hook()).exitCode, 0);
    plugin('0.17.5');
    final r = await hook();
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
  });

  group('before ~/.emu/bin', () {
    setUp(() => plugin('0.17.5'));

    test('a link into an older version folder (even a gone one) points at /emu-setup', () async {
      Link('$bin/emu').createSync('$home/.claude/plugins/cache/emu/emu/0.17.2/emu');
      expect((await hook()).stdout, contains('/emu-setup'));
    });

    test('a link to a checkout, or to a version as new: silent', () async {
      Link('$bin/emu').createSync('$home/src/emu/emu');
      expect((await hook()).stdout, isEmpty);
      Link('$bin/emu').deleteSync();
      final dir = '$home/.claude/plugins/cache/emu/emu/0.17.5';
      Directory(dir).createSync(recursive: true);
      File('$dir/emu').writeAsStringSync('');
      Link('$bin/emu').createSync('$dir/emu');
      expect((await hook()).stdout, isEmpty);
    });
  });

  group('EMU_AUTO_UPDATE=1', () {
    setUp(() => plugin('0.17.5'));

    test('starts emu update --local detached and says so', () async {
      installed('0.17.4');
      dart();
      final r = await hook(env: {'EMU_AUTO_UPDATE': '1'});
      expect(r.stdout, contains('백그라운드'));
      await until(() => File('$home/ran').existsSync());
      expect(File('$home/ran').readAsStringSync(), 'update --yes --local\n');
      expect(File('$home/.emu/auto-update.failed').existsSync(), isFalse);
    });

    test('a failure is noted once: the next session gets the notice, not another build', () async {
      installed('0.17.4', script: 'echo boom; exit 1');
      dart();
      await hook(env: {'EMU_AUTO_UPDATE': '1'});
      final failed = File('$home/.emu/auto-update.failed');
      await until(failed.existsSync);
      await until(() => failed.readAsStringSync().trim() == '0.17.5');
      File('$home/ran').deleteSync();
      final r = await hook(env: {'EMU_AUTO_UPDATE': '1'});
      expect(r.stdout, contains('실패'));
      expect(File('$home/ran').existsSync(), isFalse);
    });

    test('a lost lock race is no failure', () async {
      installed('0.17.4', script: 'echo "another emu update is running"; exit 1');
      dart();
      await hook(env: {'EMU_AUTO_UPDATE': '1'});
      await until(() => File('$home/ran').existsSync());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File('$home/.emu/auto-update.failed').existsSync(), isFalse);
    });

    test('without dart: just the notice', () async {
      installed('0.17.4');
      final tools = '${tmp.path}/tools';
      Directory(tools).createSync();
      for (final t in ['sed', 'head', 'grep', 'cat']) {
        final found = ['/usr/bin/$t', '/bin/$t'].firstWhere((p) => File(p).existsSync());
        Link('$tools/$t').createSync(found);
      }
      final r = await hook(env: {'EMU_AUTO_UPDATE': '1'}, path: tools);
      expect(r.stdout, contains('emu update'));
      expect(File('$home/ran').existsSync(), isFalse);
    });
  });

  test('hooks.json runs the script from the plugin root, with a short timeout', () async {
    final json = File('hooks/hooks.json').readAsStringSync();
    expect(json, contains(r'${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh'));
    expect(json, contains('"timeout": 5'));
  });
}
