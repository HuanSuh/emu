import 'package:emu/src/device_manager.dart';
import 'package:test/test.dart';

void main() {
  test('parseFlutterDevices reads id/name/platform/emulator', () {
    const json = '''
    [
      {"name":"sdk gphone64 arm64","id":"emulator-5554","emulator":true,
       "platformType":"android","targetPlatform":"android-arm64"},
      {"name":"iPhone 15","id":"ABC-123","emulator":true,
       "platformType":"ios","targetPlatform":"ios"}
    ]''';
    final devices = parseFlutterDevices(json);
    expect(devices.length, 2);
    expect(devices[0].id, 'emulator-5554');
    expect(devices[0].platform, 'android');
    expect(devices[0].emulator, isTrue);
    expect(devices[1].name, 'iPhone 15');
    expect(devices[1].platform, 'ios');
  });

  test('parseFlutterDevices falls back to target platform', () {
    const json = '[{"name":"d","id":"x","targetPlatform":"android-x64"}]';
    final devices = parseFlutterDevices(json);
    expect(devices.single.platform, 'android');
    expect(devices.single.emulator, isFalse);
  });

  test('parseFlutterDevices tolerates empty input', () {
    expect(parseFlutterDevices('[]'), isEmpty);
    expect(parseFlutterDevices('{}'), isEmpty);
  });

  group('platformForDeviceId', () {
    test('iOS simulator UDIDs are UUIDs', () {
      expect(platformForDeviceId('A1B2C3D4-1234-5678-9ABC-DEF012345678'), 'ios');
      // simctl prints them uppercase, but don't depend on that.
      expect(platformForDeviceId('a1b2c3d4-1234-5678-9abc-def012345678'), 'ios');
    });

    test('Android emulators and physical serials are android', () {
      expect(platformForDeviceId('emulator-5554'), 'android');
      // A physical serial must not be mistaken for iOS — the old
      // `startsWith('emulator-')` check got this wrong.
      expect(platformForDeviceId('R5CT30ABCDE'), 'android');
    });

    test('unknown or absent ids fall back to android', () {
      expect(platformForDeviceId(null), 'android');
      expect(platformForDeviceId(''), 'android');
      // UUID-like but malformed (short final group) is not a simulator udid.
      expect(platformForDeviceId('A1B2C3D4-1234-5678-9ABC-DEF01234567'), 'android');
    });
  });
}
