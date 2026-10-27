import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/models.dart';
import 'package:emu/src/page_ask.dart';
import 'package:emu/src/pages.dart';
import 'package:emu/src/pages_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Actions whose command asks (`::emu-ask`) and prints what it got back.
const _emuYaml = r'''
pages:
  - id: tools
    title: Tools
    toolbar:
      - action: { id: ask, label: Push, run: [./tool/t.sh, ask], interactive: true }
      - action: { id: quick, run: [./tool/t.sh, ask], interactive: true, askTimeout: 1 }
      - action: { id: paused, run: [./tool/t.sh, ask], interactive: true, timeout: 1 }
      - action: { id: plain, run: [./tool/t.sh, ask] }
      - action: { id: bad, run: [./tool/t.sh, bad], interactive: true }
      - action: { id: two, run: [./tool/t.sh, two], interactive: true }
    blocks:
      - output: {}
''';

const _script = r'''#!/bin/sh
case "$1" in
  ask)
    echo "before EMU_ASK=$EMU_ASK"
    printf '%s\n' '::emu-ask {"id":"go","kind":"confirm","title":"Overwrite 2 files?","detail":"a.tpl\nb.tpl","danger":true}'
    read -r answer
    echo "got $answer" ;;
  bad)
    echo '::emu-ask {not json'
    read -r a; echo "got $a"
    echo '::emu-ask {"id":7,"kind":"shout","title":"?"}'
    read -r b; echo "got $b" ;;
  two)
    printf '::emu-ask {"id":"env","kind":"choose","title":"Where?","options":["stage","prod"]}\n::emu-ask {"id":"msg","kind":"prompt","fields":[{"name":"m","default":"hi"}]}\n'
    read -r a; read -r b; echo "got $a $b" ;;
esac
''';

