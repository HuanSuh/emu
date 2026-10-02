import 'package:emu/src/engine.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterEngine.buildRunArgs', () {
    test('includes device/flavor/target and dart-define(s)', () {
      final args = FlutterEngine.buildRunArgs(
        deviceId: 'emulator-5554',
        flavor: 'dev',
        target: 'lib/main_dev.dart',
        dartDefines: ['ENV=dev'],
        dartDefineFromFile: ['config.json'],
      );
      expect(args, [
        'run',
        '--machine',
        '-d', 'emulator-5554',
        '--flavor', 'dev',
        '-t', 'lib/main_dev.dart',
        '--dart-define=ENV=dev',
        '--dart-define-from-file=config.json',
      ]);
    });

    test('passes dart-entrypoint-args as repeated -a pairs', () {
      final args = FlutterEngine.buildRunArgs(
        dartEntrypointArgs: ['--verbose', 'seed=1'],
      );
      expect(args, containsAllInOrder(['-a', '--verbose', '-a', 'seed=1']));
    });

    test('includes device-timeout, device-connection, dds-port, no-dds', () {
      final args = FlutterEngine.buildRunArgs(
        deviceTimeoutSec: 30,
        deviceConnection: 'wireless',
        ddsPort: 8181,
        noDds: true,
      );
      expect(args, containsAll(<String>[
        '--device-timeout=30',
        '--device-connection=wireless',
        '--dds-port=8181',
        '--no-dds',
      ]));
    });

    test('omits dds/device flags entirely when unset', () {
      final args = FlutterEngine.buildRunArgs();
      expect(args.any((a) => a.startsWith('--device-timeout')), isFalse);
      expect(args.any((a) => a.startsWith('--device-connection')), isFalse);
      expect(args.any((a) => a.startsWith('--dds-port')), isFalse);
      expect(args.contains('--no-dds'), isFalse);
    });
  });

  group('buildAttachArgs', () {
    final run = FlutterEngine.buildRunArgs(
      deviceId: 'emulator-5554',
      flavor: 'development',
      target: 'lib/main_development.dart',
      dartDefines: ['A=1'],
      dartDefineFromFile: ['config.local.json'],
      dartEntrypointArgs: ['--x'],
      ddsPort: 8181,
    );

    test('keeps entry point, defines and DDS; drops run-only flags', () {
      final a = FlutterEngine.buildAttachArgs(run,
          deviceId: 'emulator-5554', debugUrl: 'http://127.0.0.1:4321/abc=/');
      expect(a.take(4), ['attach', '--machine', '-d', 'emulator-5554']);
      expect(a, containsAllInOrder(['-t', 'lib/main_development.dart']));
      expect(a, contains('--dart-define=A=1'));
      expect(a, contains('--dart-define-from-file=config.local.json'));
      expect(a, contains('--dds-port=8181'));
      expect(a, isNot(contains('--flavor')));
      expect(a, isNot(contains('-a')));
      expect(a, containsAllInOrder(['--debug-url', 'http://127.0.0.1:4321/abc=/']));
      expect(a, isNot(contains('--app-id')));
    });

    test('falls back to --app-id without a debug URL', () {
      final a = FlutterEngine.buildAttachArgs(run, deviceId: 'X', appId: 'com.x.dev');
      expect(a, containsAllInOrder(['--app-id', 'com.x.dev']));
      expect(a, isNot(contains('--debug-url')));
    });
  });
}
