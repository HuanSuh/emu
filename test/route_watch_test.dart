import 'dart:async';

import 'package:emu/src/log_store.dart';
import 'package:emu/src/models.dart';
import 'package:emu/src/route_watch.dart';
import 'package:test/test.dart';

/// A connection the test feeds by hand.
class FakeSource implements VmEventSource {
  FakeSource({this.isolate});
  @override
  final String? isolate;
  final controller = StreamController<VmEvent>();
  bool closed = false;

  @override
  Stream<VmEvent> get events => controller.stream;

  void add(VmEvent e) => controller.add(e);

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) unawaited(controller.close()); // as the real one: nobody may listen
  }
}

VmExtensionEvent route(Map<String, dynamic> data, {String isolate = 'isolates/1', bool history = false}) =>
    VmExtensionEvent('Emu.Route', isolate, data, history: history);

/// Let stream listeners run.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('Emu.Route contract', () {
    late List<String> problems;
    setUp(() => problems = []);
    ({String location, String? name, String? detail})? parse(Map<String, dynamic> data) =>
        parseEmuRoute(data, problems.add);

    test('location, name and detail; unknown fields are ignored', () {
      expect(parse({'location': '/user/42?tab=posts', 'name': 'user', 'detail': 'feed', 'later': 1}),
          (location: '/user/42?tab=posts', name: 'user', detail: 'feed'));
      expect(parse({'location': '/'}), (location: '/', name: null, detail: null));
      expect(problems, isEmpty);
    });

    test('no usable location: the event is ignored, with a reason', () {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'location': null},
        {'location': 42},
        {'location': ''},
        {'location': '   '},
        {'name': 'user'},
      ]) {
        expect(parse(bad), isNull, reason: '$bad');
      }
      expect(problems.toSet(), {'Emu.Route without a `location` string — the event is ignored'});
    });

    test('a name or detail that is not a string is dropped; an empty one is none', () {
      expect(parse({'location': '/a', 'name': 3, 'detail': ''}), (location: '/a', name: null, detail: null));
      expect(problems, ['Emu.Route `name` is not a string — the field is ignored']);
    });

    test('values are kept as sent, cut at 1024 characters', () {
      final long = '한' * 1500;
      final r = parse({'location': ' /a ', 'name': long, 'detail': '${'x' * 1023}😀😀'})!;
      expect(r.location, ' /a ');
      expect(r.name!.runes.length, 1024);
      expect(r.detail, '${'x' * 1023}😀');
    });
  });

  group('RouteTracker', () {
    late LogStore store;
    late List<String> warnings;
    late RouteTracker tracker;
    setUp(() {
      store = LogStore();
      warnings = [];
      tracker = RouteTracker(store, warn: warnings.add)..connected('isolates/1');
    });

    List<LogEntry> routes() => store.query(kinds: {LogKind.route});

    test('a report sets the screen on what follows and writes one route entry', () {
      store.add('before');
      tracker.onEvent(route({'location': '/user/42', 'name': 'user', 'detail': 'feed'}));
      final after = store.add('after');
      final e = routes().single;
      expect((e.text, e.route, e.routeName, e.level, e.source), ('[route] /user/42 · feed', '/user/42 · feed', 'user', LogLevel.system, 'route'));
      expect(e.data, {'via': 'app', 'location': '/user/42', 'name': 'user', 'detail': 'feed'});
      expect((after.route, after.routeName), ('/user/42 · feed', 'user'));
      expect(store.query(grep: 'before').single.route, isNull);
      expect(tracker.appReports, isTrue);
    });

    test('the same screen again is one entry; a new detail is a new one, without the old fields', () {
      tracker.onEvent(route({'location': '/', 'name': 'home', 'detail': 'feed'}));
      tracker.onEvent(route({'location': '/', 'name': 'home', 'detail': 'feed'}));
      tracker.onEvent(route({'location': '/', 'detail': 'profile'}));
      expect([for (final e in routes()) (e.route, e.routeName)], [('/ · feed', 'home'), ('/ · profile', null)]);
    });

    test("DDS's history sets the screen from the app isolate's last report, with no entries", () {
      tracker.onEvent(route({'location': '/old-isolate'}, isolate: 'isolates/0', history: true));
      tracker.onEvent(route({'location': '/a'}, history: true));
      tracker.onEvent(route({'location': '/b', 'name': 'b'}, history: true));
      tracker.onEvent(VmExtensionEvent('Flutter.Frame', 'isolates/1', const {}, history: true));
      expect(routes(), isEmpty);
      expect((store.currentRoute, store.currentRouteName), ('/b', 'b'));
      tracker.onEvent(route({'location': '/b', 'name': 'b'})); // live, the same: still no entry
      tracker.onEvent(route({'location': '/c'}));
      expect([for (final e in routes()) e.route], ['/c']);
    });

    test('history from an old isolate alone does not count as the app reporting', () {
      tracker.onEvent(route({'location': '/before-restart'}, isolate: 'isolates/0', history: true));
      expect((store.currentRoute, tracker.appReports), (null, false));
    });

    test('a hot restart clears the screen until the new isolate reports', () {
      tracker.onEvent(route({'location': '/a'}));
      tracker.onEvent(VmIsolateEvent('IsolateExit', 'isolates/1', name: 'main'));
      expect((store.currentRoute, tracker.appReports), (null, false));
      expect(store.add('in between').route, isNull);
      tracker.onEvent(VmIsolateEvent('IsolateStart', 'isolates/2', name: 'main'));
      tracker.onEvent(route({'location': '/late'}, isolate: 'isolates/1')); // the old one: ignored
      tracker.onEvent(route({'location': '/'}, isolate: 'isolates/2'));
      expect(store.currentRoute, '/');
    });

    test("another isolate's report or exit changes nothing", () {
      tracker.onEvent(route({'location': '/a'}));
      tracker.onEvent(VmIsolateEvent('IsolateStart', 'isolates/9', name: 'compute'));
      tracker.onEvent(route({'location': '/from-worker'}, isolate: 'isolates/9'));
      tracker.onEvent(VmIsolateEvent('IsolateExit', 'isolates/9', name: 'compute'));
      expect(store.currentRoute, '/a');
    });

    test('a problem is said once a session', () {
      tracker.onEvent(route({'location': 1}));
      tracker.onEvent(route({}));
      tracker.onEvent(route({'location': '/a', 'name': 2}));
      tracker.onEvent(route({'location': '/b', 'name': 2}));
      expect(warnings, [
        'Emu.Route without a `location` string — the event is ignored',
        'Emu.Route `name` is not a string — the field is ignored',
      ]);
      expect([for (final e in routes()) e.route], ['/a', '/b']);
    });

    test('disconnected forgets the screen', () {
      tracker.onEvent(route({'location': '/a'}));
      tracker.disconnected();
      expect((store.currentRoute, store.currentRouteName), (null, null));
    });
  });

  group('RouteWatcher', () {
    late LogStore store;
    late List<String> warnings;
    late List<String> connects;
    late List<FakeSource> sources;
    late List<RouteCollection> states;
    Object? failWith;

    RouteWatcher watcher({Duration retryAfter = Duration.zero}) => RouteWatcher(
          tracker: RouteTracker(store, warn: warnings.add),
          connect: (uri) async {
            connects.add(uri);
            final error = failWith;
            if (error != null) throw error;
            final s = FakeSource(isolate: 'isolates/1');
            sources.add(s);
            return s;
          },
          warn: warnings.add,
          onState: states.add,
          retryAfter: retryAfter,
        );

    setUp(() {
      store = LogStore();
      warnings = [];
      connects = [];
      sources = [];
      states = [];
      failWith = null;
    });

    test('follows the URI: connects, feeds the tracker, connects again on a new URI, closes on none', () async {
      final w = watcher();
      await w.follow(null);
      expect([connects, w.state], [<String>[], RouteCollection.connecting]);
      await w.follow('ws://a');
      expect([connects, w.state], [['ws://a'], RouteCollection.on]);
      sources.single.add(route({'location': '/a'}));
      await pump();
      expect(store.currentRoute, '/a');

      await w.follow('ws://a'); // the status said the same URI again
      expect(connects, ['ws://a']);
      await w.follow('ws://b');
      expect([connects, sources.first.closed, store.currentRoute], [['ws://a', 'ws://b'], true, null]);
      await w.follow(null);
      expect((sources.last.closed, w.state), (true, RouteCollection.connecting));
      expect(states, [RouteCollection.on, RouteCollection.connecting, RouteCollection.on, RouteCollection.connecting]);
      await w.dispose();
    });

    test('a failed connection is one warning and a state; the URI changing tries again', () async {
      final w = watcher();
      failWith = StateError('refused');
      await w.follow('ws://a');
      expect((w.state, w.error), (RouteCollection.failed, 'Bad state: refused'));
      expect(warnings, ["timeline: no screen changes — could not connect to the app's VM Service: Bad state: refused"]);
      failWith = null;
      await w.follow('ws://b');
      expect([w.state, w.error], [RouteCollection.on, isNull]);
      await w.dispose();
    });

    test('a connection that drops under the same URI is tried again once', () async {
      final w = watcher();
      await w.follow('ws://a');
      await sources.single.close();
      await pump();
      await pump();
      expect(connects, ['ws://a', 'ws://a']);
      expect(w.state, RouteCollection.on);
      await sources.last.close();
      await pump();
      await pump();
      expect(connects, hasLength(2), reason: 'once');
      expect(w.state, RouteCollection.connecting);
      await w.dispose();
    });

    test('a URI that changes while connecting closes the late connection', () async {
      final gate = Completer<void>();
      final late = FakeSource();
      final w = RouteWatcher(
        tracker: RouteTracker(store, warn: warnings.add),
        connect: (uri) async {
          connects.add(uri);
          if (uri == 'ws://slow') {
            await gate.future;
            return late;
          }
          return FakeSource();
        },
        warn: warnings.add,
      );
      final slow = w.follow('ws://slow');
      await pump(); // now waiting to connect
      await w.follow('ws://fast');
      gate.complete();
      await slow;
      expect((late.closed, w.state), (true, RouteCollection.on));
      await w.dispose();
    });
  });
}
