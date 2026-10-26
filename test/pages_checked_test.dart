import 'dart:convert';
import 'dart:io';

import 'package:emu/src/pages.dart';
import 'package:emu/src/pages_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Checked rows (`check:` lists): `{{checked.<col>...}}`, `{{checked.<col>}}`,
/// `{{checked.count}}`, `needs: checked`, the tool's own state and bulk buttons.
const _emuYaml = r'''
pages:
  - id: tpl
    toolbar:
      - action: { id: deploy, run: [./tool/t.sh, args, deploy, "{{checked.name...}}", --env, stage], needs: checked, confirm: true }
      - action: { id: names, run: [./tool/t.sh, args, --names, "{{checked.name}}", "{{checked.count}} picked"] }
      - action: { id: paths, run: [./tool/t.sh, args, "{{checked.path...}}"] }
      - action:
          id: ship
          run: [./tool/t.sh, args, ship]
          confirm:
            title: "Ship {{checked.count}} templates?"
            message: "{{checked.name}} go out."
            preview: [./tool/t.sh, args, --dry-run, "{{checked.name...}}"]
    blocks:
      - list:
          id: templates
          run: [./tool/t.sh, list]
          key: name
          check: true
          columns: [name, path]
          rowActions:
            - action: { id: push, run: [./tool/t.sh, args, push, "{{row.name}}"], bulk: true }
  - id: own
    blocks:
      - list:
          id: templates
          run: [./tool/t.sh, list]
          key: name
          check: true
      - list:
          id: picks
          run: [./tool/t.sh, picks]
          key: name
          check: { column: upload, toggle: [./tool/t.sh, toggle, "{{row.name}}"] }
      - form:
          id: f
          fields: [{ name: x }]
          actions:
            - action: { id: go, run: [./tool/t.sh, args, "{{templates.checked.name...}}", "{{picks.checked.name}}"] }
            - action: { id: picked, run: [./tool/t.sh, args, "{{picks.checked.count}}"], needs: picks.checked }
  - id: two
    toolbar:
      - action: { id: a, run: [./tool/t.sh, args, "{{one.checked.name...}}"] }
    blocks:
      - list: { id: one, run: [./tool/t.sh, list], check: true }
      - list: { id: other, run: [./tool/t.sh, list], check: true }
''';

const _script = r'''#!/bin/sh
case "$1" in
  list) echo '[{"name": "home", "path": "t/home.json"}, {"name": "card", "path": "t/card.json"}, {"name": "two words", "path": "t/2.json"}]' ;;
  picks) if [ -f .picked ]; then echo '[{"name": "a", "upload": "yes"}, {"name": "b", "upload": "no"}]'; else echo '[{"name": "a", "upload": "no"}, {"name": "b", "upload": "no"}]'; fi ;;
  toggle) touch .picked; echo "toggled $2" ;;
  args) shift; for a in "$@"; do echo "[$a]"; done ;;
esac
''';

Map<String, dynamic> _page(String yaml) => jsonDecode(jsonEncode(loadYaml(yaml))) as Map<String, dynamic>;

