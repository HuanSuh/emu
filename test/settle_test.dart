import 'package:emu/src/settle.dart';
import 'package:test/test.dart';

void main() {
  group('settleQuiescent', () {
    test('true only for the exact evaluate result', () {
      expect(settleQuiescent('true'), isTrue);
    });

    test('anything else means still animating/rebuilding', () {
      expect(settleQuiescent('false'), isFalse);
      expect(settleQuiescent(''), isFalse);
      expect(settleQuiescent(null), isFalse);
    });
  });

  group('settleCheckExpr', () {
    test('checks both idle phase and no scheduled frame', () {
      expect(settleCheckExpr, contains('SchedulerBinding.instance.schedulerPhase'));
      expect(settleCheckExpr, contains('SchedulerPhase.idle'));
      expect(settleCheckExpr, contains('!SchedulerBinding.instance.hasScheduledFrame'));
    });
  });

  group('waitForSettle', () {
    test('returns false rather than throwing when the VM service is unreachable', () async {
      final settled = await waitForSettle(
        'ws://127.0.0.1:1/ws',
        timeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 20),
      );
      expect(settled, isFalse);
    });
  });
}
