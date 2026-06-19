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
}
