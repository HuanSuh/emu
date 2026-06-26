/// The engine: owns a `flutter run --machine` process and exposes high-level
/// controls (hot reload, hot restart, cold restart, stop) plus log and status
/// streams. There is exactly one engine per driven project, owned by the server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'daemon_protocol.dart';
import 'env.dart';
import 'log_store.dart';
import 'models.dart';

/// Result of a control action (reload/restart), surfaced to callers.
class ActionResult {
  ActionResult({required this.ok, required this.message, this.code});
  final bool ok;
  final String message;
  final int? code;

  Map<String, dynamic> toJson() => {'ok': ok, 'message': message, 'code': code};
}

class FlutterEngine {
  FlutterEngine({
    required this.projectRoot,
    required this.logStore,
    this.flutterExecutable = 'flutter',
  });

  final String projectRoot;
  final LogStore logStore;
  final String flutterExecutable;

  Process? _process;
  int _nextRequestId = 1;
  final Map<int, Completer<DaemonResponse>> _pending = {};

  /// True only while we are deliberately stopping (via [stop]). Lets
  /// [_handleExit] tell an intentional quit from a crash/build failure, since
  /// the daemon emits `app.stop` in both cases.
  bool _stopping = false;

  /// Args last used to start, so a cold restart can replay them.
  List<String> _lastRunArgs = const [];

  AppStatus _status = AppStatus(state: AppRunState.stopped);
  AppStatus get status => _status;

  final _statusController = StreamController<AppStatus>.broadcast();
  Stream<AppStatus> get statusStream => _statusController.stream;

  bool get isRunning => _process != null && _status.state == AppRunState.running;

