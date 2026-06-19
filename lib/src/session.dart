/// Per-project session state: where the project root is, the `.emu/` state
/// directory, and the running server's coordinates (`.emu/server.json`).
library;

import 'dart:convert';
import 'dart:io';

class Session {
  Session(this.projectRoot)
      : stateDir = Directory('${projectRoot.path}/.emu');

  final Directory projectRoot;
  final Directory stateDir;

  File get logFile => File('${stateDir.path}/run.jsonl');
  File get serverInfoFile => File('${stateDir.path}/server.json');

  /// Walk up from [start] (default: cwd, or $EMU_PROJECT) looking for pubspec.yaml.
  static Session? find({String? start}) {
    var dir = Directory(start ?? Platform.environment['EMU_PROJECT'] ?? Directory.current.path)
        .absolute;
    while (true) {
      if (File('${dir.path}/pubspec.yaml').existsSync()) {
        return Session(dir);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Like [find] but throws a clear error when no Flutter project is found.
  static Session require({String? start}) {
    final s = find(start: start);
    if (s == null) {
      throw StateError(
          'No pubspec.yaml found. Run inside a Flutter project, or set EMU_PROJECT=/path/to/app.');
    }
    return s;
  }

  void ensureState() {
    if (!stateDir.existsSync()) stateDir.createSync(recursive: true);
    final gitignore = File('${stateDir.path}/.gitignore');
    if (!gitignore.existsSync()) gitignore.writeAsStringSync('*\n');
  }

  /// Record the running server so CLI clients can find it.
  void writeServerInfo({required int port, required int pid}) {
    ensureState();
    serverInfoFile.writeAsStringSync(jsonEncode({
      'port': port,
      'pid': pid,
      'project': projectRoot.path,
      'startedAt': DateTime.now().toIso8601String(),
    }));
  }

  /// Read the recorded server info, or null if none/unparseable.
  ServerInfo? readServerInfo() {
    if (!serverInfoFile.existsSync()) return null;
    try {
      final m = jsonDecode(serverInfoFile.readAsStringSync()) as Map<String, dynamic>;
      return ServerInfo(
        port: m['port'] as int,
        pid: m['pid'] as int,
        project: m['project'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  void clearServerInfo() {
    if (serverInfoFile.existsSync()) serverInfoFile.deleteSync();
  }
}

class ServerInfo {
  ServerInfo({required this.port, required this.pid, this.project});
  final int port;
  final int pid;
  final String? project;

  String get baseUrl => 'http://127.0.0.1:$port';
}
