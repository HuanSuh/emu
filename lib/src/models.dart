/// Core data models shared by the engine, server, CLI, and dashboard.
///
/// Everything here is plain Dart (no Flutter, no dart:io) so it can be reused
/// by every entrypoint and unit-tested in isolation.
library;

import 'dart:convert';

/// Severity of a single log line.
///
/// Flutter's `--machine` output does not tag every line with a level, so most
/// levels are inferred heuristically (see [LogStore]). [LogLevel.system] is used
/// for emu's own lifecycle messages (device boot, restart issued, etc.).
enum LogLevel {
  debug,
  info,
  warn,
  error,
  system;

  static LogLevel fromName(String? name) {
    switch (name?.toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'error':
      case 'severe':
        return LogLevel.error;
      case 'system':
        return LogLevel.system;
      case 'info':
      default:
        return LogLevel.info;
    }
  }

  /// Ordering used by `--level` filters: a filter of [warn] matches warn+error.
  int get rank => switch (this) {
        LogLevel.debug => 0,
        LogLevel.info => 1,
        LogLevel.system => 1,
        LogLevel.warn => 2,
        LogLevel.error => 3,
      };
}

/// A single captured log line.
class LogEntry {
  LogEntry({
    required this.seq,
    required this.timestamp,
    required this.level,
    required this.text,
    this.source = 'app',
  });

  /// Monotonic sequence number assigned by the [LogStore]. Lets clients request
  /// "everything after seq N" without relying on wall-clock time.
  final int seq;

  final DateTime timestamp;
  final LogLevel level;
  final String text;

  /// Where the line came from: `app` (Flutter app/daemon), `stderr`, `system`.
  final String source;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'ts': timestamp.toIso8601String(),
        'level': level.name,
        'source': source,
        'text': text,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        seq: json['seq'] as int,
        timestamp: DateTime.parse(json['ts'] as String),
        level: LogLevel.fromName(json['level'] as String?),
        text: json['text'] as String,
        source: (json['source'] as String?) ?? 'app',
      );

  /// One JSON object per line, for `.emu/run.jsonl` and `logs --json`.
  String toJsonl() => '${jsonEncode(toJson())}\n';
}

/// Lifecycle state of the driven app.
enum AppRunState { stopped, starting, running, restarting, failed }

/// A snapshot of the engine/app state, surfaced by `status` and the dashboard.
class AppStatus {
  AppStatus({
    required this.state,
    this.deviceId,
    this.deviceName,
    this.appId,
    this.vmServiceUri,
    this.devToolsUri,
    this.startedAt,
    this.lastReloadAt,
    this.message,
  });

  final AppRunState state;
  final String? deviceId;
  final String? deviceName;

  /// The Flutter daemon's app id, needed to issue restart requests.
  final String? appId;

  /// Dart VM Service URI (the endpoint DevTools/probe connect to).
  final String? vmServiceUri;

  /// Browsable Flutter DevTools URL (from the daemon's `devtools.serve`),
  /// already pointed at this app's VM Service. Null until DevTools is served.
  final String? devToolsUri;

  final DateTime? startedAt;
  final DateTime? lastReloadAt;

  /// Human-readable detail for the current state (e.g. a build error summary).
  final String? message;

  AppStatus copyWith({
    AppRunState? state,
    String? deviceId,
    String? deviceName,
    String? appId,
    String? vmServiceUri,
    String? devToolsUri,
    DateTime? startedAt,
    DateTime? lastReloadAt,
    String? message,
  }) =>
      AppStatus(
        state: state ?? this.state,
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        appId: appId ?? this.appId,
        vmServiceUri: vmServiceUri ?? this.vmServiceUri,
        devToolsUri: devToolsUri ?? this.devToolsUri,
        startedAt: startedAt ?? this.startedAt,
        lastReloadAt: lastReloadAt ?? this.lastReloadAt,
        message: message ?? this.message,
      );

  Map<String, dynamic> toJson() => {
        'state': state.name,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'appId': appId,
        'vmServiceUri': vmServiceUri,
        'devToolsUri': devToolsUri,
        'startedAt': startedAt?.toIso8601String(),
        'lastReloadAt': lastReloadAt?.toIso8601String(),
        'message': message,
      };

  factory AppStatus.fromJson(Map<String, dynamic> json) => AppStatus(
        state: AppRunState.values
            .firstWhere((s) => s.name == json['state'], orElse: () => AppRunState.stopped),
        deviceId: json['deviceId'] as String?,
        deviceName: json['deviceName'] as String?,
        appId: json['appId'] as String?,
        vmServiceUri: json['vmServiceUri'] as String?,
        devToolsUri: json['devToolsUri'] as String?,
        startedAt: _parseDate(json['startedAt']),
        lastReloadAt: _parseDate(json['lastReloadAt']),
        message: json['message'] as String?,
      );
}

/// A device discoverable by `flutter devices`.
class DeviceInfo {
  DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.emulator,
    this.targetPlatform,
  });

  final String id;
  final String name;

  /// `android`, `ios`, `macos`, `web`, etc. (derived).
  final String platform;
  final bool emulator;
  final String? targetPlatform;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'emulator': emulator,
        'targetPlatform': targetPlatform,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final target = json['targetPlatform'] as String?;
    return DeviceInfo(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? json['id'] as String,
      platform: (json['platform'] as String?) ?? _platformFromTarget(target),
      emulator: (json['emulator'] as bool?) ?? false,
      targetPlatform: target,
    );
  }
}

String _platformFromTarget(String? target) {
  if (target == null) return 'unknown';
  if (target.startsWith('android')) return 'android';
  if (target.startsWith('ios')) return 'ios';
  if (target.startsWith('darwin') || target == 'macos') return 'macos';
  return target;
}

DateTime? _parseDate(Object? v) => v == null ? null : DateTime.tryParse(v as String);
