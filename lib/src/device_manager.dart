/// Device discovery and emulator/simulator boot.
///
/// Booting is best-effort and platform-gated: Android via the SDK `emulator` +
/// `adb`, iOS via `xcrun simctl` (macOS only). Parsing is split out as a pure
/// function so it can be unit-tested against fixtures.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'env.dart';
import 'models.dart';

/// Parse the JSON emitted by `flutter devices --machine` into [DeviceInfo]s.
/// Pure (no IO) for testability.
List<DeviceInfo> parseFlutterDevices(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! List) return const [];
  return decoded.whereType<Map>().map((raw) {
    final m = raw.cast<String, dynamic>();
    final target = m['targetPlatform'] as String?;
    return DeviceInfo(
      id: m['id'] as String,
      name: (m['name'] as String?) ?? m['id'] as String,
      platform: _platform(m['platformType'] as String?, target),
      emulator: (m['emulator'] as bool?) ?? false,
      targetPlatform: target,
    );
  }).toList();
}

String _platform(String? platformType, String? target) {
  if (platformType != null && platformType.isNotEmpty) return platformType;
  if (target == null) return 'unknown';
  if (target.startsWith('android')) return 'android';
  if (target.startsWith('ios')) return 'ios';
  if (target.startsWith('darwin')) return 'macos';
  return target;
}

