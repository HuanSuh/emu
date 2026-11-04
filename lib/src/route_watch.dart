/// Screen changes for the timeline, when `emu.yaml` turns them on
/// (`timeline: {routes: true}`).
///
/// The server keeps one VM Service connection to the app for the session and
/// listens on the `Extension` stream for `Emu.Route`, an event the app posts
/// with `dart:developer`'s `postEvent` — no emu package (the contract is in
/// the README). Each one sets the screen [LogStore] stamps on every entry
/// and writes a `route` entry.
///
/// `flutter run` goes through DDS, which keeps the stream's past events and
/// sends them to each new subscriber before it answers the subscription:
/// those arrive marked [VmExtensionEvent.history]. They set the current
/// screen (the app's last report) but write no entry — they happened before.
///
/// An app that sends no `Emu.Route` still gets screens, worked out without
/// its code (the "framework" layer, [RouteTracker]): after a framework
/// `Flutter.Navigation` event, or a location from a listener emu puts on the
/// app's `RouteInformationProvider` ([routerListenerExpression]), a snapshot
/// of the routes on screen ([snapshotExpression], answered as an
/// `Emu.Snapshot` event). Once the app's isolate sends an `Emu.Route`, only
/// what it sends counts — until a hot restart.
library;

import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'log_store.dart';
import 'models.dart';

/// Screen collection as `/api/logs` reports it (`routes`).
enum RouteCollection {
  /// `timeline.routes` is not on: no connection, no screens.
  off,

  /// On, not connected: no app yet, or connecting.
  connecting,
  on,

  /// The connection failed: logs, requests and inputs go on without screens.
  failed,
}

/// One event of the app's VM Service, as screen collection needs it.
sealed class VmEvent {}

class VmExtensionEvent extends VmEvent {
  VmExtensionEvent(this.kind, this.isolate, this.data, {this.history = false});
  final String kind;
  final String? isolate;
  final Map<String, dynamic> data;

  /// DDS kept it from before this connection subscribed.
  final bool history;
}

class VmIsolateEvent extends VmEvent {
  VmIsolateEvent(this.kind, this.isolate, {this.name});

  /// `IsolateStart`, `IsolateRunnable`, `IsolateExit`, …
  final String kind;
  final String? isolate;
  final String? name;
}

/// A subscribed connection to the app — a seam for tests (`EmuServer(routeSource:)`).
abstract interface class VmEventSource {
  /// The app's isolate when it subscribed, or null.
  String? get isolate;

  /// Past events first (marked [VmExtensionEvent.history]), then live ones;
  /// done when the connection closes.
  Stream<VmEvent> get events;

  /// [expression] in the scope of the library [libraryUri] of [isolate],
  /// now (no pause): the string it gives, or null. Throws when it can't.
  Future<String?> evaluate(String isolate, String libraryUri, String expression);
  Future<void> close();
}

typedef VmEventSourceFactory = Future<VmEventSource> Function(String wsUri);

class _VmServiceSource implements VmEventSource {
  _VmServiceSource(this._service);
  final VmService _service;
  final _events = StreamController<VmEvent>();

  @override
  String? isolate;

  @override
  Stream<VmEvent> get events => _events.stream;

