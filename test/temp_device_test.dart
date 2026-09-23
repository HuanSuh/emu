import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:emu/src/temp_device.dart';
import 'package:test/test.dart';

void main() {
  group('chooseSystemImage', () {
    const installed = [
      'android-24/google_apis/arm64-v8a',
      'android-34/google_apis/arm64-v8a',
      'android-34/google_apis_playstore/arm64-v8a',
      'android-36/google_apis_playstore/arm64-v8a',
      'android-36/google_apis_playstore/x86_64',
      'android-37/android-wear/arm64-v8a',
      'android-37/google_apis_playstore_ps16k/arm64-v8a',
    ];

    test('highest API for the host ABI, skipping non-phone tags', () {
      expect(chooseSystemImage(installed, 'arm64-v8a'),
          'system-images;android-36;google_apis_playstore;arm64-v8a');
      expect(chooseSystemImage(installed, 'x86_64'),
          'system-images;android-36;google_apis_playstore;x86_64');
    });

    test('Play Store beats Google APIs at the same API level', () {
      expect(chooseSystemImage(installed.take(3).toList(), 'arm64-v8a'),
          'system-images;android-34;google_apis_playstore;arm64-v8a');
    });

    test('minor API versions order after their major', () {
      expect(
          chooseSystemImage(
              ['android-36/google_apis/arm64-v8a', 'android-36.1/google_apis/arm64-v8a'],
              'arm64-v8a'),
          'system-images;android-36.1;google_apis;arm64-v8a');
    });

    test('null when nothing matches', () {
      expect(chooseSystemImage(const [], 'arm64-v8a'), isNull);
      expect(chooseSystemImage(['android-37/android-tv/arm64-v8a'], 'arm64-v8a'), isNull);
      expect(chooseSystemImage(['android-Baklava/google_apis/arm64-v8a'], 'arm64-v8a'), isNull);
    });
  });

  group('chooseIosSimSpec', () {
    Map<String, dynamic> runtime(String version, bool available, List<String> types) => {
          'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll('.', '-')}',
          'version': version,
          'isAvailable': available,
          'supportedDeviceTypes': [
            for (final t in types)
              {'name': t, 'identifier': 'type.${t.replaceAll(' ', '-')}'},
          ],
        };

    test('newest available runtime, base iPhone model', () {
      final json = jsonEncode({
        'runtimes': [
          runtime('17.5', true, ['iPhone 15 Pro', 'iPhone 15']),
          runtime('26.0.1', true, ['iPhone 17 Pro', 'iPhone Air', 'iPhone 17', 'iPad Air']),
          runtime('27.0', false, ['iPhone 18']),
          {
            'identifier': 'com.apple.CoreSimulator.SimRuntime.watchOS-12-0',
            'version': '30.0',
            'isAvailable': true,
            'supportedDeviceTypes': [
              {'name': 'iPhone 99', 'identifier': 'x'},
            ],
          },
        ],
      });
      expect(chooseIosSimSpec(json),
          ('com.apple.CoreSimulator.SimRuntime.iOS-26-0-1', 'type.iPhone-17'));
    });

    test('falls back to the first iPhone, and past runtimes without one', () {
      final json = jsonEncode({
        'runtimes': [
          runtime('26.0', true, ['iPad Air']),
          runtime('17.5', true, ['iPhone SE (3rd generation)', 'iPhone 15 Pro']),
        ],
      });
      expect(chooseIosSimSpec(json)!.$2, 'type.iPhone-SE-(3rd-generation)');
    });

    test('null on no runtime or bad JSON', () {
      expect(chooseIosSimSpec('{"runtimes": []}'), isNull);
      expect(chooseIosSimSpec('nope'), isNull);
    });
  });

  test('chooseAvdDeviceProfile picks the newest plain Pixel', () {
    expect(chooseAvdDeviceProfile(['tv_4k', 'pixel', 'pixel_4', 'pixel_4_xl', 'pixel_5', 'pixel_c']),
        'pixel_5');
    expect(chooseAvdDeviceProfile(['pixel_9', 'pixel_10', 'pixel_9_pro_fold']), 'pixel_10');
    expect(chooseAvdDeviceProfile(['Nexus 5', 'pixel']), 'pixel');
    expect(chooseAvdDeviceProfile(['Nexus 5']), isNull);
  });

  test('tempDeviceName is AVD-safe and tagged with the project', () {
    final name = tempDeviceName('/work/my app+x/', random: Random(1));
    expect(name, matches(RegExp(r'^emu_tmp_my_app_x_[0-9a-f]{8}$')));
  });

  group('TempDevices', () {
    late Directory dir;
    late Set<int> alive;
    late TempDevices registry;

    TempDevice device(String name, int pid, {String? udid}) => TempDevice(
        platform: udid == null ? 'android' : 'ios',
        name: name,
        udid: udid,
        ownerPid: pid,
        ownerPort: 4577,
        project: '/a');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('emu_temp_device_test');
      alive = {};
      registry = TempDevices(dir: dir, isAlive: (l) async => alive.contains(l.pid));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('records round-trip and are found by owner', () {
      registry.record(device('emu_tmp_a_0001', 1));
      registry.record(device('emu_tmp_a_0002', 2, udid: 'ABC-1'));
      expect(registry.ownedBy(1).single.name, 'emu_tmp_a_0001');
      final ios = registry.ownedBy(2).single;
      expect(ios.platform, 'ios');
      expect(ios.udid, 'ABC-1');
      expect(registry.ownedBy(3), isEmpty);
    });

    test('orphans are the devices whose owner is dead', () async {
      registry.record(device('emu_tmp_a_0001', 1));
      registry.record(device('emu_tmp_a_0002', 2));
      alive.add(1);
      expect((await registry.orphans()).map((d) => d.name), ['emu_tmp_a_0002']);
    });

    test('forget removes the record; unparseable files are ignored', () {
      final d = device('emu_tmp_a_0001', 1);
      registry.record(d);
      File('${dir.path}/junk.json').writeAsStringSync('{');
      registry.forget(d);
      expect(registry.all(), isEmpty);
      registry.forget(d); // Idempotent.
    });

    test('empty when the registry dir does not exist', () {
      expect(TempDevices(dir: Directory('${dir.path}/missing')).all(), isEmpty);
    });
  });
}
