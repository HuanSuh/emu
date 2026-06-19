/// Encode/decode for the Flutter daemon protocol used by `flutter run --machine`.
///
/// The daemon speaks newline-delimited JSON. Every protocol message is a single
/// line consisting of a one-element JSON array, e.g.
///
///     [{"event":"app.started","params":{"appId":"abc"}}]
///     [{"id":1,"result":{"code":0,"message":"..."}}]
///
/// Lines that are NOT wrapped in `[...]` are ordinary stdout (build output,
/// `print()` from the app before the isolate is wired up, etc.) and are surfaced
/// verbatim as log lines.
///
/// Reference: https://github.com/flutter/flutter/blob/master/packages/flutter_tools/doc/daemon.md
library;

import 'dart:convert';

/// A decoded daemon message: either a [DaemonResponse] (reply to a request we
/// sent, identified by `id`), a [DaemonEvent] (`event` + `params`), or a
/// [DaemonRawLine] for output that isn't a protocol message at all.
sealed class DaemonMessage {
  const DaemonMessage();

  /// Parse a single line of daemon stdout. Returns a [DaemonRawLine] when the
  /// line is not a recognizable protocol message.
  static DaemonMessage parse(String line) {
    final trimmed = line.trimRight();
    if (trimmed.length < 2 || !trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      return DaemonRawLine(line);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return DaemonRawLine(line);
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      return DaemonRawLine(line);
    }
    final obj = (decoded.first as Map).cast<String, dynamic>();
    if (obj.containsKey('id')) {
      return DaemonResponse(
        id: (obj['id'] as num).toInt(),
        result: obj['result'],
        error: obj['error'],
      );
    }
    if (obj.containsKey('event')) {
      return DaemonEvent(
        event: obj['event'] as String,
        params: (obj['params'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    }
    return DaemonRawLine(line);
  }
}

/// A reply to a request we issued.
class DaemonResponse extends DaemonMessage {
  const DaemonResponse({required this.id, this.result, this.error});

  final int id;
  final Object? result;
  final Object? error;

  bool get isError => error != null;
}

/// An unsolicited event emitted by the daemon (app lifecycle, logs, progress).
class DaemonEvent extends DaemonMessage {
  const DaemonEvent({required this.event, required this.params});

  final String event;
  final Map<String, dynamic> params;
}

/// A line that is not a protocol message — treated as raw app/build output.
class DaemonRawLine extends DaemonMessage {
  const DaemonRawLine(this.line);
  final String line;
}

/// Encodes a request to send to the daemon's stdin (with trailing newline).
String encodeDaemonRequest(int id, String method, [Map<String, dynamic>? params]) {
  final obj = <String, dynamic>{'id': id, 'method': method};
  if (params != null) obj['params'] = params;
  return '${jsonEncode([obj])}\n';
}
