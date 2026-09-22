/// Machine-wide device leases: one emu server owns a device at a time, across
/// projects and worktrees. A lease is a small JSON file under
/// `~/.emu/devices/` naming the owning server (pid + port + project). See
/// `docs/DEVICE_LEASE.md`.
library;

import 'dart:convert';
import 'dart:io';

class DeviceLease {
  DeviceLease({
    required this.deviceId,
    required this.pid,
    required this.port,
    required this.project,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String deviceId;

  /// The owning emu server process.
  final int pid;

  /// The owning server's HTTP port (for the liveness ping and the dashboard hint).
  final int port;
  final String project;
  final DateTime startedAt;

  String get dashboard => 'http://127.0.0.1:$port';

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'pid': pid,
        'port': port,
        'project': project,
        'startedAt': startedAt.toIso8601String(),
      };

  static DeviceLease? tryParse(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      return DeviceLease(
        deviceId: m['deviceId'] as String,
        pid: m['pid'] as int,
        port: m['port'] as int,
        project: m['project'] as String,
        startedAt: DateTime.tryParse(m['startedAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Outcome of [DeviceLeases.acquire]: either acquired, or held by a live [holder].
class LeaseResult {
  LeaseResult.acquired() : holder = null;
  LeaseResult.conflict(DeviceLease this.holder);

  /// The live lease that blocked us; null when acquired.
  final DeviceLease? holder;
  bool get acquired => holder == null;
}

/// Whether the server that wrote [lease] is still alive.
typedef LeaseLiveness = Future<bool> Function(DeviceLease lease);

/// File-safe name for a device id (`emulator-5554`, a simulator UUID, or a
/// physical serial that may contain `:` for wireless adb).
String leaseFileName(String deviceId) =>
    '${deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

class DeviceLeases {
  DeviceLeases({Directory? dir, LeaseLiveness? isAlive})
      : dir = dir ?? defaultDir(),
        _isAlive = isAlive ?? serverAlive;

  final Directory dir;
  final LeaseLiveness _isAlive;

  /// `$HOME/.emu/devices` — machine-wide so separate projects/worktrees see
  /// each other's leases.
  static Directory defaultDir() =>
      Directory('${Platform.environment['HOME'] ?? '.'}/.emu/devices');

  File _file(String deviceId) => File('${dir.path}/${leaseFileName(deviceId)}');

  /// Claim [lease.deviceId] for [lease]'s server. Succeeds when the device is
  /// free, already ours (same pid), held by a previous session of the same
  /// project (the one `up` just reclaimed), or held by a dead server.
  Future<LeaseResult> acquire(DeviceLease lease) async {
    dir.createSync(recursive: true);
    final file = _file(lease.deviceId);
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        file.createSync(exclusive: true);
        file.writeAsStringSync(jsonEncode(lease.toJson()), flush: true);
        return LeaseResult.acquired();
      } on FileSystemException {
        // Exists — inspect the holder below.
      }
      final text = _readOrNull(file);
      if (text == null) continue; // Released between our create and read.
      if (text.isEmpty) {
        // Another server created it and hasn't written yet — don't mistake
        // that for a stale lease.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      final holder = DeviceLease.tryParse(text);
      if (holder != null) {
        if (holder.pid == lease.pid) {
          file.writeAsStringSync(jsonEncode(lease.toJson()), flush: true);
          return LeaseResult.acquired();
        }
        if (holder.project != lease.project && await _isAlive(holder)) {
          return LeaseResult.conflict(holder);
        }
      }
      // Stale (dead, unparseable, or our own project's previous session).
      // Re-check the content is unchanged before deleting, so we don't remove
      // a lease a racing server wrote after we read it.
      if (_readOrNull(file) == text) _deleteQuietly(file);
    }
    final holder = holderOf(lease.deviceId);
    if (holder != null) return LeaseResult.conflict(holder);
    throw StateError('could not acquire the lease on ${lease.deviceId} (${file.path})');
  }

  /// Remove the lease on [deviceId] only if [ownerPid] holds it.
  void release(String deviceId, int ownerPid) {
    final file = _file(deviceId);
    final holder = DeviceLease.tryParse(_readOrNull(file) ?? '');
    if (holder != null && holder.pid == ownerPid) _deleteQuietly(file);
  }

  /// The recorded lease on [deviceId], alive or not.
  DeviceLease? holderOf(String deviceId) =>
      DeviceLease.tryParse(_readOrNull(_file(deviceId)) ?? '');

  /// The lease on [deviceId] if its server is still alive, else null.
  Future<DeviceLease?> liveHolderOf(String deviceId) async {
    final h = holderOf(deviceId);
    return (h != null && await _isAlive(h)) ? h : null;
  }

  static String? _readOrNull(File f) {
    try {
      return f.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  static void _deleteQuietly(File f) {
    try {
      f.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// Default liveness: the pid exists AND an emu server answers on the recorded
/// port. Either alone is fooled by reuse (a recycled pid, or another emu
/// server that later bound the same port).
Future<bool> serverAlive(DeviceLease lease) async {
  try {
    final kill = await Process.run('kill', ['-0', '${lease.pid}']);
    if (kill.exitCode != 0) return false;
  } catch (_) {
    return false;
  }
  final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
  try {
    final req = await client
        .getUrl(Uri.parse('${lease.dashboard}/api/status'))
        .timeout(const Duration(milliseconds: 800));
    final res = await req.close().timeout(const Duration(milliseconds: 800));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Human-readable conflict explanation for [holder] on [deviceId].
String leaseConflictMessage(String deviceId, DeviceLease holder) =>
    'device $deviceId is in use by another emu session\n'
    '  project: ${holder.project}   dashboard: ${holder.dashboard}\n'
    '  → pick another --device, run `emu down` in that project, or pass --share-device';
