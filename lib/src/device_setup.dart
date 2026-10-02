/// Per-session device preparation declared in `emu.yaml` (or `up` flags):
/// adb port mappings (`reversePorts`/`forwardPorts`) and shell hooks
/// (`onDeviceReady`/`onAppStarted`). Parsing and command building are pure so
/// they are unit-testable; [DeviceSetup] runs them against a device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One adb port mapping. [device] is the socket on the device/emulator,
/// [host] the one on this Mac — e.g. `adb reverse tcp:8000 tcp:8000` lets the
/// app reach `localhost:8000` on the Mac.
class PortMapping {
  const PortMapping(this.device, this.host);
  final String device;
  final String host;

  /// Round-trips through [parsePortMapping] (used for `__serve` args).
  String get spec => '$device:$host';

  @override
  bool operator ==(Object other) =>
      other is PortMapping && other.device == device && other.host == host;
  @override
  int get hashCode => Object.hash(device, host);
  @override
  String toString() => '$device → $host';
}

final _socket = RegExp(r'^[a-z]+:[^:\s]+$');

/// Parse one `reversePorts`/`forwardPorts` entry:
/// - `8000` → `tcp:8000` on both sides
/// - `"8000:9000"` → device `tcp:8000`, host `tcp:9000`
/// - `"tcp:8000:tcp:9000"` (any adb socket kinds, e.g. `localabstract:x:tcp:9000`)
/// Null when it is none of these.
PortMapping? parsePortMapping(Object? entry) {
  final s = '$entry'.trim();
  if (entry is int || RegExp(r'^\d+$').hasMatch(s)) {
    return _validPort(s) ? PortMapping('tcp:$s', 'tcp:$s') : null;
  }
  final pair = RegExp(r'^(\d+):(\d+)$').firstMatch(s);
  if (pair != null) {
    return _validPort(pair[1]!) && _validPort(pair[2]!)
        ? PortMapping('tcp:${pair[1]}', 'tcp:${pair[2]}')
        : null;
  }
  final parts = s.split(':');
  if (parts.length == 4) {
    final dev = '${parts[0]}:${parts[1]}';
    final host = '${parts[2]}:${parts[3]}';
    if (_socket.hasMatch(dev) && _socket.hasMatch(host)) return PortMapping(dev, host);
  }
  return null;
}

bool _validPort(String s) {
  final n = int.tryParse(s);
  return n != null && n > 0 && n < 65536;
}

/// `adb` argv applying [m] for [serial]: `reverse <device> <host>` makes the
/// device's socket reach the host's; `forward <host> <device>` the opposite.
List<String> adbMapArgs(String serial, PortMapping m, {required bool reverse}) => reverse
    ? ['-s', serial, 'reverse', m.device, m.host]
    : ['-s', serial, 'forward', m.host, m.device];

/// `adb` argv removing [m] again.
List<String> adbUnmapArgs(String serial, PortMapping m, {required bool reverse}) => reverse
    ? ['-s', serial, 'reverse', '--remove', m.device]
    : ['-s', serial, 'forward', '--remove', m.host];

/// Mappings currently active on [serial], from `adb reverse --list` /
/// `adb forward --list` output (`<serial> <local> <remote>` per line; for
/// reverse, local is the device side).
List<PortMapping> parseAdbMapList(String out, String serial, {required bool reverse}) => [
      for (final line in const LineSplitter().convert(out))
        if (line.trim().split(RegExp(r'\s+')) case [final s, final a, final b]
            when s == serial || reverse)
          reverse ? PortMapping(a, b) : PortMapping(b, a),
    ];

/// Environment for hook commands.
Map<String, String> hookEnvironment({
  required String deviceId,
  required String platform,
  required String projectRoot,
  String? appId,
}) =>
    {
      'EMU_DEVICE': deviceId,
      'EMU_PLATFORM': platform,
      'EMU_PROJECT': projectRoot,
      'EMU_APP_ID': ?appId,
    };

/// The installed app's id (Android `applicationId` / iOS bundle id) from the
/// build outputs under [projectRoot] — the newest one, so it matches the
/// build `flutter run` just installed. Null if none is found.
String? builtAppId(String projectRoot, String platform) {
  if (platform == 'android') {
    final dir = Directory('$projectRoot/build/app/outputs');
    if (!dir.existsSync()) return null;
    File? newest;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('output-metadata.json')) continue;
      if (newest == null || f.lastModifiedSync().isAfter(newest.lastModifiedSync())) newest = f;
    }
    if (newest == null) return null;
    try {
      return (jsonDecode(newest.readAsStringSync()) as Map)['applicationId'] as String?;
    } catch (_) {
      return null;
    }
  }
  final plist = File('$projectRoot/build/ios/iphonesimulator/Runner.app/Info.plist');
  if (!plist.existsSync()) return null;
  final r = Process.runSync('plutil', ['-extract', 'CFBundleIdentifier', 'raw', plist.path]);
  final id = '${r.stdout}'.trim();
  return r.exitCode == 0 && id.isNotEmpty ? id : null;
}

