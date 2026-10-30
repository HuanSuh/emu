// Dashboard fixes that are easy to get wrong, run in node: functions are cut
// out of web/app.js and web/pages.js by name. One node process per group.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// `function <name>(…) {…}` at the top level of [src]: up to the first `}`
/// alone on a line.
String _fn(String src, String name) {
  final start = src.indexOf('\nfunction $name(');
  if (start < 0) throw StateError('no function $name');
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

/// Runs [body] (a JS function body) after [prelude]; returns what it returns, as JSON.
Future<Object?> _js(String prelude, String body) async {
  final dir = Directory.systemTemp.createTempSync('emu_web_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/t.js')
    ..writeAsStringSync('$prelude\nprocess.stdout.write(JSON.stringify((() => { $body })() ?? null));');
  final r = await Process.run('node', [file.path]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return jsonDecode(r.stdout as String);
}

void main() {
  final app = File('web/app.js').readAsStringSync();

  test(
    'a stream message that is not JSON is skipped, the rest still parse',
    skip: _node ? false : 'node is not installed',
    () async {
      final r = await _js(
        '''
const warned = [];
const console = { warn: (m) => warned.push(m) };
${_fn(app, 'streamMessage')}
''',
        '''
      const long = '{' + 'x'.repeat(1000);
      return {
        ok: streamMessage('{"type":"status","status":{"state":"running"}}'),
        bad: streamMessage('{"type":"log",'),
        long: streamMessage(long),
        after: streamMessage('{"type":"pages"}'),
        warned: warned.length,
        short: warned[1].length < 400,
        says: warned[0].includes('{"type":"log",'),
      };
    ''',
      );
      expect(r, {
        'ok': {
          'type': 'status',
          'status': {'state': 'running'},
        },
        'bad': null,
        'long': null,
        'after': {'type': 'pages'},
        'warned': 2,
        'short': true,
        'says': true,
      });
    },
  );

  final pages = File('web/pages.js').readAsStringSync();

  // Just enough DOM for the focus helpers: tag[attr] selectors (comma lists), closest, contains, focus.
  const dom = '''
const document = { body: null, activeElement: null };
class El {
  constructor(tag, attrs = {}, kids = []) {
    this.tag = tag; this.attrs = attrs; this.kids = []; this.parent = null;
    for (const k of kids) { k.parent = this; this.kids.push(k); }
  }
  getAttribute(a) { return a in this.attrs ? this.attrs[a] : null; }
  hasAttribute(a) { return a in this.attrs; }
  matches(sel) {
    return sel.split(',').some(part => {
      const [, tag, attr] = part.trim().match(/^(\\w*)(?:\\[([\\w-]+)\\])?\$/);
      return (!tag || tag === this.tag) && (!attr || this.hasAttribute(attr));
    });
  }
  closest(sel) { for (let e = this; e; e = e.parent) if (e.matches(sel)) return e; return null; }
  contains(o) { for (let e = o; e; e = e.parent) if (e === this) return true; return false; }
  querySelectorAll(sel) {
    const out = [];
    const walk = (e) => { for (const k of e.kids) { if (k.matches(sel)) out.push(k); walk(k); } };
    walk(this);
    return out;
  }
  focus(opts) { document.activeElement = this; this.focusOpts = opts; }
  set rows(kids) { this.kids = []; for (const k of kids) { k.parent = this; this.kids.push(k); } }
}
const h = (tag, attrs, ...kids) => new El(tag, attrs, kids);
const row = (key, ...extra) => h('tr', { 'data-row': key },
  h('td', {}, h('input', { 'data-check': '' })), h('td', {}, ...extra),
  h('td', {}, h('button', { 'data-action': 'open' }), h('button', { 'data-action': 'del' })));
const head = () => h('tr', {}, h('th', {}, h('input', { 'data-check-all': '' })));
const what = (e) => e && (e.closest('tr[data-row], tr[data-dir]')?.getAttribute('data-row') ?? 'head') + ' '
  + Object.entries(e.attrs).map(([k, v]) => v ? k + '=' + v : k).join(' ');
''';

  test(
    'a redraw keeps keyboard focus on the same control of the same row',
    skip: _node ? false : 'node is not installed',
    () async {
      final r = await _js(
        '''
$dom
${['focusKeyIn', 'refocusIn', 'focusablesIn'].map((n) => _fn(pages, n)).join('\n')}
${RegExp(r'^const (FOCUS_ATTRS|FOCUSABLE) = .*$', multiLine: true).allMatches(pages).map((m) => m[0]).join('\n')}
''',
        '''
      const host = h('div', { 'data-rows': '' });
      const search = h('input', { type: 'text' });
      const block = h('div', {}, search, host);
      // Draws [keys] the way renderListRows does: key focus, swap the rows, put focus back.
      const redraw = (keys) => {
        const key = focusKeyIn(host, document.activeElement);
        host.rows = [head(), ...keys.map(k => row(k, h('a', { href: '#' })))];
        refocusIn(host, key);
        return key;
      };
      const find = (k, sel) => host.querySelectorAll('tr[data-row]').find(t => t.getAttribute('data-row') === k).querySelectorAll(sel)[0];
      const out = {};
      redraw(['a', 'b', 'c']);

      find('b', 'button').parent.kids[1].focus(); // "del" on b
      redraw(['c', 'b', 'a']);
      out.action = what(document.activeElement);
      out.fresh = host.contains(document.activeElement);
      out.preventScroll = document.activeElement.focusOpts?.preventScroll;

      find('a', '[data-check]').focus();
      redraw(['a', 'b']);
      out.check = what(document.activeElement);

      host.querySelectorAll('[data-check-all]')[0].focus();
      redraw(['b', 'a']);
      out.all = what(document.activeElement);

      find('a', 'a').focus(); // no data- attribute: by its place in the row
      redraw(['a']);
      out.link = what(document.activeElement);

      find('a', '[data-action]').focus();
      const gone = document.activeElement;
      redraw(['b']); // its row went away: nothing is focused for it
      out.gone = document.activeElement === gone;

      search.focus(); // typing in the filter, outside the rows
      out.outside = redraw(['a', 'b']);
      out.stays = document.activeElement === search;
      return out;
    ''',
      );
      expect(r, {
        'action': 'b data-action=del',
        'fresh': true,
        'preventScroll': true,
        'check': 'a data-check',
        'all': 'head data-check-all',
        'link': 'a href=#',
        'gone': true,
        'outside': null,
        'stays': true,
      });
    },
  );
}
