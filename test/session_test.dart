import 'package:emu/src/session.dart';
import 'package:test/test.dart';

void main() {
  group('decideUpAction', () {
    test('no live server → start', () {
      expect(decideUpAction(serverAlive: false), UpSessionAction.start);
      // appState is ignored when the server never answered a ping.
      expect(decideUpAction(serverAlive: false, appState: 'running'), UpSessionAction.start);
    });

    test('server alive and app running/starting/restarting → refuse', () {
      for (final state in ['running', 'starting', 'restarting']) {
        expect(
          decideUpAction(serverAlive: true, appState: state),
          UpSessionAction.refuseRunning,
          reason: 'state=$state',
        );
      }
    });

    test('server alive but app stopped → reclaim ghost session', () {
      expect(
        decideUpAction(serverAlive: true, appState: 'stopped'),
        UpSessionAction.reclaimGhost,
      );
    });

    test('server alive but app failed → reclaim ghost session', () {
      expect(
        decideUpAction(serverAlive: true, appState: 'failed'),
        UpSessionAction.reclaimGhost,
      );
    });

    test('server alive but app state unknown/unreadable → refuse (conservative default)', () {
      expect(decideUpAction(serverAlive: true, appState: null), UpSessionAction.refuseRunning);
    });
  });
}