void main() {
  group('parsing', () {
    PagesConfig parse(String blocksAndToolbar) => parsePages([_page('id: p\n$blocksAndToolbar')]);

    test('check: true and check: {column, toggle}; the toggle is the list\'s "check" row action', () {
      final c = parsePages(loadYaml(_emuYaml)['pages']);
      expect(c.problems, isEmpty);
      final tpl = c.page('tpl')!;
      expect(tpl.checkList, 'templates');
      expect((tpl.block('templates') as ListBlock).rowAction('push')!.bulk, isTrue);
      expect((tpl.item('deploy') as PageAction).needsChecked, 'templates');
      final page = c.page('own')!;
      expect(page.checkLists.map((b) => b.id), ['templates', 'picks']);
      expect(page.checkList, isNull); // two: an unqualified {{checked.*}} would be ambiguous
      expect((page.block('templates') as ListBlock).check!.column, isNull);
      final picks = page.block('picks') as ListBlock;
      expect(picks.check!.column, 'upload');
      expect(picks.rowAction('check')!.run!.argv, ['./tool/t.sh', 'toggle', '{{row.name}}']);
      expect(picks.toJson()['check'], {'column': 'upload', 'toggle': "./tool/t.sh toggle '{{row.name}}'"});
      final form = page.block('f') as FormBlock;
      expect(page.checkedListsOf(form.action('go')!), {'templates', 'picks'});
      expect(form.action('picked')!.needsChecked, 'picks');
    });

    test('an unqualified {{checked.*}} needs exactly one check list', () {
      var c = parse('''
toolbar:
  - action: { id: a, run: [x, "{{checked.name...}}"] }
blocks:
  - list: { id: l, run: [x] }
''');
      expect(c.problems.single, contains('no list on this page has check:'));
      c = parse('''
toolbar:
  - action: { id: a, run: [x, "{{checked.name...}}"] }
  - action: { id: b, run: [x, "{{one.checked.name...}}"], needs: one.checked }
blocks:
  - list: { id: one, run: [x], check: true }
  - list: { id: two, run: [x], check: true }
''');
      expect(c.problems.single, allOf(contains('p.a.run'), contains('several lists have check:')));
      expect(c.page('p')!.item('b'), isNotNull);
    });

    test('where the placeholders and needs may go, and how they are spelled', () {
      final c = parse('''
toolbar:
  - action: { id: part, run: [x, "--names={{checked.name...}}"] }
  - action: { id: count, run: [x, "{{checked.count...}}"] }
  - action: { id: bare, run: [x, "{{checked}}"] }
  - action: { id: url, openUrl: "app://x?n={{checked.name...}}" }
  - action: { id: urlok, openUrl: "app://x?n={{checked.name}}&c={{checked.count}}" }
  - action: { id: spreadrow, run: [x, "{{selected.name...}}"] }
  - action: { id: other, run: [x, "{{nope.checked.name}}"] }
  - action: { id: needs, run: [x], needs: selected }
  - action: { id: needsok, run: [x], needs: checked }
  - action: { id: msg, run: [x], confirm: "{{checked.name...}} go out" }
  - toggle: { id: t, state: [x, "{{checked.count}}"], on: [x], off: [x] }
blocks:
  - list:
      id: l
      run: [x, "{{checked.name}}"]
      check: true
  - list:
      id: m
      run: [x]
      rowActions:
        - action: { id: b, run: [x, "{{row.name}}"], bulk: true }
''');
      final all = c.problems.join('\n');
      expect(all, contains('p.part.run: {{checked.name...}} must be a whole argument'));
      expect(all, contains('p.count.run: {{checked.count}} is one number'));
      expect(all, contains('p.bare.run: {{checked}} needs a column'));
      expect(all, contains('p.url.openUrl: an openUrl is one URL'));
      expect(all, contains('p.spreadrow.run: ... only spreads checked rows'));
      expect(all, contains('p.other.run: no list "nope" with check:'));
      expect(all, contains('p.needs.needs: needs takes checked or <list>.checked'));
      expect(
        all,
        contains('p.msg.confirm: {{checked.name...}} spreads into arguments — in text use {{checked.<col>}}'),
      );
      expect(all, contains('p.t.state: {{checked.*}} only works in actions'));
      expect(all, contains('p.l.run: {{checked.*}} only works in actions'));
      expect(all, contains('p.m.b.bulk: it runs on the checked rows'));
      final page = c.page('p')!;
      expect(page.toolbar.map((i) => i.id), ['urlok', 'needsok']);
      expect((page.item('needsok') as PageAction).toJson()['needsChecked'], 'l');
    });

    test('check.toggle takes the row action id "check"', () {
      final c = parse('''
blocks:
  - list:
      id: l
      run: [x]
      check: { column: up, toggle: [x, "{{row.name}}"] }
      rowActions:
        - action: { id: check, run: [y] }
''');
      expect(c.problems.single, contains('check is taken by check.toggle'));
      expect(
        parse('blocks: [{list: {id: l, run: [x], check: {column: up}}}]').problems.single,
        contains('p.l.check: expected true, or {column: <col>, toggle: [program, arg, …]}'),
      );
    });
  });

  group('fill', () {
    const cmd = PageCommand.argv([
      'x',
      '{{checked.name...}}',
      '--names',
      '{{checked.name}}',
      'n={{checked.count}}',
      '{{a.checked.id...}}',
    ]);
    final rows = [
      {'name': 'one two', 'id': '1'},
      {'name': r'$(id);', 'id': '2'},
    ];

    test('spreads one argument per row, joins with commas, counts', () {
      expect(cmd.fill({}, checked: {'l': rows, 'a': rows}, checkList: 'l').argv, [
        'x',
        'one two',
        r'$(id);',
        '--names',
        r'one two,$(id);',
        'n=2',
        '1',
        '2',
      ]);
    });

    test('no rows: no spread arguments, an empty join, a zero', () {
      expect(cmd.fill({}, checkList: 'l').argv, ['x', '--names', '', 'n=0']);
    });

    test('a checked row without the column is a missing value of kind checked', () {
      expect(
        () => cmd.fill(
          {},
          checked: {
            'l': [
              {'id': '1'},
            ],
          },
          checkList: 'l',
        ),
        throwsA(
          isA<MissingValue>().having((e) => e.kind, 'kind', 'checked').having((e) => e.key, 'key', 'checked.name...'),
        ),
      );
    });

    test('placeholders and checkedLists name the lists', () {
      expect(cmd.placeholders, {'checked.name...', 'checked.name', 'checked.count', 'a.checked.id...'});
      expect(cmd.checkedLists('l'), {'l', 'a'});
      expect(MissingValue('a.checked.id...').kind, 'checked');
      expect(MissingValue('selected.checked').kind, 'selected');
    });
  });

  group('runs', () {
    late Directory root;
    late PagesApi api;

    setUp(() {
      root = Directory.systemTemp.createTempSync('emu_checked_');
      File('${root.path}/emu.yaml').writeAsStringSync(_emuYaml);
      final script = File('${root.path}/tool/t.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync(_script);
      Process.runSync('chmod', ['+x', script.path]);
      api = PagesApi(
        projectRoot: root.path,
        home: root.path,
        environment: () => {},
        followUp: (_) async => {'ok': true},
        openUrl: (url) async => {'ok': true},
        broadcast: (_) {},
        log: (_, _) {},
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, Map<String, dynamic>)> call(String path, Map<String, dynamic> body) async {
      final uri = Uri.parse('http://127.0.0.1:4577$path');
      final res = await api.handle(Request('POST', uri, body: jsonEncode(body)), uri.path);
      return (res.statusCode, jsonDecode(await res.readAsString()) as Map<String, dynamic>);
    }

    test('the rows the dashboard sends spread into arguments, each whole', () async {
      final (code, j) = await call('/api/pages/tpl/run/names', {
        'checked': {
          'templates': [
            {'name': 'home', 'path': 't/home.json'},
            {'name': 'two words', 'path': 't/2.json'},
          ],
        },
      });
      expect(code, 200);
      expect(j['output'], '[--names]\n[home,two words]\n[2 picked]\n');
    });

    test('needs: checked refuses with nothing checked; confirm shows every argument', () async {
      var (code, j) = await call('/api/pages/tpl/run/deploy', {});
      expect(code, 400);
      expect(j['needs'], 'checked');
      expect(j['error'], contains('check a row in templates first'));

      (code, j) = await call('/api/pages/tpl/run/deploy', {
        'checked': [
          {'name': 'home'},
          {'name': 'two words'},
        ],
      });
      expect(code, 428);
      expect(j['command'], "./tool/t.sh args deploy home 'two words' --env stage");
    });

    test("confirm's title, message and preview read the checked rows too", () async {
      final (code, j) = await call('/api/pages/tpl/run/ship', {
        'checked': ['home', 'two words'],
      });
      expect(code, 428);
      expect(j['command'], './tool/t.sh args ship');
      expect(j['confirm'], containsPair('title', 'Ship 2 templates?'));
      expect(j['confirm'], containsPair('message', 'home,two words go out.'));
      expect(j['preview'], containsPair('text', '[--dry-run]\n[home]\n[two words]\n'));
    });

    test('keys (emu run --checked) are looked up in the list; an unknown key is refused', () async {
      var (code, j) = await call('/api/pages/tpl/run/paths', {
        'checked': ['card', 'home'],
      });
      expect(code, 200);
      expect(j['output'], '[t/card.json]\n[t/home.json]\n'); // in the order given
      (code, j) = await call('/api/pages/tpl/run/paths', {
        'checked': {
          'templates': ['nope'],
        },
      });
      expect(code, 400);
      expect(j['needs'], 'checked');
      expect(j['error'], contains('no row "nope" in templates'));
    });

    test('nothing checked and no needs: the spread is no arguments', () async {
      final (code, j) = await call('/api/pages/tpl/run/paths', {});
      expect(code, 200);
      expect(j['output'], '');
    });

    test("the tool's own checks come from its list, and the toggle runs as row action check", () async {
      var (code, j) = await call('/api/pages/own/forms/f/picked', {});
      expect(code, 400);
      expect(j['error'], contains('its toggle: emu run own.picks.check --row')); // not --checked: the tool decides

      (code, j) = await call('/api/pages/own/rows/picks/check', {
        'row': {'name': 'a'},
      });
      expect(code, 200);
      expect(j['output'], 'toggled a\n');

      (code, j) = await call('/api/pages/own/forms/f/go', {
        'checked': {
          'templates': ['home'],
          'picks': ['b'], // ignored: the tool says which are checked
        },
      });
      expect(code, 200);
      expect(j['output'], '[home]\n[a]\n');
    });

    test("a bare list of keys is the page's one check: true list's", () async {
      var (code, j) = await call('/api/pages/own/forms/f/go', {
        'checked': ['home'],
      });
      expect(code, 200);
      expect(j['output'], '[home]\n[]\n'); // picks: what the tool says (nothing yet)

      (code, j) = await call('/api/pages/two/run/a', {
        'checked': ['home'],
      });
      expect(code, 400);
      expect(j['error'], contains('say which list'));
      (code, j) = await call('/api/pages/two/run/a', {
        'checked': {
          'one': ['home'],
        },
      });
      expect(j['output'], '[home]\n');
    });
  });
}
