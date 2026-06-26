/// Environment sanitation for spawned child processes.
///
/// A stale `SDKROOT`/`DEVELOPER_DIR` (e.g. left pointing at an Xcode that was
/// since deleted) breaks every `xcrun`/`xcodebuild`/`simctl` invocation and any
/// `flutter` build that shells out to them. We strip such vars when their path
/// no longer exists so emu's children get a working toolchain.
library;

import 'dart:io';

/// Parent environment with stale Xcode toolchain vars removed.
///
/// Pass together with `includeParentEnvironment: false` to actually drop the
/// vars (a plain `environment:` map can only add/override, not remove).
Map<String, String> spawnEnvironment() {
  final env = Map<String, String>.of(Platform.environment);
  _dropIfMissing(env, 'SDKROOT', isDir: false);
  _dropIfMissing(env, 'DEVELOPER_DIR', isDir: true);
  return env;
}

void _dropIfMissing(Map<String, String> env, String key, {required bool isDir}) {
  final value = env[key];
  if (value == null || value.isEmpty) return;
  final exists = isDir ? Directory(value).existsSync() : File(value).existsSync();
  if (!exists) env.remove(key);
}