class DeviceException implements Exception {
  DeviceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DeviceManager {
  DeviceManager({this.flutterExecutable = 'flutter'});

  final String flutterExecutable;

  bool get isMacOS => Platform.isMacOS;

  /// List devices known to Flutter (connected/booted/wireless).
  Future<List<DeviceInfo>> listDevices() async {
    final res = await Process.run(flutterExecutable, ['devices', '--machine']);
    if (res.exitCode != 0) {
      throw DeviceException('flutter devices failed: ${res.stderr}');
    }
    final out = (res.stdout as String).trim();
    // `flutter devices --machine` may print a banner before the JSON array.
    final start = out.indexOf('[');
    if (start < 0) return const [];
    return parseFlutterDevices(out.substring(start));
  }

  /// Names of installed Android AVDs (`emulator -list-avds`).
  Future<List<String>> listAndroidAvds() async {
    if (!await _hasCommand('emulator')) return const [];
    final res = await Process.run('emulator', ['-list-avds']);
    if (res.exitCode != 0) return const [];
    return (res.stdout as String).split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  /// Serials of running Android emulators (`adb devices`), in adb's order.
  Future<List<String>> _runningAndroidEmulators() async {
    if (!await _hasCommand('adb')) return const [];
    final res = await Process.run('adb', ['devices']);
    if (res.exitCode != 0) return const [];
    return parseAdbEmulators(res.stdout as String);
  }

  /// AVD name behind a running emulator serial (`adb -s <serial> emu avd name`).
  Future<String?> _avdNameOf(String serial) async {
    final res = await Process.run('adb', ['-s', serial, 'emu', 'avd', 'name']);
    if (res.exitCode != 0) return null;
    final name = (res.stdout as String).split('\n').first.trim();
    return name.isEmpty || name == 'OK' ? null : name;
  }

  /// Pick an Android emulator: reuse the first running one [claim] accepts,
  /// otherwise boot an AVD that isn't already running and claim that.
  /// [claim] reserves the device for this session (see `device_lease.dart`)
  /// and returns false when another session holds it. Returns the device id.
  Future<String> bootAndroid({
    String? avd,
    Future<bool> Function(String deviceId)? claim,
    void Function(String)? onProgress,
  }) async {
    final take = claim ?? (_) async => true;
    final running = await _runningAndroidEmulators();
    for (final serial in running) {
      if (await take(serial)) {
        onProgress?.call('Android emulator already running: $serial');
        return serial;
      }
      onProgress?.call('Android emulator $serial is in use by another emu session — skipping');
    }
    if (!await _hasCommand('emulator')) {
      throw DeviceException('Android SDK `emulator` not found on PATH.');
    }
    if (!await _hasCommand('adb')) {
      throw DeviceException('`adb` not found on PATH.');
    }
    final avds = await listAndroidAvds();
    final runningAvds = <String>[
      for (final serial in running) ?(await _avdNameOf(serial)),
    ];
    final target = avd ?? chooseAvdToBoot(avds, runningAvds);
    if (target == null) {
      throw DeviceException(avds.isEmpty
          ? 'No Android AVD found. Create one in Android Studio Device Manager.'
          : 'Every Android emulator is in use by another emu session and no other '
              'AVD is left to boot. Create another AVD, run `emu down` in the other '
              'project, or pass --share-device.');
    }
    onProgress?.call('booting Android AVD: $target');
    // The emulator binary locates its Qt/qemu libs relative to its own
    // directory, so it must be launched by absolute path AND with that
    // directory as the working dir — otherwise it fails with
    // "Qt library not found" when started from an arbitrary cwd.
    final emuPath = await _resolvePath('emulator') ?? 'emulator';
    final emuDir = emuPath.contains('/')
        ? emuPath.substring(0, emuPath.lastIndexOf('/'))
        : null;
    // Detached so the emulator outlives this process.
    await Process.start(
      emuPath,
      ['@$target', '-no-snapshot-save'],
      mode: ProcessStartMode.detached,
      workingDirectory: emuDir,
    );
    onProgress?.call('waiting for Android boot to complete...');
    // Other emulators may already be running, so identify ours as the serial
    // that wasn't there before the boot.
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final fresh = (await _runningAndroidEmulators()).where((s) => !running.contains(s));
      for (final serial in fresh) {
        final res = await Process.run(
            'adb', ['-s', serial, 'shell', 'getprop', 'sys.boot_completed']);
        if ((res.stdout as String).trim() != '1') continue;
        if (await take(serial)) return serial;
        throw DeviceException('booted $serial but another emu session claimed it first.');
      }
    }
    throw DeviceException('Timed out waiting for Android emulator to boot.');
  }

  /// Pick an iOS simulator: an explicit [udid] (claimed, then booted if
  /// needed), else the first booted one [claim] accepts, else a shut-down
  /// iPhone claimed before booting. Returns its udid. macOS only.
  Future<String> bootIos({
    String? udid,
    Future<bool> Function(String deviceId)? claim,
    void Function(String)? onProgress,
  }) async {
    if (!isMacOS) throw DeviceException('iOS simulators are macOS-only.');
    if (!await _hasCommand('xcrun')) {
      throw DeviceException('`xcrun` not found. Install Xcode command line tools.');
    }
    final take = claim ?? (_) async => true;
    final list = await _xcrun(['simctl', 'list', 'devices', '-j']);
    if (list.exitCode != 0) {
      throw DeviceException(
          'xcrun simctl failed (is full Xcode installed and selected?): ${list.stderr}');
    }
    final sims = parseSimctlDevices(list.stdout as String);

    String? chosen;
    if (udid != null) {
      if (!await take(udid)) {
        throw DeviceException('simulator $udid is in use by another emu session.');
      }
      chosen = udid;
    } else {
      for (final s in sims.where((s) => s.booted)) {
        if (await take(s.udid)) {
          onProgress?.call('iOS simulator already booted: ${s.udid}');
          _openSimulatorApp();
          return s.udid;
        }
        onProgress?.call('iOS simulator ${s.udid} is in use by another emu session — skipping');
      }
      for (final s in sims.where((s) => !s.booted && s.name.contains('iPhone'))) {
        if (await take(s.udid)) {
          chosen = s.udid;
          break;
        }
      }
    }
    if (chosen == null) {
      throw DeviceException(sims.any((s) => s.name.contains('iPhone'))
          ? 'Every iPhone simulator is in use by another emu session. Run `emu down` '
              'in the other project, pass --device <udid>, or pass --share-device.'
          : 'No available iPhone simulator found (check Xcode > Settings > Platforms).');
    }
    onProgress?.call('booting iOS simulator: $chosen');
    final boot = await _xcrun(['simctl', 'boot', chosen]);
    // "Unable to boot device in current state: Booted" is fine.
    if (boot.exitCode != 0 && !'${boot.stderr}'.contains('Booted')) {
      throw DeviceException('Failed to boot iOS simulator: ${boot.stderr}');
    }
    _openSimulatorApp();
    await _xcrun(['simctl', 'bootstatus', chosen, '-b']);
    return chosen;
  }

  void _openSimulatorApp() {
    if (isMacOS) {
      unawaited(Process.run('open', ['-a', 'Simulator']));
    }
  }

  /// Power off one device (best-effort). Only emulators/simulators can be
  /// powered off; returns false for a physical device.
  Future<bool> shutdownDevice(String deviceId) async {
    if (platformForDeviceId(deviceId) == 'ios') {
      if (!isMacOS) return false;
      final res = await _xcrun(['simctl', 'shutdown', deviceId]);
      return res.exitCode == 0;
    }
    if (!deviceId.startsWith('emulator-')) return false;
    final res = await Process.run('adb', ['-s', deviceId, 'emu', 'kill']);
    return res.exitCode == 0;
  }

  /// Capture a screenshot to [outPath]. Picks adb or simctl by platform.
  Future<void> screenshot(String outPath, {required String platform, String? udid}) async {
    if (platform == 'ios' && isMacOS) {
      final res = await _xcrun(['simctl', 'io', udid ?? 'booted', 'screenshot', outPath]);
      if (res.exitCode != 0) throw DeviceException('screenshot failed: ${res.stderr}');
    } else {
      // stdoutEncoding: null keeps the PNG bytes raw (default would decode to a
      // String and corrupt the image).
      final res = await Process.run('adb', [..._serial(udid), 'exec-out', 'screencap', '-p'],
          stdoutEncoding: null);
      if (res.exitCode != 0) throw DeviceException('screenshot failed: ${res.stderr}');
      await File(outPath).writeAsBytes(res.stdout as List<int>);
    }
  }

  /// `-s <serial>` so commands hit the intended device when several are attached.
  List<String> _serial(String? udid) =>
      (udid == null || udid.isEmpty) ? const [] : ['-s', udid];

  /// Run `xcrun` with a sanitized environment (stale SDKROOT/DEVELOPER_DIR
  /// removed) so simctl works even when the shell points at a deleted Xcode.
  Future<ProcessResult> _xcrun(List<String> args, {Encoding? stdoutEncoding}) =>
      Process.run('xcrun', args,
          environment: spawnEnvironment(),
          includeParentEnvironment: false,
          stdoutEncoding: stdoutEncoding ?? systemEncoding);

  Future<bool> _hasCommand(String cmd) async => (await _resolvePath(cmd)) != null;

  /// Full path of a command via `which`, or null if not found.
  Future<String?> _resolvePath(String cmd) async {
    try {
      final res = await Process.run('which', [cmd]);
      if (res.exitCode != 0) return null;
      final path = (res.stdout as String).trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }
}

final _iosUdid = RegExp(
    r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
    caseSensitive: false);

/// Which toolchain drives [deviceId]: iOS simulators are identified by a UUID,
/// everything else (`emulator-5554`, or a physical serial like `R5CT30ABCDE`)
/// is Android. Unknown ids fall back to Android, the only platform whose
/// input/screenshot path works without a UDID.
String platformForDeviceId(String? deviceId) =>
    _iosUdid.hasMatch(deviceId ?? '') ? 'ios' : 'android';

/// Pick which AVD `--android` boots when the user didn't name one. Blindly
/// taking the alphabetically-first AVD once booted a foldable (`Galaxy_Z_Flip`)
/// that failed to launch. Prefer Google's reference phone images (Pixel/gphone/
/// Nexus), which are the most reliable under the emulator, and avoid non-phone
/// form factors (wear/tv/automotive/foldables/tablets). Ties keep list order.
String? preferredAvd(List<String> avds) {
  if (avds.isEmpty) return null;
  var best = avds.first;
  var bestScore = _avdScore(best);
  for (final a in avds.skip(1)) {
    final s = _avdScore(a);
    if (s > bestScore) {
      best = a;
      bestScore = s;
    }
  }
  return best;
}

int _avdScore(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'wear|_tv_|androidtv|automotive|foldable|fold|flip|tablet').hasMatch(n)) {
    return -1;
  }
  if (RegExp(r'pixel|gphone|nexus').hasMatch(n)) return 2;
  return 1;
}

