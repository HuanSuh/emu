import 'dart:convert';
import 'dart:io';

import 'package:emu/src/registry.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emu_registry_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  SessionEntry entry(String project, {int port = 4577, int pid = 1, DateTime? startedAt}) =>
      SessionEntry(project: project, port: port, pid: pid, name: project.split('/').last, startedAt: startedAt);

  group('sessionIdFor / projectNameOf', () {
    test('id is stable, 12 hex digits, differs per path', () {
      final a = sessionIdFor('/work/app');
      expect(a, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(sessionIdFor('/work/app'), a);
      expect(sessionIdFor('/work/app-wt'), isNot(a));
    });

    test('name comes from pubspec, else the directory', () {
      final p = Directory('${tmp.path}/some_dir')..createSync();
      expect(projectNameOf(p.path), 'some_dir');
      File('${p.path}/pubspec.yaml').writeAsStringSync('# app\nname: my_app\nversion: 1.0.0\n');
      expect(projectNameOf(p.path), 'my_app');
    });
  });

  group('SessionRegistry', () {
    test('write, read back, json round trip', () {
      final reg = SessionRegistry(dir: Directory('${tmp.path}/sessions'));
      final e = entry('/work/app', port: 4580, pid: 42)
          .withDevice(deviceId: 'emulator-5554', deviceName: 'Pixel', platform: 'android');
      reg.write(e);
      final back = reg.all().single;
      expect(back.id, e.id);
      expect(back.port, 4580);
      expect(back.deviceName, 'Pixel');
      expect(back.platform, 'android');
      expect(back.toJson()['device'], {'id': 'emulator-5554', 'name': 'Pixel', 'platform': 'android'});
      expect(back.toJson()['dashboard'], 'http://127.0.0.1:4580');
      expect(back.toJson(), isNot(contains('token')));
    });

    test('remove only by the owning pid', () {
      final reg = SessionRegistry(dir: Directory('${tmp.path}/sessions'));
      final e = entry('/work/app', pid: 42);
      reg.write(e);
      reg.remove(e.id, 7); // a newer session of the project replaced it? not this pid
      expect(reg.all(), hasLength(1));
      reg.remove(e.id, 42);
      expect(reg.all(), isEmpty);
    });

    test('live drops dead servers and sorts newest first', () async {
      final now = DateTime.now();
      final reg = SessionRegistry(
        dir: Directory('${tmp.path}/sessions'),
        isAlive: (e) async => e.pid != 2,
      );
      reg.write(entry('/a', pid: 1, startedAt: now.subtract(const Duration(hours: 1))));
      reg.write(entry('/b', pid: 2));
      reg.write(entry('/c', pid: 3, startedAt: now));
      final live = await reg.live();
      expect(live.map((e) => e.project), ['/c', '/a']);
      expect(reg.all().map((e) => e.project), unorderedEquals(['/a', '/c']));
    });

    test('ignores junk files and a missing dir', () async {
      final dir = Directory('${tmp.path}/sessions');
      expect(SessionRegistry(dir: dir).all(), isEmpty);
      dir.createSync();
      File('${dir.path}/x.json').writeAsStringSync('{nope');
      File('${dir.path}/y.txt').writeAsStringSync('hi');
      expect(SessionRegistry(dir: dir).all(), isEmpty);
    });
  });

  group('matchSessions', () {
    final live = [
      entry('/work/app'),
      entry('/work2/app'),
      entry('/work/other'),
    ];
    test('by id, path, then name', () {
      expect(matchSessions(live, sessionIdFor('/work/other')).single.project, '/work/other');
      expect(matchSessions(live, '/work2/app').single.project, '/work2/app');
      expect(matchSessions(live, '/work2/app/').single.project, '/work2/app');
      expect(matchSessions(live, 'other').single.project, '/work/other');
      expect(matchSessions(live, 'app'), hasLength(2)); // ambiguous name
      expect(matchSessions(live, 'nope'), isEmpty);
    });
  });

  group('RecentProjects', () {
    test('records newest first, one per project, remembers the port', () {
      final r = RecentProjects(file: File('${tmp.path}/projects.json'));
      expect(r.lastPort('/a'), isNull);
      r.record('/a', port: 4577, name: 'a');
      r.record('/b', port: 4578, name: 'b');
      r.record('/a', port: 4581, name: 'a');
      expect(r.list().map((p) => p['project']), ['/a', '/b']);
      expect(r.lastPort('/a'), 4581);
      expect(r.lastPort('/b'), 4578);
      final raw = jsonDecode(File('${tmp.path}/projects.json').readAsStringSync()) as Map;
      expect((raw['projects'] as List).first['lastStartedAt'], isA<String>());
    });

    test('keeps at most ${RecentProjects.max}', () {
      final r = RecentProjects(file: File('${tmp.path}/projects.json'));
      for (var i = 0; i < RecentProjects.max + 5; i++) {
        r.record('/p$i', port: 4577, name: 'p$i');
      }
      expect(r.list(), hasLength(RecentProjects.max));
      expect(r.list().first['project'], '/p${RecentProjects.max + 4}');
    });

    test('a broken file reads as empty', () {
      final f = File('${tmp.path}/projects.json')..writeAsStringSync('[');
      expect(RecentProjects(file: f).list(), isEmpty);
    });
  });

  group('pickSessionPort', () {
    Future<bool> Function(int) freeExcept(Set<int> taken) => (p) async => !taken.contains(p);

    test('the last port when it is free', () async {
      expect(await pickSessionPort(lastPort: 4583, isFree: freeExcept({})), 4583);
    });

    test('first free from start when the last one is taken', () async {
      expect(await pickSessionPort(lastPort: 4583, isFree: freeExcept({4583, 4577})), 4578);
      expect(await pickSessionPort(isFree: freeExcept({4577, 4578})), 4579);
    });

    test('with mocks, the mock ports must be free too', () async {
      // 4577's mock ports (4590/4591) are taken by another session's mock server.
      expect(await pickSessionPort(mockOffset: 13, isFree: freeExcept({4591})), 4579);
      // 4578 → 4591 taken; 4579 → 4592/4593 free.
      expect(await pickSessionPort(lastPort: 4578, mockOffset: 13, isFree: freeExcept({4591})), 4579);
    });

    test('no upper bound', () async {
      final taken = {for (var p = 4577; p < 4620; p++) p};
      expect(await pickSessionPort(isFree: freeExcept(taken)), 4620);
    });

    test('portIsFree sees a bound port', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port; // reading it after close can throw
      expect(await portIsFree(port), isFalse);
      await s.close();
      expect(await _freeSoon(port), isTrue);
    });
  });
}

/// Whether [portIsFree] sees [port] free within [within]. A process that
/// another test file starts holds this process's listening sockets from fork
/// until exec, so a port just closed can still be bound for a moment.
Future<bool> _freeSoon(int port, {Duration within = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(within);
  while (!await portIsFree(port)) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return true;
}
