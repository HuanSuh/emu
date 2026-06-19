// Single entrypoint for the `emu` tool.
//
// Normal commands go through the CLI client. The hidden `__serve` subcommand
// runs the server that owns the engine (spawned detached by `emu up`).
import 'dart:io';

import 'package:emu/src/cli.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '__serve') {
    exit(await runServe(args.sublist(1)));
  }
  exit(await runCli(args));
}
