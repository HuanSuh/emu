// window.emu (the html block helper) and the dashboard's checks of what a
// frame sends, run in node: functions are cut out of web/pages.js by name.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// `function <name>(…) {…}` at the top level of [src]: up to the first `}`
/// alone on a line.
String _fn(String src, String name) {
  final start = src.indexOf('\nfunction $name(');
  if (start < 0) throw StateError('no function $name in web/pages.js');
  final end = src.indexOf('\n}\n', start);
  return src.substring(start + 1, end + 2);
}

final _node = () {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Runs [body] (an async JS function body) after [prelude]; returns what it returns, as JSON.
Future<Object?> _js(String prelude, String body) async {
  final dir = Directory.systemTemp.createTempSync('emu_web_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/t.js')
    ..writeAsStringSync('$prelude\n(async () => { $body })().then('
        '(v) => process.stdout.write(JSON.stringify(v ?? null)), (e) => { console.error(e); process.exit(1); });');
  final r = await Process.run('node', [file.path]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return jsonDecode(r.stdout as String);
}

void main() {
  final src = File('web/pages.js').readAsStringSync();

  group('window.emu', skip: _node ? false : 'node is not installed', () {
    // A frame's world: parent.postMessage records what it sends; answer() replies as the dashboard.
    final prelude = '''
const sent = [];
const parent = { postMessage: (m) => sent.push(m) };
let onMessage = null;
const addEventListener = (type, fn) => { if (type === 'message') onMessage = fn; };
const window = {};
${_fn(src, 'frameHelper')}
frameHelper();
const emu = window.emu;
const answer = (body) => onMessage({ source: parent, data: { type: 'emu:result', reqId: sent.at(-1).reqId, ...body } });
''';

    test('choose sends its options and resolves to the value, or null', () async {
      final r = await _js(prelude, '''
        const p = emu.choose({ title: 'env', options: [{ value: 'stage', label: 'stage' }, 'prod'], multiple: false });
        const msg = sent.at(-1);
        answer({ value: 'stage' });
        const picked = await p;
        const q = emu.choose({ title: 'env', options: ['a'] });
        answer({ value: null, error: 'cancelled' });
        return { msg, picked, cancelled: await q };
      ''');
      expect(r, {
        'msg': {
          'title': 'env',
          'options': [
            {'value': 'stage', 'label': 'stage'},
            'prod',
          ],
          'multiple': false,
          'type': 'emu:choose',
          'reqId': 1,
        },
        'picked': 'stage',
        'cancelled': null,
      });
    });

    test('select and refresh ask, and resolve to the answer', () async {
      final r = await _js(prelude, '''
        const s = emu.select('home/banner.json');
        const sel = sent.at(-1);
        answer({ ok: false, error: 'no row' });
        const own = emu.refresh(); const r1 = sent.at(-1); answer({ ok: true });
        const other = emu.refresh('templates'); const r2 = sent.at(-1); answer({ ok: true });
        return { sel, selected: await s, r1, r2, refreshed: [await own, await other] };
      ''');
      expect(r, {
        'sel': {'key': 'home/banner.json', 'type': 'emu:select', 'reqId': 1},
        'selected': {'ok': false, 'error': 'no row'},
        'r1': {'type': 'emu:refresh', 'reqId': 2},
        'r2': {'block': 'templates', 'type': 'emu:refresh', 'reqId': 3},
        'refreshed': [
          {'ok': true},
          {'ok': true},
        ],
      });
    });

    test("run carries the view's words for its dialog; never confirmed", () async {
      final r = await _js(prelude, '''
        emu.run('deploy', { input: { env: 'stage' }, confirm: { title: 'Push?', detail: 'a\\nb' } });
        emu.run('rollback', { confirm: 'Sure?', confirmed: true });
        emu.run('sync');
        return sent;
      ''');
      expect(r, [
        {
          'id': 'deploy',
          'input': {'env': 'stage'},
          'confirm': {'title': 'Push?', 'detail': 'a\nb'},
          'type': 'emu:run',
          'reqId': 1,
        },
        {
          'id': 'rollback',
          'input': <String, Object?>{},
          'confirm': {'title': 'Sure?'},
          'type': 'emu:run',
          'reqId': 2,
        },
        {'id': 'sync', 'input': <String, Object?>{}, 'type': 'emu:run', 'reqId': 3},
      ]);
    });
  });

  group("the dashboard's reading of a frame's request", skip: _node ? false : 'node is not installed', () {
    final prelude = [
      'const frameRefreshed = {}; const FRAME_REFRESH_MS = 1000; const blockKey = (page, block) => `\${page.id}.\${block.id}`;',
      for (final f in ['clip', 'frameAsk', 'frameOptions', 'withAsk', 'pruneFrameRefreshed', 'runAskOpts', 'runAskValue']) _fn(src, f),
    ].join('\n');

    test('choose options: values once, strings/numbers/booleans only, labels as text', () async {
      final r = await _js(prelude, '''
        return frameOptions(['a', { value: 'a', label: 'again' }, { value: 2, label: 'two' }, true,
          { label: 'no value' }, null, { value: { x: 1 } }, { value: 'b', label: '<b>bold</b>' }, { value: '2' }]);
      ''');
      expect(r, [
        {'value': 'a', 'label': 'a'},
        {'value': 2, 'label': 'two'},
        {'value': true, 'label': 'true'},
        {'value': 'b', 'label': '<b>bold</b>'},
        {'value': '2', 'label': '2'},
      ]);
      expect(await _js(prelude, 'return [frameOptions(undefined), frameOptions("a"), frameOptions(Array(300).fill(0).map((_, i) => i)).length];'), [
        <Object?>[],
        <Object?>[],
        200,
      ]);
    });

    test("a merged dialog: the view's words lead, emu.yaml's follow with the command", () async {
      final r = await _js(prelude, '''
        const run = { title: 'Push to stage', message: 'right away', command: './tpl.sh deploy stage', preview: null, button: 'push', danger: false };
        return withAsk(run, frameAsk({ title: 'Push 2 templates?', detail: 'a\\nb', danger: true, button: 'yes!', html: '<i>' }));
      ''');
      expect(r, {
        'title': 'Push 2 templates?',
        'message': '',
        'detail': 'a\nb',
        'action': {'title': 'Push to stage', 'message': 'right away', 'detail': ''},
        'command': './tpl.sh deploy stage',
        'preview': null,
        'button': 'push', // emu.yaml's, not the view's
        'danger': true,
      });
    });

    test("emu.yaml's words stay whole under action: the view's detail can't take their place", () async {
      final r = await _js(prelude, '''
        const run = { title: 'Push to stage', message: 'right away', detail: 'from emu.yaml', command: 'x', button: 'push', danger: true };
        const merged = withAsk(run, frameAsk({ title: 'Push?', detail: 'from the view', danger: false }));
        const bare = withAsk(run, frameAsk({ title: 'Push?' }));
        return { merged: [merged.detail, merged.action, merged.danger], bare: [bare.detail, bare.action.detail] };
      ''');
      expect(r, {
        'merged': [
          'from the view',
          {'title': 'Push to stage', 'message': 'right away', 'detail': 'from emu.yaml'},
          true, // a view can't make a danger run look safe
        ],
        'bare': ['', 'from emu.yaml'],
      });
    });

    test("a running command's question: text cut to size, headed with its page and action", () async {
      final r = await _js(prelude, '''
        const confirm = runAskOpts({ page: 'tools', item: 'push', from: { page: 'Tools', action: 'Push' },
          ask: { kind: 'confirm', title: 'x'.repeat(300), detail: 'a\\nb', danger: true, button: '<b>go</b>' } });
        const prompt = runAskOpts({ page: 'tools', item: 'push', ask: { kind: 'prompt', fields: [{ name: 'm', default: 'hi' }, { label: 'no name' }] } });
        const choose = runAskOpts({ page: 'tools', item: 'push', ask: { kind: 'choose', options: ['stage', 'prod'], multiple: false } });
        return {
          from: confirm.from, title: confirm.title.length, rest: [confirm.detail, confirm.danger, confirm.button],
          fields: prompt.fields, prompt: [runAskValue('prompt', prompt, { ok: true, values: { m: 'yo' } }), runAskValue('prompt', prompt, { ok: false })],
          confirm: [runAskValue('confirm', confirm, { ok: true }), runAskValue('confirm', confirm, { ok: false })],
          choose: [runAskValue('choose', choose, { ok: true, picked: [1] }), runAskValue('choose', choose, { ok: false })],
        };
      ''');
      expect(r, {
        'from': '“Push” on page “Tools” (emu.yaml) asks while it runs:',
        'title': 200,
        'rest': ['a\nb', true, '<b>go</b>'], // as text: openDialog sets textContent
        'fields': [
          {'name': 'm', 'label': 'm', 'default': 'hi'},
        ],
        'prompt': [
          {'m': 'yo'},
          null,
        ],
        'confirm': [true, false],
        'choose': ['prod', null],
      });
    });

    test("refreshes are forgotten when a page is drawn: other pages', gone blocks', old ones", () async {
      final r = await _js(prelude, '''
        const now = Date.now();
        Object.assign(frameRefreshed, { 'a.view': now, 'a.gone': now, 'a.list': now - 5000, 'b.view': now });
        pruneFrameRefreshed({ id: 'a', blocks: [{ id: 'view' }, { id: 'list' }] });
        const kept = Object.keys(frameRefreshed);
        pruneFrameRefreshed(null); // the Debug tab
        return { kept, debug: Object.keys(frameRefreshed) };
      ''');
      expect(r, {
        'kept': ['a.view'],
        'debug': <Object?>[],
      });
    });
  });
}
