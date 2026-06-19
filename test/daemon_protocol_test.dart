import 'package:emu/src/daemon_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('DaemonMessage.parse', () {
    test('parses an event', () {
      final m = DaemonMessage.parse('[{"event":"app.started","params":{"appId":"abc"}}]');
      expect(m, isA<DaemonEvent>());
      m as DaemonEvent;
      expect(m.event, 'app.started');
      expect(m.params['appId'], 'abc');
    });

    test('parses a response with result', () {
      final m = DaemonMessage.parse('[{"id":3,"result":{"code":0,"message":"ok"}}]');
      expect(m, isA<DaemonResponse>());
      m as DaemonResponse;
      expect(m.id, 3);
      expect(m.isError, isFalse);
      expect((m.result as Map)['code'], 0);
    });

    test('parses a response with error', () {
      final m = DaemonMessage.parse('[{"id":4,"error":"boom"}]');
      m as DaemonResponse;
      expect(m.isError, isTrue);
      expect(m.error, 'boom');
    });

    test('treats non-bracketed output as a raw line', () {
      final m = DaemonMessage.parse('Launching lib/main.dart on iPhone 15…');
      expect(m, isA<DaemonRawLine>());
    });

    test('treats malformed json as a raw line', () {
      final m = DaemonMessage.parse('[not json]');
      expect(m, isA<DaemonRawLine>());
    });
  });

  test('encodeDaemonRequest produces the daemon wire shape', () {
    final line = encodeDaemonRequest(1, 'app.restart', {'appId': 'x', 'fullRestart': true});
    expect(line.endsWith('\n'), isTrue);
    expect(line.contains('"id":1'), isTrue);
    expect(line.contains('"method":"app.restart"'), isTrue);
    expect(line.contains('"fullRestart":true'), isTrue);
    // parse() distinguishes only by the id/event keys, so a request (which has
    // an id) round-trips through parse() as a DaemonResponse. The engine never
    // parses its own requests, so this quirk is harmless.
    final m = DaemonMessage.parse(line.trim());
    expect(m, isA<DaemonResponse>());
    expect((m as DaemonResponse).id, 1);
  });
}
