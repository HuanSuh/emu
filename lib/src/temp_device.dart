/// Throwaway devices for `emu up --temp-device`: an AVD / simulator created
/// for one session and deleted by its `emu down`, so parallel sessions don't
/// leave 2–3GB devices behind. Each one is recorded under
/// `~/.emu/temp-devices/` with its owning server, so a device whose server
/// died without `down` can still be found and removed later.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'device_lease.dart';

class TempDevice {
  TempDevice({
    required this.platform,
    required this.name,
    this.udid,
    required this.ownerPid,
    required this.ownerPort,
    required this.project,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// `android` | `ios`.
  final String platform;

  /// AVD name (Android) or simulator name (iOS).
  final String name;

  /// Simulator udid (iOS only).
  final String? udid;

  /// The emu server that created it (liveness as for a [DeviceLease]).
  final int ownerPid;
  final int ownerPort;
  final String project;
  final DateTime createdAt;

  /// Registry key — unique per device.
  String get key => udid ?? name;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'name': name,
        if (udid != null) 'udid': udid,
        'ownerPid': ownerPid,
        'ownerPort': ownerPort,
        'project': project,
        'createdAt': createdAt.toIso8601String(),
      };

  static TempDevice? tryParse(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      return TempDevice(
        platform: m['platform'] as String,
        name: m['name'] as String,
        udid: m['udid'] as String?,
        ownerPid: m['ownerPid'] as int,
        ownerPort: m['ownerPort'] as int,
        project: m['project'] as String,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  /// The owner as a lease, to reuse [serverAlive].
  DeviceLease get ownerLease =>
      DeviceLease(deviceId: key, pid: ownerPid, port: ownerPort, project: project);
}

class TempDevices {
  TempDevices({Directory? dir, LeaseLiveness? isAlive})
      : dir = dir ?? defaultDir(),
        _isAlive = isAlive ?? serverAlive;

  final Directory dir;
  final LeaseLiveness _isAlive;

  /// `$HOME/.emu/temp-devices`.
  static Directory defaultDir() =>
      Directory('${Platform.environment['HOME'] ?? '.'}/.emu/temp-devices');

  File _file(String key) => File('${dir.path}/${leaseFileName(key)}');

  void record(TempDevice d) {
    dir.createSync(recursive: true);
    _file(d.key).writeAsStringSync(jsonEncode(d.toJson()), flush: true);
  }

  void forget(TempDevice d) {
    try {
      _file(d.key).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  List<TempDevice> all() {
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
        ?TempDevice.tryParse(_readOrEmpty(f)),
    ];
  }

  /// Devices created by the server with [pid].
  List<TempDevice> ownedBy(int pid) => all().where((d) => d.ownerPid == pid).toList();

  /// Devices whose creating server is gone (it died without `emu down`).
  Future<List<TempDevice>> orphans() async => [
        for (final d in all())
          if (!await _isAlive(d.ownerLease)) d,
      ];

  static String _readOrEmpty(File f) {
    try {
      return f.readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }
}

/// Name for a new temp device: `emu_tmp_<project>_<8 hex>`, restricted to the
/// characters AVD names allow (also used verbatim for simulators).
String tempDeviceName(String projectPath, {Random? random}) {
  final base = projectPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'app';
  final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final suffix = (random ?? Random()).nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return 'emu_tmp_${safe}_$suffix';
}

/// The `sdkmanager` package id of the system image a temp AVD is built from,
/// out of the installed images given as `android-<api>/<tag>/<abi>` paths
/// (relative to `$ANDROID_SDK/system-images`). Picks the host [abi], a phone
/// tag (Play Store > Google APIs > plain AOSP; no wear/tv/automotive/16k
/// variants), then the highest API level. Null when nothing fits.
String? chooseSystemImage(List<String> installed, String abi) {
  const tagScore = {'google_apis_playstore': 2, 'google_apis': 1, 'default': 0};
  final api = RegExp(r'^android-(\d+)(?:\.(\d+))?$');
  (String, int, int, int)? best;
  for (final path in installed) {
    final parts = path.split('/');
    if (parts.length != 3 || parts[2] != abi) continue;
    final m = api.firstMatch(parts[0]);
    final score = tagScore[parts[1]];
    if (m == null || score == null) continue;
    final major = int.parse(m.group(1)!);
    final minor = int.tryParse(m.group(2) ?? '') ?? 0;
    final c = best;
    if (c == null ||
        major > c.$2 ||
        (major == c.$2 && (minor > c.$3 || (minor == c.$3 && score > c.$4)))) {
      best = (path, major, minor, score);
    }
  }
  return best == null ? null : 'system-images;${best.$1.replaceAll('/', ';')}';
}

/// Hardware profile for a temp AVD out of `avdmanager list device -c`: the
/// newest plain Pixel phone (`pixel_7` over `pixel_7_pro`/`pixel_fold`/
/// `pixel_c`), else `pixel`. Null (let avdmanager default) when none — the
/// installed command-line tools may predate any given model.
String? chooseAvdDeviceProfile(List<String> profiles) {
  final plain = RegExp(r'^pixel_(\d+)$');
  String? best;
  var bestN = -1;
  for (final p in profiles) {
    final n = int.tryParse(plain.firstMatch(p.trim())?.group(1) ?? '');
    if (n != null && n > bestN) {
      best = p.trim();
      bestN = n;
    }
  }
  return best ?? (profiles.map((p) => p.trim()).contains('pixel') ? 'pixel' : null);
}

/// Emulator ABI matching this host.
String hostAndroidAbi() =>
    Platform.version.contains('arm64') ? 'arm64-v8a' : 'x86_64';

/// `(runtimeId, deviceTypeId)` for a temp simulator from
/// `xcrun simctl list runtimes -j`: the newest available iOS runtime and its
/// base iPhone model (`iPhone 17` over `iPhone 17 Pro`), else its first iPhone.
(String, String)? chooseIosSimSpec(String runtimesJson) {
  final List runtimes;
  try {
    runtimes = (jsonDecode(runtimesJson) as Map)['runtimes'] as List;
  } catch (_) {
    return null;
  }
  List<int> version(Map r) =>
      '${r['version']}'.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  int cmp(List<int> a, List<int> b) {
    for (var i = 0; i < max(a.length, b.length); i++) {
      final d = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  final ios = runtimes
      .whereType<Map>()
      .where((r) => r['isAvailable'] == true && '${r['identifier']}'.contains('SimRuntime.iOS'))
      .toList()
    ..sort((a, b) => cmp(version(b), version(a)));
  for (final r in ios) {
    final iphones = ((r['supportedDeviceTypes'] as List?) ?? const [])
        .whereType<Map>()
        .where((t) => '${t['name']}'.startsWith('iPhone'))
        .toList();
    if (iphones.isEmpty) continue;
    final base = iphones.firstWhere((t) => RegExp(r'^iPhone \d+$').hasMatch('${t['name']}'),
        orElse: () => iphones.first);
    return ('${r['identifier']}', '${base['identifier']}');
  }
  return null;
}
