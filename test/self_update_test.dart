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

    test('an empty lock left long ago (died before writing its pid) is removed and taken', () async {
      final lock = File('$home/.emu/update.lock')..createSync(recursive: true);
      lock.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 1)));
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
      final stable = '$home/.emu/bin/emu';
      expect(r.binary, stable);
      expect(r.linked, ['$bin/emu']);
      expect(Link('$bin/emu').targetSync(), stable);
      expect(File(stable).readAsStringSync(), 'new');
      expect(File('$oldDir/emu').existsSync(), isTrue, reason: 'the old build stays for whatever still runs it');
      final rec = InstallRecord.read(home)!;
      expect(rec.version, '0.2.0');
      expect(rec.source, 'plugin');
      expect(rec.dir, newDir);
      expect(rec.marketplace, 'emu');
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

    test('characterization: an old version-folder link is a plugin install, any marketplace name', () {
      final dir = '$plugins/cache/some-market/emu/1.2.3';
      Directory(dir).createSync(recursive: true);
      expect(updater('$dir/emu').kind, InstallKind.plugin);
      expect(updater('$oldDir/emu').kind, InstallKind.plugin);
    });

    test('characterization: a checkout inside the plugin cache is a git install', () {
      Directory('$oldDir/.git').createSync();
      File('$oldDir/pubspec.yaml').writeAsStringSync('name: emu\n');
      expect(updater('$oldDir/emu').kind, InstallKind.git);
    });

    test('characterization: a plugin folder with a pubspec but no .git stays a plugin install', () {
      File('$oldDir/pubspec.yaml').writeAsStringSync('name: emu\n');
      expect(updater('$oldDir/emu').kind, InstallKind.plugin);
    });

    test('characterization: up to date, nothing runs and PATH stays', () async {
      final r = await updater('$oldDir/emu', path: bin, current: '0.2.0').apply('0.2.0');
      expect(r.updated, isFalse);
      expect(r.binary, '$oldDir/emu');
      expect(cmds.calls, isEmpty);
      expect(Link('$bin/emu').targetSync(), '$oldDir/emu');
    });

    test('characterization: ~/.local/bin is moved even when it is not on PATH', () async {
      pluginUpdates();
      final tools = '${tmp.path}/tools';
      Directory(tools).createSync();
      File('$tools/claude').writeAsStringSync('');
      final r = await updater('$oldDir/emu', path: tools).apply('0.2.0');
      expect(r.linked, ['$bin/emu']);
    });

    test('characterization: a regular file named emu on PATH is left alone', () async {
      pluginUpdates();
      final other = '${tmp.path}/other';
      Directory(other).createSync();
      File('$other/emu').writeAsStringSync('mine');
      final r = await updater('$oldDir/emu', path: '$other:$bin').apply('0.2.0');
      expect(r.linked, ['$bin/emu']);
      expect(File('$other/emu').readAsStringSync(), 'mine');
    });

    test('characterization: a dangling link that was never ours is left alone', () async {
      pluginUpdates();
      final other = '${tmp.path}/other';
      Directory(other).createSync();
      Link('$other/emu').createSync('${tmp.path}/gone/emu');
      final r = await updater('$oldDir/emu', path: '$other:$bin').apply('0.2.0');
      expect(r.linked, ['$bin/emu']);
      expect(Link('$other/emu').targetSync(), '${tmp.path}/gone/emu');
    });

    test('characterization: a failed update releases the lock', () async {
      cmds.answers['claude plugin update'] = ProcessResult(0, 1, '', 'network down');
      await expectLater(updater('$oldDir/emu', path: bin).apply('0.2.0'), throwsA(isA<UpdateError>()));
      expect(File('$home/.emu/update.lock').existsSync(), isFalse);
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

  group('fixed location', () {
    late String plugins;
    late String bin;
    late String stable;

    /// A plugin version folder Claude Code put on disk.
    String pluginDir(String v, {bool built = false}) {
      final dir = '$plugins/cache/emu/emu/$v';
      Directory('$dir/.claude-plugin').createSync(recursive: true);
      File('$dir/build.sh').writeAsStringSync('');
      File('$dir/.claude-plugin/plugin.json').writeAsStringSync('{"name":"emu","version":"$v"}');
      if (built) File('$dir/emu').writeAsStringSync('build $v');
      return dir;
    }

    void installed(String dir, String v, {String scope = 'user'}) =>
        File('$plugins/installed_plugins.json').writeAsStringSync(jsonEncode({
          'plugins': {
            'emu@emu': [
              {'scope': scope, 'installPath': dir, 'version': v},
            ],
          },
        }));

    void record(String v, {String source = 'plugin', String? dir}) {
      Directory('$home/.emu/bin').createSync(recursive: true);
      File(stable).writeAsStringSync('stable $v');
      InstallRecord(
              version: v, source: source, dir: dir, pluginsDir: plugins, marketplace: 'emu', plugin: 'emu')
          .write(home);
    }

    setUp(() {
      plugins = '$home/.claude/plugins';
      Directory(plugins).createSync(recursive: true);
      bin = '$home/.local/bin';
      Directory(bin).createSync(recursive: true);
      stable = '$home/.emu/bin/emu';
    });

    test('is its own kind; the source comes from the record, the plugin without one', () {
      expect(updater(stable).kind, InstallKind.stable);
      expect(updater(stable).source, InstallKind.plugin);
      record('0.1.0', source: 'git', dir: '${tmp.path}/repo');
      expect(updater(stable).kind, InstallKind.stable);
      expect(updater(stable).source, InstallKind.git);
    });

    test('a version on disk needs neither the network nor claude', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      final dir = pluginDir('0.2.0');
      installed(dir, '0.2.0');
      Link('$bin/emu').createSync(stable);
      cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('build 0.2.0');
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.2.0"}\n', '');
      final u = SelfUpdater(
        executable: stable,
        currentVersion: '0.1.0',
        environment: {'HOME': home, 'PATH': bin},
        run: cmds.call,
        latestVersion: () async => null, // offline
        appInstalled: () => false,
        lockFile: File('$home/.emu/update.lock'),
      );
      expect(u.pluginReady?.version, '0.2.0');
      final c = await u.check();
      expect(c.newer, isTrue);
      expect(c.latest, '0.2.0');
      final r = await u.apply(c.latest!);
      expect(cmds.calls, ['bash build.sh @$dir', 'emu version --json']);
      expect(r.binary, stable);
      expect(r.linked, isEmpty, reason: 'the link already points here');
      expect(File(stable).readAsStringSync(), 'build 0.2.0');
      expect(InstallRecord.read(home)!.version, '0.2.0');
      expect(InstallRecord.read(home)!.dir, dir);
    });

    test('a release newer than what is on disk is fetched; a failed fetch falls back to the disk', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      final dir = pluginDir('0.1.5');
      installed(dir, '0.1.5');
      File('$bin/claude').writeAsStringSync('');
      cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('b');
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.1.5"}\n', '');
      cmds.answers['claude plugin update'] = ProcessResult(0, 1, '', 'offline');
      final lines = <String>[];
      await updater(stable, path: bin).apply('0.2.0', log: lines.add);
      expect(lines, contains(contains('already on disk')));
      expect(InstallRecord.read(home)!.version, '0.1.5');
    });

    test('never a downgrade: an older or same plugin is not ready, an older build not installed', () async {
      record('0.3.0', dir: pluginDir('0.3.0'));
      installed(pluginDir('0.2.0'), '0.2.0', scope: 'project');
      expect(updater(stable, current: '0.3.0').pluginReady, isNull);
      installed(pluginDir('0.3.0'), '0.3.0');
      expect(updater(stable, current: '0.3.0').pluginReady, isNull);
      // A hub still running 0.1.0 after the CLI went to 0.3.0: nothing is ready.
      expect(updater(stable).pluginReady, isNull);
    });

    test('--local looks only at the disk', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      installed(pluginDir('0.1.0'), '0.1.0');
      var asked = false;
      final u = SelfUpdater(
        executable: stable,
        currentVersion: '0.1.0',
        environment: {'HOME': home, 'PATH': ''},
        run: cmds.call,
        latestVersion: () async {
          asked = true;
          return '0.9.0';
        },
        appInstalled: () => false,
        lockFile: File('$home/.emu/update.lock'),
      );
      final c = await u.check(localOnly: true);
      expect(c.newer, isFalse);
      expect(asked, isFalse);
    });

    test('the swap is a rename: a running file keeps its inode and contents', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      final dir = pluginDir('0.2.0');
      installed(dir, '0.2.0');
      cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('new');
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.2.0"}\n', '');
      // An open handle stands for a running binary's mapped file.
      final running = File(stable).openSync();
      addTearDown(running.closeSync);
      await updater(stable, path: bin).apply('0.2.0');
      expect(String.fromCharCodes(running.readSync(100)), 'stable 0.1.0');
      expect(File(stable).readAsStringSync(), 'new');
      expect(Directory('$home/.emu/bin').listSync().map((e) => e.path.split('/').last).toSet(), {'emu', 'emu.json'},
          reason: 'no temp file left');
    });

    test('a failed install leaves the old binary', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      final dir = pluginDir('0.2.0');
      installed(dir, '0.2.0');
      cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('new');
      await expectLater(updater(stable, path: bin).apply('0.2.0'), throwsA(isA<UpdateError>()));
      expect(File(stable).readAsStringSync(), 'stable 0.1.0', reason: 'no version: not installed');
    });

    test('another update holding the lock is refused, and migrate too', () async {
      record('0.1.0', dir: pluginDir('0.1.0'));
      final lock = File('$home/.emu/update.lock')..writeAsStringSync('');
      addTearDown(() {
        if (lock.existsSync()) lock.deleteSync();
      });
      final dir = pluginDir('0.1.0');
      Link('$bin/emu').createSync('$plugins/cache/emu/emu/0.0.9/emu');
      await expectLater(updater(stable, path: bin).migrate(), throwsA(isA<UpdateError>()));
      await expectLater(updater('$dir/emu', path: bin).install(), throwsA(isA<UpdateError>()));
      expect(Link('$bin/emu').targetSync(), '$plugins/cache/emu/emu/0.0.9/emu');
    });

    group('migration', () {
      test('(a) a link to the running binary and (b) a dead plugin link move; the rest stay', () async {
        final dir = pluginDir('0.1.0', built: true);
        final other = '${tmp.path}/other';
        final dead = '${tmp.path}/dead';
        final mine = '${tmp.path}/mine';
        final alive = '${tmp.path}/alive';
        for (final d in [other, dead, mine, alive]) {
          Directory(d).createSync();
        }
        Link('$bin/emu').createSync('$dir/emu');
        Link('$dead/emu').createSync('$plugins/cache/emu/emu/0.0.1/emu');
        Link('$mine/emu').createSync('${tmp.path}/checkout/emu'); // dangling, not the plugin's
        final older = pluginDir('0.0.9', built: true);
        Link('$alive/emu').createSync('$older/emu'); // not dangling, not running
        File('$other/emu').writeAsStringSync('mine');
        final u = updater('$dir/emu', path: '$other:$dead:$mine:$alive:$bin');
        final r = await u.migrate();
        expect(r!.binary, stable);
        expect(r.linked, unorderedEquals(['$bin/emu', '$dead/emu']));
        expect(Link('$bin/emu').targetSync(), stable);
        expect(Link('$dead/emu').targetSync(), stable);
        expect(Link('$mine/emu').targetSync(), '${tmp.path}/checkout/emu');
        expect(Link('$alive/emu').targetSync(), '$older/emu');
        expect(File('$other/emu').readAsStringSync(), 'mine');
        expect(File(stable).readAsStringSync(), 'build 0.1.0');
        final rec = InstallRecord.read(home)!;
        expect(rec.source, 'plugin');
        expect(rec.dir, dir);
      });

      test('a dead plugin link of another plugin name stays', () async {
        final dir = pluginDir('0.1.0', built: true);
        Link('$bin/emu').createSync('$plugins/cache/emu/other/0.0.1/emu');
        await updater('$dir/emu', path: bin).migrate();
        expect(Link('$bin/emu').targetSync(), '$plugins/cache/emu/other/0.0.1/emu');
      });

      test('a git checkout is not moved', () async {
        final repo = '${tmp.path}/emu';
        Directory('$repo/.git').createSync(recursive: true);
        File('$repo/pubspec.yaml').writeAsStringSync('name: emu\n');
        File('$repo/emu').writeAsStringSync('old');
        Link('$bin/emu').createSync('$repo/emu');
        expect(await updater('$repo/emu', path: bin).migrate(), isNull);
        expect(Link('$bin/emu').targetSync(), '$repo/emu');
        expect(File(stable).existsSync(), isFalse);
      });

      test('stable with nothing to repair does nothing', () async {
        record('0.1.0');
        Link('$bin/emu').createSync(stable);
        expect(await updater(stable, path: bin).migrate(), isNull);
      });

      test('stable repairs a dead plugin link', () async {
        record('0.1.0');
        Link('$bin/emu').createSync('$plugins/cache/emu/emu/0.0.1/emu');
        final r = await updater(stable, path: bin).migrate();
        expect(r!.linked, ['$bin/emu']);
        expect(Link('$bin/emu').targetSync(), stable);
      });

      test('an old pinned binary does not replace a newer one, but its link moves', () async {
        record('0.5.0');
        final dir = pluginDir('0.1.0', built: true);
        Link('$bin/emu').createSync('$dir/emu');
        final lines = <String>[];
        await updater('$dir/emu', path: bin).migrate(log: lines.add);
        expect(File(stable).readAsStringSync(), 'stable 0.5.0');
        expect(InstallRecord.read(home)!.version, '0.5.0');
        expect(Link('$bin/emu').targetSync(), stable);
        expect(lines, contains(contains('keeping it')));
      });

      test('a development build never migrates', () async {
        final dir = pluginDir('0.1.0', built: true);
        expect(await updater('$dir/emu', path: bin, current: '0.0.0-dev').migrate(), isNull);
        expect(File(stable).existsSync(), isFalse);
      });
    });

    test('install from a checkout records git, and update then pulls that checkout', () async {
      final repo = '${tmp.path}/emu';
      Directory('$repo/.git').createSync(recursive: true);
      File('$repo/pubspec.yaml').writeAsStringSync('name: emu\n');
      File('$repo/emu').writeAsStringSync('old');
      await updater('$repo/emu', path: bin).install();
      final rec = InstallRecord.read(home)!;
      expect(rec.source, 'git');
      expect(rec.dir, repo);
      cmds.effects['bash build.sh'] = (wd) => File('$wd/emu').writeAsStringSync('new');
      cmds.answers['emu version --json'] = ProcessResult(0, 0, '{"version":"0.2.0"}\n', '');
      final r = await updater(stable, path: bin).apply('0.2.0');
      expect(cmds.calls, contains('git -C $repo pull --ff-only'));
      expect(r.binary, stable);
      expect(File(stable).readAsStringSync(), 'new');
      expect(InstallRecord.read(home)!.source, 'git');
    });

    test('the macOS app follows the new path', () async {
      final dir = pluginDir('0.1.0', built: true);
      cmds.answers['emu app install'] = ProcessResult(0, 0, '{"ok":true}\n', '');
      final r = await updater('$dir/emu', path: bin, app: true).migrate();
      expect(cmds.calls.last, 'emu app install --if-changed --json');
      expect(r!.app, 'updated');
    });
  });

  test('characterization: a loose binary is unknown and nothing runs', () async {
    final u = updater('${tmp.path}/emu');
    expect(u.kind, InstallKind.unknown);
    await expectLater(u.check(), throwsA(isA<UpdateError>().having((e) => e.refused, 'refused', isTrue)));
    await expectLater(u.apply('0.2.0'), throwsA(isA<UpdateError>().having((e) => e.refused, 'refused', isTrue)));
    expect(cmds.calls, isEmpty);
  });

  test('a development build or a loose binary is refused', () async {
    File('${tmp.path}/emu').writeAsStringSync('');
    await expectLater(updater('${tmp.path}/emu', current: '0.0.0-dev').preflight(),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('development build'))));
    await expectLater(updater('${tmp.path}/emu').preflight(),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('cannot locate'))));
  });
}
