/// Groups Flutter's exception console banners into structured records.
///
/// Flutter prints uncaught exceptions as a banner bracketed by `═══╡ ... ╞═══`
/// (opening, with the library name inside) and a closing line of bare `═`.
/// [LogStore]/`inferLevel` already flags every line of that banner as an error
/// line individually; this groups the lines back into one record per banner,
/// working purely off already-captured [LogEntry]s (no VM Service, no new
/// storage) so it's trivially unit-testable.
library;

import 'models.dart';

/// The opening banner line, e.g.
/// `═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════`.
final _openBanner = RegExp(r'^═+╡(.*)╞═+$');

/// A closing banner line: nothing but `═`.
final _closeBanner = RegExp(r'^═{10,}$');

/// The line right after the banner opens, e.g.
/// `The following NullCheckError was thrown building MyWidget(...):`.
final _thrownBy = RegExp(r'^The following (\S+) was thrown\b');

/// Android's daemon `app.log` forwards adb logcat, which tags every physical
/// line with `<level>/<tag>( pid): `, e.g. `I/flutter ( 1234): message` (see
/// `log_store.dart`'s `_logcatPrefix` / its tests) — including every line of
/// an exception banner. Strip that tag before matching the banner regexes
/// against it, or `_openBanner`/`_closeBanner`/`_thrownBy` (anchored at `^`)
/// never match on Android and `emu errors` silently reports none.
final _logcatTag = RegExp(r'^[EWIDV]/\S+\s*\(\s*\d+\s*\)\s*:\s*');

String _stripLogcatTag(String text) => text.replaceFirst(_logcatTag, '');

/// One exception banner, grouped from the raw log lines between an opening
/// and closing banner line (inclusive of both).
class StructuredError {
  StructuredError({
    required this.startSeq,
    required this.endSeq,
    required this.library,
    required this.exceptionType,
    required this.raw,
    required this.closed,
  });

  /// Seq of the opening banner line.
  final int startSeq;

  /// Seq of the closing banner line, or (when [closed] is false) the last
  /// captured entry's seq — the banner was still printing when this scan ran.
  final int endSeq;

  /// Text inside `╡ ... ╞` on the opening line, e.g. "EXCEPTION CAUGHT BY
  /// WIDGETS LIBRARY". Null when the opening line didn't match the expected
  /// shape (the raw text is preserved regardless).
  final String? library;

  /// The exception's runtime type, e.g. "NullCheckError". Null when the line
  /// following the banner didn't match "The following X was thrown ...".
  final String? exceptionType;

  /// The full original text of every line in the banner, newline-joined.
  final String raw;

  /// Whether the closing `═` line was actually seen. False means this record
  /// is a best-effort snapshot of a banner still being printed — callers that
  /// poll with a seq cursor must not advance their cursor past [startSeq] - 1
  /// for an unclosed record, or they will never see its real, complete text.
  final bool closed;

  Map<String, dynamic> toJson() => {
        'startSeq': startSeq,
        'endSeq': endSeq,
        'library': library,
        'exceptionType': exceptionType,
        'raw': raw,
        'closed': closed,
      };
}

/// Scan [entries] in seq order and group each exception banner (an opening
/// `═══╡ ... ╞═══` line through the next all-`═` closing line) into one
/// [StructuredError]. Lines outside any banner are ignored — this only
/// extracts the structured records, it doesn't replace `logs`.
///
/// A banner that never closes (log buffer truncated / capture ended mid-
/// banner) is still returned, closed at the last available entry — a partial
/// record beats silently dropping it.
List<StructuredError> parseErrorBanners(List<LogEntry> entries) {
  final sorted = entries.toList()..sort((a, b) => a.seq.compareTo(b.seq));
  final out = <StructuredError>[];

  int? openIndex;
  for (var i = 0; i < sorted.length; i++) {
    final text = _stripLogcatTag(sorted[i].text.trim());
    if (openIndex == null) {
      if (_openBanner.hasMatch(text)) openIndex = i;
      continue;
    }
    if (_closeBanner.hasMatch(text)) {
      out.add(_buildRecord(sorted, openIndex, i, closed: true));
      openIndex = null;
    } else if (_openBanner.hasMatch(text)) {
      // A second opening line before the first banner closed: two banners'
      // lines interleaved (e.g. two concurrent log sources) rather than one
      // banner containing a literal "╡...╞" in its body. Close the first one
      // here (unclosed — its real end was never seen) instead of silently
      // merging both banners' text into one mis-attributed record.
      out.add(_buildRecord(sorted, openIndex, i - 1, closed: false));
      openIndex = i;
    }
  }
  // Unterminated banner: still printing (or the log buffer was truncated
  // mid-banner) — report a best-effort snapshot rather than dropping it, but
  // mark it unclosed so callers know not to treat [endSeq] as final.
  if (openIndex != null) {
    out.add(_buildRecord(sorted, openIndex, sorted.length - 1, closed: false));
  }
  return out;
}

StructuredError _buildRecord(List<LogEntry> sorted, int openIndex, int closeIndex,
    {required bool closed}) {
  final open = sorted[openIndex];
  final bannerMatch = _openBanner.firstMatch(_stripLogcatTag(open.text.trim()));
  final library = bannerMatch?.group(1)?.trim();

  String? exceptionType;
  if (openIndex + 1 <= closeIndex) {
    final thrownMatch =
        _thrownBy.firstMatch(_stripLogcatTag(sorted[openIndex + 1].text.trim()));
    exceptionType = thrownMatch?.group(1);
  }

  final raw = sorted.sublist(openIndex, closeIndex + 1).map((e) => e.text).join('\n');
  return StructuredError(
    startSeq: open.seq,
    endSeq: sorted[closeIndex].seq,
    library: (library == null || library.isEmpty) ? null : library,
    exceptionType: exceptionType,
    raw: raw,
    closed: closed,
  );
}
