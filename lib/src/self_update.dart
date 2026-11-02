/// `emu update` — and the hub's Update button, which runs the same steps in
/// the hub process. The ways emu gets installed, all handled here:
///
/// - git checkout: the binary sits in a clone of the repo (`emu-setup` from a
///   checkout, or a manual `./build.sh`) → `git pull --ff-only` + `build.sh`
///   in place. build.sh swaps the new binary in with a rename, so a running
///   `emu` (the hub) keeps its own file.
/// - fixed location: the binary sits in `~/.emu/bin/emu`, whatever the plugin
///   version, and PATH links to it (`emu install`, which `emu-setup` runs).
///   `~/.emu/bin/emu.json` records where it came from ([InstallRecord]). A new
///   version is built in its source folder, then copied in and renamed over
///   the old file ([_installStable]): running hubs and sessions keep their
///   inode, and nothing is ever rewritten in place (macOS kills a signed
///   binary whose pages changed).
/// - Claude Code plugin, older installs: the binary sits in the plugin cache
///   (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/emu`), PATH
///   links to it. The next `emu update` moves them to the fixed location.
///
/// A plugin source: when Claude Code already fetched a newer version
/// (auto-update), that folder is built as is ([pluginReady]) — no network, no
/// `claude` CLI. Otherwise `claude plugin marketplace update` + `claude plugin
/// update` fetch it first. Without the `claude` CLI and nothing fetched: the
/// old advice (`/plugin update emu`, then `/emu-setup`).
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

/// How the running binary is installed. [stable] is `~/.emu/bin/emu`; its
/// source ([SelfUpdater.source]) is a [git] checkout or a [plugin].
enum InstallKind { git, plugin, stable, unknown }

/// `~/.emu/bin/emu.json`: what the binary next to it was built from. The
/// SessionStart hook reads `version` from it too (hooks/session-start.sh), so
/// keep one key per line.
class InstallRecord {
  InstallRecord({required this.version, required this.source, this.dir, this.pluginsDir, this.marketplace, this.plugin});

  final String version;

  /// `plugin` or `git`.
  final String source;

  /// The source folder it was built in.
  final String? dir;
  final String? pluginsDir;
  final String? marketplace;
  final String? plugin;

  static File fileIn(String home) => File('$home/.emu/bin/emu.json');