  void _add(VmEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// Library ids by isolate and uri: an isolate's are fixed until it goes.
  final Map<String, Map<String, String>> _libraries = {};

  @override
  Future<String?> evaluate(String isolate, String libraryUri, String expression) async {
    final libs = _libraries[isolate] ??= {
      for (final l in (await _service.getIsolate(isolate)).libraries ?? const <LibraryRef>[])
        if (l.uri != null && l.id != null) l.uri!: l.id!,
    };
    final lib = libs[libraryUri];
    if (lib == null) return null;
    final r = await _service.evaluate(isolate, lib, expression);
    if (r is! InstanceRef || r.kind != InstanceKind.kString) return null;
    if (r.valueAsStringIsTruncated ?? false) {
      final full = await _service.getObject(isolate, r.id!);
      if (full is Instance) return full.valueAsString;
    }
    return r.valueAsString;
  }

  @override
  Future<void> close() async {
    await _service.dispose();
    // Not awaited: with no one listening (a connection dropped before it was
    // used) the close would never finish.
    if (!_events.isClosed) unawaited(_events.close());
  }
}

/// Connect to [wsUri] and subscribe to its `Extension` and `Isolate` streams.
Future<VmEventSource> connectVmEvents(String wsUri) async {
  final service = await vmServiceConnectUri(wsUri);
  final source = _VmServiceSource(service);
  var answered = false;
  service.onExtensionEvent.listen((e) => source._add(VmExtensionEvent(
      e.extensionKind ?? '', e.isolate?.id, e.extensionData?.data ?? const {}, history: !answered)));
  service.onIsolateEvent.listen((e) => source._add(VmIsolateEvent(e.kind ?? '', e.isolate?.id, name: e.isolate?.name)));
  unawaited(service.onDone.then((_) {
    if (!source._events.isClosed) source._events.close();
  }));
  try {
    // DDS sends what it kept, then answers, with nothing in between: all
    // that comes before the answer is history.
    await service.streamListen(EventStreams.kExtension);
    answered = true;
    await service.streamListen(EventStreams.kIsolate);
    final isolates = (await service.getVM()).isolates ?? const <IsolateRef>[];
    source.isolate = (isolates.where((i) => i.name == 'main').firstOrNull ?? isolates.firstOrNull)?.id;
  } catch (_) {
    await source.close();
    rethrow;
  }
  return source;
}

/// Where the framework layer's expressions run: its scope has
/// `WidgetsBinding`, `ModalRoute`, `PopupRoute`, `Page`, `Timer` and
/// `dart:developer` (as `developer`). `Router` is not imported there, so it
/// is found by its type's name.
const frameworkLibrary = 'package:flutter/src/widgets/navigator.dart';

/// One line from [source]: flutter_tools hands an expression to its compiler
/// by lines, and a second line fails to compile. No `//` comments in [source].
String oneLine(String source) =>
    source.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');

/// Has the app look at the routes on screen and post them as an
/// `Emu.Snapshot` event `{location, chain}`: the `Router`'s location (null
/// without one), and from the outermost Navigator in, each current route's
/// `name`, runtime `type`, whether its settings are a `Page` (the router put
/// it there) and whether it is a `PopupRoute` (a dialog, a sheet) — or
/// `{error}`. Routes that aren't current are skipped with what's under them,
/// so what is left is what's on top. Each route is found as the
/// `_ModalScope` widget it builds — a private name, matched as text: if
/// Flutter renames it the chain comes back empty rather than wrong.
///
/// The look waits for the app's next turn (`Timer.run`): an evaluation can
/// land in the middle of a frame being built, where the element tree can't
/// be walked (`visitChildElements() called during build`).
final snapshotExpression = oneLine(r'''
(() {
  Timer.run(() {
    try {
      final root = WidgetsBinding.instance.rootElement;
      String? location;
      final chain = <Map<String, Object?>>[];
      void visit(Element e) {
        final w = e.widget;
        final t = w.runtimeType.toString();
        if (location == null && t.startsWith('Router<')) {
          try {
            final uri = (w as dynamic).routeInformationProvider?.value?.uri;
            if (uri != null) location = '$uri';
          } catch (_) {}
        }
        if (t.startsWith('_ModalScope<')) {
          final r = (w as dynamic).route as ModalRoute<dynamic>;
          if (!r.isCurrent) return;
          chain.add({'name': r.settings.name, 'type': '${r.runtimeType}', 'page': r.settings is Page, 'popup': r is PopupRoute});
        }
        e.visitChildElements(visit);
      }
      if (root != null) visit(root);
      developer.postEvent('Emu.Snapshot', {'location': location, 'chain': chain});
    } catch (e) {
      developer.postEvent('Emu.Snapshot', {'error': '$e'});
    }
  });
  return 'scheduled';
})()
''');

/// Puts a listener on the app's `RouteInformationProvider` that sends each
/// new location as `Emu.RouterInformation`: what a snapshot can't see, as
/// `go_router` reports a `push` to its listeners and then quietly puts the
/// location back. Once per isolate: it registers the service extension
/// `ext.emu.timelineRouter` and stops when that is taken. Gives
/// `listening`, `already`, or — try again later — `no router` (the app may
/// not have built its `Router` yet) or `busy` (it landed mid-build, see
/// [snapshotExpression]).
final routerListenerExpression = oneLine(r'''
(() {
  final root = WidgetsBinding.instance.rootElement;
  dynamic provider;
  void find(Element e) {
    if (provider != null) return;
    final w = e.widget;
    if (w.runtimeType.toString().startsWith('Router<')) {
      provider = (w as dynamic).routeInformationProvider;
      if (provider != null) return;
    }
    e.visitChildElements(find);
  }
  try {
    if (root != null) find(root);
  } catch (_) {
    return 'busy';
  }
  final p = provider;
  if (p == null) return 'no router';
  try {
    developer.registerExtension('ext.emu.timelineRouter', (m, a) async => developer.ServiceExtensionResponse.result('{}'));
  } catch (_) {
    return 'already';
  }
  p.addListener(() => developer.postEvent('Emu.RouterInformation', {'location': '${p.value.uri}'}));
  return 'listening';
})()
''');

/// The framework layer's screen from a [snapshot] (an `Emu.Snapshot`, see
/// [snapshotExpression]) and the router listener's last location, or null
/// when it shows nothing to go by:
///
/// - `route`: the router's location ([routerLocation] first — a `push`
///   only shows there), else the top route's name, else its type. A top
///   route the router didn't put there (a dialog, a sheet, a
///   `Navigator.push`ed page) is added as `location · <its name or type>`.
/// - `name`: the innermost router page's name (`go_router`: its name or
///   path pattern); without a router, the top route's name.
({String route, String? name, Map<String, dynamic> data})? frameworkRoute(Map<String, dynamic>? snapshot,
    {String? routerLocation}) {
  final json = snapshot;
  if (json == null) return null;
  final chain = [
    for (final r in (json['chain'] is List ? json['chain'] as List : const []))
      if (r is Map) (name: r['name'] is String ? r['name'] as String : null, type: '${r['type']}', page: r['page'] == true),
  ];
  final seen = json['location'];
  final location = routerLocation ?? (seen is String && seen.isNotEmpty ? seen : null);
  final top = chain.lastOrNull;
  if (location == null) {
    if (top == null) return null;
    return (route: top.name ?? top.type, name: top.name, data: {'via': 'framework', 'name': ?top.name, 'description': top.type});
  }
  final page = chain.where((r) => r.page).lastOrNull;
  final detail = top != null && !top.page ? top.name ?? top.type : null;
  return (
    route: detail != null ? '$location · $detail' : location,
    name: page?.name,
    data: {
      'via': 'framework',
      'location': location,
      'name': ?page?.name,
      'detail': ?detail,
      'description': ?top?.type,
    },
  );
}

/// How much of each `Emu.Route` value is kept, in characters.
const routeValueLimit = 1024;

/// The fields of an `Emu.Route` event (the README's contract): `location`, a
/// non-empty string, and optional `name` and `detail` strings. Other fields
/// are ignored and each value is cut at [routeValueLimit]; values are kept as
/// sent otherwise. Null, after telling [problem] why, when it can't be used.
({String location, String? name, String? detail})? parseEmuRoute(
    Map<String, dynamic> data, void Function(String problem) problem) {
  String cut(String s) => s.runes.length > routeValueLimit ? String.fromCharCodes(s.runes.take(routeValueLimit)) : s;
  String? optional(String key) {
    final v = data[key];
    if (v == null) return null;
    if (v is! String) {
      problem('Emu.Route `$key` is not a string — the field is ignored');
      return null;
    }
    return v.isEmpty ? null : cut(v);
  }

  final location = data['location'];
  if (location is! String || location.trim().isEmpty) {
    problem('Emu.Route without a `location` string — the event is ignored');
    return null;
  }
  return (location: cut(location), name: optional('name'), detail: optional('detail'));
}

/// What `Emu.Route` events mean for the timeline, apart from the connection:
/// fed [VmEvent]s, it keeps [store]'s current screen and writes `route` entries.
class RouteTracker {
  RouteTracker(this.store, {required this.warn, this.debounce = const Duration(milliseconds: 150)});

