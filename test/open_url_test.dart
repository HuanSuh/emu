import 'package:emu/src/open_url.dart';
import 'package:test/test.dart';

void main() {
  group('buildOpenUrlCommand', () {
    test('android without a device id: plain adb invocation', () {
      final cmd = buildOpenUrlCommand(
        platform: 'android',
        deviceId: null,
        url: 'myapp://x',
      );
      expect(cmd.executable, 'adb');
      expect(cmd.arguments, [
        'shell',
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        "'myapp://x'",
      ]);
    });

    test('android with a device id: targets it via -s', () {
      final cmd = buildOpenUrlCommand(
        platform: 'android',
        deviceId: 'emulator-5554',
        url: 'myapp://x',
      );
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
        "'myapp://x'",
      ]);
    });

    test('ios: xcrun simctl openurl with the udid', () {
      final cmd = buildOpenUrlCommand(
        platform: 'ios',
        deviceId: 'A1B2C3D4-1234-5678-9ABC-DEF012345678',
        url: 'myapp://x',
      );
      expect(cmd.executable, 'xcrun');
      expect(cmd.arguments, [
        'simctl',
        'openurl',
        'A1B2C3D4-1234-5678-9ABC-DEF012345678',
        'myapp://x',
      ]);
    });

    test('ios without a known udid falls back to "booted"', () {
      final cmd = buildOpenUrlCommand(
        platform: 'ios',
        deviceId: null,
        url: 'myapp://x',
      );
      expect(cmd.arguments, ['simctl', 'openurl', 'booted', 'myapp://x']);
    });

    test('android quotes the url for the device shell that adb shell feeds', () {
      // adb shell does not preserve argv boundaries: it joins its arguments and
      // hands the string to the device's sh. Without quoting, sh splits at `&`
      // and every parameter after the first is silently dropped.
      const url = 'myapp://home?nav_mode=go&tab=BENEFIT_MAIN&delayed=1000';
      final cmd = buildOpenUrlCommand(
        platform: 'android',
        deviceId: null,
        url: url,
      );
      expect(cmd.arguments.last, "'$url'");
      expect(cmd.arguments.length, 7);
    });

    test('android neutralises other shell metacharacters too', () {
      const url = 'myapp://checkout?id=1&ref=a;b`whoami`|c';
      final cmd = buildOpenUrlCommand(
        platform: 'android',
        deviceId: null,
        url: url,
      );
      expect(cmd.arguments.last, "'$url'");
    });

    test('ios passes the url through unquoted (simctl execs directly)', () {
      const url = 'myapp://home?a=1&b=2';
      final cmd = buildOpenUrlCommand(
        platform: 'ios',
        deviceId: null,
        url: url,
      );
      expect(cmd.arguments.last, url);
    });
  });

  group('quoteForDeviceShell', () {
    test('wraps a plain value in single quotes', () {
      expect(quoteForDeviceShell('abc'), "'abc'");
    });

    test('closes, escapes and reopens an embedded single quote', () {
      // ' cannot be escaped inside single quotes in POSIX sh.
      expect(quoteForDeviceShell("a'b"), r"'a'\''b'");
    });
  });
}
