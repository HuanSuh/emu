import 'dart:convert';
import 'dart:io';

import 'package:emu/src/self_update.dart';
import 'package:test/test.dart';

/// Fake commands for the update: records each call, answers from [answers]
/// (`'git pull'` → result), and lets a call do something to the disk.
class FakeCommands {
  final calls = <String>[];
  final answers = <String, ProcessResult>{};
  final effects = <String, void Function(String? workingDirectory)>{};

  Future<ProcessResult> call(String exe, List<String> args, {String? workingDirectory}) async {
    final name = exe.split('/').last;
    final line = [name, ...args].join(' ');
    calls.add(workingDirectory == null ? line : '$line @$workingDirectory');
    for (final e in effects.entries) {
      if (line.startsWith(e.key)) e.value(workingDirectory);
    }
    for (final e in answers.entries) {
      if (line.startsWith(e.key)) return e.value;
    }
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  late Directory tmp;
  late String home;
  late FakeCommands cmds;

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('emu_update_').resolveSymbolicLinksSync());
    home = '${tmp.path}/home';
    Directory(home).createSync();
    cmds = FakeCommands();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  SelfUpdater updater(String exe, {String path = '', bool app = false, String current = '0.1.0'}) => SelfUpdater(
        executable: exe,
        currentVersion: current,
        environment: {'HOME': home, 'PATH': path},
        run: cmds.call,
        latestVersion: () async => '0.2.0',
        appInstalled: () => app,
        lockFile: File('$home/.emu/update.lock'),
      );

  void builds(String dir) {
    cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('new');
  }

