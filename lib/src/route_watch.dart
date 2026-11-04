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
  RouteTracker(this.store, {required this.warn});

  final LogStore store;

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
  void connected(String? isolate) {
    _isolate = isolate;
  }

  /// The connection is gone: the app stopped or restarted, or the URI changed.
  void disconnected() {
    _isolate = null;
    _clear();
  }

  void _clear() {
    store.currentRoute = null;
    store.currentRouteName = null;
    appReports = false;
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
      case VmExtensionEvent(kind: 'Emu.Route', :final isolate, :final data, :final history):
        if (_isolate != null && isolate != null && isolate != _isolate) return;
        if (_isolate == null) {
          // DDS's past: only the app's isolate counts, and it is unknown.
          if (history) return;
          _isolate = isolate;
        }
        final route = parseEmuRoute(data, _problem);
        if (route == null) return;
        appReports = true;
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
      tracker.connected(source.isolate);
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
    await _drop();
  }
}
