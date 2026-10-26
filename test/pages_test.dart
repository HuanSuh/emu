import 'package:emu/src/pages.dart';
import 'package:emu/src/project_config.dart';
import 'package:emu/src/pages_api.dart';
import 'package:test/test.dart';

void main() {
  group('parsePages', () {
    test('a page with a toggle, actions and an output block', () {
      final c = parsePages([
        {
          'id': 'templates',
          'title': 'Templates',
          'toolbar': [
            {
              'toggle': {
                'id': 'local',
                'label': 'local templates',
                'state': ['./tool/templates', 'status', '--json'],
                'on': ['./tool/templates', 'on'],
                'off': ['./tool/templates', 'off'],
                'then': 'reload',
              },
            },
            {'action': {'id': 'sync', 'run': ['./tool/templates', 'sync'], 'then': 'reload'}},
            {'action': {'id': 'publish', 'label': 'publish…', 'run': 'tool/publish.sh --all', 'confirm': true, 'timeout': 300}},
          ],
          'blocks': [
            {'output': {'area': 'bottom'}},
          ],
        },
      ]);
      expect(c.problems, isEmpty);
      final page = c.page('templates')!;
      expect(page.title, 'Templates');
      final toggle = page.item('local') as PageToggle;
      expect(toggle.state.argv, ['./tool/templates', 'status', '--json']);
      expect(toggle.then, Then.reload);
      final sync = page.item('sync') as PageAction;
      expect(sync.label, 'sync'); // defaults to the id
      expect(sync.confirm, isNull);
      expect(sync.timeout, defaultTimeout);
      final publish = page.item('publish') as PageAction;
      expect(publish.run!.shell, 'tool/publish.sh --all');
      expect(publish.run!.invocation.$1, 'sh');
      expect(publish.run!.invocation.$2, ['-c', 'tool/publish.sh --all']);
      expect(publish.confirm, isNotNull);
      expect(publish.confirm!.danger, isFalse);
      expect(publish.toJson()['confirm'], isTrue);
      expect(publish.timeout, const Duration(seconds: 300));
      expect(page.blocks.single, isA<OutputBlock>().having((b) => b.id, 'id', 'output'));
    });

    test('argv entries may be numbers; the title defaults to the id', () {
      final c = parsePages([
        {'id': 'p', 'toolbar': [{'action': {'id': 'a', 'run': ['sleep', 1]}}]},
      ]);
      expect(c.page('p')!.title, 'p');
      expect((c.page('p')!.item('a') as PageAction).run!.argv, ['sleep', '1']);
    });

    test('problems name where they are, and only the broken item is dropped', () {
      final c = parsePages([
        {
          'id': 'p',
          'toolbar': [
            {'action': {'id': 'ok', 'run': ['true']}},
            {'action': {'id': 'norun'}},
            {'action': {'id': 'badthen', 'run': ['true'], 'then': 'deploy'}},
            {'action': {'id': 'badtimeout', 'run': ['true'], 'timeout': -1}},
            {'toggle': {'id': 'half', 'state': ['x'], 'on': ['y']}},
            {'button': {'id': 'x'}},
            {'action': {'id': 'ok', 'run': ['true']}},
            {'action': {'id': 'bad id!', 'run': ['true']}},
            'not a map',
          ],
          'blocks': [
            {'output': {'id': 'o', 'area': 'side'}},
            {'chart': {'id': 'c'}},
          ],
        },
        {'id': 'debug'},
        {'title': 'no id'},
        {'id': 'p'},
      ]);
      expect(c.page('p')!.toolbar.map((i) => i.id), ['ok']);
      expect(c.page('p')!.blocks, isEmpty);
      final all = c.problems.join('\n');
      for (final expected in [
        'p.norun.run: missing',
        'p.badthen: then must be none, reload or restart',
        'p.badtimeout: timeout must be a positive number',
        'p.half.off: missing',
        'unknown toolbar item "button"',
        'p.ok: id is used twice',
        'needs an id of letters, digits, - or _ (got "bad id!")',
        'p.toolbar[8]: expected one entry',
        'p.o: area must be left, main or bottom',
        'unknown block "chart"',
        '"debug" is the built-in page',
        'pages[2]: needs an id',
        'pages[3]: page id "p" is used twice',
      ]) {
        expect(all, contains(expected));
      }
    });

    test('a non-list is one problem, absence is none', () {
      expect(parsePages(null).problems, isEmpty);
      expect(parsePages({'id': 'p'}).problems.single, contains('expected a list'));
    });
  });

  group('lists, diffs and placeholders', () {
    PagesConfig parse(List<Map<String, dynamic>> blocks, {List<Map<String, dynamic>> toolbar = const []}) =>
        parsePages([
          {'id': 'p', 'toolbar': toolbar, 'blocks': blocks},
        ]);

    test('a list and a diff with their defaults', () {
      final c = parse([
        {
          'list': {
            'id': 'items',
            'run': ['./tool/t', 'list', '--json'],
            'columns': ['name', 'local:chip', 'changes:count'],
            'rowActions': [
              {'action': {'id': 'check', 'run': ['./tool/t', 'check', '{{row.name}}']}},
            ],
            'watch': 'templates/**',
          },
        },
        {
          'diff': {
            'id': 'changes',
            'run': ['./tool/t', 'diff', '{{selected.name}}', '--against', '{{seg}}'],
            'segments': ['base', 'prod'],
          },
        },
      ]);
      expect(c.problems, isEmpty);
      final page = c.page('p')!;
      final list = page.block('items') as ListBlock;
      expect(list.area, 'left');
      expect(list.title, 'items');
      expect([for (final col in list.columns) '${col.key}:${col.format}'], ['name:text', 'local:chip', 'changes:count']);
      expect(list.rowAction('check')!.run!.placeholders, {'row.name'});
      expect(list.watch, ['templates/**']);
      expect(page.selectionList, same(list));
      final diff = page.block('changes') as DiffBlock;
      expect(diff.area, 'main');
      expect(diff.run.placeholders, {'selected.name', 'seg'});
      expect(page.toJson()['selection'], 'items');
    });

    test('a text column may take a width and cut its start; chips and counts take neither', () {
      final c = parse([
        {
          'list': {
            'id': 'items',
            'run': ['./tool/t', 'list'],
            'columns': ['path:text:40em:start', 'title:text:18ch', 'file:start', 'note:320px', 'name', 'on:chip'],
          },
        },
        {'list': {'id': 'chip', 'run': ['./tool/t'], 'columns': ['on:chip:10em']}},
        {'list': {'id': 'unit', 'run': ['./tool/t'], 'columns': ['path:text:40']}},
        {'list': {'id': 'twice', 'run': ['./tool/t'], 'columns': ['path:start:start']}},
      ]);
      final list = c.page('p')!.block('items') as ListBlock;
      expect([for (final col in list.columns) col.toJson()], [
        {'key': 'path', 'format': 'text', 'width': '40em', 'clip': 'start'},
        {'key': 'title', 'format': 'text', 'width': '18ch'},
        {'key': 'file', 'format': 'text', 'clip': 'start'},
        {'key': 'note', 'format': 'text', 'width': '320px'},
        {'key': 'name', 'format': 'text'},
        {'key': 'on', 'format': 'chip'},
      ]);
      expect(c.problems, [
        for (final (id, spec) in [('chip', 'on:chip:10em'), ('unit', 'path:text:40'), ('twice', 'path:start:start')])
          startsWith('p.$id.columns: "$spec" should be name or name:text|chip|count'),
      ]);
    });

    test('sort: a list starts in the order of a column, ascending unless :desc', () {
      final c = parse([
        {'list': {'id': 'items', 'run': ['./tool/t'], 'sort': 'minVer:desc'}},
        {'list': {'id': 'asc', 'run': ['./tool/t'], 'sort': 'name'}},
        {'list': {'id': 'bad', 'run': ['./tool/t'], 'sort': 'name:down'}},
        {'list': {'id': 'list', 'run': ['./tool/t'], 'sort': ['name']}},
      ]);
      final page = c.page('p')!;
      expect((page.block('items') as ListBlock).toJson()['sort'], {'key': 'minVer', 'dir': 'desc'});
      expect((page.block('asc') as ListBlock).toJson()['sort'], {'key': 'name', 'dir': 'asc'});
      expect(c.problems, [
        'p.bad.sort: expected <col> or <col>:asc|desc (got "name:down")',
        'p.list.sort: expected <col> or <col>:asc|desc (got "[name]")',
      ]);
    });

    test('tree: one column, several, or a map with how many levels start open', () {
      final c = parse([
        {'list': {'id': 'one', 'run': ['./tool/t'], 'tree': 'path'}},
        {'list': {'id': 'two', 'run': ['./tool/t'], 'tree': ['env', 'path']}},
        {'list': {'id': 'map', 'run': ['./tool/t'], 'tree': {'columns': ['env', 'path'], 'open': 1}}},
        {'list': {'id': 'empty', 'run': ['./tool/t'], 'tree': <String>[]}},
        {'list': {'id': 'depth', 'run': ['./tool/t'], 'tree': {'columns': 'path', 'open': -1}}},
        {'list': {'id': 'extra', 'run': ['./tool/t'], 'tree': {'columns': 'path', 'closed': true}}},
      ]);
      final page = c.page('p')!;
      expect((page.block('one') as ListBlock).toJson()['tree'], {'columns': ['path'], 'open': 0});
      expect((page.block('two') as ListBlock).toJson()['tree'], {'columns': ['env', 'path'], 'open': 0});
      expect((page.block('map') as ListBlock).toJson()['tree'], {'columns': ['env', 'path'], 'open': 1});
      expect(c.problems, [
        for (final id in ['empty', 'depth', 'extra'])
          'p.$id.tree: expected a column, a list of columns, or {columns: [env, path], open: <depth>}',
      ]);
    });

    test('segments as a map: optional, and the one to hide for the picked row', () {
      final c = parse([
        {'list': {'id': 'files', 'run': ['./tool/t']}},
        {
          'diff': {
            'id': 'content',
            'run': ['./tool/t', 'diff', '{{selected.path}}', '--against', '{{seg}}'],
            'segments': {'values': ['prod', 'stage'], 'optional': true, 'hide': '{{selected.env}}'},
          },
        },
        {'diff': {'id': 'plain', 'run': ['./tool/t', '{{seg}}'], 'segments': {'values': ['a']}}},
        {'diff': {'id': 'empty', 'run': ['./tool/t'], 'segments': {'values': <String>[]}}},
        {'diff': {'id': 'extra', 'run': ['./tool/t'], 'segments': {'values': ['a'], 'default': 'a'}}},
        {'diff': {'id': 'flag', 'run': ['./tool/t'], 'segments': {'values': ['a'], 'optional': 'yes'}}},
        {'diff': {'id': 'row', 'run': ['./tool/t'], 'segments': {'values': ['a'], 'hide': '{{row.env}}'}}},
      ]);
      final page = c.page('p')!;
      final json = (page.block('content') as DiffBlock).toJson();
      expect(json['segments'], ['prod', 'stage']);
      expect(json['segmentsOptional'], isTrue);
      expect(json['segmentsHide'], '{{selected.env}}');
      expect(json['uses'], containsAll(['selected.path', 'seg', 'selected.env'])); // the pick decides what shows
      expect((page.block('plain') as DiffBlock).toJson().keys, isNot(contains('segmentsOptional')));
      expect(c.problems, [
        for (final id in ['empty', 'extra', 'flag'])
          'p.$id.segments: expected a list of names, or {values: [a, b], optional: true, hide: "{{selected.<col>}}"}',
        "p.row.segments.hide: {{row.*}} only works in a list's rowActions",
      ]);
    });

    test('fill puts each value inside its own argument', () {
      const cmd = PageCommand.argv(['./tool/t', 'diff', '--name={{selected.name}}', '{{seg}}']);
      final filled = cmd.fill({'selected.name': r'a b; rm -rf ~ $(id)', 'seg': 'prod'});
      expect(filled.argv, ['./tool/t', 'diff', r'--name=a b; rm -rf ~ $(id)', 'prod']);
      expect(filled.display, r"./tool/t diff '--name=a b; rm -rf ~ $(id)' prod");
      expect(() => cmd.fill({'seg': 'prod'}),
          throwsA(isA<MissingValue>().having((e) => e.kind, 'kind', 'selected')));
    });

    test('placeholders are refused where they could run as code or have no value', () {
      final c = parse(
        [
          {'list': {'id': 'items', 'run': ['./tool/t', 'list', '{{selected.name}}']}},
          {'list': {'id': 'other', 'run': ['./tool/t', '{{row.name}}']}},
          {'diff': {'id': 'd1', 'run': ['./tool/t', 'diff', '{{seg}}']}},
          {'diff': {'id': 'd2', 'run': ['./tool/t', '{{selected}}']}},
          {'diff': {'id': 'd3', 'run': ['./tool/t', '{{env.HOME}}']}},
          {'diff': {'id': 'd4', 'run': ['./tool/t', '{{seg.x}}'], 'segments': ['a']}},
          {'list': {'id': 'bad', 'run': ['./tool/t'], 'columns': ['name:bold']}},
          {'list': {'id': 'w', 'run': ['./tool/t'], 'watch': ['../outside/**']}},
        ],
        toolbar: [
          {'action': {'id': 'sh', 'run': './tool/t publish {{selected.name}}'}},
          {'action': {'id': 'ok', 'run': ['./tool/t', 'publish', '{{selected.name}}']}},
          {'action': {'id': 'exe', 'run': ['{{selected.name}}', 'publish']}},
          {'action': {'id': 'exe2', 'run': ['./tool/{{selected.name}}']}},
        ],
      );
      final all = c.problems.join('\n');
      for (final expected in [
        'p.sh.run: placeholders work only in the [program, arg, …] form',
        "p.exe.run: the program can't contain a placeholder",
        "p.exe2.run: the program can't contain a placeholder",
        "p.items.run: {{selected.*}} can't be used by the list that makes the selection",
        "p.other.run: {{row.*}} only works in a list's rowActions",
        'p.d1.run: {{seg}} only works in a diff block with segments',
        'p.d2.run: {{selected}} needs a column',
        'p.d3.run: unknown placeholder {{env.HOME}}',
        'p.d4.run: {{seg}} takes no column',
        'p.bad.columns: "name:bold" should be name or name:text|chip|count',
        'p.w.watch: expected project-relative globs',
      ]) {
        expect(all, contains(expected));
      }
      expect(c.page('p')!.toolbar.map((i) => i.id), ['ok']);
      expect(c.page('p')!.blocks, isEmpty);
    });

    test('an html block: a project .html file, optional data, declared actions only', () {
      final c = parse(
        [
          {
            'html': {
              'id': 'tree',
              'src': 'tool/pages/tree.html',
              'run': ['./tool/config', 'value', '{{selected.key}}', '--json'],
              'actions': ['sync'],
            },
          },
          {'html': {'id': 'static', 'src': 'tool/pages/help.html'}},
          {'html': {'id': 'abs', 'src': '/etc/passwd.html'}},
          {'html': {'id': 'up', 'src': '../other/x.html'}},
          {'html': {'id': 'notes', 'src': 'notes.md'}},
          {'html': {'id': 'ghost', 'src': 'x.html', 'actions': ['deploy']}},
        ],
        toolbar: [
          {'action': {'id': 'sync', 'run': ['./tool/config', 'sync']}},
        ],
      );
      final page = c.page('p')!;
      final tree = page.block('tree') as HtmlBlock;
      expect(tree.area, 'main');
      expect(tree.run!.placeholders, {'selected.key'});
      expect(tree.actions, ['sync']);
      expect((page.block('static') as HtmlBlock).run, isNull);
      expect(page.blocks.map((b) => b.id), ['tree', 'static']);
      final all = c.problems.join('\n');
      expect(all, contains('p.abs.src: expected a project-relative .html file'));
      expect(all, contains('p.up.src: expected a project-relative .html file'));
      expect(all, contains('p.notes.src: expected a project-relative .html file'));
      expect(all, contains('p.ghost.actions: no toolbar action "deploy"'));
      expect(c.watching('tool/pages/tree.html'), {'p': ['tree']}); // its own file reloads it
    });

    test("an html block's inputs and own actions; toolbar ids stay strings", () {
      final c = parse(
        [
          {
            'html': {
              'id': 'deploy',
              'title': 'Deploy',
              'src': 'tool/emu/deploy.html',
              'inputs': ['env', 'message'],
              'actions': [
                'sync',
                {'action': {'id': 'plan', 'run': ['./tool/tpl.sh', 'plan', '{{input.env}}', '{{selected.name}}']}},
                {
                  'action': {
                    'id': 'push',
                    'run': ['./tool/tpl.sh', 'push', '{{input.env}}', '--message', '{{input.message}}'],
                    'confirm': true,
                  },
                },
                {'action': {'id': 'typo', 'run': ['./tool/tpl.sh', '{{input.nope}}']}},
                {'action': {'id': 'plan', 'run': ['./tool/tpl.sh', 'again']}},
                {'list': {'id': 'x'}},
              ],
            },
          },
          {'html': {'id': 'clash', 'src': 'x.html', 'actions': [{'action': {'id': 'sync', 'run': ['true']}}]}},
          {'html': {'id': 'badin', 'src': 'x.html', 'inputs': ['ok', 'not ok']}},
          {'html': {'id': 'dupin', 'src': 'x.html', 'inputs': ['a', 'a']}},
          {'html': {'id': 'notlist', 'src': 'x.html', 'actions': 'sync'}},
        ],
        toolbar: [
          {'action': {'id': 'sync', 'run': ['./tool/tpl.sh', 'sync']}},
          {'action': {'id': 'peek', 'run': ['./tool/tpl.sh', '{{input.env}}']}}, // inputs are the block's alone
        ],
      );
      final page = c.page('p')!;
      final deploy = page.block('deploy') as HtmlBlock;
      expect(deploy.inputs, ['env', 'message']);
      expect(deploy.actions, ['sync']);
      expect(deploy.blockActions.map((a) => a.id), ['plan', 'push']);
      expect(deploy.action('plan')!.placeholders, {'input.env', 'selected.name'});
      expect(deploy.action('push')!.confirm, isNotNull);
      expect(deploy.action('sync'), isNull); // a toolbar id is not the block's own
      final json = deploy.toJson();
      expect(json['inputs'], ['env', 'message']);
      expect(json['actions'], ['sync']);
      expect([for (final a in json['blockActions'] as List) a['id']], ['plan', 'push']);
      expect(page.blocks.map((b) => b.id), ['deploy']);
      expect(page.toolbar.map((i) => i.id), ['sync']);
      final all = c.problems.join('\n');
      for (final expected in [
        "p.peek.run: {{input.*}} only works in a form's actions or an html block's own actions",
        "p.deploy.typo.run: no \"nope\" in this block's inputs:",
        'p.deploy.actions[4]: expected a toolbar action id, or `- action: {id: …, run: […]}` with an id unique in this block',
        'p.deploy.actions[5]: expected a toolbar action id',
        'p.clash.actions: "sync" is also a toolbar id',
        'p.badin.inputs: expected a list of distinct names',
        'p.dupin.inputs: expected a list of distinct names',
        'p.notlist.actions: expected a list of toolbar action ids',
      ]) {
        expect(all, contains(expected));
      }
    });

    test('a form: fields, and actions that read them; openUrl instead of run', () {
      final c = parse(
        [
          {
            'form': {
              'id': 'link',
              'fields': [
                {'name': 'url', 'label': 'URL', 'placeholder': 'myapp://home', 'default': 'myapp://home'},
                {'name': 'note'},
              ],
              'actions': [
                {'action': {'id': 'open', 'openUrl': '{{input.url}}', 'confirm': true}},
                {'action': {'id': 'log', 'run': ['./tool/t', '{{input.note}}', '{{selected.name}}']}},
                {'action': {'id': 'typo', 'run': ['./tool/t', '{{input.nope}}']}},
                {'action': {'id': 'both', 'run': ['x'], 'openUrl': 'myapp://x'}},
                {'action': {'id': 'then', 'openUrl': 'myapp://x', 'then': 'reload'}},
                {'action': {'id': 'nourl', 'openUrl': 3}},
              ],
            },
          },
          {'form': {'id': 'noactions', 'fields': [{'name': 'a'}]}},
          {'form': {'id': 'dup', 'fields': [{'name': 'a'}, {'name': 'a'}], 'actions': [{'action': {'id': 'a', 'run': ['x']}}]}},
          {'list': {'id': 'items', 'run': ['x'], 'rowActions': [{'action': {'id': 'go', 'openUrl': 'myapp://item/{{row.id}}'}}]}},
        ],
        toolbar: [
          {'action': {'id': 'home', 'openUrl': 'myapp://home'}},
          {'action': {'id': 'bad', 'run': ['./tool/t', '{{input.url}}']}},
        ],
      );
      final page = c.page('p')!;
      final form = page.block('link') as FormBlock;
      expect(form.area, 'main');
      expect([for (final f in form.fields) f.name], ['url', 'note']);
      expect(form.fields.first.initial, 'myapp://home');
      expect(form.actions.map((a) => a.id), ['open', 'log']);
      final open = form.action('open')!;
      expect(open.run, isNull);
      expect(open.openUrl!.argv, ['{{input.url}}']);
      expect(open.display, 'open-url {{input.url}}');
      expect(open.toJson()['openUrl'], '{{input.url}}');
      expect((page.item('home') as PageAction).display, 'open-url myapp://home');
      expect((page.block('items') as ListBlock).rowAction('go')!.placeholders, {'row.id'});
      expect(page.blocks.map((b) => b.id), ['link', 'items']);
      final all = c.problems.join('\n');
      for (final expected in [
        'p.link.typo.run: no field "nope" in this form',
        'p.link.both: give run or openUrl, not both',
        "p.link.then: then doesn't apply to openUrl",
        'p.link.nourl.openUrl: expected a URL',
        'p.noactions.actions: a form needs at least one action',
        'p.dup.fields[1]: needs a name of letters, digits, - or _, unique in this form',
        "p.bad.run: {{input.*}} only works in a form's actions or an html block's own actions",
      ]) {
        expect(all, contains(expected));
      }
    });

    test('a form without fields is a button panel; panel: says so, note: explains it', () {
      final run = {'action': {'id': 'a', 'run': ['x']}};
      final c = parse([
        {'form': {'id': 'nofields', 'actions': [run]}},
        {'form': {'id': 'empty', 'fields': [], 'note': 'no input', 'actions': [run]}},
        {
          'panel': {
            'id': 'deploy',
            'title': 'Deploy',
            'area': 'left',
            'note': 'stage and dev push straight to the remote branch.',
            'actions': [
              {'action': {'id': 'stage', 'run': ['./tool/deploy', 'stage', '{{selected.name}}'], 'confirm': true}},
              {'action': {'id': 'typo', 'run': ['./tool/deploy', '{{input.msg}}']}},
            ],
          },
        },
        {'panel': {'id': 'typed', 'actions': [{'action': {'id': 'a', 'run': ['x', '{{input.msg}}']}}]}},
        {'panel': {'id': 'withfields', 'fields': [{'name': 'msg'}], 'actions': [run]}},
        {'panel': {'id': 'noactions'}},
        {'form': {'id': 'badnote', 'note': ['x'], 'actions': [run]}},
        {'form': {'id': 'badfields', 'fields': 'msg', 'actions': [run]}},
      ]);
      final page = c.page('p')!;
      expect(page.blocks.map((b) => b.id), ['nofields', 'empty', 'deploy']);
      final deploy = page.block('deploy') as FormBlock;
      expect(deploy.area, 'left');
      expect(deploy.fields, isEmpty);
      expect(deploy.actions.map((a) => a.id), ['stage']);
      expect(deploy.toJson(), allOf(
        containsPair('kind', 'form'),
        containsPair('note', 'stage and dev push straight to the remote branch.'),
        containsPair('fields', isEmpty),
      ));
      expect((page.block('nofields') as FormBlock).toJson().containsKey('note'), isFalse);
      expect((page.block('empty') as FormBlock).note, 'no input');
      expect((page.block('nofields') as FormBlock).area, 'main');
      final all = c.problems.join('\n');
      for (final expected in [
        'p.deploy.typo.run: no field "msg" — this form has no fields',
        'p.typed.a.run: no field "msg" — this form has no fields',
        'p.withfields.fields: a panel has no fields — make it a form to add some',
        'p.noactions.actions: a panel needs at least one action',
        'p.badnote.note: expected a line of text',
        'p.badfields.fields: expected a list',
      ]) {
        expect(all, contains(expected));
      }
    });

    test('watch globs match project-relative paths', () {
      bool m(String glob, String path) => globToRegExp(glob).hasMatch(path);
      expect(m('templates/**', 'templates/home.json'), isTrue);
      expect(m('templates/**', 'templates/a/b.json'), isTrue);
      expect(m('templates/**', 'lib/main.dart'), isFalse);
      expect(m('**/*.json', 'a.json'), isTrue);
      expect(m('**/*.json', 'x/y/a.json'), isTrue);
      expect(m('templates/*.json', 'templates/a/b.json'), isFalse);
      expect(m('./.local/**', '.local/x'), isTrue);
      expect(m('config?.yaml', 'config1.yaml'), isTrue);
      expect(m('a.b', 'aXb'), isFalse);

      final c = parse([
        {'list': {'id': 'items', 'run': ['./tool/t'], 'watch': ['templates/**']}},
        {'diff': {'id': 'changes', 'run': ['./tool/t'], 'watch': ['templates/*.json', 'base/**']}},
      ]);
      expect(c.watching('templates/home.json'), {'p': ['items', 'changes']});
      expect(c.watching('base/x'), {'p': ['changes']});
      expect(c.watching('lib/main.dart'), isEmpty);
    });
  });

  test('auto: a toolbar action may run on file changes; one that needs a person or values may not', () {
    final c = parsePages([
      {
        'id': 'p',
        'toolbar': [
          {
            'action': {
              'id': 'sync',
              'run': ['./tool/t', 'sync'],
              'then': 'reload',
              'auto': {'watch': ['tpl/**'], 'debounce': 250, 'on': true},
            },
          },
          {'action': {'id': 'plain', 'run': ['./tool/t'], 'auto': {'watch': 'tpl/*.txt'}}},
          {'action': {'id': 'ask', 'run': ['./tool/t'], 'confirm': true, 'auto': {'watch': ['tpl/**']}}},
          {'action': {'id': 'pick', 'run': ['./tool/t', '{{selected.name}}'], 'auto': {'watch': ['tpl/**']}}},
          {'action': {'id': 'link', 'openUrl': 'myapp://home', 'auto': {'watch': ['tpl/**']}}},
          {'action': {'id': 'nowatch', 'run': ['./tool/t'], 'auto': {'debounce': 100}}},
          {'action': {'id': 'soon', 'run': ['./tool/t'], 'auto': {'watch': ['tpl/**'], 'debounce': 'soon'}}},
          {'action': {'id': 'out', 'run': ['./tool/t'], 'auto': {'watch': ['../x/**']}}},
          {'action': {'id': 'extra', 'run': ['./tool/t'], 'auto': {'watch': ['tpl/**'], 'every': 5}}},
        ],
        'blocks': [
          {
            'list': {
              'id': 'items',
              'run': ['./tool/t'],
              'rowActions': [
                {'action': {'id': 'row', 'run': ['./tool/t'], 'auto': {'watch': ['tpl/**']}}},
              ],
            },
          },
        ],
      },
    ]);
    final page = c.page('p')!;
    expect((page.item('sync') as PageAction).toJson()['auto'], {'watch': ['tpl/**'], 'debounce': 250, 'on': true});
    expect((page.item('plain') as PageAction).auto!.toJson(), {'watch': ['tpl/*.txt'], 'debounce': 400, 'on': false});
    expect((page.item('plain') as PageAction).auto!.matches('tpl/home.txt'), isTrue);
    expect(page.toolbar.map((i) => i.id), ['sync', 'plain']);
    expect(c.problems, [
      "p.ask.auto: an action that asks first (confirm) can't run on its own",
      'p.pick.auto: an action that runs on its own has no pick, row or input to fill {{selected.name}} with',
      'p.link.auto: works with run:, not openUrl',
      'p.nowatch.auto.watch: say which project files start it, like "templates/**"',
      'p.soon.auto.debounce: expected milliseconds (got "soon")',
      'p.out.auto.watch: expected project-relative globs like "templates/**"',
      'p.extra.auto: expected {watch: ["templates/**"], debounce: <ms>, on: true|false}',
      'p.items.row.auto: only toolbar actions run on their own',
    ]);
  });

  test('shellQuote quotes only what sh would split or expand', () {
    expect(shellQuote('./tool/x'), './tool/x');
    expect(shellQuote('--target=../cdn'), '--target=../cdn');
    expect(shellQuote('two words'), "'two words'");
    expect(shellQuote(r"it's $HOME"), r"'it'\''s $HOME'");
    expect(const PageCommand.argv(['echo', 'a b']).display, "echo 'a b'");
  });

  group('parseToggleState', () {
    test('reads {"on": bool, "detail"?}', () {
      expect(parseToggleState('{"on": true, "detail": 2}'), {'on': true, 'detail': '2'});
      expect(parseToggleState('{"on":false}\n'), {'on': false});
    });

    test('takes the last line when the tool logs first', () {
      expect(parseToggleState('syncing…\nok\n{"on": true}\n'), {'on': true});
    });

    test('anything else is null', () {
      expect(parseToggleState(''), isNull);
      expect(parseToggleState('on'), isNull);
      expect(parseToggleState('{"on": "yes"}'), isNull);
      expect(parseToggleState('[true]'), isNull);
    });
  });

  group('confirm', () {
    PagesConfig parse(Object? confirm, {List<Map<String, dynamic>> blocks = const []}) => parsePages([
          {
            'id': 'p',
            'toolbar': [
              {'action': {'id': 'a', 'label': 'stage 배포', 'run': ['./tool/t', 'deploy'], 'confirm': confirm}},
            ],
            'blocks': blocks,
          },
        ]);
    ConfirmSpec? spec(PagesConfig c) => (c.page('p')!.item('a') as PageAction?)?.confirm;

    test('true, false, a message, or a map', () {
      expect(spec(parse(false)), isNull);
      expect(spec(parse(null)), isNull);
      final plain = spec(parse(true))!;
      expect([plain.title, plain.message, plain.button, plain.preview], everyElement(isNull));
      expect(plain.danger, isFalse);
      expect(spec(parse('stage 에 push 합니다'))!.message, 'stage 에 push 합니다');

      final c = parse({
        'title': '배포 저장소 stage 브랜치에 push 할까요?',
        'message': '{{selected.name}} 을 stage 에 push 합니다.',
        'danger': true,
        'button': 'push',
        'preview': ['./tool/t', 'deploy', '--dry-run', '{{selected.name}}'],
        'allowOnPreviewError': true,
      }, blocks: [
        {'list': {'id': 'items', 'run': ['./tool/t', 'list']}},
      ]);
      expect(c.problems, isEmpty);
      final s = spec(c)!;
      expect(s.title, '배포 저장소 stage 브랜치에 push 할까요?');
      expect(s.danger, isTrue);
      expect(s.button, 'push');
      expect(s.preview!.argv, ['./tool/t', 'deploy', '--dry-run', '{{selected.name}}']);
      expect(s.allowOnPreviewError, isTrue);
      final action = c.page('p')!.item('a') as PageAction;
      // The message and the preview read the selection too, so the button waits for a pick.
      expect(action.placeholders, {'selected.name'});
      expect(action.toJson(), containsPair('danger', true));
      expect(action.toJson(), containsPair('preview', "./tool/t deploy --dry-run '{{selected.name}}'"));
    });

    test('a wrong key, type or placeholder is a problem and hides that action', () {
      for (final (confirm, problem) in [
        ({'titel': 'x'}, 'p.a.confirm: unknown "titel"'),
        ({'danger': 'yes'}, 'p.a.confirm.danger: expected true or false'),
        ({'message': ['x']}, 'p.a.confirm.message: expected text'),
        ({'message': '{{row.id}}'}, "p.a.confirm.message: {{row.*}} only works in a list's rowActions"),
        ({'title': '{{nope}}'}, 'p.a.confirm.title: unknown placeholder {{nope}}'),
        ({'button': '{{selected.x}}'}, 'p.a.confirm.button: placeholders work only in title and message'),
        ({'preview': 'sh {{selected.x}}'}, 'p.a.confirm.preview: placeholders work only in the [program, arg, …] form'),
        ({'preview': 3}, 'p.a.confirm.preview: expected [program, arg, …] or a shell string'),
        (3, 'p.a.confirm: expected true, a message, or a map'),
      ]) {
        final c = parse(confirm);
        expect(c.problems, [startsWith(problem)], reason: '$confirm');
        expect(c.page('p')!.toolbar, isEmpty, reason: '$confirm');
      }
    });
  });

  test('looksLikePatch', () {
    expect(looksLikePatch('diff --git a/x b/x\n'), isTrue);
    expect(looksLikePatch('--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n'), isTrue);
    expect(looksLikePatch('3 templates\n@@ -1,2 +1,2 @@\n'), isTrue);
    expect(looksLikePatch('--- done ---\nok'), isFalse);
    expect(looksLikePatch('[{"name": "a"}]'), isFalse);
  });

  test('the html block example in docs/ parses without problems', () {
    final config = loadProjectConfig('docs/examples/html-block', home: 'docs/examples/html-block');
    final c = parsePages(config.pages);
    expect(c.problems, isEmpty);
    final view = c.page('deploy')!.block('view') as HtmlBlock;
    expect(view.inputs, ['env', 'message']);
    expect(view.actions, ['sync']);
    expect(view.blockActions.map((a) => a.id), ['plan', 'deploy', 'rollback']);
    final deploy = view.action('deploy')!.confirm!;
    expect(deploy.danger, isTrue);
    expect(deploy.placeholders, {'input.env'}); // the dialog names the branch the view chose
    expect(view.action('rollback')!.confirm, isNotNull);
    // emu.select picks rows of the page's list.
    expect(c.page('deploy')!.selectionList!.id, 'templates');
  });
}
