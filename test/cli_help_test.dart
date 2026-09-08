import 'dart:async';

import 'package:emu/src/cli.dart';
import 'package:test/test.dart';

/// Runs [argv] through [runCli] with stdout/stderr captured instead of
/// printed, so assertions can inspect usage text without polluting the test
/// runner's own output.
Future<(int, String)> _run(List<String> argv) async {
  final buf = StringBuffer();
  final code = await runZoned(
    () => runCli(argv),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => buf.writeln(line),
    ),
  );
  return (code, buf.toString());
}

void main() {
  // Every ArgParser-backed subcommand must accept --help without throwing,
  // print usage, and exit 0 — see https://github.com/HuanSuh/emu/issues/2.
  const subcommands = ['up', 'assert', 'probe', 'inspect', 'logs', 'tap', 'swipe', 'settle'];

  group('--help never crashes and exits 0', () {
    for (final cmd in subcommands) {
      test(cmd, () async {
        final (code, out) = await _run([cmd, '--help']);
        expect(code, 0);
        expect(out.toLowerCase(), contains('usage'));
      });
    }
  });

  group('an unknown flag never crashes and exits 2', () {
    // Usage on this path goes to stderr, which isn't routed through the
    // print() zone capture above — only the exit code is asserted here.
    for (final cmd in subcommands) {
      test(cmd, () async {
        final (code, _) = await _run([cmd, '--this-flag-does-not-exist']);
        expect(code, 2);
      });
    }
  });
}