  static InstallRecord? read(String home) {
    try {
      final m = jsonDecode(fileIn(home).readAsStringSync()) as Map<String, dynamic>;
      final version = m['version'];
      if (version is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return null;
      return InstallRecord(
        version: version,
        source: m['source'] == 'git' ? 'git' : 'plugin',
        dir: m['dir'] as String?,
        pluginsDir: m['pluginsDir'] as String?,
        marketplace: m['marketplace'] as String?,
        plugin: m['plugin'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  void write(String home) {
    final f = fileIn(home);
    final tmp = File('${f.path}.$pid');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
      'version': version,
      'source': source,
      'dir': ?dir,
      'pluginsDir': ?pluginsDir,
      'marketplace': ?marketplace,
      'plugin': ?plugin,
    })}\n');
    tmp.renameSync(f.path);
  }
}

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

  String get _home => env['HOME'] ?? '.';

  /// Where emu lives, whatever the plugin version.
  String get stableBinary => '$_home/.emu/bin/emu';

  InstallRecord? get record => InstallRecord.read(_home);

  InstallKind get kind {
    if (executable == stableBinary || executable == _resolve(stableBinary)) return InstallKind.stable;
    if (File('${_dir.path}/pubspec.yaml').existsSync() && Directory('${_dir.path}/.git').existsSync()) {
      return InstallKind.git;
    }
    if (_cachePlugin != null) return InstallKind.plugin;
    return InstallKind.unknown;
  }

  /// Where updates come from: [kind], with [InstallKind.stable] replaced by
  /// what it was built from. No record (removed by hand): the plugin, which is
  /// how `~/.emu/bin` gets filled.
  InstallKind get source {
    final k = kind;
    if (k != InstallKind.stable) return k;
    return record?.source == 'git' ? InstallKind.git : InstallKind.plugin;
  }

  /// The checkout to pull and build.
  String get _gitDir => kind == InstallKind.stable ? record?.dir ?? _dir.path : _dir.path;

  /// `…/plugins/cache/<marketplace>/<plugin>/<version>/emu` → its parts; the
  /// record's for the fixed location.
  ({String pluginsDir, String marketplace, String plugin})? get _plugin {
    if (kind == InstallKind.stable) {
      final r = record;
      return (
        pluginsDir: r?.pluginsDir ?? '$_home/.claude/plugins',
        marketplace: r?.marketplace ?? 'emu',
        plugin: r?.plugin ?? 'emu',
      );
    }
    return _cachePlugin;
  }

  ({String pluginsDir, String marketplace, String plugin})? get _cachePlugin {
    final m = RegExp(r'^(.*/plugins)/cache/([^/]+)/([^/]+)/[^/]+/[^/]+$').firstMatch(executable);
    if (m == null) return null;
    return (pluginsDir: m.group(1)!, marketplace: m.group(2)!, plugin: m.group(3)!);
  }

  /// A newer version Claude Code already put on disk (auto-update, or
  /// `/plugin update`) but this CLI isn't built from yet: no network needed.
  /// Newer only: a project scope pinning an older version is no downgrade,
  /// and [installPath] prefers the user scope.
  ({String version, String dir})? get pluginReady {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(currentVersion) || source != InstallKind.plugin) return null;
    final p = _plugin;
    if (p == null) return null;
    final dir = installPath(p.pluginsDir, '${p.plugin}@${p.marketplace}');
    if (dir == null || !File('$dir/build.sh').existsSync()) return null;
    final String version;
    try {
      final v = (jsonDecode(File('$dir/.claude-plugin/plugin.json').readAsStringSync()) as Map)['version'];
      if (v is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v)) return null;
      version = v;
    } catch (_) {
      return null;
    }
    // A hub still running after `emu update` replaced the file: what is
    // installed counts, not what this process is.
    final installed = record?.version;
    final base = kind == InstallKind.stable && installed != null && isNewer(installed, currentVersion)
        ? installed
        : currentVersion;
    return isNewer(version, base) ? (version: version, dir: dir) : null;
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
  /// local changes is just up to date. [localOnly] looks only at what is
  /// already on disk ([pluginReady]) — the background auto-update.
  Future<({InstallKind install, String? latest, bool newer})> check({bool localOnly = false}) async {
    final install = checkInstall();
    final latest = localOnly ? pluginReady?.version ?? currentVersion : await this.latest();
    final newer = latest != null && isNewer(latest, currentVersion);
    if (newer) await checkReady();
    return (install: install, latest: latest, newer: newer);
  }

  /// Whether it can update now: a clean checkout, or the `claude` CLI (or a
  /// version already on disk, which doesn't need it).
  Future<InstallKind> checkReady() async {
    final k = kind;
    switch (source) {
      case InstallKind.git:
        final dirty = await _run('git', ['-C', _gitDir, 'status', '--porcelain']);
        if (dirty.exitCode == 0 && '${dirty.stdout}'.trim().isNotEmpty) {
          throw UpdateError('refusing to update: uncommitted changes in $_gitDir — commit or stash first.',
              refused: true);
        }
        return k;
      case InstallKind.plugin:
        if (which('claude') == null && pluginReady == null) {
          throw UpdateError(
              'this emu was installed as a Claude Code plugin and the `claude` CLI is not on PATH, so '
              '`emu update` can\'t fetch the new version itself. Update the plugin from Claude Code '
              '(e.g. `/plugin update emu`), then re-run the `/emu-setup` command to rebuild the binary '
              'and refresh the PATH symlink.',
              refused: true);
        }
        return k;
      case InstallKind.stable:
      case InstallKind.unknown:
        throw _unknownInstall();
    }
  }

  static UpdateError _unknownInstall() => UpdateError(
      'cannot locate the emu source checkout or plugin folder next to the running binary '
      '(expected the PATH symlink from `emu-setup` to point into a git checkout or the Claude Code '
      'plugin cache).',
      refused: true);

