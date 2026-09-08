/// Builds the platform-specific process invocation for `emu open-url` —
/// split out as a pure function so the argument assembly (the part that
/// actually matters for avoiding shell-injection) can be unit-tested without
/// spawning a process.
library;

/// A resolved `Process.run` invocation: executable + argv, never a shell
/// string on the host.
///
/// On Android that is not sufficient on its own: `adb shell` does not preserve
/// argv boundaries. It joins its arguments with spaces and hands the result to
/// the *device*'s `/bin/sh`, which re-parses `&`, `;`, backticks and friends.
/// So the URL is additionally quoted for that shell — see [quoteForDeviceShell].
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
  // `xcrun simctl openurl` execs directly, so the raw url is already safe.
  if (platform == 'ios') {
    return OpenUrlCommand('xcrun', [
      'simctl',
      'openurl',
      deviceId ?? 'booted',
      url,
    ]);
  }
  return OpenUrlCommand('adb', [
    if (deviceId != null && deviceId.isNotEmpty) ...['-s', deviceId],
    'shell',
    'am',
    'start',
    '-a',
    'android.intent.action.VIEW',
    '-d',
    quoteForDeviceShell(url),
  ]);
}

/// Wraps [value] so the device-side `/bin/sh` that `adb shell` feeds sees it as
/// one word.
///
/// Everything inside single quotes is literal to POSIX sh, and a single quote
/// itself cannot be escaped there — it is closed, escaped outside, and reopened
/// (`'` -> `'\''`).
///
/// Without this, `emu open-url 'myapp://home?a=1&b=2'` reaches the device as
/// `am start ... -d myapp://home?a=1&b=2`; sh splits at `&`, the intent gets
/// `myapp://home?a=1`, and every parameter after the first is silently dropped.
String quoteForDeviceShell(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";
