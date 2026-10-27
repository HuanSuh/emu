import 'package:emu/src/log_store.dart';
import 'package:emu/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('inferLevel', () {
    test('detects errors', () {
      expect(inferLevel('Unhandled Exception: boom'), LogLevel.error);
      expect(inferLevel('E/flutter: bad'), LogLevel.error);
    });
    test('detects warnings', () {
      expect(inferLevel('Warning: deprecated API'), LogLevel.warn);
    });
    test('stderr without markers is at least warn', () {
      expect(inferLevel('something on stderr', isStderr: true), LogLevel.warn);
    });
    test('plain lines are info', () {
      expect(inferLevel('hello world'), LogLevel.info);
    });
    test('logcat prefix wins over substring sniffing', () {
      // A W/ line that contains "Failed" is a warning, not an error.
      expect(
        inferLevel('W/OpenGLRenderer( 9478): Failed to choose config'),
        LogLevel.warn,
      );
      expect(inferLevel('E/AndroidRuntime( 1): FATAL'), LogLevel.error);
      expect(inferLevel('D/EGL_emulation( 9478): app_time_stats'), LogLevel.debug);
      expect(inferLevel('I/flutter ( 1): hello'), LogLevel.info);
    });
  });

  group('LogStore.query', () {
    late LogStore store;
    setUp(() {
      store = LogStore();
      store.add('starting up');
      store.add('Unhandled Exception: npe');
      store.add('Warning: slow frame');
      store.add('user tapped button');
    });

    test('grep filters case-insensitively', () {
      final r = store.query(grep: 'exception');
      expect(r.length, 1);
      expect(r.first.text, contains('npe'));
    });

    test('level keeps that severity and above', () {
      final r = store.query(level: LogLevel.warn);
      expect(r.map((e) => e.level), everyElement(predicate<LogLevel>(
        (l) => l.rank >= LogLevel.warn.rank)));
      expect(r.length, 2); // the exception + the warning
    });

    test('sinceSeq returns only newer entries', () {
      final all = store.query();
      final cut = all[1].seq;
      final r = store.query(sinceSeq: cut);
      expect(r.every((e) => e.seq > cut), isTrue);
      expect(r.length, 2);
    });

    test('limit keeps the most recent N', () {
      final r = store.query(limit: 2);
      expect(r.length, 2);
      expect(r.last.text, 'user tapped button');
    });
  });

  group('LogStore capacity', () {
    test('keeps exactly the newest capacity entries, seq keeps rising', () {
      final store = LogStore(capacity: 10);
      for (var i = 1; i <= 37; i++) {
        store.add('line $i');
        final all = store.query();
        expect(all.length, i < 10 ? i : 10);
        expect(all.last.seq, i);
        expect(all.first.seq, i < 10 ? 1 : i - 9);
      }
      expect(store.query(sinceSeq: 30).map((e) => e.seq), [31, 32, 33, 34, 35, 36, 37]);
      expect(store.query(limit: 3).map((e) => e.text), ['line 35', 'line 36', 'line 37']);
      expect(store.query(grep: r'line [0-9]$'), isEmpty); // 1-9 already dropped
    });

    test('clear empties the buffer but seq continues', () {
      final store = LogStore(capacity: 10);
      for (var i = 0; i < 25; i++) {
        store.add('x');
      }
      store.clear();
      expect(store.query(), isEmpty);
      expect(store.add('after').seq, 26);
      expect(store.query().map((e) => e.seq), [26]);
    });

    test('appending at capacity stays cheap', () {
      // Shifting the whole buffer on every line made this take seconds.
      final store = LogStore();
      for (var i = 0; i < store.capacity; i++) {
        store.add('fill');
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        store.add('more');
      }
      sw.stop();
      expect(store.query().length, store.capacity);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });
}
