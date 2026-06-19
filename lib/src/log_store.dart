/// In-memory ring buffer of log entries with persistence and filtered queries.
///
/// The store is the single source of truth for logs. The engine appends lines;
/// the server/CLI/dashboard read via [query] or subscribe to [stream].
library;

import 'dart:async';
import 'dart:io';

import 'models.dart';

/// Heuristic level detection for a raw log line.
///
/// Flutter's daemon tags very little, so we sniff common markers. Order matters:
/// error wins over warning wins over debug.
/// Android logcat lines carry an authoritative level prefix like `W/Tag( pid):`
/// — that wins over generic word-sniffing (a `W/` line saying "Failed" is still
/// a warning, not an error).
final _logcatPrefix = RegExp(r'^([EWIDV])/\w');

LogLevel inferLevel(String text, {bool isStderr = false}) {
  final trimmed = text.trimLeft();
  final m = _logcatPrefix.firstMatch(trimmed);
  if (m != null) {
    switch (m.group(1)) {
      case 'E':
        return LogLevel.error;
      case 'W':
        return LogLevel.warn;
      case 'D':
      case 'V':
        return LogLevel.debug;
      case 'I':
        return LogLevel.info;
    }
  }

  final l = text.toLowerCase();
  const errorMarkers = [
    'exception',
    'error:',
    ' error ',
    'severe',
    'failed',
    'failure',
    'unhandled',
    'stack trace',
    '═══╡ exception',
    '╞═══',
    '[e]',
  ];
  const warnMarkers = ['warning', 'warn:', '[w]', '⚠'];
  const debugMarkers = ['[v]', 'verbose', '[d]', 'debug:'];

  for (final marker in errorMarkers) {
    if (l.contains(marker)) return LogLevel.error;
  }
  // stderr without an explicit error marker is still likely a warning at least.
  if (isStderr) return LogLevel.warn;
  for (final marker in warnMarkers) {
    if (l.contains(marker)) return LogLevel.warn;
  }
  for (final marker in debugMarkers) {
    if (l.contains(marker)) return LogLevel.debug;
  }
  return LogLevel.info;
}

class LogStore {
  LogStore({this.capacity = 50000, File? persistFile}) : _persistFile = persistFile {
    if (_persistFile != null) {
      _sink = _persistFile.openWrite(mode: FileMode.append);
    }
  }

  final int capacity;
  final File? _persistFile;
  IOSink? _sink;

  final List<LogEntry> _buffer = [];
  int _seq = 0;

  final _controller = StreamController<LogEntry>.broadcast();

  /// Live stream of newly appended entries.
  Stream<LogEntry> get stream => _controller.stream;

  /// Highest sequence number issued so far.
  int get lastSeq => _seq;

  /// Append a raw line, inferring its level unless one is supplied.
  LogEntry add(
    String text, {
    LogLevel? level,
    String source = 'app',
    DateTime? timestamp,
  }) {
    final entry = LogEntry(
      seq: ++_seq,
      timestamp: timestamp ?? DateTime.now(),
      level: level ?? inferLevel(text, isStderr: source == 'stderr'),
      text: text,
      source: source,
    );
    _buffer.add(entry);
    if (_buffer.length > capacity) {
      _buffer.removeRange(0, _buffer.length - capacity);
    }
    _sink?.write(entry.toJsonl());
    if (!_controller.isClosed) _controller.add(entry);
    return entry;
  }

  /// Convenience for emu's own lifecycle messages.
  LogEntry system(String text) => add(text, level: LogLevel.system, source: 'system');

  /// Return entries matching the given filters, newest-last.
  ///
  /// - [grep] is a case-insensitive regular expression matched against text.
  /// - [level] keeps entries at or above that severity (by [LogLevel.rank]).
  /// - [sinceSeq] keeps entries with seq strictly greater than the value.
  /// - [limit] keeps only the most recent N of the matched set.
  List<LogEntry> query({
    String? grep,
    LogLevel? level,
    int? sinceSeq,
    DateTime? since,
    int? limit,
  }) {
    RegExp? re;
    if (grep != null && grep.isNotEmpty) {
      re = RegExp(grep, caseSensitive: false);
    }
    var result = _buffer.where((e) {
      if (sinceSeq != null && e.seq <= sinceSeq) return false;
      if (since != null && e.timestamp.isBefore(since)) return false;
      if (level != null && e.level.rank < level.rank) return false;
      if (re != null && !re.hasMatch(e.text)) return false;
      return true;
    }).toList();
    if (limit != null && result.length > limit) {
      result = result.sublist(result.length - limit);
    }
    return result;
  }

  /// Drop all buffered entries (and truncate the persistence file).
  void clear() {
    _buffer.clear();
    if (_persistFile != null) {
      _sink?.flush();
      _persistFile.writeAsStringSync('');
    }
  }

  Future<void> close() async {
    await _controller.close();
    await _sink?.flush();
    await _sink?.close();
  }
}
