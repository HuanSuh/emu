/// "What changed" for the dashboard's Changes tab and `emu diff` — git diffs
/// of the project between two *trees*, so every scope (uncommitted, vs a base
/// branch, applied by the last reload, not yet reloaded) is the same operation.
///
/// The working tree is captured as a tree object through a throwaway index
/// (`GIT_INDEX_FILE` + `add -A` + `write-tree`): unlike `git stash create`
/// that includes untracked files (an agent's new files are untracked), and it
/// never touches the user's real index, stash list or files. The only side
/// effect is unreachable objects in `.git/objects`, which `git gc` prunes.
library;

import 'dart:io';

/// Which two trees a diff compares.
enum DiffScope {
  /// HEAD → working tree (uncommitted, including untracked files).
  head('head'),

  /// merge-base(base, HEAD) → working tree: everything this branch adds.
  base('base'),

  /// Previous reload snapshot → last reload snapshot: what the last
  /// hot reload/restart (or launch) actually applied.
  reload('reload'),

  /// Last reload snapshot → working tree: edits the app hasn't picked up yet.
  pending('pending');

  const DiffScope(this.wire);
  final String wire;

  static DiffScope? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// One changed file, from `git diff --numstat`.
class DiffFile {
  DiffFile({required this.path, required this.added, required this.deleted, required this.binary});

  final String path;
  final int added;
  final int deleted;
  final bool binary;

  bool get generated => isGeneratedPath(path);

  Map<String, dynamic> toJson() => {
        'path': path,
        'added': added,
        'deleted': deleted,
        'binary': binary,
        'generated': generated,
      };
}

/// Parses `git diff --numstat --no-renames` output (`added\tdeleted\tpath`,
/// `-\t-\tpath` for binaries).
List<DiffFile> parseNumstat(String out) {
  final files = <DiffFile>[];
  for (final line in out.split('\n')) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    final binary = parts[0] == '-';
    files.add(DiffFile(
      path: parts.sublist(2).join('\t'),
      added: binary ? 0 : int.tryParse(parts[0]) ?? 0,
      deleted: binary ? 0 : int.tryParse(parts[1]) ?? 0,
      binary: binary,
    ));
  }
  return files;
}

final _generated = RegExp(
  r'\.(g|freezed|gr|mocks|config|pb|pbenum|pbjson|pbserver)\.dart$'
  r'|(^|/)(vendor|generated)/'
  r'|\.min\.(js|css)$'
  r'|(^|/)(pubspec|Podfile|package-lock|yarn)\.lock$'
  r'|(^|/)pnpm-lock\.yaml$',
);

/// Code generators' output, vendored and lock files — hidden by default in the
/// dashboard because they drown the hand-written change (a Freezed model edit
/// regenerates hundreds of lines).
bool isGeneratedPath(String path) => _generated.hasMatch(path);

final _safeRef = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

/// A branch/ref name safe to hand to git as an argument: no option-looking
/// `-x`, no `..` ranges, no revision syntax (`^`, `~`, `@{`, `:`).
bool isSafeRef(String ref) => _safeRef.hasMatch(ref) && !ref.contains('..') && !ref.endsWith('/');

final _objectId = RegExp(r'^[0-9a-f]{40}([0-9a-f]{24})?$');

/// A full SHA-1 or SHA-256 object id — what /api/diff/files hands out as
/// `from`/`to`, and nothing else (no refs, no revision syntax).
bool isObjectId(String s) => _objectId.hasMatch(s);

/// A path as /api/diff/files lists it: relative, inside the project. Rejects
/// absolute paths, `..` segments and git pathspec magic (`:(top)`, `:/`) —
/// it's handed to git after `--`, where magic still applies.
bool isProjectRelativePath(String p) =>
    p.isNotEmpty &&
    !p.startsWith('/') &&
    !p.startsWith('\\') &&
    !p.startsWith(':') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(p) &&
    !p.split(RegExp(r'[/\\]')).contains('..');

/// The branch a feature branch most likely forked from: the git-flow
/// integration branch first (develop/development), then main/master. A local
/// branch beats a remote one; among remotes upstream first — in a fork layout
/// origin is your fork (possibly stale) and upstream the real base — then
/// origin, then any other. The [current] branch is never its own base.
String? pickDefaultBase(Iterable<String> branches, {String? current}) {
  final list = branches.toList();
  bool sameAsCurrent(String b) => current != null && (b == current || b.endsWith('/$current'));
  int remoteRank(String b) => b.startsWith('upstream/') ? 0 : b.startsWith('origin/') ? 1 : 2;
  for (final name in const ['develop', 'development', 'main', 'master']) {
    if (name == current) continue;
    if (list.contains(name)) return name;
    final remotes = list.where((b) => b.endsWith('/$name') && !sameAsCurrent(b)).toList()
      ..sort((a, b) => remoteRank(a).compareTo(remoteRank(b)));
    if (remotes.isNotEmpty) return remotes.first;
  }
  return null;
}

const _watchNoise = {
  '.git', '.dart_tool', 'build', '.emu', '.idea', '.gradle', 'node_modules', 'Pods', '.symlinks', 'DerivedData',
};

/// Whether a file event at [relPath] (relative to the project) is tool or
/// build churn rather than an edit — `flutter run` alone rewrites `build/`
/// and `.dart_tool/` constantly, which would otherwise re-diff in a loop.
bool isWatchNoise(String relPath) =>
    relPath.isEmpty || relPath.split(RegExp(r'[/\\]')).any(_watchNoise.contains);

