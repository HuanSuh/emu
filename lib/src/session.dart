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

  /// Record the running server so CLI clients can find it — and the session
  /// token they must send (see `api_guard.dart`).
  void writeServerInfo({required int port, required int pid, String? token}) {
    ensureState();
    serverInfoFile.writeAsStringSync(jsonEncode({
      'port': port,
      'pid': pid,
      'project': projectRoot.path,
      'startedAt': DateTime.now().toIso8601String(),
      'token': ?token,
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
        token: m['token'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  void clearServerInfo() {
    if (serverInfoFile.existsSync()) serverInfoFile.deleteSync();
  }
}

/// What `emu up` should do given the state of an already-registered session.
enum UpSessionAction {
  /// No live server for this project — proceed with a fresh launch.
  start,

  /// A server is up and the app is actually running/starting — refuse; the
  /// existing session must be torn down with `emu down` first.
  refuseRunning,

  /// A server process answers pings but the app isn't actually up (crashed,
  /// or its process was killed/interrupted independently of the server) — a
  /// "ghost" session. Reclaim it and proceed with a fresh launch instead of
  /// blocking the user with a misleading "already running" refusal.
  reclaimGhost,
}

/// Decide what `up` should do given whether the existing session's server
/// answered a ping and, if so, the app's reported run state (an
/// [AppRunState] name from `/api/status`, or null if it couldn't be read).
///
/// Pulled out as a pure function so the ghost-session decision — the part
/// that previously misled users with "already running" when only the server
/// process, not the app, was alive — is unit-testable without a real server.
UpSessionAction decideUpAction({required bool serverAlive, String? appState}) {
  if (!serverAlive) return UpSessionAction.start;
  if (appState == 'stopped' || appState == 'failed') return UpSessionAction.reclaimGhost;
  return UpSessionAction.refuseRunning;
}

class ServerInfo {
  ServerInfo({required this.port, required this.pid, this.project, this.token});
  final int port;
  final int pid;
  final String? project;

  /// Null for a server from before session tokens (it doesn't check one).
  final String? token;

  String get baseUrl => 'http://127.0.0.1:$port';

  /// Headers every API request to this server carries.
  Map<String, String> get headers => {'X-Emu-Token': ?token};
}