  /// The newest version to go to, or null when GitHub can't be reached and
  /// nothing newer is on disk.
  Future<String?> latest() async {
    final released = await _latestVersion();
    final ready = pluginReady?.version;
    if (released == null || ready == null) return released ?? ready;
    return isNewer(ready, released) ? ready : released;
  }

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
      final fromPlugin = source == InstallKind.plugin;
      final binary = fromPlugin ? await _updatePlugin(latest, say) : await _updateGit(say);
      final linked = fromPlugin ? _relink(binary, say) : const <String>[];
      final app = await _updateApp(binary, say);
      return UpdateResult(
          install: install, from: currentVersion, latest: latest, updated: true, binary: binary, linked: linked, app: app);
    } finally {
      _unlock();
    }
  }

  Future<String> _updateGit(void Function(String) say) async {
    say('» git pull --ff-only');
    final dir = _gitDir;
    final pull = await _run('git', ['-C', dir, 'pull', '--ff-only']);
    if (pull.exitCode != 0) throw UpdateError('git pull failed: ${_out(pull)}');
    await _build(dir, say);
    if (kind != InstallKind.stable) return '$dir/emu';
    final built = await _builtVersion('$dir/emu');
    if (built == null) throw UpdateError('cannot tell the version of the build in $dir.');
    _installStable('$dir/emu', InstallRecord(version: built, source: 'git', dir: dir), say);
    return stableBinary;
  }

  Future<String> _updatePlugin(String latest, void Function(String) say) async {
    final p = _plugin!;
    final id = '${p.plugin}@${p.marketplace}';
    final ready = pluginReady;
    // Already on disk and as new as it gets: nothing to fetch.
    if (ready == null || isNewer(latest, ready.version)) {
      final claude = which('claude');
      try {
        if (claude == null) throw UpdateError('no `claude` CLI');
        say('» claude plugin marketplace update ${p.marketplace}');
        final market = await _run(claude, ['plugin', 'marketplace', 'update', p.marketplace]);
        if (market.exitCode != 0) throw UpdateError('claude plugin marketplace update failed: ${_out(market)}');
        say('» claude plugin update $id');
        final up = await _run(claude, ['plugin', 'update', id]);
        if (up.exitCode != 0) throw UpdateError('claude plugin update failed: ${_out(up)}');
      } on UpdateError catch (e) {
        if (ready == null) rethrow;
        say('! could not fetch v$latest (${e.message}) — using v${ready.version}, already on disk');
      }
    }
    final dir = installPath(p.pluginsDir, id);
    if (dir == null || !File('$dir/build.sh').existsSync()) {
      throw UpdateError('cannot find the updated plugin folder in ${p.pluginsDir}/installed_plugins.json');
    }
    final current = kind == InstallKind.stable ? record?.dir : _dir.path;
    if (current != null && _resolve(dir) == _resolve(current) && pluginReady == null) {
      throw UpdateError('the plugin is still at $dir after `claude plugin update` — '
          'the marketplace may not have v$latest yet; try again later.');
    }
    await _build(dir, say);
    // Only a newer build takes over: never an older cache folder.
    final built = await _builtVersion('$dir/emu');
    if (built == null || !isNewer(built, currentVersion)) {
      throw UpdateError('the build in $dir is v${built ?? '?'}, not newer than v$currentVersion — '
          'PATH still points at the old one.');
    }
    final installed = record?.version;
    if (installed != null && File(stableBinary).existsSync() && isNewer(installed, built)) {
      throw UpdateError('the build in $dir is v$built, older than the installed v$installed — keeping that one.');
    }
    _installStable(
        '$dir/emu',
        InstallRecord(
            version: built, source: 'plugin', dir: dir, pluginsDir: p.pluginsDir, marketplace: p.marketplace, plugin: p.plugin),
        say);
    return stableBinary;
  }

  /// Copy [from] next to the fixed location and rename it there, then record
  /// it. The rename leaves the old inode to whoever runs it (a hub, sessions);
  /// a copy over it would change a running, signed binary.
  void _installStable(String from, InstallRecord rec, void Function(String) say) {
    final dst = File(stableBinary);
    final tmp = File('${dst.path}.tmp.$pid');
    try {
      dst.parent.createSync(recursive: true);
      if (tmp.existsSync()) tmp.deleteSync();
      File(from).copySync(tmp.path); // keeps the mode
      tmp.renameSync(dst.path);
      rec.write(_home);
    } on FileSystemException catch (e) {
      if (tmp.existsSync()) tmp.deleteSync();
      throw UpdateError('could not install ${dst.path}: ${e.message}');
    }
    say('» installed ${dst.path} (v${rec.version})');
  }

  /// `emu install`: put this binary in the fixed location and move the PATH
  /// links ([_relink]), from any install. A newer one already there stays:
  /// a project scope pinning an old plugin never downgrades. Refuses what
  /// [checkInstall] refuses.
  Future<UpdateResult> install({void Function(String)? log}) async {
    final say = log ?? (_) {};
    final k = checkInstall();
    _lock();
    try {
      final linked = _adopt(say);
      final app = await _updateApp(stableBinary, say);
      return UpdateResult(install: k, from: currentVersion, latest: currentVersion, binary: stableBinary, linked: linked, app: app);
    } finally {
      _unlock();
    }
  }

  /// What `emu update` does when there is nothing newer: an old version-folder
  /// plugin install moves to the fixed location, and links left dangling by
  /// the plugin's cleanup are repaired. Git checkouts stay where they are.
  /// Null when there was nothing to do.
  Future<UpdateResult?> migrate({void Function(String)? log}) async {
    final say = log ?? (_) {};
    final k = kind;
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(currentVersion)) return null;
    if (k == InstallKind.git || k == InstallKind.unknown) return null;
    if (k == InstallKind.stable && _deadPluginLinks().isEmpty) return null;
    _lock();
    try {
      final linked = _adopt(say);
      final app = k == InstallKind.stable && linked.isEmpty ? null : await _updateApp(stableBinary, say);
      return UpdateResult(install: k, from: currentVersion, latest: currentVersion, binary: stableBinary, linked: linked, app: app);
    } finally {
      _unlock();
    }
  }

  List<String> _adopt(void Function(String) say) {
    if (kind != InstallKind.stable) {
      final installed = record?.version;
      if (installed != null && File(stableBinary).existsSync() && isNewer(installed, currentVersion)) {
        say('! $stableBinary is already v$installed, newer than this v$currentVersion — keeping it');
      } else {
        final p = _plugin;
        _installStable(
            executable,
            p != null
                ? InstallRecord(
                    version: currentVersion,
                    source: 'plugin',
                    dir: _dir.path,
                    pluginsDir: p.pluginsDir,
                    marketplace: p.marketplace,
                    plugin: p.plugin)
                : InstallRecord(version: currentVersion, source: 'git', dir: _dir.path),
            say);
      }
    }
    return _relink(stableBinary, say);
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

  /// PATH's folders and `emu-setup`'s two targets.
  Set<String> get _linkDirs => {
        ...(env['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
        '/usr/local/bin',
        if (env['HOME'] != null) '${env['HOME']}/.local/bin',
      };

  static final _pluginBuild = RegExp(r'/plugins/cache/[^/]+/emu/[^/]+/emu$');

  /// A link into the plugin cache whose version folder is gone.
  static bool _deadPluginLink(Link link) {
    try {
      final target = link.targetSync();
      return _pluginBuild.hasMatch(target) && !File(target).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  List<Link> _deadPluginLinks() => [
        for (final dir in _linkDirs)
          if (_deadPluginLink(Link('$dir/emu'))) Link('$dir/emu'),
      ];

  /// Move every PATH link (and `emu-setup`'s two targets) that pointed at the
  /// running binary, or at a plugin build whose folder is gone, to [binary].
  /// Any other link is someone's own. Each swap is a rename, so `emu` on PATH
  /// is never missing, even for a moment.
  List<String> _relink(String binary, void Function(String) say) {
    final old = _resolve(executable);
    final moved = <String>[];
    var pointed = false;
    for (final dir in _linkDirs) {
      final link = Link('$dir/emu');
      if (!link.existsSync()) continue;
      if (!_deadPluginLink(link)) {
        try {
          final resolved = File(link.path).resolveSymbolicLinksSync();
          if (resolved == _resolve(binary)) {
            pointed = true;
            continue;
          }
          if (resolved != old) continue;
        } on FileSystemException {
          continue; // dangling, or not ours
        }
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
    if (moved.isEmpty && !pointed) say('! no PATH link pointed at $executable — link $binary yourself (or re-run `/emu-setup`)');
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
