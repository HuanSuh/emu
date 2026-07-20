import 'package:emu/src/launch_config.dart';
import 'package:test/test.dart';

void main() {
  group('stripJsonc', () {
    test('removes line and block comments outside strings', () {
      const src = '''
{
  // a line comment
  "a": 1, /* block */
  "url": "https://example.com" // trailing
}''';
      final cleaned = stripJsonc(src);
      expect(cleaned.contains('line comment'), isFalse);
      expect(cleaned.contains('block'), isFalse);
      // The // inside the string must survive.
      expect(cleaned.contains('https://example.com'), isTrue);
    });

    test('removes trailing commas', () {
      const src = '{ "a": [1, 2,], "b": 3, }';
      final cleaned = stripJsonc(src);
      expect(cleaned.contains(',]'), isFalse);
      expect(cleaned.contains(', }'), isFalse);
    });
  });

  group('parseLaunchJson', () {
    test('extracts flavor/target/dart-define from args', () {
      const src = '''
{
  "configurations": [
    {
      "name": "dev",
      "type": "dart",
      "program": "lib/main_dev.dart",
      "args": ["--flavor", "development", "--dart-define", "ENV=dev", "--dart-define=API=x"]
    }
  ]
}''';
      final configs = parseLaunchJson(src);
      expect(configs, hasLength(1));
      final c = configs.single;
      expect(c.name, 'dev');
      expect(c.mode, 'debug');
      expect(c.flavor, 'development');
      expect(c.target, 'lib/main_dev.dart');
      expect(c.dartDefines, ['ENV=dev', 'API=x']);
      expect(c.isDebug, isTrue);
    });

    test('reads flags from toolArgs and =form', () {
      const src = '''
{ "configurations": [
  { "name": "stg", "type": "dart", "toolArgs": ["--flavor=staging", "-t", "lib/s.dart"] }
] }''';
      final c = parseLaunchJson(src).single;
      expect(c.flavor, 'staging');
      expect(c.target, 'lib/s.dart');
    });

    test('captures flutterMode and deviceId, marks non-debug', () {
      const src = '''
{ "configurations": [
  { "name": "rel", "type": "dart", "flutterMode": "release", "deviceId": "emulator-5554" }
] }''';
      final c = parseLaunchJson(src).single;
      expect(c.mode, 'release');
      expect(c.deviceId, 'emulator-5554');
      expect(c.isDebug, isFalse);
    });

    test('extracts dart-define-from-file paths (space and = form)', () {
      const src = '''
{ "configurations": [
  { "name": "x", "type": "dart", "args": [
      "--dart-define-from-file", "secret.json",
      "--dart-define-from-file=other.json"
  ] }
] }''';
      final c = parseLaunchJson(src).single;
      expect(c.dartDefineFromFile, ['secret.json', 'other.json']);
      expect(c.unsupported, isEmpty);
    });

    test('resolves relative dart-define-from-file paths against projectRoot', () {
      const src = '''
{ "configurations": [
  { "name": "x", "type": "dart", "args": ["--dart-define-from-file", "secret.json"] }
] }''';
      final c = parseLaunchJson(src, projectRoot: '/proj').single;
      expect(c.dartDefineFromFile, ['/proj/secret.json']);
    });

    test('leaves absolute dart-define-from-file paths untouched', () {
      const src = '''
{ "configurations": [
  { "name": "x", "type": "dart", "args": ["--dart-define-from-file", "/etc/secret.json"] }
] }''';
      final c = parseLaunchJson(src, projectRoot: '/proj').single;
      expect(c.dartDefineFromFile, ['/etc/secret.json']);
    });

    test('dart-define and dart-define-from-file coexist', () {
      const src = '''
{ "configurations": [
  { "name": "x", "type": "dart", "args": [
      "--dart-define", "ENV=dev",
      "--dart-define-from-file", "secret.json"
  ] }
] }''';
      final c = parseLaunchJson(src).single;
      expect(c.dartDefines, ['ENV=dev']);
      expect(c.dartDefineFromFile, ['secret.json']);
    });

    test('skips non-dart and unnamed entries', () {
      const src = '''
{ "configurations": [
  { "name": "node thing", "type": "node" },
  { "type": "dart" },
  { "name": "ok", "type": "dart" }
] }''';
      final configs = parseLaunchJson(src);
      expect(configs.map((c) => c.name), ['ok']);
    });
  });
}