  final LogStore store;

  /// How long the framework layer waits after a trigger before it looks:
  /// a `pushAndRemoveUntil` or a burst of pops is one look.
  final Duration debounce;

  /// A problem with the app's events — said once a session, or an app that
  /// sends bad ones would fill the log.
  final void Function(String message) warn;
  final Set<String> _warned = {};

  /// The app's isolate: other isolates' events (one from before a hot
  /// restart in DDS's history, a background isolate's) don't set the screen.
  String? _isolate;

  /// Whether the app's isolate sent an `Emu.Route`: it reports its screens itself.
  bool appReports = false;

  void _problem(String message) {
    if (_warned.add(message)) warn(message);
  }

  /// A connection subscribed; [isolate] is the app's. Events follow.
  /// [evaluate] runs the framework layer's expressions; without it there is
  /// only what the app reports.
  void connected(String? isolate, {Future<String?> Function(String isolate, String library, String expression)? evaluate}) {
    _isolate = isolate;
    _evaluate = evaluate;
    _resetFramework();
    _look();
  }

  /// The connection is gone: the app stopped or restarted, or the URI changed.
  void disconnected() {
    _isolate = null;
    _evaluate = null;
    _clear();
  }

  void _clear() {
    store.currentRoute = null;
    store.currentRouteName = null;
    appReports = false;
    _resetFramework();
  }

