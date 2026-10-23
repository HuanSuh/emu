/// Machine-wide list of running emu sessions, so `emu ls` (and the hub, see
/// `docs/HUB.md`) can find every session without knowing its project.
///
/// - `~/.emu/sessions/<id>.json` — one file per running server, written once
///   it is bound and again when its device is known, removed on shutdown. A
///   server that died without cleaning up is dropped by the next reader
///   ([SessionRegistry.live]). No session token in here: that stays in the
///   project's `.emu/server.json`.
/// - `~/.emu/projects.json` — recently started projects and the port each
///   last used, so a project gets the same dashboard origin (and with it the
///   layout the browser remembered) when it comes back.
library;

import 'dart:convert';
import 'dart:io';

import 'device_lease.dart';

/// Stable id for a project root: 12 hex digits of its 64-bit FNV-1a hash.
String sessionIdFor(String projectRoot) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(projectRoot)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (h >>> 16).toRadixString(16).padLeft(12, '0'); // top 48 bits, unsigned
}

/// The `name:` of the project's pubspec, else the directory name.
String projectNameOf(String projectRoot) {
  try {
    final text = File('$projectRoot/pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true).firstMatch(text);
    if (m != null) return m.group(1)!;
  } on FileSystemException {
    // Fall through.
  }
  return projectRoot.split(Platform.pathSeparator).lastWhere((s) => s.isNotEmpty, orElse: () => projectRoot);
}

class SessionEntry {
  SessionEntry({
    required this.project,
    required this.port,
    required this.pid,
    String? id,
    String? name,
    this.deviceId,
    this.deviceName,
    this.platform,
    this.mockPort,
    this.emuVersion,
    DateTime? startedAt,
  })  : id = id ?? sessionIdFor(project),
        name = name ?? projectNameOf(project),
        startedAt = startedAt ?? DateTime.now();

  final String id;
  final String project;
  final String name;
  final int port;
  final int pid;
  final String? deviceId;
  final String? deviceName;
  final String? platform;
  final int? mockPort;
  final String? emuVersion;
  final DateTime startedAt;

  String get dashboard => 'http://127.0.0.1:$port';

  SessionEntry withDevice({String? deviceId, String? deviceName, String? platform}) => SessionEntry(
        id: id,
        project: project,
        name: name,
        port: port,
        pid: pid,
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        platform: platform ?? this.platform,
        mockPort: mockPort,
        emuVersion: emuVersion,
        startedAt: startedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'project': project,
        'name': name,
        'port': port,
        'pid': pid,
        'dashboard': dashboard,
        if (deviceId != null)
          'device': {'id': deviceId, 'name': ?deviceName, 'platform': ?platform},
        'mockPort': ?mockPort,
        'emuVersion': ?emuVersion,
        'startedAt': startedAt.toIso8601String(),
      };

  static SessionEntry? tryParse(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      final device = m['device'] as Map<String, dynamic>?;
      return SessionEntry(
        id: m['id'] as String,
        project: m['project'] as String,
        name: m['name'] as String?,
        port: m['port'] as int,
        pid: m['pid'] as int,
        deviceId: device?['id'] as String?,
        deviceName: device?['name'] as String?,
        platform: device?['platform'] as String?,
        mockPort: m['mockPort'] as int?,
        emuVersion: m['emuVersion'] as String?,
        startedAt: DateTime.tryParse(m['startedAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Whether the server at [pid]/[port] is still alive.
typedef SessionLiveness = Future<bool> Function(SessionEntry entry);

Future<bool> _serverAlive(SessionEntry e) => serverAliveAt(e.pid, e.port);

Directory _emuHome() => Directory('${Platform.environment['HOME'] ?? '.'}/.emu');

/// Write [text] to [file] through a temp file + rename, so a reader never
/// sees half of it.
void _writeAtomic(File file, String text) {
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.$pid.tmp');
  try {
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
  } catch (_) {
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Never written.
    }
    rethrow;
  }
}

class SessionRegistry {
  SessionRegistry({Directory? dir, SessionLiveness? isAlive})
      : dir = dir ?? Directory('${_emuHome().path}/sessions'),
        _isAlive = isAlive ?? _serverAlive;

  final Directory dir;
  final SessionLiveness _isAlive;

  File _file(String id) => File('${dir.path}/$id.json');

  void write(SessionEntry e) => _writeAtomic(_file(e.id), jsonEncode(e.toJson()));

  /// Remove [id]'s entry only if the server [ownerPid] wrote it — a later
  /// session of the same project may already have replaced it.
  void remove(String id, int ownerPid) {
    final f = _file(id);
    final e = _read(f);
    if (e != null && e.pid == ownerPid) _delete(f);
  }

  /// Every recorded entry, alive or not.
  List<SessionEntry> all() {
    if (!dir.existsSync()) return [];
    return [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.json')) ?_read(f),
    ];
  }

  /// Entries whose server still answers, most recently started first. Dead
  /// ones are deleted (when unchanged since read, so a racing write survives).
  Future<List<SessionEntry>> live() async {
    final out = <SessionEntry>[];
    final entries = all();
    final alive = await Future.wait(entries.map(_isAlive));
    for (var i = 0; i < entries.length; i++) {
      if (alive[i]) {
        out.add(entries[i]);
      } else {
        final f = _file(entries[i].id);
        if (_read(f)?.pid == entries[i].pid) _delete(f);
      }
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  static SessionEntry? _read(File f) {
    try {
      return SessionEntry.tryParse(f.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  static void _delete(File f) {
    try {
      f.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// `~/.emu/projects.json`: recently started projects, newest first.
class RecentProjects {
  RecentProjects({File? file}) : file = file ?? File('${_emuHome().path}/projects.json');

  final File file;
  static const max = 20;

  List<Map<String, dynamic>> list() {
    try {
      final m = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return [for (final p in m['projects'] as List) Map<String, dynamic>.from(p as Map)];
    } catch (_) {
      return [];
    }
  }

  /// The port [project] last ran on.
  int? lastPort(String project) {
    for (final p in list()) {
      if (p['project'] == project) return p['port'] as int?;
    }
    return null;
  }

  void record(String project, {required int port, String? name}) {
    final rest = list().where((p) => p['project'] != project);
    final entry = {
      'project': project,
      'name': name ?? projectNameOf(project),
      'port': port,
      'lastStartedAt': DateTime.now().toIso8601String(),
    };
    try {
      _writeAtomic(file, jsonEncode({'projects': [entry, ...rest].take(max).toList()}));
    } on FileSystemException {
      // Only a convenience — never fail a start over it.
    }
  }
}

/// First dashboard port for a session that didn't ask for one: the port the
/// project last used, else the first one up from [start]. With [mockOffset]
/// (the mock server's `port + 13`, and `+ 14` for http) those must be free too.
Future<int> pickSessionPort({
  int? lastPort,
  int start = 4577,
  int? mockOffset,
  Future<bool> Function(int port) isFree = portIsFree,
  int tries = 200,
}) async {
  Future<bool> fits(int p) async =>
      await isFree(p) &&
      (mockOffset == null || (await isFree(p + mockOffset) && await isFree(p + mockOffset + 1)));
  if (lastPort != null && await fits(lastPort)) return lastPort;
  for (var p = start; p < start + tries; p++) {
    if (p == lastPort) continue;
    if (await fits(p)) return p;
  }
  return start; // Everything taken: let the server's own bind fallback decide.
}

/// Whether nothing listens on loopback [port] (what the session server binds).
Future<bool> portIsFree(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Sessions [query] names: its id, its project path (absolute, or relative to
/// the cwd), or its name — a name may match several.
List<SessionEntry> matchSessions(List<SessionEntry> live, String query) {
  final byId = live.where((e) => e.id == query).toList();
  if (byId.isNotEmpty) return byId;
  final path = Directory(query).absolute.path.replaceFirst(RegExp(r'/+$'), '');
  final byPath = live.where((e) => e.project == path || e.project == query).toList();
  if (byPath.isNotEmpty) return byPath;
  return live.where((e) => e.name == query).toList();
}
