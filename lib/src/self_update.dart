/// `emu update` — and the hub's Update button, which runs the same steps in
/// the hub process. Two ways emu gets installed, both handled here:
///
/// - git checkout: the binary sits in a clone of the repo (`emu-setup` from a
///   checkout, or a manual `./build.sh`) → `git pull --ff-only` + `build.sh`
///   in place. build.sh swaps the new binary in with a rename, so a running
///   `emu` (the hub) keeps its own file.
/// - Claude Code plugin: the binary sits in the plugin cache
///   (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/emu`), PATH
///   links to it (`emu-setup`) → `claude plugin marketplace update` +
///   `claude plugin update` fetch the new version into a new cache folder,
///   `build.sh` builds it there, and the PATH links that pointed at the old
///   binary are moved to the new one. Without the `claude` CLI: the old
///   advice (`/plugin update emu`, then `/emu-setup`).
///
/// Then the macOS app, if installed, is rebuilt by the new binary when its
/// sources (or the binary it runs) changed. Every command goes through
/// [UpdateRunner], so tests run it all against fake commands.
library;

import 'dart:convert';
import 'dart:io';

import 'version.dart';

/// Runs one command of the update — a seam for tests.
typedef UpdateRunner = Future<ProcessResult> Function(String exe, List<String> args, {String? workingDirectory});

Future<ProcessResult> _runProcess(String exe, List<String> args, {String? workingDirectory}) =>
    Process.run(exe, args, workingDirectory: workingDirectory);

enum InstallKind { git, plugin, unknown }

/// Where an update stopped, and why. [refused] = nothing was changed (dirty
/// tree, no `claude` CLI, another update running…).
class UpdateError implements Exception {
  UpdateError(this.message, {this.refused = false});
  final String message;
  final bool refused;
  @override
  String toString() => message;
}

class UpdateResult {
  UpdateResult({
    required this.install,
    required this.from,
    required this.latest,
    this.updated = false,
    this.binary,
    this.linked = const [],
    this.app,
  });
  final InstallKind install;
  final String from;
  final String latest;
  final bool updated;

  /// The new emu binary (what to restart the hub with).
  final String? binary;

  /// PATH links moved to [binary] (plugin installs).
  final List<String> linked;

  /// The macOS app: `updated`, `current`, `failed: …`, or null when not installed.
  final String? app;

  Map<String, dynamic> toJson() => {
        'ok': true,
        'updated': updated,
        'install': install.name,
        if (updated) ...{'from': from, 'to': latest} else ...{'current': from, 'latest': latest},
        'binary': ?binary,
        if (linked.isNotEmpty) 'linked': linked,
        'app': ?app,
      };
}

class SelfUpdater {
  SelfUpdater({
    String? executable,
    String? currentVersion,
    Map<String, String>? environment,
    UpdateRunner? run,
    Future<String?> Function()? latestVersion,
    this.appInstalled,
    File? lockFile,
  })  : executable = executable ?? _resolvedSelf(),
        currentVersion = currentVersion ?? kEmuVersion,
        env = environment ?? Platform.environment,
        _run = run ?? _runProcess,
        _latestVersion = latestVersion ?? latestReleaseVersion,
        lockFile = lockFile ?? File('${(environment ?? Platform.environment)['HOME'] ?? '.'}/.emu/update.lock');

  /// The running emu binary, links resolved.
  final String executable;
  final String currentVersion;
  final Map<String, String> env;
  final UpdateRunner _run;
  final Future<String?> Function() _latestVersion;

  /// Whether the macOS app is installed (default: `~/Applications/emu.app`).
  final bool Function()? appInstalled;

  /// Held while an update runs, so the CLI and the hub can't run two at once.
  final File lockFile;

  static String _resolvedSelf() => _resolve(Platform.resolvedExecutable);