  // ---- the framework layer ---------------------------------------------------

  Future<String?> Function(String isolate, String library, String expression)? _evaluate;
  Timer? _lookTimer;

  /// The router listener's last location, and whether it is on, for [_isolate].
  String? _routerLocation;
  bool _listening = false;

  void _resetFramework() {
    _lookTimer?.cancel();
    _lookTimer = null;
    _routerLocation = null;
    _listening = false;
  }

  /// Look at the screen after [debounce] — again, if a look was due.
  void _look() {
    if (_evaluate == null || appReports) return;
    _lookTimer?.cancel();
    _lookTimer = Timer(debounce, () => unawaited(_snapshot()));
  }

  Future<String?> _run(String isolate, String expression) async {
    try {
      return await _evaluate?.call(isolate, frameworkLibrary, expression);
    } catch (_) {
      return null; // a reload compiling, the isolate going: the next trigger looks again
    }
  }

  /// Put the router listener on if it isn't, then have the app take a
  /// snapshot: it answers with an `Emu.Snapshot` event ([_apply]).
  Future<void> _snapshot() async {
    final isolate = _isolate;
    if (isolate == null || appReports) return;
    if (!_listening) {
      final r = await _run(isolate, routerListenerExpression);
      if (isolate == _isolate && (r == 'listening' || r == 'already')) _listening = true;
    }
    if (isolate == _isolate && !appReports) await _run(isolate, snapshotExpression);
  }

  void _apply(Map<String, dynamic> snapshot) {
    final seen = frameworkRoute(snapshot, routerLocation: _routerLocation);
    if (seen == null) return;
    if (seen.route == store.currentRoute && seen.name == store.currentRouteName) return;
    store.currentRoute = seen.route;
    store.currentRouteName = seen.name;
    store.add('[route] ${seen.route}', level: LogLevel.system, source: 'route', kind: LogKind.route, data: seen.data);
  }

  void onEvent(VmEvent e) {
    switch (e) {
      case VmIsolateEvent(kind: 'IsolateExit', :final isolate) when isolate != null && isolate == _isolate:
        // Hot restart: the screen is unknown until the new isolate says.
        _isolate = null;
        _clear();
      case VmIsolateEvent(kind: 'IsolateStart' || 'IsolateRunnable', :final isolate, :final name)
          when _isolate == null && (name == null || name == 'main'):
        _isolate = isolate;
        _look();
      case VmExtensionEvent(kind: 'Flutter.Navigation' || 'Flutter.FirstFrame', :final isolate, history: false)
          when isolate == null || isolate == _isolate:
        // The event's own route isn't used: a pop names the route it closed.
        _look();
      case VmExtensionEvent(kind: 'Emu.RouterInformation', :final isolate, :final data, history: false)
          when isolate == null || isolate == _isolate:
        if (data['location'] case final String location when location.isNotEmpty) _routerLocation = location;
        _look();
      case VmExtensionEvent(kind: 'Emu.Snapshot', :final isolate, :final data, history: false)
          when (isolate == null || isolate == _isolate) && _evaluate != null && !appReports:
        _apply(data);
      case VmExtensionEvent(kind: 'Emu.Route', :final isolate, :final data, :final history):
        if (_isolate != null && isolate != null && isolate != _isolate) return;
        if (_isolate == null) {
          // DDS's past: only the app's isolate counts, and it is unknown.
          if (history) return;
          _isolate = isolate;
        }
        final route = parseEmuRoute(data, _problem);
        if (route == null) return;
        // The app reports its screens: stop guessing them for this isolate.
        appReports = true;
        _lookTimer?.cancel();
        _set(route, entry: !history);
      default:
        break;
    }
  }

