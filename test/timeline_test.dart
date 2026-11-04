import 'dart:convert';
import 'dart:io';

import 'package:emu/src/cli.dart' show formatTimelineLine;
import 'package:emu/src/log_store.dart';
import 'package:emu/src/models.dart';
import 'package:test/test.dart';

void main() {
  final t = DateTime(2026, 11, 4, 9, 5, 7, 42);

  group('LogEntry JSON', () {
    test('a plain line without a screen is byte-for-byte the old JSON', () {
      final e = LogEntry(seq: 3, timestamp: t, level: LogLevel.info, text: 'hello');
      expect(jsonEncode(e.toJson()),
          '{"seq":3,"ts":"2026-11-04T09:05:07.042","level":"info","source":"app","text":"hello"}');
    });

    test('kind, route, routeName and data round-trip', () {
      final e = LogEntry(
        seq: 9,
        timestamp: t,
        level: LogLevel.system,
        text: '[action] tap --text "Pay"',
        source: 'action',
        kind: LogKind.action,
        route: '/cart · sheet:coupon',
        routeName: 'cart',
        data: {'cmd': 'tap', 'x': 10, 'y': 20},
      );
      final back = LogEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      // A list, not a record: a record compares its fields with ==, and two
      // maps with the same entries aren't ==.
      expect(
        [back.seq, back.kind, back.route, back.routeName, back.data, back.source, back.level],
        [9, 'action', '/cart · sheet:coupon', 'cart', {'cmd': 'tap', 'x': 10, 'y': 20}, 'action', LogLevel.system],
      );
      expect(back.kindName, 'action');
    });

    test('an old line has no kind or screen; unknown keys are ignored', () {
      final e = LogEntry.fromJson({
        'seq': 1,
        'ts': '2026-11-04T09:05:07.042',
        'level': 'warn',
        'text': 'old',
        'later': {'field': true},
      });
      expect((e.kind, e.kindName, e.route, e.routeName, e.data, e.source), (null, 'log', null, null, null, 'app'));
    });
  });

  group('LogKind.parse', () {
    test('names, all, and empty', () {
      expect(LogKind.parse(null), isNull);
      expect(LogKind.parse(' '), isNull);
      expect(LogKind.parse('all'), LogKind.all);
      expect(LogKind.parse('route, action'), {'route', 'action'});
      expect(LogKind.parse('log,request,'), LogKind.legacy);
    });

    test('an unknown name is an error that lists the names', () {
      expect(
        () => LogKind.parse('route,screens'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains('screens'), contains('action')))),
      );
    });
  });

  group('LogStore kinds and screens', () {
    late LogStore store;
    setUp(() {
      store = LogStore();
      store.add('app line');
      store.add('[mock] GET /a → 200', source: 'mock', kind: LogKind.request);
      store.add('[route] /a', level: LogLevel.system, source: 'route', kind: LogKind.route);
      store.add('[action] tap --text "Login"', level: LogLevel.system, source: 'action', kind: LogKind.action);
      store.add('another app line');
    });

    test('every kind by default; legacy keeps plain lines and requests', () {
      expect(store.query().length, 5);
      expect([for (final e in store.query(kinds: LogKind.legacy)) e.text],
          ['app line', '[mock] GET /a → 200', 'another app line']);
      expect([for (final e in store.query(kinds: {LogKind.route, LogKind.action})) e.kindName], ['route', 'action']);
    });

    test('the filter applies before the limit', () {
      // The last two entries overall are an action and a plain line; the last
      // two kept ones are the request and that plain line.
      expect([for (final e in store.query(kinds: LogKind.legacy, limit: 2)) e.text],
          ['[mock] GET /a → 200', 'another app line']);
    });

    test('grep sees the text of every kind it is given', () {
      expect(store.query(grep: 'login', kinds: LogKind.legacy), isEmpty);
      expect(store.query(grep: 'login').single.kind, LogKind.action);
    });

    test('add stamps the current screen; earlier entries keep theirs', () {
      store.currentRoute = '/user/42';
      store.currentRouteName = 'user';
      final a = store.add('on the user screen');
      store.currentRoute = null;
      store.currentRouteName = null;
      final b = store.add('screen unknown again');
      expect((a.route, a.routeName), ('/user/42', 'user'));
      expect((b.route, b.routeName), (null, null));
      expect(jsonEncode(b.toJson()), isNot(contains('route')));
    });

    test('routeAt replaces the current screen, null included', () {
      store.currentRoute = '/now';
      store.currentRouteName = 'now';
      final sent = store.add('[mock] x', kind: LogKind.request, routeAt: (route: '/then', routeName: null));
      final unknown = store.add('[mock] y', kind: LogKind.request, routeAt: (route: null, routeName: null));
      expect((sent.route, sent.routeName), ('/then', null));
      expect((unknown.route, unknown.routeName), (null, null));
    });
  });

  group('readLogFile', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('emu_timeline_file'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('filters like the store, skips unreadable lines, keeps the last N', () {
      LogEntry line(int seq, String text, {String? kind}) =>
          LogEntry(seq: seq, timestamp: t, level: LogLevel.info, text: text, kind: kind);
      final file = File('${dir.path}/run.jsonl')
        ..writeAsStringSync([
          line(1, 'one'),
          line(2, '[action] tap 1 2', kind: LogKind.action),
          line(3, 'two'),
          line(4, 'three'),
        ].map((e) => e.toJsonl()).join());
      file.writeAsStringSync('{not json\n\n', mode: FileMode.append);
      expect([for (final e in readLogFile(file, LogFilter(kinds: LogKind.legacy))) e.text], ['one', 'two', 'three']);
      expect([for (final e in readLogFile(file, LogFilter(), limit: 2)) e.text], ['two', 'three']);
      expect([for (final e in readLogFile(file, LogFilter(sinceSeq: 1, kinds: {LogKind.action}))) e.seq], [2]);
      expect(readLogFile(File('${dir.path}/missing.jsonl'), LogFilter()), isEmpty);
    });
  });

  group('formatTimelineLine', () {
    test('seq, time to the ms, level, then the screen when known', () {
      final e = LogEntry(seq: 57, timestamp: t, level: LogLevel.info, text: '[mock] GET /a → 200', route: '/user/42');
      expect(formatTimelineLine(e), '    57 09:05:07.042 I  [/user/42] [mock] GET /a → 200');
      final plain = LogEntry(seq: 1234567, timestamp: t, level: LogLevel.error, text: 'boom');
      expect(formatTimelineLine(plain), '1234567 09:05:07.042 E  boom');
    });
  });
}
