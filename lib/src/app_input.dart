/// How emu's input reaches the app: taps, swipes and text through the VM
/// Service (`input.dart`), deep links through adb/simctl (`open_url.dart`).
///
/// The server sends every input through one [AppInput], so it can record
/// each as a timeline `action` entry — and tests can stand in for the device.
library;

import 'dart:io';

import 'device_setup.dart' show runWithTimeout;
import 'input.dart';
import 'open_url.dart';

abstract interface class AppInput {
  Future<void> tap(String wsUri, int x, int y);
  Future<void> swipe(String wsUri, int x1, int y1, int x2, int y2, {required int durationMs});
  Future<void> text(String wsUri, String text, {required bool append});

  /// Run [cmd] (a deep link), bounded: an offline device can hang adb.
  Future<ProcessResult> openUrl(OpenUrlCommand cmd);
}

/// The real device.
class DeviceInput implements AppInput {
  const DeviceInput();

  @override
  Future<void> tap(String wsUri, int x, int y) => runTap(wsUri, x, y);

  @override
  Future<void> swipe(String wsUri, int x1, int y1, int x2, int y2, {required int durationMs}) =>
      runSwipe(wsUri, x1, y1, x2, y2, durationMs: durationMs);

  @override
  Future<void> text(String wsUri, String text, {required bool append}) => runText(wsUri, text, append: append);

  @override
  Future<ProcessResult> openUrl(OpenUrlCommand cmd) => runWithTimeout(cmd.executable, cmd.arguments);
}
