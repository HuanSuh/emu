import 'package:emu/src/open_url.dart';
import 'package:test/test.dart';

void main() {
  group('buildOpenUrlCommand', () {
    test('android without a device id: plain adb invocation', () {
      final cmd = buildOpenUrlCommand(platform: 'android', deviceId: null, url: 'myapp://x');
      expect(cmd.executable, 'adb');
      expect(cmd.arguments,
          ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', 'myapp://x']);
    });

    test('android with a device id: targets it via -s', () {
      final cmd = buildOpenUrlCommand(
          platform: 'android', deviceId: 'emulator-5554', url: 'myapp://x');
      expect(cmd.executable, 'adb');
      expect(cmd.arguments, [
        '-s',
        'emulator-5554',
        'shell',
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        'myapp://x',
      ]);
    });

    test('ios: xcrun simctl openurl with the udid', () {
      final cmd = buildOpenUrlCommand(
          platform: 'ios', deviceId: 'A1B2C3D4-1234-5678-9ABC-DEF012345678', url: 'myapp://x');
      expect(cmd.executable, 'xcrun');
      expect(cmd.arguments,
          ['simctl', 'openurl', 'A1B2C3D4-1234-5678-9ABC-DEF012345678', 'myapp://x']);
    });

    test('ios without a known udid falls back to "booted"', () {
      final cmd = buildOpenUrlCommand(platform: 'ios', deviceId: null, url: 'myapp://x');
      expect(cmd.arguments, ['simctl', 'openurl', 'booted', 'myapp://x']);
    });

    test('a url containing shell metacharacters is passed as a single argv entry, unmodified', () {
      const url = 'myapp://checkout?id=1&ref=a;b`whoami`';
      final cmd = buildOpenUrlCommand(platform: 'android', deviceId: null, url: url);
      expect(cmd.arguments.last, url);
      expect(cmd.arguments.length, 7);
    });
  });
}
