import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/models.dart';
import 'package:emu/src/pages.dart';
import 'package:emu/src/pages_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// A project whose emu.yaml drives `tool/t.sh`: real processes, no app.
const _emuYaml = r'''
pages:
  - id: tools
    title: Tools
    toolbar:
      - toggle:
          id: local
          state: [./tool/t.sh, status]
          on: [./tool/t.sh, set, "true"]
          off: [./tool/t.sh, set, "false"]
          then: reload
      - action: { id: hello, run: [./tool/t.sh, hello, "two words"] }
      - action: { id: env, run: 'echo "dev=$EMU_DEVICE root=$(basename "$EMU_PROJECT")"' }
      - action: { id: fail, run: [./tool/t.sh, fail] }
      - action: { id: reload, run: [./tool/t.sh, hello], then: reload }
      - action: { id: publish, run: [./tool/t.sh, hello, published], confirm: true }
      - action:
          id: deploy
          label: stage 배포
          run: [./tool/t.sh, hello, deployed]
          confirm:
            title: push to stage?
            message: pushes to the stage branch
            danger: true
            button: push
            preview: [./tool/t.sh, patch]
      - action: { id: rows, run: [./tool/t.sh, hello], confirm: { preview: [./tool/t.sh, rows] } }
      - action: { id: text, run: [./tool/t.sh, hello], confirm: { message: "plain words", preview: [./tool/t.sh, hello, preview] } }
      - action: { id: badpreview, run: [./tool/t.sh, hello], confirm: { preview: [./tool/t.sh, fail] } }
      - action: { id: softpreview, run: [./tool/t.sh, hello], confirm: { preview: [./tool/t.sh, fail], allowOnPreviewError: true } }
      - action: { id: slow, run: [sleep, 5], timeout: 1 }
      - action: { id: missing, run: [./tool/nope.sh] }
      - action: { id: steps, run: [./tool/t.sh, steps], timeout: 20 }
      - action: { id: sync, run: [./tool/t.sh, log, sync], then: reload, auto: { watch: ["tpl/*.txt"], debounce: 30, on: true } }
      - action: { id: watcher, run: [./tool/t.sh, log, watcher], auto: { watch: ["tpl/*.txt"] } }
      - action: { id: self, run: [./tool/t.sh, self], timeout: 20, auto: { watch: ["own/**"], debounce: 30, on: true } }
      - action: { id: late, run: [./tool/t.sh, late], auto: { watch: ["late/**"], debounce: 30, on: true } }
    blocks:
      - output: {}
''';

const _script = r'''#!/bin/sh
case "$1" in
  status) echo "checking…"; if [ -f .state ]; then echo "{\"on\": $(cat .state), \"detail\": \"3 files\"}"; else echo '{"on": false}'; fi ;;
  set) printf %s "$2" > .state ;;
  hello) echo "hello $2"; echo "warn" >&2 ;;
  fail) echo "line 1"; echo "line 2"; exit 3 ;;
  patch) printf -- '--- a/t.json\n+++ b/t.json\n@@ -1 +1 @@\n-old\n+new\n' ;;
  rows) echo '[{"name": "home", "changes": 2}, {"name": "<b>x</b>", "changes": 0}]' ;;
  steps) echo one; while [ ! -f go ]; do sleep 0.05; done; echo two ;;
  log) echo "$2" >> runs.log ;;
  self) mkdir -p own; touch own/x.txt; echo touched; while [ ! -f go ]; do sleep 0.05; done; echo self >> runs.log ;;
  late) mkdir -p late; touch late/x.txt; echo late >> runs.log ;;
esac
''';

