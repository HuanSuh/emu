/// In-memory ring buffer of log entries with persistence and filtered queries.
///
/// The store is the single source of truth for logs. The engine appends lines;
/// the server/CLI/dashboard read via [query] or subscribe to [stream].
library;

import 'dart:async';
import 'dart:convert';
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

/// Which entries a read keeps: [LogStore.query] and the CLI's offline
/// reads of `run.jsonl` ([readLogFile]) share it, so both see the same.
class LogFilter {
  LogFilter({String? grep, this.level, this.sinceSeq, this.since, this.kinds, String? route})
      : grep = grep == null || grep.isEmpty ? null : RegExp(grep, caseSensitive: false),
        route = route == null || route.isEmpty ? null : RegExp(route, caseSensitive: false);

  /// Case-insensitive, matched against the text.
  final RegExp? grep;

  /// Case-insensitive, matched against the screen and its name: an entry
  /// whose either one matches is kept, one with no screen never is.
  final RegExp? route;

  /// Keep entries at or above this severity (by [LogLevel.rank]).
  final LogLevel? level;

  /// Keep entries with seq strictly greater than this.
  final int? sinceSeq;
  final DateTime? since;

  /// [LogKind] names to keep; null keeps every kind.
  final Set<String>? kinds;

  bool matches(LogEntry e) {
    if (sinceSeq != null && e.seq <= sinceSeq!) return false;
    if (since != null && e.timestamp.isBefore(since!)) return false;
    if (kinds != null && !kinds!.contains(e.kindName)) return false;
    if (level != null && e.level.rank < level!.rank) return false;
    if (grep != null && !grep!.hasMatch(e.text)) return false;
    if (route != null) {
      final r = route!;
      if (!(e.route != null && r.hasMatch(e.route!)) && !(e.routeName != null && r.hasMatch(e.routeName!))) {
        return false;
      }
    }
    return true;
  }

  /// The matches in [entries], only the most recent [limit] of them — the
  /// filter applies first, so a limit counts kept entries.
  List<LogEntry> apply(Iterable<LogEntry> entries, {int? limit}) {
    var result = entries.where(matches).toList();
    if (limit != null && result.length > limit) {
      result = result.sublist(result.length - limit);
    }
    return result;
  }
}

/// The entries of a `run.jsonl` [file] that [filter] keeps, the last [limit]
/// of them. Unreadable lines are skipped: the file may be mid-write.
List<LogEntry> readLogFile(File file, LogFilter filter, {int? limit}) {
  if (!file.existsSync()) return const [];
  final entries = <LogEntry>[];
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      entries.add(LogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
    } catch (_) {}
  }
  return filter.apply(entries, limit: limit);
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

  /// May hold up to [_slack] entries past [capacity] so trimming happens in
  /// batches instead of shifting the whole list on every line; [_visible]
  /// hides that overflow, so readers still see at most [capacity] entries.
  final List<LogEntry> _buffer = [];
  int _seq = 0;

  int get _slack => capacity ~/ 10 + 1;

  Iterable<LogEntry> get _visible =>
      _buffer.length > capacity ? _buffer.skip(_buffer.length - capacity) : _buffer;

  final _controller = StreamController<LogEntry>.broadcast();

  /// Live stream of newly appended entries.
  Stream<LogEntry> get stream => _controller.stream;

  /// Highest sequence number issued so far.
  int get lastSeq => _seq;

  /// The current screen, stamped on every entry [add] makes; null while
  /// unknown. Whoever tracks the screen sets these.
  String? currentRoute;
  String? currentRouteName;

  /// Append a raw line, inferring its level unless one is supplied.
  ///
  /// The entry gets [currentRoute] and [currentRouteName], or [routeAt]'s
  /// screen instead (a request: the screen that sent it, when it started).
  LogEntry add(
    String text, {
    LogLevel? level,
    String source = 'app',
    DateTime? timestamp,
    String? kind,
    Map<String, dynamic>? data,
    ({String? route, String? routeName})? routeAt,
  }) {
    final entry = LogEntry(
      seq: ++_seq,
      timestamp: timestamp ?? DateTime.now(),
      level: level ?? inferLevel(text, isStderr: source == 'stderr'),
      text: text,
      source: source,
      kind: kind,
      route: routeAt != null ? routeAt.route : currentRoute,
      routeName: routeAt != null ? routeAt.routeName : currentRouteName,
      data: data,
    );
    _buffer.add(entry);
    if (_buffer.length > capacity + _slack) {
      _buffer.removeRange(0, _buffer.length - capacity);
    }
    _sink?.write(entry.toJsonl());
    if (!_controller.isClosed) _controller.add(entry);
    return entry;
  }

  /// Convenience for emu's own lifecycle messages.
  LogEntry system(String text) => add(text, level: LogLevel.system, source: 'system');

  /// Return entries matching the given filters, newest-last (see [LogFilter]).
  ///
  /// [kinds] defaults to every kind. A caller standing in for what the log
  /// showed before the timeline passes [LogKind.legacy] itself.
  /// [limit] keeps only the most recent N of the matched set.
  List<LogEntry> query({
    String? grep,
    LogLevel? level,
    int? sinceSeq,
    DateTime? since,
    int? limit,
    Set<String>? kinds,
    String? route,
  }) =>
      LogFilter(grep: grep, level: level, sinceSeq: sinceSeq, since: since, kinds: kinds, route: route)
          .apply(_visible, limit: limit);

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