  void _setStatus(AppStatus next) {
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  /// Build the `flutter run --machine` argument list.
  static List<String> buildRunArgs({
    String? deviceId,
    String? flavor,
    String? target,
    List<String> dartDefines = const [],
    List<String> extra = const [],
  }) {
    return [
      'run',
      '--machine',
      if (deviceId != null) ...['-d', deviceId],
      if (flavor != null) ...['--flavor', flavor],
      if (target != null) ...['-t', target],
      for (final d in dartDefines) '--dart-define=$d',
      ...extra,
    ];
  }

  /// Start the app. Throws [StateError] if already running.
  Future<void> start(List<String> runArgs, {String? deviceName}) async {
    if (_process != null) {
      throw StateError('engine already running');
    }
    _stopping = false;
    _lastRunArgs = runArgs;
    _setStatus(AppStatus(
      state: AppRunState.starting,
      deviceName: deviceName,
      startedAt: DateTime.now(),
    ));
    logStore.system('starting: $flutterExecutable ${runArgs.join(' ')}');

    final proc = await Process.start(
      flutterExecutable,
      runArgs,
      workingDirectory: projectRoot,
      environment: spawnEnvironment(),
      includeParentEnvironment: false,
    );
    _process = proc;

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          _handleStdoutLine,
          onError: (Object e) => logStore.add('stdout error: $e', source: 'stderr'),
        );
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) => logStore.add(line, source: 'stderr'),
        );

    unawaited(proc.exitCode.then(_handleExit));
  }

  void _handleExit(int code) {
    logStore.system('flutter process exited (code $code)');
    _process = null;
    // Fail any in-flight requests.
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(DaemonResponse(id: -1, error: 'process exited'));
      }
    }
    _pending.clear();
    if (!_stopping) {
      _setStatus(_status.copyWith(
        state: code == 0 ? AppRunState.stopped : AppRunState.failed,
        message: code == 0 ? null : 'flutter exited with code $code',
      ));
    }
  }

  void _handleStdoutLine(String line) {
    final msg = DaemonMessage.parse(line);
    switch (msg) {
      case DaemonRawLine(:final line):
        if (line.trim().isNotEmpty) logStore.add(line);
      case DaemonResponse():
        final c = _pending.remove(msg.id);
        if (c != null && !c.isCompleted) c.complete(msg);
      case DaemonEvent():
        _handleEvent(msg);
    }
  }

  void _handleEvent(DaemonEvent e) {
    switch (e.event) {
      case 'daemon.connected':
        logStore.system('daemon connected (flutter pid ${e.params['pid']})');
      case 'app.start':
        _setStatus(_status.copyWith(
          appId: e.params['appId'] as String?,
          deviceId: e.params['deviceId'] as String?,
        ));
      case 'app.debugPort':
        final ws = e.params['wsUri'] as String?;
        if (ws != null) {
          _setStatus(_status.copyWith(vmServiceUri: ws));
          logStore.system('VM Service: $ws');
        }
      case 'app.started':
        _setStatus(_status.copyWith(state: AppRunState.running, message: ''));
        logStore.system('app started');
      case 'app.log':
        final log = e.params['log'] as String?;
        final isError = (e.params['error'] as bool?) ?? false;
        if (log != null) {
          for (final l in const LineSplitter().convert(log)) {
            logStore.add(l, level: isError ? LogLevel.error : null);
          }
        }
      case 'app.progress':
        final message = e.params['message'] as String?;
        final finished = (e.params['finished'] as bool?) ?? false;
        if (message != null && message.isNotEmpty && !finished) {
          logStore.system(message);
        }
      case 'app.stop':
        _setStatus(_status.copyWith(state: AppRunState.stopped));
        logStore.system('app stopped');
      case 'daemon.logMessage':
        final level = e.params['level'] as String?;
        final message = e.params['message'] as String?;
        if (message != null) {
          logStore.add(message, level: LogLevel.fromName(level));
        }
      default:
        // Unhandled events are ignored on purpose.
        break;
    }
  }

  Future<DaemonResponse> _request(String method, [Map<String, dynamic>? params]) {
    final proc = _process;
    if (proc == null) {
      return Future.value(DaemonResponse(id: -1, error: 'not running'));
    }
    final id = _nextRequestId++;
    final completer = Completer<DaemonResponse>();
    _pending[id] = completer;
    proc.stdin.write(encodeDaemonRequest(id, method, params));
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);
        return DaemonResponse(id: id, error: 'timeout waiting for $method');
      },
    );
  }

  Future<ActionResult> _restart({required bool fullRestart}) async {
    final appId = _status.appId;
    if (appId == null) {
      return ActionResult(ok: false, message: 'app not started yet');
    }
    final label = fullRestart ? 'hot restart' : 'hot reload';
    logStore.system('$label requested');
    _setStatus(_status.copyWith(state: AppRunState.restarting));
    final resp = await _request('app.restart', {
      'appId': appId,
      'fullRestart': fullRestart,
      'pause': false,
      'reason': 'manual',
    });
    _setStatus(_status.copyWith(
      state: AppRunState.running,
      lastReloadAt: DateTime.now(),
    ));
    if (resp.isError) {
      final msg = '$label failed: ${resp.error}';
      logStore.add(msg, level: LogLevel.error, source: 'system');
      return ActionResult(ok: false, message: msg);
    }
    final result = (resp.result as Map?)?.cast<String, dynamic>();
    final code = (result?['code'] as num?)?.toInt() ?? 0;
    final rawMsg = result?['message'] as String?;
    final message = (rawMsg != null && rawMsg.isNotEmpty) ? rawMsg : '$label complete';
    final ok = code == 0;
    logStore.system(ok ? '$label complete' : '$label: $message');
    return ActionResult(ok: ok, message: message, code: code);
  }

  Future<ActionResult> hotReload() => _restart(fullRestart: false);

  Future<ActionResult> hotRestart() => _restart(fullRestart: true);

  /// Full stop + relaunch (picks up native/pubspec changes a hot restart can't).
  Future<ActionResult> coldRestart() async {
    logStore.system('cold restart requested');
    final args = List<String>.from(_lastRunArgs);
    final deviceName = _status.deviceName;
    await stop();
    // Give the OS a moment to release the device/port.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      await start(args, deviceName: deviceName);
      return ActionResult(ok: true, message: 'cold restart launched');
    } catch (e) {
      return ActionResult(ok: false, message: 'cold restart failed: $e');
    }
  }

  /// Stop the app and the underlying process.
  Future<void> stop() async {
    _stopping = true;
    final proc = _process;
    if (proc == null) {
      _setStatus(_status.copyWith(state: AppRunState.stopped));
      return;
    }
    _setStatus(_status.copyWith(state: AppRunState.stopped));
    final appId = _status.appId;
    if (appId != null) {
      await _request('app.stop', {'appId': appId})
          .timeout(const Duration(seconds: 8), onTimeout: () => DaemonResponse(id: -1));
    }
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 8), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    _process = null;
  }

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
  }
}
