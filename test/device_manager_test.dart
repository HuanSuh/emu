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

  group('preferredAvd', () {
    test('empty list yields null', () {
      expect(preferredAvd([]), isNull);
    });

    test('the reported case: prefer Pixel over an alphabetically-first foldable', () {
      // `--android` used to take avds.first (Galaxy_Z_Flip) and fail to boot.
      expect(preferredAvd(['Galaxy_Z_Flip', 'Pixel_8_Pro_API_34']), 'Pixel_8_Pro_API_34');
    });

    test('deprioritizes non-phone form factors', () {
      expect(preferredAvd(['Wear_OS_Round', 'Pixel_7']), 'Pixel_7');
      expect(preferredAvd(['Foldable_API_34', 'gphone64_arm64']), 'gphone64_arm64');
    });

    test('ties keep original order', () {
      expect(preferredAvd(['Pixel_8', 'Pixel_7']), 'Pixel_8');
      expect(preferredAvd(['Custom_A', 'Custom_B']), 'Custom_A');
    });

    test('falls back to first when nothing scores higher', () {
      // All same (unknown) score → first wins.
      expect(preferredAvd(['My_Device', 'Other_Device']), 'My_Device');
    });
  });

  group('parseAdbEmulators', () {
    test('keeps ready emulators, drops physical/offline/unauthorized', () {
      const out = 'List of devices attached\n'
          'emulator-5554\tdevice\n'
          'R5CT30ABCDE\tdevice\n'
          'emulator-5556\toffline\n'
          'emulator-5558\tdevice\n'
          'emulator-5560\tunauthorized\n';
      expect(parseAdbEmulators(out), ['emulator-5554', 'emulator-5558']);
    });

    test('no devices', () {
      expect(parseAdbEmulators('List of devices attached\n\n'), isEmpty);
    });
  });

  group('chooseAvdToBoot', () {
    test('skips AVDs that are already running', () {
      expect(chooseAvdToBoot(['Pixel_7', 'Pixel_8'], ['Pixel_7']), 'Pixel_8');
    });

    test('still applies the phone preference among the rest', () {
      expect(chooseAvdToBoot(['Pixel_7', 'Galaxy_Z_Flip', 'Pixel_8'], ['Pixel_7']), 'Pixel_8');
    });

    test('null when every AVD is running', () {
      expect(chooseAvdToBoot(['Pixel_7'], ['Pixel_7']), isNull);
    });
  });

  test('parseSimctlDevices keeps available sims with booted state, in order', () {
    const json = '''
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid":"U1","name":"iPhone 15","state":"Booted","isAvailable":true},
        {"udid":"U2","name":"iPhone 16","state":"Shutdown","isAvailable":true},
        {"udid":"U3","name":"iPhone 14","state":"Shutdown","isAvailable":false}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
        {"udid":"U4","name":"Apple Watch","state":"Booted","isAvailable":true}
      ]
    }}''';
    final sims = parseSimctlDevices(json);
    expect(sims.map((s) => s.udid), ['U1', 'U2', 'U4']);
    expect(sims.map((s) => s.booted), [true, false, true]);
    expect(sims[1].name, 'iPhone 16');
  });
}
