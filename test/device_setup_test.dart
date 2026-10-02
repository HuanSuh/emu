import 'dart:io';

import 'package:emu/src/device_setup.dart';
import 'package:emu/src/project_config.dart';
import 'package:test/test.dart';

void main() {
  group('parsePortMapping', () {
    test('a bare port maps tcp on both sides', () {
      expect(parsePortMapping(8000), const PortMapping('tcp:8000', 'tcp:8000'));
      expect(parsePortMapping('8000'), const PortMapping('tcp:8000', 'tcp:8000'));
    });

    test('device:host ports', () {
      expect(parsePortMapping('8000:9000'), const PortMapping('tcp:8000', 'tcp:9000'));
    });

    test('full adb socket specs', () {
      expect(parsePortMapping('tcp:8000:tcp:9000'), const PortMapping('tcp:8000', 'tcp:9000'));
      expect(parsePortMapping('localabstract:chrome:tcp:9222'),
          const PortMapping('localabstract:chrome', 'tcp:9222'));
    });

    test('spec round-trips', () {
      const m = PortMapping('tcp:8000', 'tcp:9000');
      expect(parsePortMapping(m.spec), m);
    });

    test('rejects garbage and out-of-range ports', () {
      for (final bad in ['', 'abc', '0', '70000', '8000:', 'tcp:8000', '1:2:3', 'TCP:1:tcp:2']) {
        expect(parsePortMapping(bad), isNull, reason: bad);
      }
    });
  });

  test('adb argv: reverse is device→host, forward is host→device', () {
    const m = PortMapping('tcp:8000', 'tcp:9000');
    expect(adbMapArgs('emulator-5554', m, reverse: true),
        ['-s', 'emulator-5554', 'reverse', 'tcp:8000', 'tcp:9000']);
    expect(adbMapArgs('emulator-5554', m, reverse: false),
        ['-s', 'emulator-5554', 'forward', 'tcp:9000', 'tcp:8000']);
    expect(adbUnmapArgs('emulator-5554', m, reverse: true),
        ['-s', 'emulator-5554', 'reverse', '--remove', 'tcp:8000']);
    expect(adbUnmapArgs('emulator-5554', m, reverse: false),
        ['-s', 'emulator-5554', 'forward', '--remove', 'tcp:9000']);
  });

  group('parseAdbMapList', () {
    test('reverse --list (first column is a transport name, not the serial)', () {
      expect(parseAdbMapList('UsbFfs tcp:8000 tcp:8000\nhost-19 tcp:81 tcp:82\n', 'emulator-5554',
              reverse: true),
          const [PortMapping('tcp:8000', 'tcp:8000'), PortMapping('tcp:81', 'tcp:82')]);
    });

    test('forward --list keeps only this serial, local side is the host', () {
      const out = 'emulator-5554 tcp:9000 tcp:8000\nemulator-5556 tcp:1 tcp:2\n';
      expect(parseAdbMapList(out, 'emulator-5554', reverse: false),
          const [PortMapping('tcp:8000', 'tcp:9000')]);
    });

    test('empty output', () {
      expect(parseAdbMapList('', 'x', reverse: true), isEmpty);
    });
  });

  test('hookEnvironment omits EMU_APP_ID when unknown', () {
    final env = hookEnvironment(deviceId: 'emulator-5554', platform: 'android', projectRoot: '/p');
    expect(env, {'EMU_DEVICE': 'emulator-5554', 'EMU_PLATFORM': 'android', 'EMU_PROJECT': '/p'});
    expect(
        hookEnvironment(deviceId: 'd', platform: 'ios', projectRoot: '/p', appId: 'a.b')['EMU_APP_ID'],
        'a.b');
  });

  group('builtAppId', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('emu_setup_test'));
    tearDown(() => root.deleteSync(recursive: true));

    test('reads the newest Android output-metadata.json', () async {
      File meta(String flavor) =>
          File('${root.path}/build/app/outputs/apk/$flavor/debug/output-metadata.json')
            ..createSync(recursive: true);
      meta('production').writeAsStringSync('{"applicationId": "com.x.prod"}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      meta('development').writeAsStringSync('{"applicationId": "com.x.dev"}');
      expect(builtAppId(root.path, 'android'), 'com.x.dev');
    });

    test('null without build outputs', () {
      expect(builtAppId(root.path, 'android'), isNull);
      expect(builtAppId(root.path, 'ios'), isNull);
    });
  });

  test('DeviceSetup runs hooks with the env and reports failures as errors', () async {
    final root = Directory.systemTemp.createTempSync('emu_hook_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final logs = <(String, bool)>[];
    final setup = DeviceSetup(projectRoot: root.path, log: (m, e) => logs.add((m, e)));
    await setup.runHooks('onDeviceReady', [r'echo "$EMU_DEVICE/$EMU_PLATFORM/$EMU_APP_ID"', 'exit 3'],
        deviceId: 'emulator-5554', platform: 'android', appId: 'com.x');
    expect(logs.map((l) => l.$1), contains('emulator-5554/android/com.x'));
    expect(logs.where((l) => l.$2).single.$1, contains('exit 3'));
  });

  test('emu.yaml keys parse into EmuConfig', () {
    final c = EmuConfig.fromMap({
      'reversePorts': [8000, '9000:9001'],
      'forwardPorts': 'tcp:1:tcp:2',
      'onDeviceReady': ['echo a'],
      'onAppStarted': ['echo b', 'echo c'],
    });
    expect(c.reversePorts, ['8000', '9000:9001']);
    expect(c.forwardPorts, ['tcp:1:tcp:2']);
    expect(c.onDeviceReady, ['echo a']);
    expect(c.onAppStarted, ['echo b', 'echo c']);
  });
}