/// A captured working tree at a launch or reload.
class TreeSnapshot {
  TreeSnapshot(this.tree, this.reason, this.at);

  final String tree;
  final String reason;
  final DateTime at;

  Map<String, dynamic> toJson() => {'reason': reason, 'at': at.toIso8601String()};
}

class DiffException implements Exception {
  DiffException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef GitRunner = Future<ProcessResult> Function(List<String> args, {Map<String, String>? environment});

/// Git diffs of the project at [root] (a Flutter project dir — may be a
/// subdirectory of the repo; paths come back relative to it).
class GitDiff {
  GitDiff(this.root, {GitRunner? runner}) : _runner = runner;

  final String root;
  final GitRunner? _runner;

  /// The last two reload snapshots, oldest first.
  final List<TreeSnapshot> snapshots = [];

  Future<ProcessResult> _git(List<String> args, {Map<String, String>? environment}) {
    final full = ['-C', root, '-c', 'core.quotepath=false', ...args];
    final r = _runner;
    if (r != null) return r(full, environment: environment);
    return Process.run('git', full, environment: environment);
  }

  Future<String> _out(List<String> args, {Map<String, String>? environment}) async {
    final r = await _git(args, environment: environment);
    if (r.exitCode != 0) throw DiffException('git ${args.first}: ${'${r.stderr}'.trim()}');
    return '${r.stdout}';
  }

  bool? _isRepo;

  /// Whether [root] is inside a git work tree (cached; a project doesn't
  /// become a repo mid-session often enough to matter).
  Future<bool> isRepo() async {
    if (_isRepo != null) return _isRepo!;
    try {
      final r = await _git(['rev-parse', '--is-inside-work-tree']);
      return _isRepo = r.exitCode == 0 && '${r.stdout}'.trim() == 'true';
    } catch (_) {
      return _isRepo = false; // git not installed
    }
  }

  /// The working tree (tracked + untracked, minus ignored) as a tree object.
  Future<String> captureTree() async {
    final realIndex = (await _out(['rev-parse', '--path-format=absolute', '--git-path', 'index'])).trim();
    final tmp = Directory.systemTemp.createTempSync('emu-diff-');
    final index = '${tmp.path}/index';
    try {
      // Seeding from the real index lets `add -A` re-hash only changed files.
      final real = File(realIndex);
      if (real.existsSync()) real.copySync(index);
      final env = {'GIT_INDEX_FILE': index};
      // Only the project dir (`.` — git runs with `-C root`): diffs are
      // `--relative` anyway, and the seeded index keeps everything outside
      // as it is, so the rest of a monorepo isn't re-hashed on every capture.
      await _out(['add', '-A', '--', '.'], environment: env);
      return (await _out(['write-tree'], environment: env)).trim();
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  Future<void> _recording = Future.value();

  /// Records the working tree at a launch/reload; keeps the last two.
  /// Serialized: status changes in quick succession must not land out of order.
  Future<void> record(String reason) => _recording = _recording.then((_) => _record(reason));

  Future<void> _record(String reason) async {
    if (!await isRepo()) return;
    try {
      snapshots.add(TreeSnapshot(await captureTree(), reason, DateTime.now()));
      if (snapshots.length > 2) snapshots.removeAt(0);
    } catch (_) {
      // Best-effort: a failed snapshot only empties the reload scopes.
    }
  }

  Future<List<String>> branches() async {
    final out = await _out(['for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes']);
    return out.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty && !s.endsWith('/HEAD')).toList();
  }

  Future<String?> defaultBase() async {
    final head = await _git(['symbolic-ref', '--quiet', '--short', 'HEAD']);
    final current = head.exitCode == 0 ? '${head.stdout}'.trim() : null; // null: detached
    return pickDefaultBase(await branches(), current: current);
  }

  /// The (from, to) trees of [scope]; null when the scope has nothing to
  /// compare yet (no reload recorded, unknown base).
  Future<(String, String)?> range(DiffScope scope, {String? base}) async {
    switch (scope) {
      case DiffScope.head:
        final head = (await _git(['rev-parse', '--verify', '--quiet', 'HEAD^{tree}']));
        // An unborn branch has no HEAD: diff against the empty tree.
        final from = head.exitCode == 0 ? '${head.stdout}'.trim() : await _emptyTree();
        return (from, await captureTree());
      case DiffScope.base:
        final ref = base ?? await defaultBase();
        if (ref == null) return null;
        if (!isSafeRef(ref)) throw DiffException('invalid base ref: $ref');
        final mb = await _git(['merge-base', ref, 'HEAD']);
        if (mb.exitCode != 0) throw DiffException('no common history with $ref');
        return ('${mb.stdout}'.trim(), await captureTree());
      case DiffScope.reload:
        if (snapshots.length < 2) return null;
        return (snapshots[0].tree, snapshots[1].tree);
      case DiffScope.pending:
        if (snapshots.isEmpty) return null;
        return (snapshots.last.tree, await captureTree());
    }
  }

  // Hashed rather than hardcoded so SHA-256 repositories work too.
  Future<String> _emptyTree() async =>
      (await _out(['hash-object', '-t', 'tree', '/dev/null'])).trim();

  static const _diffFlags = ['diff', '--no-color', '--no-ext-diff', '--no-renames', '--relative'];

  Future<List<DiffFile>> files((String, String) range) async =>
      parseNumstat(await _out([..._diffFlags, '--numstat', range.$1, range.$2]));

  /// The unified diff of one [path] (relative to [root]) in [range].
  Future<String> patch((String, String) range, String path) =>
      _out([..._diffFlags, range.$1, range.$2, '--', path]);
}