/// `adb [args]`, killed after [timeout] — a device vanishing mid-call can
/// hang adb, which would stall the watchdog for good. A timeout reads as a
/// failure (exit code -1).
Future<ProcessResult> runAdb(List<String> args,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final proc = await Process.start('adb', args);
  final out = StringBuffer(), err = StringBuffer();
  final drained = Future.wait([
    proc.stdout.transform(systemEncoding.decoder).forEach(out.write),
    proc.stderr.transform(systemEncoding.decoder).forEach(err.write),
  ]);
  final code = await proc.exitCode.timeout(timeout, onTimeout: () {
    proc.kill(ProcessSignal.sigkill);
    return -1;
  });
  await drained.timeout(const Duration(seconds: 2), onTimeout: () => const []);
  return ProcessResult(proc.pid, code, '$out', code == -1 ? 'adb timed out' : '$err');
}

/// Applies a session's port mappings and runs its hooks on one device.
class DeviceSetup {
  DeviceSetup({
    this.reversePorts = const [],
    this.forwardPorts = const [],
    this.onDeviceReady = const [],
    this.onAppStarted = const [],
    required this.projectRoot,
    required this.log,
  });

  final List<PortMapping> reversePorts;
  final List<PortMapping> forwardPorts;
  final List<String> onDeviceReady;
  final List<String> onAppStarted;
  final String projectRoot;

  /// `(message, isError)`.
  final void Function(String message, bool isError) log;

  bool get hasPorts => reversePorts.isNotEmpty || forwardPorts.isNotEmpty;

  /// Apply every mapping on Android [serial]. iOS simulators share the Mac's
  /// network, so there is nothing to map (logged once).
  Future<void> applyPorts(String serial, String platform) async {
    if (!hasPorts) return;
    if (platform != 'android') {
      log('reversePorts/forwardPorts ignored on $platform (the simulator shares the Mac\'s network)',
          false);
      return;
    }
    for (final (list, reverse) in [(reversePorts, true), (forwardPorts, false)]) {
      for (final m in list) {
        final r = await runAdb(adbMapArgs(serial, m, reverse: reverse));
        if (r.exitCode == 0) {
          log('adb ${reverse ? 'reverse' : 'forward'} $m', false);
        } else {
          log('adb ${reverse ? 'reverse' : 'forward'} $m failed: ${'${r.stderr}'.trim()}', true);
        }
      }
    }
  }

  /// Mappings that are declared but no longer active on [serial] (adb server
  /// restarted, emulator rebooted). Null when adb can't be asked.
  Future<List<(PortMapping, bool)>?> missingPorts(String serial) async {
    final missing = <(PortMapping, bool)>[];
    for (final (list, reverse) in [(reversePorts, true), (forwardPorts, false)]) {
      if (list.isEmpty) continue;
      final r = await runAdb(reverse ? ['-s', serial, 'reverse', '--list'] : ['forward', '--list']);
      if (r.exitCode != 0) return null;
      final active = parseAdbMapList('${r.stdout}', serial, reverse: reverse);
      missing.addAll([for (final m in list) if (!active.contains(m)) (m, reverse)]);
    }
    return missing;
  }

  /// Best-effort removal on `emu down`.
  Future<void> removePorts(String serial) async {
    for (final (list, reverse) in [(reversePorts, true), (forwardPorts, false)]) {
      for (final m in list) {
        await runAdb(adbUnmapArgs(serial, m, reverse: reverse), timeout: const Duration(seconds: 3));
      }
    }
  }

  /// Run [commands] (`sh -c`, project root as cwd) in order with
  /// `EMU_DEVICE`/`EMU_PLATFORM`/`EMU_PROJECT`/`EMU_APP_ID` set. A failing
  /// command is logged as an error (so it lands in `up`'s verdict) but does
  /// not stop the launch.
  Future<void> runHooks(String stage, List<String> commands,
      {required String deviceId, required String platform, String? appId}) async {
    final env = hookEnvironment(
        deviceId: deviceId, platform: platform, projectRoot: projectRoot, appId: appId);
    for (final cmd in commands) {
      log('hook $stage: $cmd', false);
      final proc = await Process.start('sh', ['-c', cmd],
          workingDirectory: projectRoot, environment: env);
      final out = StringBuffer();
      final drained = Future.wait([
        proc.stdout.transform(utf8.decoder).forEach(out.write),
        proc.stderr.transform(utf8.decoder).forEach(out.write),
      ]);
      final code = await proc.exitCode.timeout(const Duration(seconds: 120), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
      await drained.timeout(const Duration(seconds: 2), onTimeout: () => const []);
      final text = out.toString().trim();
      if (text.isNotEmpty) log(text, false);
      if (code == -1) {
        log('hook $stage timed out after 120s: $cmd', true);
      } else if (code != 0) {
        log('hook $stage failed (exit $code): $cmd', true);
      }
    }
  }
}
