/// First-frame detection.
///
/// `running` from the Flutter daemon only means the Dart entrypoint started —
/// the engine may not have rasterized anything yet. Input sent in that window
/// lands on a screen with no widgets and is silently lost, which is a trap for
/// agents that `up` then immediately `tap`.
///
/// Flutter exposes this as a service extension whose `enabled` flag is
/// *queryable* rather than a one-shot event, so it can be polled without racing
/// a frame that already happened before we connected.
library;

import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Fires once the first frame has been rasterized — i.e. pixels are actually on
/// screen, which is what makes the app tappable. (The non-rasterized variant
/// only reports that the frame was built.)
const firstFrameExtension = 'ext.flutter.didSendFirstFrameRasterizedEvent';

/// Whether [json] from the extension reports the frame as sent. Flutter renders
/// the flag as a string in some versions and a bool in others, so accept both.
bool firstFrameSent(Map<String, dynamic>? json) =>
    json?['enabled'].toString() == 'true';

/// Poll [vmServiceUri] until the app has painted, or [timeout] elapses.
/// Returns false rather than throwing: a missed frame signal should degrade the
/// caller's confidence, not fail the command.
Future<bool> waitForFirstFrame(String vmServiceUri,
    {Duration timeout = const Duration(seconds: 20)}) async {
  VmService? service;
  try {
    service = await vmServiceConnectUri(vmServiceUri);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final ref in (await service.getVM()).isolates ?? const <IsolateRef>[]) {
        final iso = await service.getIsolate(ref.id!);
        // The extension only registers once the framework is up.
        if (!(iso.extensionRPCs ?? const []).contains(firstFrameExtension)) continue;
        final res = await service.callServiceExtension(firstFrameExtension, isolateId: ref.id!);
        if (firstFrameSent(res.json)) return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await service?.dispose();
  }
}
