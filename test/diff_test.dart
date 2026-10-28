import 'dart:io';

import 'package:emu/src/diff.dart';
import 'package:test/test.dart';

void main() {
  group('parseNumstat', () {
    test('text and binary rows', () {
      final files = parseNumstat('12\t3\tlib/a.dart\n-\t-\tassets/x.png\n\n');
      expect(files.map((f) => f.path), ['lib/a.dart', 'assets/x.png']);
      expect((files[0].added, files[0].deleted, files[0].binary), (12, 3, false));
      expect((files[1].added, files[1].deleted, files[1].binary), (0, 0, true));
    });

    test('keeps tabs inside a path', () {
      expect(parseNumstat('1\t0\tweird\tname.txt').single.path, 'weird\tname.txt');
    });
  });

  test('isGeneratedPath', () {
    for (final p in [
      'lib/m.g.dart',
      'lib/m.freezed.dart',
      'lib/gen/router.gr.dart',
      'web/vendor/lottie.js',
      'a/b.min.js',
      'pubspec.lock',
      'ios/Podfile.lock',
    ]) {
      expect(isGeneratedPath(p), isTrue, reason: p);
    }
    for (final p in ['lib/main.dart', 'lib/vendors.dart', 'web/app.js', 'pubspec.yaml']) {
      expect(isGeneratedPath(p), isFalse, reason: p);
    }
  });

  test('isSafeRef rejects options, ranges and revision syntax', () {
    for (final r in ['develop', 'origin/main', 'feat/a-b_c.1']) {
      expect(isSafeRef(r), isTrue, reason: r);
    }
    for (final r in ['-p', '--output=x', 'a..b', 'HEAD~1', 'main^', 'x@{1}', 'a:b', 'a b', '', 'feat/']) {
      expect(isSafeRef(r), isFalse, reason: r);
    }
  });

  test('pickDefaultBase prefers develop(ment), then main/master, local before remote', () {
    expect(pickDefaultBase(['main', 'develop', 'feat/x']), 'develop');
    expect(pickDefaultBase(['main', 'development', 'feat/x']), 'development');
    expect(pickDefaultBase(['feat/x', 'origin/develop', 'main']), 'origin/develop');
    expect(pickDefaultBase(['master', 'feat/x']), 'master');
    expect(pickDefaultBase(['feat/x']), isNull);
  });

  test('pickDefaultBase: upstream before origin, never the current branch', () {
    expect(pickDefaultBase(['origin/development', 'upstream/development']), 'upstream/development');
    expect(pickDefaultBase(['fork/main', 'origin/main']), 'origin/main');
    // On development itself: skip it (and its remotes), fall back to main.
    expect(
      pickDefaultBase(['development', 'upstream/development', 'origin/main', 'upstream/main'], current: 'development'),
      'upstream/main',
    );
  });

  test('isWatchNoise skips build and tool directories', () {
    for (final p in ['.git/index', 'build/app/x.o', '.dart_tool/pkg', 'ios/Pods/a.h', '.emu/run.jsonl', 'a/build/b', '']) {
      expect(isWatchNoise(p), isTrue, reason: p);
    }
    for (final p in ['lib/main.dart', 'lib/builder.dart', 'pubspec.yaml', 'lib/build_info.dart']) {
      expect(isWatchNoise(p), isFalse, reason: p);
    }
  });

  test('isObjectId accepts only full SHA-1/SHA-256 ids', () {
    expect(isObjectId('a' * 40), isTrue);
    expect(isObjectId('0123456789abcdef' * 4), isTrue);
    for (final s in ['a' * 39, 'a' * 41, 'A' * 40, 'HEAD', 'develop', '-p', '${'a' * 40}^', '']) {
      expect(isObjectId(s), isFalse, reason: s);
    }
  });

  test('isProjectRelativePath rejects escapes and pathspec magic', () {
    for (final p in ['lib/a.dart', 'a', 'lib/..foo/x.dart', 'web/vendor/x.min.js']) {
      expect(isProjectRelativePath(p), isTrue, reason: p);
    }
    for (final p in ['', '/etc/passwd', '../x', 'lib/../../x', ':(top)x', ':/x', r'C:\x', r'lib\..\x']) {
      expect(isProjectRelativePath(p), isFalse, reason: p);
    }
  });

  test('DiffScope wire names round-trip', () {
    for (final s in DiffScope.values) {
      expect(DiffScope.fromWire(s.wire), s);
    }
    expect(DiffScope.fromWire('nope'), isNull);
  });

  group('GitDiff (real repo)', () {
    late Directory dir;
    late GitDiff diff;

    Future<String> git(List<String> args) async {
      final r = await Process.run('git', ['-C', dir.path, ...args]);
      expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}';
    }

    void write(String path, String body) {
      File('${dir.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    Future<List<String>> changed(DiffScope scope, {String? base}) async {
      final range = await diff.range(scope, base: base);
      if (range == null) return const [];
      return [for (final f in await diff.files(range)) f.path]..sort();
    }

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('emu-diff-test-');
      await git(['init', '-q', '-b', 'develop']);
      await git(['config', 'user.email', 't@t']);
      await git(['config', 'user.name', 't']);
      write('lib/a.dart', 'a1\n');
      write('.gitignore', 'build/\n');
      await git(['add', '-A']);
      await git(['commit', '-q', '-m', 'init']);
      diff = GitDiff(dir.path);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('head: modified + untracked, ignored excluded, real index untouched', () async {
      write('lib/a.dart', 'a2\n');
      write('lib/new.dart', 'n\n');
      write('build/out.txt', 'x\n');
      expect(await diff.isRepo(), isTrue);
      expect(await changed(DiffScope.head), ['lib/a.dart', 'lib/new.dart']);
      // Nothing staged by the snapshot, the new file is still untracked.
      expect((await git(['diff', '--cached', '--name-only'])).trim(), isEmpty);
      expect(await git(['status', '--porcelain']), contains('?? lib/new.dart'));
    });

    test('reload/pending follow the recorded snapshots', () async {
      expect(await diff.range(DiffScope.reload), isNull);
      expect(await diff.range(DiffScope.pending), isNull);

      await diff.record('launch');
      write('lib/a.dart', 'a2\n');
      write('lib/b.dart', 'b\n');
      await diff.record('reload');
      write('lib/c.dart', 'c\n');

      // The reload applied a + b; c was written after it.
      expect(await changed(DiffScope.reload), ['lib/a.dart', 'lib/b.dart']);
      expect(await changed(DiffScope.pending), ['lib/c.dart']);

      final patch = await diff.patch((await diff.range(DiffScope.reload))!, 'lib/a.dart');
      expect(patch, contains('-a1'));
      expect(patch, contains('+a2'));
    });

    test('records land in call order even when an earlier capture is slower', () async {
      // The first capture's write-tree is held back, so unserialized records
      // would finish (and append) out of order.
      var writeTrees = 0;
      final slow = GitDiff(dir.path, runner: (args, {environment}) async {
        if (args.contains('write-tree') && writeTrees++ == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return Process.run('git', args, environment: environment);
      });
      await Future.wait([slow.record('launch'), slow.record('reload-1'), slow.record('reload-2')]);
      expect(slow.snapshots.map((s) => s.reason), ['reload-1', 'reload-2']);
    });

    test('keeps only the last two snapshots', () async {
      await diff.record('launch');
      await diff.record('reload');
      await diff.record('reload');
      expect(diff.snapshots, hasLength(2));
    });

    test('base: everything since the fork point, including uncommitted', () async {
      await git(['checkout', '-q', '-b', 'feat/x']);
      write('lib/f.dart', 'f\n');
      await git(['add', '-A']);
      await git(['commit', '-q', '-m', 'feat']);
      write('lib/u.dart', 'u\n');
      expect(await diff.defaultBase(), 'develop');
      expect(await changed(DiffScope.base), ['lib/f.dart', 'lib/u.dart']);
      expect(() => diff.range(DiffScope.base, base: '--output=/tmp/x'), throwsA(isA<DiffException>()));
    });

    test('paths are relative to a project in a subdirectory', () async {
      write('app/lib/m.dart', 'm\n');
      write('other/z.txt', 'z\n');
      final sub = GitDiff('${dir.path}/app');
      final range = await sub.range(DiffScope.head);
      expect([for (final f in await sub.files(range!)) f.path], ['lib/m.dart']);
    });

    test('a subdirectory project snapshots only its own files', () async {
      write('app/lib/m.dart', 'm\n');
      write('other/z.txt', 'outside-only-content\n');
      await GitDiff('${dir.path}/app').captureTree();
      final blob = (await git(['hash-object', 'other/z.txt'])).trim();
      final r = await Process.run('git', ['-C', dir.path, 'cat-file', '-e', blob]);
      expect(r.exitCode, isNot(0), reason: 'the file outside the project was hashed into the object store');
      // ...while the project's own new file was.
      final own = (await git(['hash-object', 'app/lib/m.dart'])).trim();
      await git(['cat-file', '-e', own]);
    });

    test('a failed temp cleanup does not hide the capture error', () async {
      // The temp dir is never created: seeding the index fails, and so does
      // the cleanup — the caller must still see the seeding error.
      final parent = _MissingTempParent(Directory.systemTemp.path);
      final err = await IOOverrides.runZoned(
        () => diff.captureTree().then<Object?>((_) => null, onError: (Object e) => e),
        getSystemTempDirectory: () => parent,
      );
      expect(err, isA<FileSystemException>().having((e) => e.message, 'message', contains('copy')));
    });

    test('head on an unborn branch diffs against the empty tree', () async {
      final fresh = Directory.systemTemp.createTempSync('emu-diff-unborn-');
      addTearDown(() => fresh.deleteSync(recursive: true));
      await Process.run('git', ['-C', fresh.path, 'init', '-q']);
      File('${fresh.path}/a.txt').writeAsStringSync('a\n');
      final d = GitDiff(fresh.path);
      expect([for (final f in await d.files((await d.range(DiffScope.head))!)) f.path], ['a.txt']);
    });

    test('isRepo is false outside a repository', () async {
      final plain = Directory.systemTemp.createTempSync('emu-diff-plain-');
      addTearDown(() => plain.deleteSync(recursive: true));
      expect(await GitDiff(plain.path).isRepo(), isFalse);
    });
  });
}

/// A temp parent whose `createTempSync` hands out a directory that doesn't exist.
class _MissingTempParent implements Directory {
  _MissingTempParent(this.path);

  @override
  final String path;

  @override
  Directory createTempSync([String? prefix]) =>
      Directory('$path/emu-missing-$pid-${DateTime.now().microsecondsSinceEpoch}');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
