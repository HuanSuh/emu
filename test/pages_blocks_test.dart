import 'dart:convert';
import 'dart:io';

import 'package:emu/src/pages_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// List rows and diffs from a real script; row buttons and the toolbar fed
/// with the selected row.
const _emuYaml = r'''
pages:
  - id: tpl
    toolbar:
      - action: { id: publish, run: [./tool/t.sh, args, publish, "{{selected.name}}"], confirm: true }
      - action: { id: home, openUrl: "myapp://home" }
    blocks:
      - list:
          id: items
          run: [./tool/t.sh, list]
          key: name
          columns: [name, local:chip]
          rowActions:
            - action: { id: check, run: [./tool/t.sh, args, check, "{{row.name}}"] }
            - action: { id: go, openUrl: "myapp://item?name={{row.name}}" }
            - action:
                id: drop
                run: [./tool/t.sh, args, drop, "{{row.name}}"]
                confirm:
                  title: "drop {{row.name}}?"
                  message: "<b>{{row.name}}</b> (local: {{row.local}}) goes"
                  preview: [./tool/t.sh, diff, "{{row.name}}", base]
          watch: [templates/**]
      - form:
          id: link
          fields:
            - { name: url }
            - { name: note }
          actions:
            - action: { id: open, openUrl: "{{input.url}}", confirm: true }
            - action: { id: echo, run: [./tool/t.sh, args, "{{input.url}}", "{{input.note}}"] }
      - panel:
          id: deploy
          note: pushes to the remote branch
          actions:
            - action: { id: stage, run: [./tool/t.sh, args, stage, "{{selected.name}}"], confirm: true }
      - diff:
          id: changes
          run: [./tool/t.sh, diff, "{{selected.name}}", "{{seg}}"]
          segments: [base, prod]
      - list:
          id: broken
          run: [./tool/t.sh, notjson]
      - html:
          id: tree
          src: tool/tree.html
          run: [./tool/t.sh, value, "{{selected.name}}"]
          actions: [publish]
      - html:
          id: plain
          src: tool/tree.html
          run: [./tool/t.sh, notjson]
      - html:
          id: help
          src: tool/help.html
      - html:
          id: escape
          src: tool/link.html
      - html:
          id: view
          src: tool/tree.html
          inputs: [env, note]
          actions:
            - publish
            - action: { id: plan, run: [./tool/t.sh, plan, "{{input.env}}"] }
            - action: { id: echo, run: [./tool/t.sh, args, "{{input.env}}", "{{input.note}}"] }
            - action: { id: push, run: [./tool/t.sh, args, push, "{{input.env}}"], confirm: true }
      - list:
          id: files
          run: [./tool/t.sh, list]
          key: name
          tree: [local, name]
      - diff:
          id: content
          run: [./tool/t.sh, diff, "{{selected.name}}", "{{seg}}"]
          segments: { values: [base, prod], optional: true, hide: "{{selected.env}}" }
''';

const _script = r'''#!/bin/sh
case "$1" in
  list) echo "loading…" >&2; echo '[{"name": "home banner", "local": true}, {"name": "card", "local": false}]' ;;
  diff) printf -- '--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old %s\n+new %s\n' "$2" "$2" "$3" "$3" ;;
  args) shift; for a in "$@"; do echo "[$a]"; done ;;
  notjson) echo "rows: 2" ;;
  plan) echo "[{\"path\": \"home.json\", \"env\": \"$2\"}]" ;;
  value) echo "{\"key\": \"$2\", \"value\": {\"title\": \"Hello\", \"items\": [1, 2]}}" ;;
esac
''';

