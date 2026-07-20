/// Post-input settle detection.
///
/// `tap`/`swipe` return as soon as the pointer event is dispatched — they say
/// nothing about whether the resulting rebuild, route transition, or
/// animation has finished. A `shot` fired immediately after often captures a
/// mid-transition frame or a loading spinner, which is a trap for agents that
/// `tap` then immediately `shot` to look at the result.
///
/// Flutter has no queryable service extension for "is the app mid-animation"
/// (unlike first-frame, which is a boolean extension), so this polls
/// `SchedulerBinding` directly via VM Service `evaluate`, the same mechanism
/// [input.dart] uses to dispatch pointer events. The check mirrors what
/// `flutter_test`'s `pumpAndSettle` and `flutter_driver`'s
/// `waitUntilNoTransientCallbacks` consider "settled": no pending frame
/// callbacks and no frame currently scheduled — held stable for a short quiet
/// window so a gap *between* two animation frames isn't mistaken for the end
/// of the animation.
library;

import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// The framework library whose scope resolves SchedulerBinding/SchedulerPhase.
const _schedulerLib = 'package:flutter/src/scheduler/binding.dart';

/// Evaluatable expression that reports whether the scheduler is idle: no
/// transient frame callbacks pending and no frame currently scheduled.
const settleCheckExpr = '(SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle && '
    '!SchedulerBinding.instance.hasScheduledFrame).toString()';

/// Whether [result] (the raw `evaluate` return value) reports a quiescent
/// scheduler. Anything other than the literal `"true"` is treated as not
/// settled — a stale or malformed read should never falsely report done.
bool settleQuiescent(String? result) => result == 'true';

/// Poll [vmServiceUri] until `SchedulerBinding` has been idle — no scheduled
/// frame, no transient callbacks — continuously for [quiet], or [timeout]
/// elapses. Returns false rather than throwing: a missed settle signal should
/// degrade the caller's confidence, not fail the command.
Future<bool> waitForSettle(
  String vmServiceUri, {
  Duration timeout = const Duration(seconds: 10),
  Duration quiet = const Duration(milliseconds: 150),
  Duration pollInterval = const Duration(milliseconds: 50),
}) async {
  VmService? service;
  try {
    service = await vmServiceConnectUri(vmServiceUri);
    final deadline = DateTime.now().add(timeout);
    DateTime? quietSince;
    while (DateTime.now().isBefore(deadline)) {
      final isolates = (await service.getVM()).isolates ?? const <IsolateRef>[];
      if (isolates.isEmpty) {
        quietSince = null;
        await Future<void>.delayed(pollInterval);
        continue;
      }
      final isoId = isolates.first.id!;
      final iso = await service.getIsolate(isoId);
      // The scheduler library only resolves once the framework binding is up.
      final lib = (iso.libraries ?? const <LibraryRef>[]).firstWhere(
        (l) => l.uri == _schedulerLib,
        orElse: () => LibraryRef(id: '', uri: '', name: ''),
      );
      if (lib.id == null || lib.id!.isEmpty) {
        quietSince = null;
        await Future<void>.delayed(pollInterval);
        continue;
      }
      final r = await service.evaluate(isoId, lib.id!, settleCheckExpr);
      final value = r is InstanceRef ? r.valueAsString : null;
      if (settleQuiescent(value)) {
        final since = quietSince ??= DateTime.now();
        if (DateTime.now().difference(since) >= quiet) return true;
      } else {
        quietSince = null;
      }
      await Future<void>.delayed(pollInterval);
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await service?.dispose();
  }
}
