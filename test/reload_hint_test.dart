import 'package:emu/src/cli.dart';
import 'package:test/test.dart';

void main() {
  group('shouldHintRestart', () {
    test('fires only on busy→silent after a successful reload', () {
      expect(
          shouldHintRestart(ok: true, wasActiveBefore: true, producedAfter: 0), isTrue);
    });

    test('does not fire when output continued', () {
      expect(
          shouldHintRestart(ok: true, wasActiveBefore: true, producedAfter: 5), isFalse);
    });

    test('does not fire on an idle app — avoids noise on ordinary reloads', () {
      expect(
          shouldHintRestart(ok: true, wasActiveBefore: false, producedAfter: 0), isFalse);
    });

    test('does not fire when the reload itself failed', () {
      expect(
          shouldHintRestart(ok: false, wasActiveBefore: true, producedAfter: 0), isFalse);
    });
  });

  group('isAppOutput', () {
    Map<String, dynamic> e(String text, {String source = 'app'}) =>
        {'text': text, 'source': source};

    test('genuine app prints count', () {
      expect(isAppOutput(e('flutter: PING')), isTrue);
      expect(isAppOutput(e('E/flutter: boom', source: 'stderr')), isTrue);
    });

    test('emu system lines are excluded', () {
      expect(isAppOutput(e('hot reload complete', source: 'system')), isFalse);
    });

    test("the daemon's reload/restart report is excluded — it lands on every reload", () {
      expect(isAppOutput(e('Reloaded 0 libraries in 29ms (compile: 5 ms).')), isFalse);
      expect(isAppOutput(e('Restarted application in 812ms.')), isFalse);
    });
  });
}
