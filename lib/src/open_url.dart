/// Builds the platform-specific process invocation for `emu open-url` —
/// split out as a pure function so the argument assembly (the part that
/// actually matters for avoiding shell-injection) can be unit-tested without
/// spawning a process.
library;

/// A resolved `Process.run` invocation: executable + argv, never a shell
/// string, so a `url` containing `&`, `;`, etc. can never be reinterpreted by
/// a shell.
class OpenUrlCommand {
  OpenUrlCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// [platform] is `android` or `ios` (see `platformForDeviceId`). [deviceId]
/// selects the target device — an adb serial (`-s <id>`) on Android, an iOS
/// simulator udid on iOS (`booted` if unknown, since a udid isn't required to
/// be resolved yet).
OpenUrlCommand buildOpenUrlCommand({
  required String platform,
  required String? deviceId,
  required String url,
}) {
  if (platform == 'ios') {
    return OpenUrlCommand('xcrun', ['simctl', 'openurl', deviceId ?? 'booted', url]);
  }
  return OpenUrlCommand('adb', [
    if (deviceId != null && deviceId.isNotEmpty) ...['-s', deviceId],
    'shell',
    'am',
    'start',
    '-a',
    'android.intent.action.VIEW',
    '-d',
    url,
  ]);
}