void main() {
  late Directory root;
  late List<Map<String, dynamic>> broadcasts;
  void Function(Map<String, dynamic>)? onBroadcast;
  late List<(String, LogLevel)> logs;
  late List<Then> followUps;
  late bool followUpOk;
  late PagesApi api;

  setUp(() {
    root = Directory.systemTemp.createTempSync('emu_pages_');
    File('${root.path}/emu.yaml').writeAsStringSync(_emuYaml);
    final script = File('${root.path}/tool/t.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(_script);
    Process.runSync('chmod', ['+x', script.path]);
    broadcasts = [];
    onBroadcast = null;
    logs = [];
    followUps = [];
    followUpOk = true;
    api = PagesApi(
      projectRoot: root.path,
      home: root.path, // no ~/.emu/config.yaml from the machine running the tests
      environment: () => {'EMU_PROJECT': root.path, 'EMU_DEVICE': 'emulator-5554'},
      followUp: (then) async {
        followUps.add(then);
        return {'action': then.name, 'ok': followUpOk, 'message': followUpOk ? 'Reloaded 1 of 9 libraries' : 'app is not running'};
      },
      openUrl: (url) async => {'ok': true},
      broadcast: (m) {
        broadcasts.add(m);
        onBroadcast?.call(m);
      },
      log: (text, level) => logs.add((text, level)),
      autoStateFile: File('${root.path}/.emu/pages_auto.json'),
    );
    Directory('${root.path}/.emu').createSync();
  });
  tearDown(() {
    api.dispose();
    root.deleteSync(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> call(String method, String path, [Map<String, dynamic>? body]) async {
    final res = await api.handle(
        Request(method, Uri.parse('http://127.0.0.1:4577$path'), body: body == null ? null : jsonEncode(body)), path);
    return (res.statusCode, jsonDecode(await res.readAsString()) as Map<String, dynamic>);
  }

  Future<(int, Map<String, dynamic>)> run(String item, [Map<String, dynamic>? body]) =>
      call('POST', '/api/pages/tools/run/$item', body ?? {});

  test('lists the pages from emu.yaml', () async {
    final (code, j) = await call('GET', '/api/pages');
    expect(code, 200);
    expect(j['problems'], isEmpty);
    final page = (j['pages'] as List).single as Map;
    expect(page['id'], 'tools');
    expect([for (final i in page['toolbar'] as List) i['id']],
        ['local', 'hello', 'env', 'fail', 'reload', 'publish', 'deploy', 'rows', 'text', 'badpreview', 'softpreview', 'slow', 'missing', 'steps',
         'sync', 'watcher', 'self', 'late']);
    expect((page['toolbar'] as List)[1]['command'], "./tool/t.sh hello 'two words'");
  });

  test('runs an argv action from the project root, output interleaved, and reports it', () async {
    final (code, j) = await run('hello');
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['exitCode'], 0);
    expect(j['output'], allOf(contains('hello two words'), contains('warn')));
    final events = [for (final b in broadcasts) b['event']];
    expect(events.first, 'started');
    expect(events.last, 'finished');
    expect(events.sublist(1, events.length - 1), everyElement('output'));
    expect([for (final b in broadcasts) if (b['event'] == 'output') b['chunk']].join(), j['output']);
    expect((broadcasts.last['run'] as Map)['output'], contains('hello two words'));
    expect(logs.first.$1, "[ext] tools.hello ▸ ./tool/t.sh hello 'two words'");
    expect(logs.last.$1, startsWith('[ext] tools.hello ✓ exit 0'));
  });

  test('a run sends its output to dashboards as it comes, all of it before finished', () async {
    // The command waits for its first line to reach a dashboard: it ends only if output streams.
    onBroadcast = (m) {
      if (m['event'] == 'output' && '${m['chunk']}'.contains('one')) File('${root.path}/go').createSync();
    };
    final (_, j) = await run('steps');
    expect(j['ok'], isTrue);
    final chunks = [for (final b in broadcasts) if (b['event'] == 'output') '${b['chunk']}'];
    expect(chunks.first, contains('one'));
    expect(chunks.join(), 'one\ntwo\n');
    expect(broadcasts.last['event'], 'finished');
    expect(broadcasts.where((b) => b['event'] == 'output').every((b) => b['page'] == 'tools' && b['item'] == 'steps'), isTrue);
  });

  test('output waiting for its batch is held to the tail, however fast it comes', () {
    final sent = <String>[];
    final live = LiveOutput(sent.add, limit: 10);
    for (var i = 0; i < 1000; i++) {
      live.add('$i,');
      expect(live.pending, lessThanOrEqualTo(20));
    }
    live.flush();
    expect(sent, ['997,998,999,'.substring(2)]);
    expect(live.pending, 0);
    live.flush();
    expect(sent, hasLength(1)); // nothing new, nothing sent
  });

  test('a string command runs with sh -c and sees the EMU_ variables', () async {
    final (_, j) = await run('env');
    expect(j['output'], contains('dev=emulator-5554 root=${root.path.split('/').last}'));
  });

  test('a failing command is not ok, and its output tail is logged as an error', () async {
    final (code, j) = await run('fail');
    expect(code, 200);
    expect(j['ok'], isFalse);
    expect(j['exitCode'], 3);
    expect(j['error'], 'exit 3');
    expect(logs.last.$2, LogLevel.error);
    expect(logs.last.$1, allOf(contains('tools.fail ✗ exit 3'), contains('line 2')));
  });

  test('then: reload follows a success only, and a failed reload fails the run', () async {
    var (_, j) = await run('reload');
    expect(followUps, [Then.reload]);
    expect(j['ok'], isTrue);
    expect((j['then'] as Map)['message'], 'Reloaded 1 of 9 libraries');

    followUpOk = false;
    (_, j) = await run('reload');
    expect(j['ok'], isFalse);
    expect(j['exitCode'], 0);
    expect(logs.last.$1, contains('reload: app is not running'));

    followUps.clear();
    await run('fail'); // no then:
    expect(followUps, isEmpty);
  });

  test('confirm: true runs only when the request says it was confirmed', () async {
    var (code, j) = await run('publish');
    expect(code, 428);
    expect(j['needsConfirm'], isTrue);
    expect(j['command'], './tool/t.sh hello published');
    expect(broadcasts, isEmpty);

    (code, j) = await run('publish', {'confirmed': true});
    expect(code, 200);
    expect(j['output'], contains('hello published'));
  });

  test('a confirm map: the dialog words, and a diff preview that runs before it opens', () async {
    var (code, j) = await run('deploy');
    expect(code, 428);
    expect(j['command'], './tool/t.sh hello deployed'); // the real command is always there
    expect(j['confirm'], {'title': 'push to stage?', 'message': 'pushes to the stage branch', 'danger': true, 'button': 'push'});
    expect(j['preview'], containsPair('ok', true));
    expect(j['preview'], containsPair('kind', 'diff'));
    expect(j['preview'], containsPair('command', './tool/t.sh patch'));
    expect(j['preview']['patch'], contains('+new'));
    expect(broadcasts, isEmpty); // the preview isn't a run
    expect(logs, isEmpty);

    (code, j) = await run('deploy', {'confirmed': true});
    expect(code, 200);
    expect(j['output'], contains('hello deployed'));
  });

  test('a preview prints rows as a table, anything else as text', () async {
    var (_, j) = await run('rows');
    expect(j['confirm'], {'title': 'Run “rows”?', 'danger': false, 'button': 'Run'});
    expect(j['preview']['kind'], 'table');
    expect(j['preview']['rows'], [
      {'name': 'home', 'changes': 2},
      {'name': '<b>x</b>', 'changes': 0},
    ]);

    (_, j) = await run('text');
    expect(j['confirm']['message'], 'plain words');
    expect(j['preview']['kind'], 'text');
    expect(j['preview']['text'], 'hello preview\n');
  });

  test('a failed preview blocks Run unless allowOnPreviewError', () async {
    var (code, j) = await run('badpreview');
    expect(code, 428);
    expect(j['preview'], containsPair('ok', false));
    expect(j['preview'], containsPair('error', 'exit 3'));
    expect(j['preview'], containsPair('blocks', true));
    expect(j['preview']['text'], contains('line 2'));

    (_, j) = await run('softpreview');
    expect(j['preview'], containsPair('ok', false));
    expect(j['preview'], containsPair('blocks', false));
  });

  test('a toggle reads its state, flips, then reports the new state', () async {
    var (code, j) = await call('GET', '/api/pages/tools/state/local');
    expect(code, 200);
    expect(j, {'ok': true, 'on': false});

    (_, j) = await run('local', {'on': true});
    expect(j['ok'], isTrue);
    expect(followUps, [Then.reload]);
    expect(j['state'], {'ok': true, 'on': true, 'detail': '3 files'});

    (_, j) = await run('local', {'on': false});
    expect((j['state'] as Map)['on'], isFalse);

    (code, j) = await run('local');
    expect(code, 400); // on or off?
  });

  test('the same item cannot run twice at once', () async {
    final first = run('slow');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final (code, j) = await run('slow');
    expect(code, 409);
    expect(j['busy'], isTrue);
    await first;
  });

  test('a command is killed at its timeout', () async {
    final (_, j) = await run('slow');
    expect(j['timedOut'], isTrue);
    expect(j['ok'], isFalse);
    expect(j['error'], startsWith('timed out'));
    expect(j['ms'], lessThan(4000));
  });

  test('a timeout also kills what the command spawned', () async {
    final marker = 'emu-killtree-${DateTime.now().microsecondsSinceEpoch}';
    final run = await api.execute('tools', 'x', PageCommand.shell('sh -c "sleep 30; : $marker" | cat'),
        const Duration(milliseconds: 300));
    expect(run.timedOut, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final left = await Process.run('pgrep', ['-f', marker]);
    expect('${left.stdout}'.trim(), isEmpty, reason: 'orphaned grandchild still running');
  });

  test('a program that is not there is reported, not thrown', () async {
    final (code, j) = await run('missing');
    expect(code, 200);
    expect(j['ok'], isFalse);
    expect(j['error'], startsWith('could not start'));
  });

  test('unknown pages and items say what exists; runs need POST', () async {
    var (code, j) = await call('POST', '/api/pages/nope/run/hello', {});
    expect(code, 404);
    expect(j['error'], contains('pages: tools'));
    (code, j) = await call('POST', '/api/pages/tools/run/nope', {});
    expect(code, 404);
    expect(j['error'], contains('hello'));
    (code, _) = await call('GET', '/api/pages/tools/run/hello');
    expect(code, 405);
    (code, _) = await call('GET', '/api/pages/tools/state/hello');
    expect(code, 404); // not a toggle
  });

  test('the last run per page is part of the listing; emu.yaml is re-read every time', () async {
    await run('hello');
    var (_, j) = await call('GET', '/api/pages');
    expect(((j['last'] as Map)['tools'] as Map)['item'], 'hello');

    File('${root.path}/emu.yaml').writeAsStringSync('pages:\n  - id: other\n    toolbar:\n      - action: {id: x}\n');
    (_, j) = await call('GET', '/api/pages');
    expect([for (final p in j['pages'] as List) p['id']], ['other']);
    expect((j['problems'] as List).single, contains('other.x.run: missing'));
  });

  group('auto:', () {
    List<String> runs() {
      final f = File('${root.path}/runs.log');
      return f.existsSync() ? f.readAsLinesSync() : [];
    }

    // Until [key] has no run waiting and none in flight (bounded, so a bug fails rather than hangs).
    Future<void> settled(String key) async {
      for (var i = 0; i < 400 && !api.autoIdle(key); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(api.autoIdle(key), isTrue, reason: '$key still busy');
    }

    test('a switch per action, kept per project and told to dashboards', () async {
      var (_, j) = await call('GET', '/api/pages');
      expect(j['auto'], {'tools.sync': true, 'tools.watcher': false, 'tools.self': true, 'tools.late': true});

      (_, j) = await call('POST', '/api/pages/tools/auto/watcher', {'on': true});
      expect(j, {'ok': true, 'on': true});
      expect(broadcasts.last, {'type': 'ext-auto', 'page': 'tools', 'item': 'watcher', 'on': true});
      expect(jsonDecode(File('${root.path}/.emu/pages_auto.json').readAsStringSync()), {'tools.watcher': true});

      final again = PagesApi(
        projectRoot: root.path,
        home: root.path,
        environment: () => {},
        followUp: (_) async => {'ok': true},
        openUrl: (_) async => {'ok': true},
        broadcast: (_) {},
        log: (_, _) {},
        autoStateFile: File('${root.path}/.emu/pages_auto.json'),
      );
      final res = await again.handle(Request('GET', Uri.parse('http://127.0.0.1:4577/api/pages')), '/api/pages');
      expect((jsonDecode(await res.readAsString()) as Map)['auto']['tools.watcher'], isTrue);

      final (code, bad) = await call('POST', '/api/pages/tools/auto/hello', {'on': true});
      expect(code, 404);
      expect(bad['error'], 'no action with auto: "hello" on page tools');
      expect((await call('POST', '/api/pages/tools/auto/watcher', {'on': 'yes'})).$1, 400);
    });

    test('a change to a watched file runs it once the changes rest, with its then:', () async {
      final file = File('${root.path}/tpl/a.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      api.filesChanged(['tpl/a.txt']);
      api.filesChanged(['tpl/a.txt', 'lib/main.dart']); // one burst: one run
      expect(api.autoIdle('tools.sync'), isFalse);
      await settled('tools.sync');
      expect(runs(), ['sync']); // not watcher: it is switched off
      expect([for (final b in broadcasts) if (b['event'] == 'started') '${b['item']} ${b['auto']}'], ['sync true']);
      expect(broadcasts.lastWhere((b) => b['event'] == 'finished')['auto'], isTrue);
      expect(followUps, [Then.reload]);
      expect(logs.map((l) => l.$1), contains("[ext] tools.sync ▸ ./tool/t.sh log sync   (auto: tpl/a.txt changed)"));

      api.filesChanged(['lib/main.dart']); // not watched
      api.filesChanged(['tpl/a.txt']); // reported again, but the run already read it
      expect(api.autoIdle('tools.sync'), isTrue);

      file.writeAsStringSync('b'); // a new edit
      api.filesChanged(['tpl/a.txt']);
      await settled('tools.sync');
      expect(runs(), ['sync', 'sync']);

      await call('POST', '/api/pages/tools/auto/sync', {'on': false});
      file.writeAsStringSync('c');
      api.filesChanged(['tpl/a.txt']);
      expect(api.autoIdle('tools.sync'), isTrue);
    });

    test('a file changed while it runs makes it run once more — no more, though it writes what it watches', () async {
      // The run writes own/x.txt and waits; the watcher reports that write while it runs.
      onBroadcast = (m) {
        if (m['event'] == 'output' && m['item'] == 'self' && '${m['chunk']}'.contains('touched')) {
          api.filesChanged(['own/x.txt']);
          File('${root.path}/go').createSync();
        }
      };
      File('${root.path}/own/x.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('edit');
      api.filesChanged(['own/x.txt']);
      await settled('tools.self');
      expect(runs(), ['self', 'self']);
      api.filesChanged(['own/x.txt']); // the once-more's own write, reported late
      expect(api.autoIdle('tools.self'), isTrue);
    });

    test('a change made during a run but reported after it also runs it once more', () async {
      File('${root.path}/late/x.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('edit');
      api.filesChanged(['late/x.txt']);
      await settled('tools.late');
      expect(runs(), ['late']);
      api.filesChanged(['late/x.txt']); // its write, reported after it ended
      await settled('tools.late');
      expect(runs(), ['late', 'late']);
      api.filesChanged(['late/x.txt']); // the once-more's write: not counted
      expect(api.autoIdle('tools.late'), isTrue);
    });
  });
}
