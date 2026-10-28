import 'dart:convert';
import 'dart:io';

import 'package:emu/src/server.dart' show readWebAsset;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String web;

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('emu_web_assets_').resolveSymbolicLinksSync());
    web = '${tmp.path}/web';
    Directory('$web/hub').createSync(recursive: true);
    File('$web/app.js').writeAsStringSync('dev app');
    File('$web/new.js').writeAsStringSync('dev new');
    File('$web/hub/hub.js').writeAsStringSync('dev hub');
    File('${tmp.path}/secret.txt').writeAsStringSync('secret');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String? read(String rel) {
    final bytes = readWebAsset(rel, diskDirs: [web]);
    return bytes == null ? null : utf8.decode(bytes);
  }

  test('a dev web dir serves its files, nested ones too', () {
    expect(read('app.js'), 'dev app');
    expect(read('new.js'), 'dev new', reason: 'a file not bundled yet still serves in dev');
    expect(read('hub/hub.js'), 'dev hub');
  });

  test('a path outside the dev web dir is never read from disk', () {
    expect(read('../secret.txt'), isNull);
    expect(read('hub/../../secret.txt'), isNull);
    expect(read('${tmp.path}/secret.txt'), isNull);
  });

  test('a path not on disk falls back to the embedded assets', () {
    expect(read('index.html'), contains('<html'));
    expect(read('nope.js'), isNull);
  });
}