void main() {
  late Directory root;
  late PagesApi api;
  late List<String> opened;

  setUp(() {
    opened = [];
    root = Directory.systemTemp.createTempSync('emu_blocks_');
    File('${root.path}/emu.yaml').writeAsStringSync(_emuYaml);
    final script = File('${root.path}/tool/t.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(_script);
    Process.runSync('chmod', ['+x', script.path]);
    File('${root.path}/tool/tree.html').writeAsStringSync('<!doctype html><p>tree</p>');
    File('${root.path}/outside.html').writeAsStringSync('secret');
    final outside = Directory.systemTemp.createTempSync('emu_outside_');
    File('${outside.path}/x.html').writeAsStringSync('outside the project');
    Link('${root.path}/tool/link.html').createSync('${outside.path}/x.html');
    addTearDown(() => outside.deleteSync(recursive: true));
    api = PagesApi(
      projectRoot: root.path,
      home: root.path,
      environment: () => {},
      followUp: (_) async => {'ok': true},
      openUrl: (url) async {
        opened.add(url);
        return url.startsWith('bad://') ? {'ok': false, 'error': 'no app handles bad://'} : {'ok': true};
      },
      broadcast: (_) {},
      log: (_, _) {},
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, Map<String, dynamic>)> call(String method, String pathAndQuery, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('http://127.0.0.1:4577$pathAndQuery');
    final res = await api.handle(Request(method, uri, body: body == null ? null : jsonEncode(body)), uri.path);
    return (res.statusCode, jsonDecode(await res.readAsString()) as Map<String, dynamic>);
  }

  test('a list block returns the rows its command prints (stdout only)', () async {
    final (code, j) = await call('GET', '/api/pages/tpl/blocks/items');
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['kind'], 'list');
    expect(j['rows'], [
      {'name': 'home banner', 'local': true},
      {'name': 'card', 'local': false},
    ]);
  });

  test('a tree list says which columns make the folders, for emu block', () async {
    final (_, j) = await call('GET', '/api/pages/tpl/blocks/files');
    expect(j['ok'], isTrue);
    expect(j['tree'], ['local', 'name']);
    expect((await call('GET', '/api/pages/tpl/blocks/items')).$2.containsKey('tree'), isFalse);
  });

  test('a list that prints something else says so', () async {
    final (_, j) = await call('GET', '/api/pages/tpl/blocks/broken');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('JSON array of objects'));
  });

  test('a diff waits for a selection, then fills it and the segment', () async {
    var (code, j) = await call('GET', '/api/pages/tpl/blocks/changes');
    expect(code, 200);
    expect(j['ok'], isFalse);
    expect(j['needs'], 'selected');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card');
    expect(j['ok'], isTrue);
    expect(j['seg'], 'base'); // the first segment unless one is picked
    expect(j['patch'], contains('+new base'));

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card&seg=prod');
    expect(j['patch'], contains('+new prod'));
    expect(j['command'], './tool/t.sh diff card prod');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card&seg=staging');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('base, prod'));
  });

  test('optional segments: none unless one is asked for, and an empty one means none', () async {
    var (_, j) = await call('GET', '/api/pages/tpl/blocks/content?selected.name=card');
    expect(j['ok'], isTrue);
    expect(j['seg'], '');
    expect(j['command'], "./tool/t.sh diff card ''");

    (_, j) = await call('GET', '/api/pages/tpl/blocks/content?selected.name=card&seg=prod');
    expect(j['patch'], contains('+new prod'));

    (_, j) = await call('GET', '/api/pages/tpl/blocks/content?selected.name=card&seg=');
    expect(j['seg'], '');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/changes?selected.name=card&seg=');
    expect(j['ok'], isFalse); // a segment must be picked there
    expect(j['error'], 'seg must be one of base, prod (got "")');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/content?selected.name=card&seg=dev');
    expect(j['error'], 'seg must be one of base, prod, or empty for none (got "dev")');
  });

  test('a row button gets its row, as one argument however it is spelled', () async {
    const nasty = r'x"; touch pwned; echo $(id) `id` ;';
    final (code, j) = await call('POST', '/api/pages/tpl/rows/items/check', {
      'row': {'name': nasty, 'local': true},
    });
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['item'], 'items.check');
    expect(j['output'], '[check]\n[$nasty]\n');
    expect(File('${root.path}/pwned').existsSync(), isFalse);
  });

  test('a toolbar action reads the selection; confirm shows the filled command', () async {
    var (code, j) = await call('POST', '/api/pages/tpl/run/publish', {});
    expect(code, 400);
    expect(j['needs'], 'selected');

    (code, j) = await call('POST', '/api/pages/tpl/run/publish', {
      'selected': {'name': 'home banner'},
    });
    expect(code, 428);
    expect(j['command'], "./tool/t.sh args publish 'home banner'");

    (code, j) = await call('POST', '/api/pages/tpl/run/publish', {
      'selected': {'name': 'home banner'},
      'confirmed': true,
    });
    expect(j['output'], '[publish]\n[home banner]\n');
  });

  test("a row button's confirm fills its words and preview from the row, as text", () async {
    var (code, j) = await call('POST', '/api/pages/tpl/rows/items/drop', {'row': {'name': 'card'}});
    expect(code, 400); // the message reads a column the command doesn't
    expect(j['needs'], 'row');

    (code, j) = await call('POST', '/api/pages/tpl/rows/items/drop', {
      'row': {'name': 'card', 'local': false},
    });
    expect(code, 428);
    expect(j['command'], './tool/t.sh args drop card');
    expect(j['confirm']['title'], 'drop card?');
    expect(j['confirm']['message'], '<b>card</b> (local: false) goes'); // the dashboard sets it as text
    expect(j['preview']['command'], './tool/t.sh diff card base');
    expect(j['preview']['patch'], contains('+new base'));
  });

  test('unknown blocks and row actions say what exists', () async {
    var (code, j) = await call('GET', '/api/pages/tpl/blocks/nope');
    expect(code, 404);
    expect(j['error'], contains('items, changes, broken, tree, plain, help, escape'));
    expect(j['error'], isNot(contains('link'))); // a form has no data to fetch
    (code, _) = await call('POST', '/api/pages/tpl/rows/items/nope', {});
    expect(code, 404);
    (code, _) = await call('POST', '/api/pages/tpl/rows/changes/check', {});
    expect(code, 404); // a diff has no row buttons
  });

  test("an html block's data: JSON as a value, other text as text, none without run", () async {
    var (_, j) = await call('GET', '/api/pages/tpl/blocks/tree?selected.name=card');
    expect(j['ok'], isTrue);
    expect(j['kind'], 'html');
    expect(j['data'], {'key': 'card', 'value': {'title': 'Hello', 'items': [1, 2]}});

    (_, j) = await call('GET', '/api/pages/tpl/blocks/tree');
    expect(j['needs'], 'selected');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/plain');
    expect(j['data'], isNull);
    expect(j['text'], 'rows: 2\n');

    (_, j) = await call('GET', '/api/pages/tpl/blocks/help');
    expect(j, {'ok': true, 'kind': 'html', 'data': null});
  });

  test("an html block's file comes from the project, never through a link out of it", () async {
    var (code, j) = await call('GET', '/api/pages/tpl/frames/tree');
    expect(code, 200);
    expect(j['html'], '<!doctype html><p>tree</p>');

    (_, j) = await call('GET', '/api/pages/tpl/frames/help');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('cannot read tool/help.html'));

    (_, j) = await call('GET', '/api/pages/tpl/frames/escape');
    expect(j['ok'], isFalse);
    expect(j['error'], contains('leads outside the project'));

    (code, _) = await call('GET', '/api/pages/tpl/frames/items');
    expect(code, 404); // a list has no frame
  });

  test('a form button gets what was typed, each value one argument', () async {
    final (code, j) = await call('POST', '/api/pages/tpl/forms/link/echo', {
      'input': {'url': 'myapp://x?a=1&b=2', 'note': r'two words; $(id)'},
    });
    expect(code, 200);
    expect(j['item'], 'link.echo');
    expect(j['output'], '[myapp://x?a=1&b=2]\n[two words; \$(id)]\n');
  });

  test('a panel (a form with no fields) runs its buttons like a form, under forms/', () async {
    var (code, j) = await call('GET', '/api/pages');
    final deploy = ((j['pages'] as List).first['blocks'] as List).firstWhere((b) => b['id'] == 'deploy');
    expect(deploy, allOf(containsPair('kind', 'form'), containsPair('note', 'pushes to the remote branch')));
    expect(deploy['fields'], isEmpty);

    (code, j) = await call('POST', '/api/pages/tpl/forms/deploy/stage', {'selected': {'name': 'card'}});
    expect(code, 428); // confirm: true
    (code, j) = await call('POST', '/api/pages/tpl/forms/deploy/stage', {'selected': {'name': 'card'}, 'confirmed': true});
    expect(code, 200);
    expect(j['item'], 'deploy.stage');
    expect(j['output'], '[stage]\n[card]\n');
  });

  test('openUrl opens the filled-in link on the device and reports it like a run', () async {
    var (code, j) = await call('POST', '/api/pages/tpl/forms/link/open', {'input': {'url': 'myapp://home?tab=2'}});
    expect(code, 428); // confirm: true — the dialog shows exactly this
    expect(j['command'], 'open-url myapp://home?tab=2');
    expect(opened, isEmpty);

    (code, j) = await call('POST', '/api/pages/tpl/forms/link/open', {
      'input': {'url': 'myapp://home?tab=2'},
      'confirmed': true,
    });
    expect(j['ok'], isTrue);
    expect(j['command'], 'open-url myapp://home?tab=2');
    expect(j['output'], 'opened myapp://home?tab=2');
    expect(opened, ['myapp://home?tab=2']);

    (_, j) = await call('POST', '/api/pages/tpl/rows/items/go', {'row': {'name': 'home banner'}});
    expect(opened.last, 'myapp://item?name=home banner');

    (_, j) = await call('POST', '/api/pages/tpl/run/home', {});
    expect(opened.last, 'myapp://home');
  });

  test('openUrl: an empty field, a missing field and a failed open', () async {
    var (code, j) = await call('POST', '/api/pages/tpl/forms/link/open', {'input': {'url': '  '}, 'confirmed': true});
    expect(code, 400);
    expect(j['error'], contains('the URL is empty'));

    (code, j) = await call('POST', '/api/pages/tpl/forms/link/open', {'confirmed': true});
    expect(code, 400);
    expect(j['needs'], 'input');

    (_, j) = await call('POST', '/api/pages/tpl/forms/link/open', {'input': {'url': 'bad://x'}, 'confirmed': true});
    expect(j['ok'], isFalse);
    expect(j['output'], 'no app handles bad://');

    (code, _) = await call('POST', '/api/pages/tpl/forms/items/check', {});
    expect(code, 404); // a list's row action isn't a form action
  });

  test("an html block's own action takes its inputs, each value one argument", () async {
    var (code, j) = await call('POST', '/api/pages/tpl/frames/view/echo', {
      'input': {'env': 'stage', 'note': r'two words; $(id)', 'extra': 'dropped'},
    });
    expect(code, 200);
    expect(j['item'], 'view.echo');
    expect(j['output'], '[stage]\n[two words; \$(id)]\n');
    expect(j.containsKey('data'), isFalse); // stdout isn't JSON

    // Only names in inputs: go along — the rest never reach a placeholder.
    (code, j) = await call('POST', '/api/pages/tpl/frames/view/echo', {
      'input': {'env': 'stage'},
    });
    expect(code, 400);
    expect(j['needs'], 'input');
  });

  test("an html block action's JSON stdout comes back as data", () async {
    final (code, j) = await call('POST', '/api/pages/tpl/frames/view/plan', {'input': {'env': 'prod'}});
    expect(code, 200);
    expect(j['ok'], isTrue);
    expect(j['data'], [
      {'path': 'home.json', 'env': 'prod'},
    ]);
  });

  test('an html block action marked confirm: true still needs the confirmation', () async {
    var (code, j) = await call('POST', '/api/pages/tpl/frames/view/push', {'input': {'env': 'prod'}});
    expect(code, 428);
    expect(j['needsConfirm'], isTrue);
    expect(j['command'], './tool/t.sh args push prod');

    (code, j) = await call('POST', '/api/pages/tpl/frames/view/push', {'input': {'env': 'prod'}, 'confirmed': true});
    expect(code, 200);
    expect(j['output'], '[push]\n[prod]\n');
  });

  test("frames/<block>/<action> runs only an html block's own actions", () async {
    var (code, j) = await call('POST', '/api/pages/tpl/frames/view/nope', {});
    expect(code, 404);
    expect(j['error'], contains('no html block action "view.nope"'));
    (code, _) = await call('POST', '/api/pages/tpl/frames/view/publish', {}); // a toolbar id: run/publish
    expect(code, 404);
    (code, _) = await call('POST', '/api/pages/tpl/frames/items/check', {}); // a list's row action
    expect(code, 404);
    (code, _) = await call('GET', '/api/pages/tpl/frames/view/echo');
    expect(code, 405);
    (code, j) = await call('GET', '/api/pages/tpl/frames/view'); // the file, as before
    expect(j['html'], '<!doctype html><p>tree</p>');
  });

  test('watching maps changed paths to the blocks to fetch again', () {
    expect(api.watching(['templates/home.json', 'lib/main.dart']), {
      'tpl': {'items'},
    });
    expect(api.watching(['lib/main.dart']), isEmpty);
  });

  test('placeholderValues reads bodies and queries', () {
    expect(
      placeholderValues(body: {
        'selected': {'name': 'a', 'n': 3, 'tags': ['x']},
        'row': {'id': true},
        'seg': 'prod',
      }),
      {'selected.name': 'a', 'selected.n': '3', 'selected.tags': '["x"]', 'row.id': 'true', 'seg': 'prod'},
    );
    expect(placeholderValues(query: {'selected.name': 'a', 'seg': 'b', 'token': 't'}), {'selected.name': 'a', 'seg': 'b'});
  });
}