/// Running emulator serials from `adb devices` output (physical devices and
/// offline/unauthorized entries are ignored).
List<String> parseAdbEmulators(String adbDevicesOutput) => [
      for (final line in adbDevicesOutput.split('\n'))
        if (line.trim().startsWith('emulator-') && line.trim().endsWith('device'))
          line.trim().split(RegExp(r'\s+')).first,
    ];

/// The AVD to boot when every running emulator is taken: the preferred one
/// among those not already running (an AVD can only run once).
String? chooseAvdToBoot(List<String> avds, List<String> runningAvds) =>
    preferredAvd(avds.where((a) => !runningAvds.contains(a)).toList());

class SimulatorInfo {
  SimulatorInfo({required this.udid, required this.name, required this.booted});
  final String udid;
  final String name;
  final bool booted;
}

/// Available simulators from `xcrun simctl list devices -j`, in listing order.
List<SimulatorInfo> parseSimctlDevices(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final devices = (data['devices'] as Map).cast<String, dynamic>();
  return [
    for (final runtime in devices.values)
      for (final d in (runtime as List).cast<Map>())
        if ((d['isAvailable'] as bool?) ?? false)
          SimulatorInfo(
            udid: d['udid'] as String,
            name: (d['name'] as String?) ?? '',
            booted: d['state'] == 'Booted',
          ),
  ];
}