  static String _resolve(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  Directory get _dir => File(executable).parent;

  InstallKind get kind {
    if (File('${_dir.path}/pubspec.yaml').existsSync() && Directory('${_dir.path}/.git').existsSync()) {
      return InstallKind.git;
    }
    if (_plugin != null) return InstallKind.plugin;
    return InstallKind.unknown;
  }

  /// `…/plugins/cache/<marketplace>/<plugin>/<version>/emu` → its parts.
  ({String pluginsDir, String marketplace, String plugin})? get _plugin {
    final m = RegExp(r'^(.*/plugins)/cache/([^/]+)/([^/]+)/[^/]+/[^/]+$').firstMatch(executable);
    if (m == null) return null;
    return (pluginsDir: m.group(1)!, marketplace: m.group(2)!, plugin: m.group(3)!);
  }

  /// A command on PATH, or null.
  String? which(String name) {
    for (final dir in (env['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final f = File('$dir/$name');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// What can be checked without changing anything: how emu is installed
  /// ([checkInstall]), and whether it can update itself now ([checkReady]).
  /// Throws a refusing [UpdateError] when it can't.
  Future<InstallKind> preflight() async {
    checkInstall();
    return checkReady();
  }

  /// A release build, installed in a way this can update. No commands run.
  InstallKind checkInstall() {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(currentVersion)) {
      throw UpdateError('this is a development build (v$currentVersion) — update its checkout yourself.', refused: true);
    }
    final k = kind;
    if (k == InstallKind.unknown) throw _unknownInstall();
    return k;
  }

  /// What `emu update` asks before it asks the user: the install
  /// ([checkInstall]), the latest release (null: offline), and — only when
  /// there is something newer — [checkReady], so an up-to-date checkout with
  /// local changes is just up to date.
  Future<({InstallKind install, String? latest, bool newer})> check() async {
    final install = checkInstall();
    final latest = await _latestVersion();
    final newer = latest != null && isNewer(latest, currentVersion);
    if (newer) await checkReady();
    return (install: install, latest: latest, newer: newer);
  }

  /// Whether it can update now: a clean checkout, or the `claude` CLI.
  Future<InstallKind> checkReady() async {
    switch (kind) {
      case InstallKind.git:
        final dirty = await _run('git', ['-C', _dir.path, 'status', '--porcelain']);
        if (dirty.exitCode == 0 && '${dirty.stdout}'.trim().isNotEmpty) {
          throw UpdateError('refusing to update: uncommitted changes in ${_dir.path} — commit or stash first.',
              refused: true);
        }
        return InstallKind.git;
      case InstallKind.plugin:
        if (which('claude') == null) {
          throw UpdateError(
              'this emu was installed as a Claude Code plugin and the `claude` CLI is not on PATH, so '
              '`emu update` can\'t fetch the new version itself. Update the plugin from Claude Code '
              '(e.g. `/plugin update emu`), then re-run the `/emu-setup` command to rebuild the binary '
              'and refresh the PATH symlink.',
              refused: true);
        }
        return InstallKind.plugin;
      case InstallKind.unknown:
        throw _unknownInstall();
    }
  }

  static UpdateError _unknownInstall() => UpdateError(
      'cannot locate the emu source checkout or plugin folder next to the running binary '
      '(expected the PATH symlink from `emu-setup` to point into a git checkout or the Claude Code '
      'plugin cache).',
      refused: true);

  /// The newest release, or null when GitHub can't be reached.
  Future<String?> latest() => _latestVersion();

  /// Update to [latest] (from [this.latest]). [log] gets one line per step.
  Future<UpdateResult> apply(String latest, {void Function(String)? log}) async {
    final say = log ?? (_) {};
    final install = checkInstall();
    if (!isNewer(latest, currentVersion)) {
      return UpdateResult(install: install, from: currentVersion, latest: latest, binary: executable);
    }
    await checkReady();
    _lock();
    try {
      final binary = install == InstallKind.git ? await _updateGit(say) : await _updatePlugin(latest, say);
      final linked = install == InstallKind.plugin ? _relink(binary, say) : const <String>[];
      final app = await _updateApp(binary, say);
      return UpdateResult(
          install: install, from: currentVersion, latest: latest, updated: true, binary: binary, linked: linked, app: app);
    } finally {
      _unlock();
    }
  }

  Future<String> _updateGit(void Function(String) say) async {
    say('» git pull --ff-only');
    final pull = await _run('git', ['-C', _dir.path, 'pull', '--ff-only']);
    if (pull.exitCode != 0) throw UpdateError('git pull failed: ${_out(pull)}');
    await _build(_dir.path, say);
    return '${_dir.path}/emu';
  }

  Future<String> _updatePlugin(String latest, void Function(String) say) async {
    final p = _plugin!;
    final claude = which('claude')!;
    final id = '${p.plugin}@${p.marketplace}';
    say('» claude plugin marketplace update ${p.marketplace}');
    final market = await _run(claude, ['plugin', 'marketplace', 'update', p.marketplace]);
    if (market.exitCode != 0) throw UpdateError('claude plugin marketplace update failed: ${_out(market)}');
    say('» claude plugin update $id');
    final up = await _run(claude, ['plugin', 'update', id]);
    if (up.exitCode != 0) throw UpdateError('claude plugin update failed: ${_out(up)}');
    final dir = installPath(p.pluginsDir, id);
    if (dir == null || !File('$dir/build.sh').existsSync()) {
      throw UpdateError('cannot find the updated plugin folder in ${p.pluginsDir}/installed_plugins.json');
    }
    if (_resolve(dir) == _resolve(_dir.path)) {
      throw UpdateError('the plugin is still at $dir after `claude plugin update` — '
          'the marketplace may not have v$latest yet; try again later.');
    }
    await _build(dir, say);
    // Only a newer build takes over PATH: never link an older cache folder.
    final built = await _builtVersion('$dir/emu');
    if (built == null || !isNewer(built, currentVersion)) {
      throw UpdateError('the build in $dir is v${built ?? '?'}, not newer than v$currentVersion — '
          'PATH still points at the old one.');
    }
    return '$dir/emu';
  }

  /// The version a built binary reports (`emu version --json`).
  Future<String?> _builtVersion(String binary) async {
    try {
      final r = await _run(binary, ['version', '--json']);
      final v = (jsonDecode('${r.stdout}'.trim().split('\n').last) as Map)['version'] as String?;
      return v != null && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v) ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// The install folder Claude Code recorded for [id] (`emu@emu`): of the
  /// entries whose folder exists, the user-scope one with the highest
  /// version (any scope when there is no user one). Old cache folders stay
  /// on disk, and a project scope may pin an older version.
  static String? installPath(String pluginsDir, String id) {
    try {
      final m = jsonDecode(File('$pluginsDir/installed_plugins.json').readAsStringSync()) as Map<String, dynamic>;
      final entries = [
        for (final e in ((m['plugins'] ?? m) as Map<String, dynamic>)[id] as List? ?? const [])
          if (e is Map && e['installPath'] is String && Directory(e['installPath'] as String).existsSync()) e,
      ];
      final user = entries.where((e) => e['scope'] == 'user').toList();
      final pool = user.isNotEmpty ? user : entries;
      if (pool.isEmpty) return null;
      String ver(Map e) {
        final v = e['version'];
        return v is String && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v) ? v : '0.0.0';
      }

      pool.sort((a, b) => compareSemver(ver(b), ver(a)));
      return pool.first['installPath'] as String;
    } catch (_) {
      return null;
    }
  }

  Future<void> _build(String dir, void Function(String) say) async {
    say('» building (build.sh)');
    final build = await _run('bash', ['build.sh'], workingDirectory: dir);
    if (build.exitCode != 0) throw UpdateError('build failed: ${_out(build)}');
    if (!File('$dir/emu').existsSync()) throw UpdateError('build.sh did not produce $dir/emu');
  }

  /// Move every PATH link (and `emu-setup`'s two targets) that pointed at the
  /// old binary to [binary]. Each swap is a rename, so `emu` on PATH is never
  /// missing, even for a moment.
  List<String> _relink(String binary, void Function(String) say) {
    final home = env['HOME'];
    final dirs = <String>{
      ...(env['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
      '/usr/local/bin',
      if (home != null) '$home/.local/bin',
    };
    final old = _resolve(executable);
    final moved = <String>[];
    for (final dir in dirs) {
      final link = Link('$dir/emu');
      try {
        if (!link.existsSync() || File(link.path).resolveSymbolicLinksSync() != old) continue;
      } on FileSystemException {
        continue; // dangling, or not ours
      }
      final tmp = Link('$dir/.emu.update.$pid');
      try {
        if (tmp.existsSync()) tmp.deleteSync();
        tmp.createSync(binary);
        tmp.renameSync(link.path);
        say('» linked ${link.path} → $binary');
        moved.add(link.path);
      } on FileSystemException catch (e) {
        if (tmp.existsSync()) tmp.deleteSync();
        throw UpdateError('could not move ${link.path} to $binary: ${e.message} — re-run `/emu-setup`');
      }
    }
    if (moved.isEmpty) say('! no PATH link pointed at $executable — link $binary yourself (or re-run `/emu-setup`)');
    return moved;
  }

  Future<String?> _updateApp(String binary, void Function(String) say) async {
    final installed = appInstalled?.call() ??
        Directory('${env['HOME'] ?? '.'}/Applications/emu.app').existsSync();
    if (!installed) return null;
    say('» updating the macOS app');
    // The new binary decides: it knows its own app sources, and rebuilds when
    // they or the binary path the app records changed.
    final r = await _run(binary, ['app', 'install', '--if-changed', '--json']);
    if (r.exitCode != 0) {
      final why = _out(r);
      say('! could not rebuild the app: $why');
      return 'failed: $why';
    }
    try {
      return (jsonDecode('${r.stdout}'.trim().split('\n').last) as Map)['skipped'] == true ? 'current' : 'updated';
    } catch (_) {
      return 'updated';
    }
  }

  /// Take [lockFile]: only an exclusive create counts. A lock left by a dead
  /// process is removed and the create tried again; an empty one is being
  /// taken by someone else right now — unless it is old: the holder died
  /// between the create and writing its pid, which is otherwise instant.
  void _lock() {
    lockFile.parent.createSync(recursive: true);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        lockFile.createSync(exclusive: true);
        lockFile.writeAsStringSync('$pid');
        return;
      } on FileSystemException {
        String content;
        try {
          content = lockFile.readAsStringSync().trim();
        } on FileSystemException {
          continue; // the holder just finished: try again
        }
        final holder = int.tryParse(content);
        if ((content.isEmpty && !_old(lockFile)) || (holder != null && holder != pid && _alive(holder))) {
          throw UpdateError('another emu update is running${holder == null ? '' : ' (pid $holder)'}.', refused: true);
        }
        try {
          lockFile.deleteSync(); // stale
        } on FileSystemException {
          // Someone else removed it first.
        }
      }
    }
    throw UpdateError('another emu update is running.', refused: true);
  }

  void _unlock() {
    try {
      if (lockFile.readAsStringSync().trim() == '$pid') lockFile.deleteSync();
    } on FileSystemException {
      // Gone.
    }
  }

  static bool _old(File f) {
    try {
      return DateTime.now().difference(f.lastModifiedSync()) > const Duration(seconds: 5);
    } on FileSystemException {
      return false; // gone: the next create decides
    }
  }

  static bool _alive(int p) {
    try {
      return Process.runSync('kill', ['-0', '$p']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static String _out(ProcessResult r) => '${r.stderr}\n${r.stdout}'.trim();
}
