/// Pure log-assertion logic, shared by `emu assert` and reusable in tests.
///
/// An assertion has two parts:
/// - expect: every pattern must match at least one log line (presence).
/// - deny:   no pattern may match any log line (absence).
///
/// Patterns are case-insensitive regular expressions matched against log text.
library;

import 'models.dart';

class AssertOutcome {
  AssertOutcome(this.expected, this.denied);

  /// pattern -> whether it was found.
  final Map<String, bool> expected;

  /// pattern -> the log texts that matched (a non-empty list means failure).
  final Map<String, List<String>> denied;

  bool get expectsMet => expected.values.every((v) => v);
  bool get denyClean => denied.values.every((l) => l.isEmpty);
  bool get pass => expectsMet && denyClean;

  Map<String, dynamic> toJson() => {
        'verdict': pass ? 'pass' : 'fail',
        'expected': expected.entries.map((e) => {'pattern': e.key, 'found': e.value}).toList(),
        'denied': denied.entries.map((e) => {'pattern': e.key, 'matches': e.value}).toList(),
      };
}

/// Evaluate [expect]/[deny] patterns against [entries].
AssertOutcome evaluateAssertion(
  Iterable<LogEntry> entries,
  List<String> expect,
  List<String> deny,
) {
  final expectRe = {for (final p in expect) p: RegExp(p, caseSensitive: false)};
  final denyRe = {for (final p in deny) p: RegExp(p, caseSensitive: false)};
  final expected = {for (final p in expect) p: false};
  final denied = {for (final p in deny) p: <String>[]};

  for (final e in entries) {
    for (final p in expect) {
      if (!expected[p]! && expectRe[p]!.hasMatch(e.text)) expected[p] = true;
    }
    for (final p in deny) {
      if (denyRe[p]!.hasMatch(e.text)) denied[p]!.add(e.text);
    }
  }
  return AssertOutcome(expected, denied);
}
