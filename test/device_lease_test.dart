import 'dart:io';

import 'package:emu/src/device_lease.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  // Pids the fake liveness check reports as alive.
  late Set<int> alive;
  late DeviceLeases leases;

  DeviceLease lease(int pid, {String project = '/a', String device = 'emulator-5554'}) =>
      DeviceLease(deviceId: device, pid: pid, port: 4577, project: project);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('emu_lease_test');
    alive = {};
    leases = DeviceLeases(dir: dir, isAlive: (l) async => alive.contains(l.pid));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('free device is acquired and recorded', () async {
    final r = await leases.acquire(lease(1));
    expect(r.acquired, isTrue);
    expect(leases.holderOf('emulator-5554')!.pid, 1);
  });

  test('re-acquiring our own lease is idempotent', () async {
    await leases.acquire(lease(1));
    alive.add(1);
    expect((await leases.acquire(lease(1))).acquired, isTrue);
  });

  test('live holder from another project blocks, and is reported', () async {
    await leases.acquire(lease(1, project: '/a'));
    alive.add(1);
    final r = await leases.acquire(lease(2, project: '/b'));
    expect(r.acquired, isFalse);
    expect(r.holder!.project, '/a');
    expect(leases.holderOf('emulator-5554')!.pid, 1, reason: 'holder untouched');
  });

  test('dead holder is reclaimed', () async {
    await leases.acquire(lease(1, project: '/a'));
    final r = await leases.acquire(lease(2, project: '/b'));
    expect(r.acquired, isTrue);
    expect(leases.holderOf('emulator-5554')!.pid, 2);
  });

  test('same project previous session is reclaimed even if still alive', () async {
    // `up` just shut down this project's ghost server; it may not have exited yet.
    await leases.acquire(lease(1, project: '/a'));
    alive.add(1);
    final r = await leases.acquire(lease(2, project: '/a'));
    expect(r.acquired, isTrue);
    expect(leases.holderOf('emulator-5554')!.pid, 2);
  });

  test('unparseable lease file is treated as stale', () async {
    File('${dir.path}/emulator-5554.json').writeAsStringSync('{garbage');
    expect((await leases.acquire(lease(2))).acquired, isTrue);
  });

  test('different devices are independent', () async {
    await leases.acquire(lease(1, project: '/a', device: 'emulator-5554'));
    alive.add(1);
    final r = await leases.acquire(lease(2, project: '/b', device: 'emulator-5556'));
    expect(r.acquired, isTrue);
  });

  test('release only removes the lease when the pid owns it', () async {
    await leases.acquire(lease(1));
    leases.release('emulator-5554', 2);
    expect(leases.holderOf('emulator-5554'), isNotNull);
    leases.release('emulator-5554', 1);
    expect(leases.holderOf('emulator-5554'), isNull);
  });

  test('liveHolderOf hides dead holders', () async {
    await leases.acquire(lease(1));
    expect(await leases.liveHolderOf('emulator-5554'), isNull);
    alive.add(1);
    expect((await leases.liveHolderOf('emulator-5554'))!.pid, 1);
  });

  test('leaseFileName makes wireless adb serials and UUIDs file-safe', () {
    expect(leaseFileName('192.168.0.5:5555'), '192.168.0.5_5555.json');
    expect(leaseFileName('A1B2C3D4-1234-5678-9ABC-DEF012345678'),
        'A1B2C3D4-1234-5678-9ABC-DEF012345678.json');
  });

  test('conflict message names the holder and the ways out', () {
    final msg = leaseConflictMessage('emulator-5554', lease(1, project: '/wt/b'));
    expect(msg, contains('/wt/b'));
    expect(msg, contains('http://127.0.0.1:4577'));
    expect(msg, contains('--share-device'));
  });

  test('default liveness: dead pid is not alive', () async {
    // Spawn and reap a short-lived process so its pid is (almost surely) free.
    final p = await Process.start('true', []);
    await p.exitCode;
    expect(await serverAlive(lease(p.pid)), isFalse);
  });

  test('default liveness: live pid without a server on the port is not alive', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close(); // Nothing listens on `port` now.
    final l = DeviceLease(deviceId: 'x', pid: pid, port: port, project: '/a');
    expect(await serverAlive(l), isFalse);
  });

  test('default liveness: live pid with a server answering is alive', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((r) => r.response
      ..statusCode = 200
      ..close());
    final l = DeviceLease(deviceId: 'x', pid: pid, port: http.port, project: '/a');
    expect(await serverAlive(l), isTrue);
    await http.close(force: true);
  });
}