  group('git checkout', () {
    late String repo;
    setUp(() {
      repo = '${tmp.path}/emu';
      Directory('$repo/.git').createSync(recursive: true);
      File('$repo/pubspec.yaml').writeAsStringSync('name: emu\n');
      File('$repo/emu').writeAsStringSync('old');
    });

    test('pulls and builds in place', () async {
      builds(repo);
      final u = updater('$repo/emu');
      expect(u.kind, InstallKind.git);
      final lines = <String>[];
      final r = await u.apply('0.2.0', log: lines.add);
      expect(cmds.calls, ['git -C $repo status --porcelain', 'git -C $repo pull --ff-only', 'bash build.sh @$repo']);
      expect(r.updated, isTrue);
      expect(r.binary, '$repo/emu');
      expect(r.toJson(), containsPair('to', '0.2.0'));
      expect(r.toJson()['install'], 'git');
      expect(lines.first, contains('git pull'));
      expect(File('$home/.emu/update.lock').existsSync(), isFalse, reason: 'the lock is released');
    });

    test('a dirty checkout is refused before anything changes', () async {
      cmds.answers['git -C'] = ProcessResult(0, 0, ' M lib/x.dart\n', '');
      final u = updater('$repo/emu');
      await expectLater(u.preflight(), throwsA(isA<UpdateError>()
          .having((e) => e.refused, 'refused', isTrue)
          .having((e) => e.message, 'message', contains('uncommitted changes'))));
      expect(cmds.calls.where((c) => c.contains('pull')), isEmpty);
    });

    test('a failed build is reported with its output', () async {
      cmds.answers['bash build.sh'] = ProcessResult(0, 1, 'compiling', 'boom');
      await expectLater(updater('$repo/emu').apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', allOf(contains('build failed'), contains('boom')))));
    });

    test('up to date: nothing runs', () async {
      final r = await updater('$repo/emu', current: '0.2.0').apply('0.2.0');
      expect(r.updated, isFalse);
      expect(r.toJson(), containsPair('current', '0.2.0'));
      expect(cmds.calls, isEmpty);
    });

    test('check: local changes matter only when there is something newer', () async {
      cmds.answers['git -C'] = ProcessResult(0, 0, ' M lib/x.dart\n', '');
      // Up to date with uncommitted changes: just up to date (as `emu update` always said).
      final same = await updater('$repo/emu', current: '0.2.0').check();
      expect(same.newer, isFalse);
      expect(same.latest, '0.2.0');
      expect(same.install, InstallKind.git);
      expect(cmds.calls, isEmpty);
      expect((await updater('$repo/emu', current: '0.2.0').apply('0.2.0')).updated, isFalse);
      // Something newer: refused, with the reason.
      await expectLater(updater('$repo/emu').check(), throwsA(isA<UpdateError>()
          .having((e) => e.refused, 'refused', isTrue)
          .having((e) => e.message, 'message', contains('uncommitted changes'))));
    });

    test('the macOS app is rebuilt by the new binary when installed', () async {
      builds(repo);
      cmds.answers['emu app install'] = ProcessResult(0, 0, '{"ok":true,"skipped":true}\n', '');
      final r = await updater('$repo/emu', app: true).apply('0.2.0');
      expect(cmds.calls.last, 'emu app install --if-changed --json');
      expect(r.app, 'current');
      cmds.answers['emu app install'] = ProcessResult(0, 0, '{"ok":true,"path":"/x"}\n', '');
      expect((await updater('$repo/emu', app: true).apply('0.2.0')).app, 'updated');
      cmds.answers['emu app install'] = ProcessResult(0, 1, '', 'swiftc failed');
      expect((await updater('$repo/emu', app: true).apply('0.2.0')).app, startsWith('failed: swiftc failed'));
    });

    test('another update holding the lock is refused', () async {
      final lock = File('$home/.emu/update.lock')..createSync(recursive: true);
      final other = await Process.start('sleep', ['5']);
      addTearDown(other.kill);
      lock.writeAsStringSync('${other.pid}');
      await expectLater(updater('$repo/emu').apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('another emu update'))));
      // An empty lock is being taken by someone else right now.
      lock.writeAsStringSync('');
      await expectLater(updater('$repo/emu').apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('another emu update'))));
      // A stale lock (dead pid) is removed and taken.
      lock.writeAsStringSync('999999');
      builds(repo);
      expect((await updater('$repo/emu').apply('0.2.0')).updated, isTrue);
      expect(lock.existsSync(), isFalse);
    });
  });

  group('Claude Code plugin', () {
    late String plugins;
    late String oldDir;
    late String bin;

    setUp(() {
      plugins = '$home/.claude/plugins';
      oldDir = '$plugins/cache/emu/emu/0.1.0';
      Directory(oldDir).createSync(recursive: true);
      File('$oldDir/build.sh').writeAsStringSync('');
      File('$oldDir/emu').writeAsStringSync('old');
      File('$plugins/installed_plugins.json').writeAsStringSync(jsonEncode({
        'version': 2,
        'plugins': {
          'emu@emu': [
            {'scope': 'user', 'installPath': oldDir, 'version': '0.1.0'},
          ],
        },
      }));
      bin = '$home/.local/bin';
      Directory(bin).createSync(recursive: true);
      Link('$bin/emu').createSync('$oldDir/emu');
      File('$bin/claude').writeAsStringSync('');
    });

    /// `claude plugin update` puts 0.2.0 in a new cache folder and records it.
    void pluginUpdates() {
      cmds.effects['claude plugin update'] = (_) {
        final dir = '$plugins/cache/emu/emu/0.2.0';
        Directory(dir).createSync(recursive: true);
        File('$dir/build.sh').writeAsStringSync('');
        File('$plugins/installed_plugins.json').writeAsStringSync(jsonEncode({
          'plugins': {
            'emu@emu': [
              {'scope': 'user', 'installPath': dir, 'version': '0.2.0'},
            ],
          },
        }));
      };
      builds('');
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.2.0","latestVersion":"0.2.0"}\n', '');
    }

    test('fetches the new version, builds it, and moves the PATH link', () async {
      pluginUpdates();
      final u = updater('$oldDir/emu', path: '$bin:/usr/bin');
      expect(u.kind, InstallKind.plugin);
      final r = await u.apply('0.2.0');
      final newDir = '$plugins/cache/emu/emu/0.2.0';
      expect(cmds.calls, [
        'claude plugin marketplace update emu',
        'claude plugin update emu@emu',
        'bash build.sh @$newDir',
        'emu version --json',
      ]);
      expect(r.binary, '$newDir/emu');
      expect(r.linked, ['$bin/emu']);
      expect(Link('$bin/emu').targetSync(), '$newDir/emu');
      expect(File('$oldDir/emu').existsSync(), isTrue, reason: 'the old build stays for whatever still runs it');
      expect(r.toJson()['install'], 'plugin');
    });

    test('a PATH link to something else is left alone', () async {
      pluginUpdates();
      final other = '${tmp.path}/other';
      Directory(other).createSync();
      File('$other/real').writeAsStringSync('');
      Link('$other/emu').createSync('$other/real');
      final r = await updater('$oldDir/emu', path: '$other:$bin').apply('0.2.0');
      expect(r.linked, ['$bin/emu']);
      expect(Link('$other/emu').targetSync(), '$other/real');
    });

    test('a build that is not newer never takes over PATH', () async {
      pluginUpdates();
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.1.0"}\n', '');
      await expectLater(updater('$oldDir/emu', path: bin).apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('not newer'))));
      expect(Link('$bin/emu').targetSync(), '$oldDir/emu');
      cmds.answers['emu version --json'] = ProcessResult(0, 1, '', 'crashed');
      await expectLater(updater('$oldDir/emu', path: bin).apply('0.2.0'), throwsA(isA<UpdateError>()));
      expect(Link('$bin/emu').targetSync(), '$oldDir/emu');
    });

    test('installPath: the user scope, highest version, of the folders that exist', () {
      String dir(String v) {
        final d = '$plugins/cache/emu/emu/$v';
        Directory(d).createSync(recursive: true);
        return d;
      }

      void record(List<Map<String, Object>> entries) => File('$plugins/installed_plugins.json')
          .writeAsStringSync(jsonEncode({'plugins': {'emu@emu': entries}}));

      record([
        {'scope': 'user', 'installPath': dir('0.1.0'), 'version': '0.1.0'},
        {'scope': 'project', 'installPath': dir('0.9.0'), 'version': '0.9.0'},
        {'scope': 'user', 'installPath': dir('0.10.0'), 'version': '0.10.0'},
        {'scope': 'user', 'installPath': '$plugins/cache/emu/emu/0.11.0', 'version': '0.11.0'}, // gone
      ]);
      expect(SelfUpdater.installPath(plugins, 'emu@emu'), '$plugins/cache/emu/emu/0.10.0');
      // No user scope: the highest of the rest.
      record([
        {'scope': 'project', 'installPath': dir('0.3.0'), 'version': '0.3.0'},
        {'scope': 'local', 'installPath': dir('0.4.0'), 'version': '0.4.0'},
      ]);
      expect(SelfUpdater.installPath(plugins, 'emu@emu'), '$plugins/cache/emu/emu/0.4.0');
      record([]);
      expect(SelfUpdater.installPath(plugins, 'emu@emu'), isNull);
    });

    test('without the claude CLI: refused, with the manual steps', () async {
      File('$bin/claude').deleteSync();
      await expectLater(updater('$oldDir/emu', path: bin).preflight(), throwsA(isA<UpdateError>()
          .having((e) => e.refused, 'refused', isTrue)
          .having((e) => e.message, 'message', allOf(contains('/plugin update emu'), contains('/emu-setup')))));
      expect(cmds.calls, isEmpty);
    });

    test('the plugin did not move: an error, no build', () async {
      await expectLater(updater('$oldDir/emu', path: bin).apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('still at'))));
      expect(cmds.calls.where((c) => c.startsWith('bash')), isEmpty);
      expect(Link('$bin/emu').targetSync(), '$oldDir/emu');
    });

    test('a failed claude plugin update stops there', () async {
      cmds.answers['claude plugin update'] = ProcessResult(0, 1, '', 'network down');
      await expectLater(updater('$oldDir/emu', path: bin).apply('0.2.0'),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('network down'))));
      expect(Link('$bin/emu').targetSync(), '$oldDir/emu');
    });
  });

  test('a development build or a loose binary is refused', () async {
    File('${tmp.path}/emu').writeAsStringSync('');
    await expectLater(updater('${tmp.path}/emu', current: '0.0.0-dev').preflight(),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('development build'))));
    await expectLater(updater('${tmp.path}/emu').preflight(),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('cannot locate'))));
  });
}