void main() {
  group('parseAsk', () {
    test('keeps what a dialog shows, as text, cut to size', () {
      final r = parseAsk(jsonEncode({
        'id': 'force',
        'kind': 'confirm',
        'title': 'x' * 300,
        'message': 'm',
        'detail': 'd' * 30000,
        'danger': true,
        'button': 'b' * 50,
        'html': '<script>',
      }));
      expect(r.error, isNull);
      expect(r.ask!.keys, unorderedEquals(['id', 'kind', 'title', 'message', 'detail', 'danger', 'button']));
      expect(r.ask!['title'], hasLength(200));
      expect(r.ask!['detail'], hasLength(20000));
      expect(r.ask!['button'], hasLength(40));
      expect(r.ask!['danger'], isTrue);
    });

    test('prompt fields and choose options: named once, values of plain kinds', () {
      final p = parseAsk(jsonEncode({
        'id': 1,
        'kind': 'prompt',
        'fields': [
          {'name': 'env', 'label': 'Env', 'default': 'stage'},
          {'name': 'env'},
          {'label': 'no name'},
          {'name': 'msg'},
        ],
      }));
      expect(p.ask!['title'], 'Input');
      expect(p.ask!['fields'], [
        {'name': 'env', 'label': 'Env', 'default': 'stage'},
        {'name': 'msg', 'label': 'msg', 'default': ''},
      ]);
      final c = parseAsk(jsonEncode({
        'kind': 'choose',
        'options': ['a', {'value': 'a'}, {'value': 2, 'label': 'two'}, {'value': {'x': 1}}, null],
        'multiple': true,
      }));
      expect(c.ask!['options'], [
        {'value': 'a', 'label': 'a'},
        {'value': 2, 'label': 'two'},
      ]);
      expect(c.ask!['multiple'], isTrue);
      expect(c.id, isNull);
    });

    test('bad JSON, an unknown kind, nothing to choose: an error, the id kept when there is one', () {
      expect(parseAsk('{nope').error, 'not JSON');
      expect(parseAsk('[1]').error, 'expected a JSON object');
      final shout = parseAsk('{"id": "s", "kind": "shout"}');
      expect((shout.ask, shout.id), (null, 's'));
      expect(shout.error, contains('confirm, prompt or choose'));
      expect(parseAsk('{"kind": "choose", "options": []}').error, contains('options'));
      expect(parseAsk('{"kind": "prompt"}').error, contains('fields'));
    });
  });

  test('checkAnswer: only what the question allows reaches the command', () {
    final confirm = parseAsk('{"kind": "confirm"}').ask!;
    expect([checkAnswer(confirm, true), checkAnswer(confirm, false), checkAnswer(confirm, 'yes')], [true, false, null]);
    final prompt = parseAsk('{"kind": "prompt", "fields": [{"name": "m"}, {"name": "n"}]}').ask!;
    expect(checkAnswer(prompt, {'m': 'hi', 'n': 3, 'extra': 'x'}), {'m': 'hi', 'n': '3'});
    expect(checkAnswer(prompt, 'hi'), isNull);
    final one = parseAsk('{"kind": "choose", "options": ["stage", "prod"]}').ask!;
    expect([checkAnswer(one, 'prod'), checkAnswer(one, 'dev'), checkAnswer(one, null)], ['prod', null, null]);
    final many = parseAsk('{"kind": "choose", "options": ["a", "b", 1], "multiple": true}').ask!;
    expect(checkAnswer(many, ['b', 'zz', 1, 'b']), ['b', 1]);
    expect(checkAnswer(many, 'a'), isNull);
  });

  group('AskLines', () {
    test('takes ask lines out, however the chunks fall; the rest goes through at once', () {
      final asks = <String?>[];
      final lines = AskLines(asks.add);
      final out = [
        lines.add('one\n::emu'),
        lines.add('-ask {"kind":'),
        lines.add('"confirm"}\r\ntwo'),
        lines.add(' and more\n::emu-asking\n'),
        lines.add('::emu-ask {}'),
        lines.close(),
      ];
      expect(asks, ['{"kind":"confirm"}']);
      expect(out, ['one\n', '', 'two', ' and more\n::emu-asking\n', '', '::emu-ask {}']);
    });

    test('an ask line over the limit is dropped, and reported as null', () {
      final asks = <String?>[];
      final lines = AskLines(asks.add);
      expect(lines.add('::emu-ask ${'x' * askLineLimit}'), '');
      expect(lines.add('still the same line\nafter\n'), 'after\n');
      expect(asks, [null]);
    });
  });

  group('emu run on a terminal', () {
    test('asks only with a terminal at both ends', () {
      expect(canAskInTerminal(stdinTerminal: true, stderrTerminal: true), isTrue);
      expect(canAskInTerminal(stdinTerminal: false, stderrTerminal: true), isFalse); // piped, or /dev/null
      expect(canAskInTerminal(stdinTerminal: true, stderrTerminal: false), isFalse);
    });

    Future<(Object?, String)> askWith(String json, List<String?> typed) async {
      final dir = Directory.systemTemp.createTempSync('emu_ask_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/err');
      final err = file.openWrite();
      final lines = [...typed];
      final value = await askInTerminal(parseAsk(json).ask!, {'page': 'Tools', 'action': 'Push'},
          readLine: () async => lines.isEmpty ? null : lines.removeAt(0), err: err);
      await err.close();
      return (value, file.readAsStringSync());
    }

    test('confirm, prompt and choose, with the page and action that ask', () async {
      final (yes, text) = await askWith('{"kind": "confirm", "title": "Overwrite?", "detail": "a\\nb", "danger": true, "button": "push"}', ['y']);
      expect(yes, isTrue);
      expect(text, allOf(contains('Tools · Push asks:'), contains('⚠ Overwrite?'), contains('  a\n  b'), contains('push? [y/N]')));
      expect((await askWith('{"kind": "confirm"}', [''])).$1, isFalse);
      expect((await askWith('{"kind": "confirm"}', [])).$1, isNull); // input ended
      expect((await askWith('{"kind": "prompt", "fields": [{"name": "m", "default": "hi"}, {"name": "n"}]}', ['', 'x'])).$1,
          {'m': 'hi', 'n': 'x'});
      expect((await askWith('{"kind": "choose", "options": ["stage", "prod"]}', ['9', '2'])).$1, 'prod');
      expect((await askWith('{"kind": "choose", "options": ["a", "b", "c"], "multiple": true}', ['3, 1'])).$1, ['c', 'a']);
      expect((await askWith('{"kind": "choose", "options": ["a"]}', [''])).$1, isNull);
    });
  });

  group('a run that asks', () {
    late Directory root;
    late List<Map<String, dynamic>> broadcasts;
    late List<(String, LogLevel)> logs;
    late List<(String, Map<String, dynamic>)> sent;
    late Set<String> here;
    void Function(Map<String, dynamic>)? onAsk;
    late PagesApi api;

    setUp(() {
      root = Directory.systemTemp.createTempSync('emu_ask_');
      File('${root.path}/emu.yaml').writeAsStringSync(_emuYaml);
      final script = File('${root.path}/tool/t.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync(_script);
      Process.runSync('chmod', ['+x', script.path]);
      broadcasts = [];
      logs = [];
      sent = [];
      here = {'tab-1'};
      onAsk = null;
      api = PagesApi(
        projectRoot: root.path,
        home: root.path,
        environment: () => {'EMU_PROJECT': root.path},
        followUp: (then) async => {'action': then.name, 'ok': true},
        openUrl: (url) async => {'ok': true},
        broadcast: broadcasts.add,
        log: (text, level) => logs.add((text, level)),
        askerHere: here.contains,
        sendToAsker: (asker, m) {
          if (!here.contains(asker)) return false;
          sent.add((asker, m));
          if (m['event'] == 'ask') scheduleMicrotask(() => onAsk?.call(m));
          return true;
        },
      );
    });
    tearDown(() {
      api.dispose();
      root.deleteSync(recursive: true);
    });

    Future<(int, Map<String, dynamic>)> call(String path, Map<String, dynamic> body) async {
      final res = await api.handle(Request('POST', Uri.parse('http://127.0.0.1:4577$path'), body: jsonEncode(body)), path);
      return (res.statusCode, jsonDecode(await res.readAsString()) as Map<String, dynamic>);
    }

    Future<Map<String, dynamic>> run(String item, {String? asker = 'tab-1'}) async =>
        (await call('/api/pages/tools/run/$item', {'asker': ?asker})).$2;

    Future<(int, Map<String, dynamic>)> answer(Map<String, dynamic> ask, Object? value) =>
        call('/api/pages/${ask['page']}/asks/${ask['askId']}', {'value': value});

    test('asks the tab that started it, writes the answer to stdin, keeps the line out of the output', () async {
      onAsk = (m) => answer(m, true);
      final j = await run('ask');
      expect(j['ok'], isTrue);
      expect(j['output'], 'before EMU_ASK=1\ngot {"id":"go","value":true}\n');
      final asks = [for (final (asker, m) in sent) if (m['event'] == 'ask') (asker, m)];
      expect(asks, hasLength(1));
      final (asker, m) = asks.single;
      expect(asker, 'tab-1');
      expect(m['from'], {'page': 'Tools', 'action': 'Push'});
      expect(m['ask'], {
        'id': 'go',
        'kind': 'confirm',
        'title': 'Overwrite 2 files?',
        'detail': 'a.tpl\nb.tpl',
        'danger': true,
        'button': 'OK',
      });
      expect(m['timeoutMs'], 120000);
      expect(sent.last.$2['event'], 'ask-done');
      // Nowhere else: not to other dashboards, not in the live output nor the log.
      final everything = jsonEncode([broadcasts, for (final l in logs) l.$1]);
      expect(everything, isNot(contains('::emu-ask')));
      expect(broadcasts.where((b) => b['event'] == 'ask'), isEmpty);
      // Answered: a second answer finds nothing.
      expect((await answer(m, false)).$1, 404);
    });

    test('a second answer to the same question, right after the first, is refused', () async {
      final codes = <int>[];
      onAsk = (m) async {
        final both = await Future.wait([answer(m, true), answer(m, false)]);
        codes.addAll([for (final (code, _) in both) code]);
      };
      final j = await run('ask');
      expect(j['output'], contains('"value":true'));
      expect(codes, [200, 404]);
    });

    test('several questions, one at a time; the answers are checked against them', () async {
      onAsk = (m) => answer(m, m['ask']['kind'] == 'choose' ? 'dev' : {'m': 'yo', 'x': 'y'});
      final j = await run('two');
      expect(j['output'], 'got {"id":"env","value":null} {"id":"msg","value":{"m":"yo"}}\n');
      expect([for (final (_, m) in sent) m['event']], ['ask', 'ask-done', 'ask', 'ask-done']);
    });

    test('no answer in askTimeout: null, and a note in the output', () async {
      final j = await run('quick');
      expect(j['ok'], isTrue);
      expect(j['output'], contains('⚠ emu-ask "go": no answer in 1s — answered null\n'));
      expect(j['output'], contains('got {"id":"go","value":null}'));
      expect(sent.last.$2['event'], 'ask-done'); // the dialog closes
    });

    test("the run's timeout stands still while a question waits", () async {
      onAsk = (m) => Future.delayed(const Duration(milliseconds: 1500), () => answer(m, true));
      final j = await run('paused');
      expect(j['ok'], isTrue, reason: '${j['error']}');
      expect(j['output'], contains('"value":true'));
      expect(j['waitedMs'], greaterThanOrEqualTo(1400));
    });

    test('no one to answer: no asker, or one that is gone — null at once, EMU_ASK=0', () async {
      final j = await run('ask', asker: null);
      expect(j['output'], startsWith('before EMU_ASK=0\n'));
      expect(j['output'], contains('no one to answer'));
      expect(j['output'], contains('got {"id":"go","value":null}'));
      here.clear();
      final k = await run('ask');
      expect(k['output'], startsWith('before EMU_ASK=0\n'));
      expect(k['output'], contains('"value":null'));
      expect(sent, isEmpty);
    });

    test('the asker going away answers its question null', () async {
      onAsk = (m) => api.askerGone('tab-1');
      final j = await run('ask');
      expect(j['output'], contains('went away — answered null'));
      expect(j['output'], contains('"value":null'));
    });

    test('a line emu cannot read: null, and a warning', () async {
      final j = await run('bad');
      expect(j['output'], contains('⚠ emu-ask: not JSON — answered null'));
      expect(j['output'], contains('⚠ emu-ask 7: kind must be confirm, prompt or choose'));
      expect(j['output'], allOf(contains('got {"id":null,"value":null}\n'), contains('got {"id":7,"value":null}\n')));
      expect(sent, isEmpty);
    });

    test('without interactive: the line is plain output, stdin is closed, nothing is asked', () async {
      final j = await run('plain');
      expect(j['output'], contains('::emu-ask {"id":"go"'));
      expect(j['output'], contains('before EMU_ASK=0'));
      expect(j['output'], contains('got \n'));
      expect(sent, isEmpty);
    });

    test('an answer for a question no one asked is refused', () async {
      expect((await call('/api/pages/tools/asks/abc', {'value': true})).$1, 404);
    });
  });

  test('interactive and askTimeout in emu.yaml', () {
    final ok = parsePages([
      {
        'id': 'p',
        'toolbar': [
          {'action': {'id': 'a', 'run': ['x'], 'interactive': true, 'askTimeout': 30}},
          {'action': {'id': 'b', 'run': ['x']}},
        ],
      },
    ]);
    expect(ok.problems, isEmpty);
    final [a as PageAction, b as PageAction] = ok.pages.single.toolbar;
    expect((a.interactive, a.askTimeout, a.toJson()['interactive']), (true, const Duration(seconds: 30), true));
    expect((b.interactive, b.askTimeout, b.toJson().containsKey('interactive')), (false, defaultAskTimeout, false));
    final bad = parsePages([
      {
        'id': 'p',
        'toolbar': [
          {'action': {'id': 'a', 'run': ['x'], 'interactive': 'yes'}},
          {'action': {'id': 'b', 'run': ['x'], 'askTimeout': 5}},
          {'action': {'id': 'c', 'openUrl': 'app://x', 'interactive': true}},
          {'action': {'id': 'd', 'run': ['x'], 'interactive': true, 'askTimeout': 0}},
          {'action': {'id': 'e', 'run': ['x'], 'interactive': true, 'auto': {'watch': ['tpl/**']}}},
        ],
      },
    ]);
    expect(bad.problems, [
      'p.a.interactive: expected true or false',
      'p.b.askTimeout: applies to an action with interactive: true',
      'p.c: interactive works with run:, not openUrl',
      'p.d.askTimeout: askTimeout must be a positive number of seconds (got "0")',
      'p.e.auto: an action that runs on its own has no one to answer what it asks — '
          'its questions would all be answered null; drop interactive or auto',
    ]);
    expect(bad.pages.single.toolbar, isEmpty);
  });
}
