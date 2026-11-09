import 'dart:async';
import 'dart:convert';

import 'package:emu/src/log_store.dart';
import 'package:emu/src/models.dart';
import 'package:emu/src/route_watch.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show RPCError, RPCErrorKind;

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
  Future<String?> evaluate(String isolate, String libraryUri, String expression) async => null;

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

  group('frameworkRoute', () {
    // As the app posts it: decoded by the VM Service client.
    Map<String, dynamic> snap(Object? location, List<Map<String, Object?>> chain) =>
        jsonDecode(jsonEncode({'location': location, 'chain': chain})) as Map<String, dynamic>;
    Map<String, Object?> page(String? name, {String type = '_PageBasedMaterialPageRoute<void>'}) =>
        {'name': name, 'type': type, 'page': true, 'popup': false};
    Map<String, Object?> route(String? name, {String type = 'MaterialPageRoute<void>', bool popup = false}) =>
        {'name': name, 'type': type, 'page': false, 'popup': popup};
    (String, String?)? of(Map<String, dynamic>? s, {String? routerLocation}) {
      final r = frameworkRoute(s, routerLocation: routerLocation);
      return r == null ? null : (r.route, r.name);
    }

    test('a router: its location, named by the innermost router page', () {
      expect(of(snap('/user/42', [page('user')])), ('/user/42', 'user'));
      expect(of(snap('/shop/item/3', [page(null), page('item/:id')])), ('/shop/item/3', 'item/:id'));
    });

    test("the listener's location wins: a push only shows there", () {
      expect(of(snap('/user/42', [page('user')]), routerLocation: '/user/8'), ('/user/8', 'user'));
    });

    test("what the router didn't put on top is the detail", () {
      expect(of(snap('/', [page('home'), route(null, type: 'DialogRoute<void>', popup: true)])),
          ('/ · DialogRoute<void>', 'home'));
      expect(of(snap('/shop', [page(null), route('shell-plain')])), ('/shop · shell-plain', null));
      final r = frameworkRoute(snap('/', [route(null, type: 'ModalBottomSheetRoute<void>', popup: true)]))!;
      expect(r.data, {'via': 'framework', 'location': '/', 'detail': 'ModalBottomSheetRoute<void>', 'description': 'ModalBottomSheetRoute<void>'});
    });

    test('no router (Navigator 1.0): the top route by name, else by type', () {
      expect(of(snap(null, [route('/'), route('/details')])), ('/details', '/details'));
      expect(of(snap(null, [route(null)])), ('MaterialPageRoute<void>', null));
    });

    test('nothing to go by, or a snapshot that failed: null', () {
      for (final s in <Map<String, dynamic>?>[null, {}, snap(null, []), {'chain': 'x'}, {'error': 'Bad state: boom'}]) {
        expect(frameworkRoute(s), isNull, reason: '$s');
      }
      // A location from the listener doesn't make a failed snapshot a screen.
      expect(frameworkRoute({'error': 'Bad state: boom'}, routerLocation: '/user/8'), isNull);
    });

    test('the expressions are one line each, with no comment to swallow the rest', () {
      for (final e in [snapshotExpression, routerListenerExpression]) {
        expect(e, isNot(contains('\n')));
        expect(e, isNot(contains('//')));
        expect(e, startsWith('(() {'));
        expect(e, endsWith('})()'));
      }
    });
  });

  group('RouteTracker framework layer', () {
    late LogStore store;
    late RouteTracker tracker;
    late List<String> calls;
    late Map<String, dynamic>? snapshot;
    late String? listener;

    /// The app's side: the snapshot expression answers on its next turn,
    /// with an Emu.Snapshot event.
    Future<String?> evaluate(String isolate, String library, String expression) async {
      expect(library, frameworkLibrary);
      final which = identical(expression, snapshotExpression) ? 'snapshot' : 'listener';
      calls.add('$which@$isolate');
      if (which == 'listener') return listener;
      final answer = snapshot;
      if (answer != null) Timer.run(() => tracker.onEvent(VmExtensionEvent('Emu.Snapshot', isolate, answer)));
      return 'scheduled';
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));
    Map<String, dynamic> snap(String? location, String name, {int? id}) => {
          'location': location,
          'chain': [
            {'name': name, 'type': 'MaterialPageRoute<void>', 'page': location != null, 'popup': false, 'id': ?id}
          ],
        };
    void routerSays(String location) =>
        tracker.onEvent(VmExtensionEvent('Emu.RouterInformation', 'isolates/1', {'location': location}));
    void navigated() => tracker.onEvent(VmExtensionEvent('Flutter.Navigation', 'isolates/1', const {}));
    List<String?> screens() => [for (final e in store.query(kinds: {LogKind.route})) e.route];

    setUp(() {
      store = LogStore();
      calls = [];
      snapshot = snap('/', 'home');
      listener = 'listening';
      tracker = RouteTracker(store, warn: (_) {}, debounce: const Duration(milliseconds: 5));
    });
    tearDown(() => tracker.disconnected());

    test('looks once connected: puts the listener on, then a route entry from the snapshot', () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      expect(calls, ['listener@isolates/1', 'snapshot@isolates/1']);
      final e = store.query(kinds: {LogKind.route}).single;
      expect((e.text, e.route, e.routeName, e.data?['via']), ('[route] /', '/', 'home', 'framework'));
    });

    test('a burst of navigation events is one look; the listener goes on once', () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      calls.clear();
      snapshot = snap('/user/42', 'user');
      for (var i = 0; i < 3; i++) {
        tracker.onEvent(VmExtensionEvent('Flutter.Navigation', 'isolates/1', const {}));
      }
      await settle();
      expect(calls, ['snapshot@isolates/1']);
      expect(store.currentRoute, '/user/42');
    });

    test("no router yet: the listener is tried again on the next look", () async {
      listener = 'no router';
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      listener = 'listening';
      tracker.onEvent(VmExtensionEvent('Flutter.FirstFrame', 'isolates/1', const {}));
      await settle();
      expect(calls, ['listener@isolates/1', 'snapshot@isolates/1', 'listener@isolates/1', 'snapshot@isolates/1']);
    });

    test("the router listener's location goes into the next look", () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      snapshot = snap('/user/42', 'user'); // what the router says after a push: the location before it
      tracker.onEvent(VmExtensionEvent('Emu.RouterInformation', 'isolates/1', const {'location': '/user/8'}));
      await settle();
      expect((store.currentRoute, store.currentRouteName), ('/user/8', 'user'));
    });

    test('a pushed page keeps its location; a pop the listener does not hear of shows the page under it', () async {
      snapshot = snap('/user/42', 'user', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      // go_router tells the listener where the push goes, then puts its location back.
      snapshot = snap('/user/42', 'user', id: 2);
      routerSays('/user/8');
      await settle();
      expect(store.currentRoute, '/user/8');
      // The back button: the Navigator pops; the listener hears nothing.
      snapshot = snap('/user/42', 'user', id: 1);
      navigated();
      await settle();
      expect(screens(), ['/user/42', '/user/8', '/user/42']);
    });

    test('pops walk back through pushed pages; go_router restoring its location on pop is not a push', () async {
      snapshot = snap('/', 'home', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      for (final (id, location) in [(2, '/a'), (3, '/b')]) {
        snapshot = snap('/', location, id: id);
        routerSays(location);
        await settle();
      }
      // context.pop(): the Navigator pops, then the listener hears the router's location — '/', not '/a'.
      snapshot = snap('/', '/a', id: 2);
      navigated();
      routerSays('/');
      await settle();
      snapshot = snap('/', 'home', id: 1);
      navigated();
      await settle();
      expect(screens(), ['/', '/a', '/b', '/a', '/']);
    });

    test('a replace that keeps the page: its new location, also when the page is on top again', () async {
      snapshot = snap('/', 'home', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      snapshot = snap('/', 'a', id: 2);
      routerSays('/a');
      await settle();
      routerSays('/a?step=2'); // go_router's replace keeps the page key: the same route, id 2
      await settle();
      snapshot = snap('/', 'b', id: 3);
      routerSays('/b');
      await settle();
      snapshot = snap('/', 'a', id: 2);
      navigated();
      await settle();
      expect(screens(), ['/', '/a', '/a?step=2', '/b', '/a?step=2']);
    });

    test('a look before the pushed page is built: its location, then kept for the page', () async {
      snapshot = snap('/', 'home', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      snapshot = snap('/a', 'home', id: 1); // the old page; the router not put back yet
      routerSays('/a');
      await settle();
      expect(store.currentRoute, '/a');
      snapshot = snap('/', 'a', id: 2); // built and put back; the next navigation event brings the look
      navigated();
      await settle();
      expect((store.currentRoute, store.currentRouteName), ('/a', 'a'));
      snapshot = snap('/', 'home', id: 1);
      navigated();
      await settle();
      expect(store.currentRoute, '/');
    });

    test('a push popped before the look is not a screen', () async {
      snapshot = snap('/', 'home', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      routerSays('/a');
      navigated(); // within the debounce: one look, at the page from before
      await settle();
      expect(screens(), ['/']);
    });

    test("a go within the page is the router's location; the listener giving that location again is not a push",
        () async {
      snapshot = snap('/', 'home', id: 1);
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      snapshot = snap('/?tab=2', 'home', id: 1);
      routerSays('/?tab=2');
      await settle();
      snapshot = snap('/?tab=2', 'a', id: 2);
      routerSays('/a');
      await settle();
      routerSays('/?tab=2'); // a refresh, with the pushed page on top
      await settle();
      expect(store.currentRoute, '/a');
      snapshot = snap('/?tab=2', 'home', id: 1);
      navigated();
      await settle();
      expect(screens(), ['/', '/?tab=2', '/a', '/?tab=2']);
    });

    test("an expression the app can't compile is one warning a session; other failures say nothing", () async {
      final warnings = <String>[];
      Object failure = RPCError.withDetails('evaluate', RPCErrorKind.kExpressionCompilationError.code,
          'Expression compilation error',
          details: "org-dartlang-debug:synthetic_debug_expression:1:300: Error: The getter 'isCurrent' isn't defined\n"
              'for the class ModalRoute');
      tracker = RouteTracker(store, warn: warnings.add, debounce: const Duration(milliseconds: 5))
        ..connected('isolates/1', evaluate: (i, l, e) async => throw failure);
      await settle();
      navigated();
      await settle();
      expect(warnings, [
        "timeline: screens without Emu.Route can be missing — emu's expression does not compile in this app: "
            "org-dartlang-debug:synthetic_debug_expression:1:300: Error: The getter 'isCurrent' isn't defined",
      ]);
      warnings.clear();
      for (final other in [StateError('compiling'), RPCError('evaluate', RPCErrorKind.kServerError.code, 'boom')]) {
        failure = other;
        navigated();
        await settle();
      }
      expect(warnings, isEmpty);
    });

    test("once the app's isolate sends Emu.Route, only that counts — until a hot restart", () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      tracker.onEvent(route({'location': '/from-app'})); // before the first look is due
      await settle();
      expect(calls, isEmpty);
      tracker.onEvent(VmExtensionEvent('Flutter.Navigation', 'isolates/1', const {}));
      await settle();
      expect([calls, store.currentRoute], [<String>[], '/from-app']);

      tracker.onEvent(VmIsolateEvent('IsolateExit', 'isolates/1', name: 'main'));
      tracker.onEvent(VmIsolateEvent('IsolateRunnable', 'isolates/2', name: 'main'));
      await settle();
      expect(calls, ['listener@isolates/2', 'snapshot@isolates/2']);
      expect(store.currentRoute, '/');
    });

    test("old events from DDS's history don't trigger a look of their own", () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      calls.clear();
      tracker.onEvent(VmExtensionEvent('Flutter.Navigation', 'isolates/1', const {}, history: true));
      await settle();
      expect(calls, isEmpty);
    });

    test('a failing evaluation, or a snapshot that failed in the app, leaves the screen as it was', () async {
      tracker.connected('isolates/1', evaluate: (i, l, e) async => throw StateError('compiling'));
      await settle();
      tracker.onEvent(VmExtensionEvent('Emu.Snapshot', 'isolates/1', const {'error': 'Bad state: boom'}));
      expect([store.currentRoute, store.query(kinds: {LogKind.route})], [null, isEmpty]);
    });

    test("a snapshot from DDS's history, or another isolate's, is not applied", () async {
      tracker.connected('isolates/1', evaluate: evaluate);
      await settle();
      tracker.onEvent(VmExtensionEvent('Emu.Snapshot', 'isolates/1', snap('/old', 'old'), history: true));
      tracker.onEvent(VmExtensionEvent('Emu.Snapshot', 'isolates/0', snap('/other', 'other')));
      expect(store.currentRoute, '/');
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
