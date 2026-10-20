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
      - action: { id: slow, run: [sleep, 5], timeout: 1 }
      - action: { id: missing, run: [./tool/nope.sh] }
    blocks:
      - output: {}
''';

const _script = r'''#!/bin/sh
case "$1" in
  status) echo "checking…"; if [ -f .state ]; then echo "{\"on\": $(cat .state), \"detail\": \"3 files\"}"; else echo '{"on": false}'; fi ;;
  set) printf %s "$2" > .state ;;
  hello) echo "hello $2"; echo "warn" >&2 ;;
  fail) echo "line 1"; echo "line 2"; exit 3 ;;
esac
''';

void main() {
  late Directory root;
  late List<Map<String, dynamic>> broadcasts;
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
      broadcast: broadcasts.add,
      log: (text, level) => logs.add((text, level)),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

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
        ['local', 'hello', 'env', 'fail', 'reload', 'publish', 'slow', 'missing']);
    expect((page['toolbar'] as List)[1]['command'], "./tool/t.sh hello 'two words'");
  });

  test('runs an argv action from the project root, output interleaved, and reports it', () async {
    final (code, j) = await run('hello');
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['exitCode'], 0);
    expect(j['output'], allOf(contains('hello two words'), contains('warn')));
    expect([for (final b in broadcasts) b['event']], ['started', 'finished']);
    expect((broadcasts.last['run'] as Map)['output'], contains('hello two words'));
    expect(logs.first.$1, "[ext] tools.hello ▸ ./tool/t.sh hello 'two words'");
    expect(logs.last.$1, startsWith('[ext] tools.hello ✓ exit 0'));
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
}
