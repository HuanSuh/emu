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
}