  void _set(({String location, String? name, String? detail}) r, {required bool entry}) {
    final value = r.detail != null ? '${r.location} · ${r.detail}' : r.location;
    // A report of the screen it already is: one screen, one entry.
    if (value == store.currentRoute && r.name == store.currentRouteName) return;
    store.currentRoute = value;
    store.currentRouteName = r.name;
    if (!entry) return;
    store.add('[route] $value',
        level: LogLevel.system,
        source: 'route',
        kind: LogKind.route,
        data: {'via': 'app', 'location': r.location, 'name': ?r.name, 'detail': ?r.detail});
  }
}

/// The connection's life: it follows the app's VM Service URI (the engine's
/// status) — connects, connects again when the URI changes, closes when it
/// goes. A failure is said once and leaves the session as it was.
class RouteWatcher {
  RouteWatcher({
    required this.tracker,
    required this.connect,
    required this.warn,
    this.onState,
    this.retryAfter = const Duration(seconds: 2),
  });

  final RouteTracker tracker;
  final VmEventSourceFactory connect;
  final void Function(String message) warn;
  final void Function(RouteCollection state)? onState;

  /// How long after the connection drops under an unchanged URI it is tried
  /// again, once.
  final Duration retryAfter;

  RouteCollection state = RouteCollection.connecting;

  /// Why [state] is [RouteCollection.failed].
  String? error;

  String? _uri;
  VmEventSource? _source;
  StreamSubscription<VmEvent>? _sub;
  int _generation = 0;
  bool _retried = false;
  bool _disposed = false;

  void _setState(RouteCollection next) {
    if (state == next) return;
    state = next;
    onState?.call(next);
  }

  /// The app's VM Service is now [uri]; null while there is none.
  Future<void> follow(String? uri) async {
    if (_disposed || uri == _uri) return;
    _uri = uri;
    _retried = false;
    await _open(uri);
  }

  Future<void> _open(String? uri) async {
    final generation = ++_generation;
    await _drop();
    if (generation != _generation || _disposed) return; // a newer URI took over
    tracker.disconnected();
    _setState(RouteCollection.connecting);
    if (uri == null) return;
    try {
      final source = await connect(uri);
      if (generation != _generation || _disposed) {
        await source.close();
        return;
      }
      _source = source;
      tracker.connected(source.isolate, evaluate: source.evaluate);
      _sub = source.events.listen(tracker.onEvent, onDone: () => _closed(generation, uri));
      error = null;
      _setState(RouteCollection.on);
    } catch (e) {
      if (generation != _generation || _disposed) return;
      error = '$e';
      _setState(RouteCollection.failed);
      warn('timeline: no screen changes — could not connect to the app\'s VM Service: $e');
    }
  }

  /// The connection closed by itself. Usually the URI changes next (a cold
  /// restart, a stop); if it is still the same after [retryAfter], try again.
  void _closed(int generation, String uri) {
    if (generation != _generation || _disposed) return;
    _source = null;
    _sub = null;
    tracker.disconnected();
    _setState(RouteCollection.connecting);
    if (_retried) return;
    _retried = true;
    Timer(retryAfter, () {
      if (generation == _generation && !_disposed && _uri == uri) unawaited(_open(uri));
    });
  }

  Future<void> _drop() async {
    final sub = _sub, source = _source;
    _sub = null;
    _source = null;
    await sub?.cancel();
    await source?.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    tracker.disconnected();
    await _drop();
  }
}
