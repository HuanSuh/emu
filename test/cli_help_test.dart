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

  // The hand-parsed subcommands used to ignore unknown options and treat a
  // stray value as a positional — `emu shot --port 4591` saved a file named
  // `4591` (https://github.com/HuanSuh/emu/issues/13).
  group('hand-parsed subcommands are strict', () {
    const manual = [
      'version', 'doctor', 'update', 'uninstall', 'devices', 'configs', 'status',
      'shot', 'open', 'open-url', 'down', 'reload', 'restart', 'cold', 'stop',
    ];
    for (final cmd in manual) {
      test('$cmd --help exits 0 with usage', () async {
        final (code, out) = await _run([cmd, '--help']);
        expect(code, 0);
        expect(out.toLowerCase(), contains('usage'));
      });
      test('$cmd rejects an unknown option', () async {
        final (code, _) = await _run([cmd, '--this-flag-does-not-exist']);
        expect(code, 2);
      });
    }

    test('shot --port 4591 is rejected, not saved as "4591"', () async {
      expect((await _run(['shot', '--port', '4591'])).$1, 2);
    });

    test('a second positional is rejected', () async {
      expect((await _run(['shot', 'a.png', 'b.png'])).$1, 2);
      expect((await _run(['status', 'extra'])).$1, 2);
    });
  });
}
