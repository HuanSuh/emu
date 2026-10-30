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

  test('a stream message that is not JSON is skipped, the rest still parse', skip: _node ? false : 'node is not installed',
      () async {
    final r = await _js('''
const warned = [];
const console = { warn: (m) => warned.push(m) };
${_fn(app, 'streamMessage')}
''', '''
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
    ''');
    expect(r, {
      'ok': {'type': 'status', 'status': {'state': 'running'}},
      'bad': null,
      'long': null,
      'after': {'type': 'pages'},
      'warned': 2,
      'short': true,
      'says': true,
    });
  });
}
