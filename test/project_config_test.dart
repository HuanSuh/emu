import 'dart:io';

import 'package:emu/src/project_config.dart';
import 'package:emu/src/project_memory.dart';
import 'package:test/test.dart';

void main() {
  group('mergeConfigMaps precedence', () {
    test('later layer overrides earlier scalar', () {
      final m = mergeConfigMaps([
        {'flavor': 'dev', 'timeout': 100},
        {'flavor': 'prod'},
      ]);
      expect(m['flavor'], 'prod');
      expect(m['timeout'], 100); // untouched by upper layer
    });

    test('null / empty values do not clobber a lower layer', () {
      final m = mergeConfigMaps([
        {'device': 'emulator-5554'},
        {'device': null, 'flavor': ''},
        {'dartDefines': <String>[]},
      ]);
      expect(m['device'], 'emulator-5554');
      expect(m.containsKey('flavor'), isFalse);
      expect(m.containsKey('dartDefines'), isFalse);
    });

    test('non-empty list replaces wholesale, no concat', () {
      final m = mergeConfigMaps([
        {'dartDefines': ['A=1', 'B=2']},
        {'dartDefines': ['C=3']},
      ]);
      expect(m['dartDefines'], ['C=3']);
    });
  });

  group('EmuConfig.fromMap', () {
    test('reads all fields with aliases', () {
      final c = EmuConfig.fromMap({
        'device': 'd', 'flavor': 'f', 'entry': 'lib/x.dart',
        'dartDefine': 'K=V', 'timeout': '30', 'port': 5000, 'platform': 'ios',
      });
      expect(c.deviceId, 'd');
      expect(c.target, 'lib/x.dart'); // entry alias
      expect(c.dartDefines, ['K=V']); // scalar string → single-element list
      expect(c.timeoutSec, 30); // string coerced
      expect(c.port, 5000);
      expect(c.platform, 'ios');
    });

    test('empty map yields all-null config', () {
      final c = EmuConfig.fromMap({});
      expect(c.deviceId, isNull);
      expect(c.dartDefines, isEmpty);
    });
  });

  group('loadProjectConfig layering (filesystem)', () {
    late Directory root;
    late Directory home;
    setUp(() {
      root = Directory.systemTemp.createTempSync('emu_cfg_root');
      home = Directory.systemTemp.createTempSync('emu_cfg_home');
    });
    tearDown(() {
      root.deleteSync(recursive: true);
      home.deleteSync(recursive: true);
    });

    test('local > project > user', () {
      Directory('${home.path}/.emu').createSync();
      File('${home.path}/.emu/config.yaml')
          .writeAsStringSync('timeout: 200\nflavor: userFlavor\ndevice: userDev\n');
      File('${root.path}/emu.yaml').writeAsStringSync('flavor: projFlavor\ndevice: projDev\n');
      File('${root.path}/emu.local.yaml').writeAsStringSync('device: localDev\n');

      final c = loadProjectConfig(root.path, home: home.path);
      expect(c.deviceId, 'localDev'); // local wins
      expect(c.flavor, 'projFlavor'); // project beats user
      expect(c.timeoutSec, 200); // only user set it
    });

    test('malformed file warns and is skipped, not fatal', () {
      File('${root.path}/emu.yaml').writeAsStringSync('flavor: [unclosed');
      final warnings = <String>[];
      final c = loadProjectConfig(root.path, home: home.path, onWarn: warnings.add);
      expect(warnings, isNotEmpty);
      expect(c.flavor, isNull);
    });
  });

  group('ensureLocalConfigIgnored', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('emu_gi'));
    tearDown(() => root.deleteSync(recursive: true));

    test('no-op when emu.local.yaml is absent', () {
      expect(ensureLocalConfigIgnored(root.path), isFalse);
      expect(File('${root.path}/.gitignore').existsSync(), isFalse);
    });

    test('creates .gitignore and adds entry when file exists', () {
      File('${root.path}/emu.local.yaml').writeAsStringSync('device: x\n');
      expect(ensureLocalConfigIgnored(root.path), isTrue);
      expect(File('${root.path}/.gitignore').readAsStringSync(), contains('emu.local.yaml'));
    });

    test('idempotent — already ignored returns false, no duplicate', () {
      File('${root.path}/emu.local.yaml').writeAsStringSync('device: x\n');
      File('${root.path}/.gitignore').writeAsStringSync('build/\nemu.local.yaml\n');
      expect(ensureLocalConfigIgnored(root.path), isFalse);
      final count = 'emu.local.yaml'
          .allMatches(File('${root.path}/.gitignore').readAsStringSync())
          .length;
      expect(count, 1);
    });

    test('appends with a newline when existing .gitignore lacks a trailing one', () {
      File('${root.path}/emu.local.yaml').writeAsStringSync('device: x\n');
      File('${root.path}/.gitignore').writeAsStringSync('build/'); // no trailing \n
      expect(ensureLocalConfigIgnored(root.path), isTrue);
      final gi = File('${root.path}/.gitignore').readAsLinesSync();
      expect(gi, containsAll(['build/', 'emu.local.yaml']));
    });
  });

  group('ProjectMemory roundtrip', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('emu_mem'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save then load preserves fields', () {
      final m = ProjectMemory.load(dir);
      m.lastDpr = 2.625;
      m.lastScreen = [1080, 2400];
      m.lastInspect = 'lib/main.dart:34';
      m.addSeenKey('loginBtn');
      m.addSeenKey('loginBtn'); // dedup
      m.addSeenKey('emailField');
      m.save();

      final r = ProjectMemory.load(dir);
      expect(r.lastDpr, 2.625);
      expect(r.lastScreen, [1080, 2400]);
      expect(r.lastInspect, 'lib/main.dart:34');
      expect(r.seenKeys, ['loginBtn', 'emailField']);
    });

    test('malformed json loads empty rather than throwing', () {
      File('${dir.path}/memory.json').writeAsStringSync('{not json');
      final m = ProjectMemory.load(dir);
      expect(m.toJson(), isEmpty);
    });
  });
}
