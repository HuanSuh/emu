/// The local server: the single owner of the [FlutterEngine]. It exposes a
/// REST + WebSocket API consumed by both the CLI and the web dashboard, and
/// serves the dashboard's static assets.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_guard.dart';
import 'device_lease.dart';
import 'device_manager.dart';
import 'device_setup.dart';
import 'diff.dart';
import 'engine.dart';
import 'error_parser.dart';
import 'eval.dart';
import 'frame.dart';
import 'hub.dart' show hubFrameAncestors;
import 'input.dart';
import 'locate.dart';
import 'log_store.dart';
import 'memory_diff.dart' as mem;
import 'mock.dart';
import 'models.dart';
import 'open_url.dart';
import 'pages.dart';
import 'pages_api.dart';
import 'probe.dart';
import 'registry.dart';
import 'report.dart';
import 'report_api.dart';
import 'session.dart';
import 'settle.dart';
import 'temp_device.dart';
import 'version.dart';
import 'web_assets.g.dart';

/// Options for launching the app, passed from `up`.
class LaunchOptions {
  LaunchOptions({
    this.platform,
    this.deviceId,
    this.flavor,
    this.target,
    this.dartDefines = const [],
    this.dartDefineFromFile = const [],
    this.dartEntrypointArgs = const [],
    this.deviceTimeoutSec,
    this.deviceConnection,
    this.ddsPort,
    this.noDds = false,
    this.shareDevice = false,
    this.tempDevice = false,
    this.bootAvd,
    this.reversePorts = const [],
    this.forwardPorts = const [],
    this.onDeviceReady = const [],
    this.onAppStarted = const [],
    this.profile,
    this.mockPort,
    this.extra = const [],
  });

  /// `android`, `ios`, or null (let flutter choose / use deviceId).
  final String? platform;
  final String? deviceId;
  final String? flavor;
  final String? target;
  final List<String> dartDefines;
  final List<String> dartDefineFromFile;

  /// Passed to the Dart entrypoint's `main(List<String> args)` (`-a`).
  final List<String> dartEntrypointArgs;

  /// Seconds to wait for devices to attach (`--device-timeout`).
  final int? deviceTimeoutSec;

  /// `both` | `attached` | `wireless` (`--device-connection`).
  final String? deviceConnection;

  /// Bind the Dart Developer Service to this port (`--dds-port`).
  final int? ddsPort;

  /// Disable the Dart Developer Service (`--no-dds`).
  final bool noDds;

  /// Skip the device lease check (`up --share-device`): run on a device even
  /// if another emu session holds it, without taking the lease ourselves.
  final bool shareDevice;

  /// Create a throwaway device for this session (`up --temp-device`), deleted
  /// by `emu down`. Needs [platform]; see `temp_device.dart`.
  final bool tempDevice;

  /// Boot (or take, if running) this AVD and claim it (`up --boot-avd`).
  final String? bootAvd;

  /// adb port mappings + hooks (see `device_setup.dart`).
  final List<PortMapping> reversePorts;
  final List<PortMapping> forwardPorts;
  final List<String> onDeviceReady;
  final List<String> onAppStarted;

  /// `up --profile`: the server re-reads `emu.yaml` for dashboard pages with it.
  final String? profile;

  /// `mocks:` in emu.yaml: where the mock server listens (https origins;
  /// http ones on the next port). Null when mocks are off.
  final int? mockPort;
  final List<String> extra;
}

class EmuServer {
  EmuServer({required this.session, DeviceLeases? leases, SessionRegistry? registry, RecentProjects? recent})
      : leases = leases ?? DeviceLeases(),
        registry = registry ?? SessionRegistry(),
        recent = recent ?? RecentProjects();

  final Session session;

  /// Machine-wide device ownership, so two sessions never drive one device.
  final DeviceLeases leases;

  /// Machine-wide list of running sessions (`emu ls`, see `registry.dart`).
  final SessionRegistry registry;
  final RecentProjects recent;
  SessionEntry? _entry;

  /// Where `--temp-device` records the devices it creates.
  final TempDevices tempDevices = TempDevices();

  /// The device this server holds the lease on, released in [dispose].
  String? _leasedDevice;

  /// The live lease that blocked the last failed [_claim].
  DeviceLease? _lastConflict;

  /// Set first thing in [dispose], so a claim still in flight (the post-hoc
  /// one in [_claimOnceFlutterPicks]) gives its lease back instead of leaking it.
  bool _disposed = false;

  /// The status listener of [_claimOnceFlutterPicks], cancelled in [dispose].
  StreamSubscription<AppStatus>? _postHocClaim;

  /// Port mappings and hooks for this session's device.
  late final DeviceSetup setup;

  /// The device [setup] was applied to (ports are removed from it on dispose).
  String? _preparedDevice;

  /// [_prepareDevice] in flight — `onAppStarted` waits for it, so its hooks
  /// never run before the ports and `onDeviceReady` hooks are in place.
  Future<void>? _preparing;

  /// [_reapplyPorts] in flight — [dispose] waits for it before removing the
  /// mappings, so a late re-apply can't outlive the session.
  Future<void>? _reapplyRun;

  /// Re-applies port mappings adb dropped (server restart, emulator reboot).
  Timer? _portWatch;

  /// Declared mappings not active at the last check (null: not checked yet
  /// or adb unreachable) — what `/api/status` reports, so polling it never
  /// shells out to adb.
  List<(PortMapping, bool)>? _portsMissing;
  StreamSubscription<AppStatus>? _setupWatch;

  late final LogStore logStore;
  late final FlutterEngine engine;

  /// The dashboard's Changes tab / `emu diff`. Snapshots the working tree on
  /// every launch and reload so "what did that reload apply" is answerable.
  late final GitDiff diff;
  AppRunState? _lastRunState;

  /// Watches the project so the Changes tab updates as files are edited,
  /// not only on reload. Debounced: an editor save or a formatter run is a
  /// burst of events.
  StreamSubscription<FileSystemEvent>? _fileWatch;
  Timer? _fileWatchDebounce;
  StreamSubscription<AppStatus>? _snapshotSub;
  final DeviceManager devices = DeviceManager();

  /// Dashboard pages from `emu.yaml` (`pages.dart`) and the runs of their items.
  late final PagesApi pages;

  /// `emu report` from the dashboard (`report_api.dart`).
  late final ReportApi report = ReportApi(ReportSources(
    from: 'dashboard',
    scrubber: () => Scrubber.forProject(session.projectRoot.path, appIds: [
      for (final platform in ['android', 'ios']) ?builtAppId(session.projectRoot.path, platform),
    ]),
    logs: () => logStore.query(limit: 1 << 20),
    screenshot: () async {
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final out = '${session.stateDir.path}/report-shot-$ts.png';
      await devices.screenshot(out, platform: _platform, udid: engine.status.deviceId);
      return out;
    },
    session: _reportSession,
  ));
  ({String id, DeviceInfo? info})? _reportDevice;

  /// The device's kind for a report's tail (`flutter devices` once per device).
  Future<({String? device, String? appState})> _reportSession() async {
    final id = engine.status.deviceId;
    if (id != null && _reportDevice?.id != id) {
      DeviceInfo? info;
      try {
        info = (await devices.listDevices()).where((d) => d.id == id).firstOrNull;
      } catch (_) {}
      _reportDevice = (id: id, info: info);
    }
    return (
      device: id == null ? null : describeDevice(_reportDevice?.info, fallbackPlatform: platformForDeviceId(id)),
      appState: engine.status.state.name,
    );
  }

  /// `emu mock`, when emu.yaml has `mocks:` (see `mock.dart`).
  MockServer? mock;
  Timer? _pagesChangedDebounce;

  /// Changed paths not yet checked against the pages' `watch:` globs.
  final Set<String> _pageWatchPaths = {};
  Timer? _pageWatchDebounce;

  HttpServer? _http;
  final Set<WebSocketChannel> _sockets = {};

  /// Every API call but the liveness ping must carry this (see
  /// `api_guard.dart`). New on every start, so a dashboard left open from an
  /// earlier session can't drive this one.
  final String token = newSessionToken();

  int get port => _http!.port;

  Future<void> start(int requestedPort, LaunchOptions opts) async {
    session.ensureState();
    logStore = LogStore(persistFile: session.logFile..writeAsStringSync(''));
    engine = FlutterEngine(projectRoot: session.projectRoot.path, logStore: logStore);

    // Fan out engine activity to connected dashboards.
    logStore.stream.listen((e) => _broadcast({'type': 'log', 'entry': e.toJson()}));
    engine.statusStream.listen((s) => _broadcast({'type': 'status', 'status': s.toJson()}));

    diff = GitDiff(session.projectRoot.path);
    _snapshotSub = engine.statusStream.listen(_snapshotOnReload);
    pages = PagesApi(
      projectRoot: session.projectRoot.path,
      profile: opts.profile,
      environment: _pageEnvironment,
      followUp: _pageFollowUp,
      openUrl: (url) async => (await _openDeepLink(url)).$2,
      broadcast: _broadcast,
      log: (text, level) => logStore.add(text, level: level, source: 'ext'),
      autoStateFile: File('${session.stateDir.path}/pages_auto.json'),
    );
    for (final problem in pages.load().problems) {
      logStore.add('emu.yaml pages: $problem', level: LogLevel.warn, source: 'system');
    }
    unawaited(_watchFiles());

    _http = await _bind(requestedPort);
    session.writeServerInfo(port: _http!.port, pid: pid, token: token);
    _register(opts);
    shelf_io.serveRequests(_http!, _handler());
    logStore.system('emu server listening on http://127.0.0.1:${_http!.port}');
    if (opts.mockPort != null) await _startMock(opts);

    setup = DeviceSetup(
      reversePorts: opts.reversePorts,
      forwardPorts: opts.forwardPorts,
      onDeviceReady: opts.onDeviceReady,
      onAppStarted: opts.onAppStarted,
      projectRoot: session.projectRoot.path,
      log: (m, isError) => isError
          ? logStore.add(m, level: LogLevel.error, source: 'system')
          : logStore.system(m),
    );
    _watchSetup();

    // Resolve a device and launch.
    await _launch(opts);
  }

  /// Record this server in the machine-wide registry, and again once its
  /// device is known. Best effort: a read-only home must not stop a session.
  void _register(LaunchOptions opts) {
    final e = _entry = SessionEntry(
      project: session.projectRoot.path,
      port: port,
      pid: pid,
      platform: opts.platform,
      mockPort: opts.mockPort,
      emuVersion: kEmuVersion,
    );
    try {
      registry.write(e);
    } on FileSystemException {
      return;
    }
    recent.record(e.project, port: e.port, name: e.name);
    _registrySub = engine.statusStream.listen((s) {
      final cur = _entry;
      if (cur == null || _disposed || s.deviceId == null) return;
      if (s.deviceId == cur.deviceId && s.deviceName == cur.deviceName) return;
      final next = _entry = cur.withDevice(
          deviceId: s.deviceId, deviceName: s.deviceName, platform: platformForDeviceId(s.deviceId!));
      try {
        registry.write(next);
      } on FileSystemException {
        // Keep the earlier entry.
      }
    });
  }

  StreamSubscription<AppStatus>? _registrySub;

  /// Reserve [deviceId] for this server. False when another live emu session
  /// holds it (then [_lastConflict] says who). With `--share-device` always
  /// true, but never takes the lease — overwriting another session's lease
  /// would break its release and `down --kill-device` protection.
  Future<bool> _claim(String deviceId, LaunchOptions opts) async {
    if (opts.shareDevice) {
      final holder = await leases.liveHolderOf(deviceId);
      if (holder != null && holder.pid != pid) {
        logStore.add(
            'sharing device $deviceId with the emu session of ${holder.project} '
            '(${holder.dashboard}) — inputs and screenshots may interleave',
            level: LogLevel.warn,
            source: 'system');
      }
      return true;
    }
    final result = await leases.acquire(DeviceLease(
      deviceId: deviceId,
      pid: pid,
      port: port,
      project: session.projectRoot.path,
    ));
    if (result.acquired) {
      if (_disposed) {
        leases.release(deviceId, pid);
        return true; // Not a conflict — we're shutting down, so don't hold it.
      }
      if (_leasedDevice != null && _leasedDevice != deviceId) {
        leases.release(_leasedDevice!, pid);
      }
      _leasedDevice = deviceId;
      return true;
    }
    _lastConflict = result.holder;
    return false;
  }

  Future<void> _launch(LaunchOptions opts) async {
    String? deviceId = opts.deviceId;
    String? deviceName;
    Future<bool> claim(String id) => _claim(id, opts);
    try {
      if (deviceId != null && !await claim(deviceId)) {
        throw DeviceException(leaseConflictMessage(deviceId, _lastConflict!));
      }
      if (opts.tempDevice) {
        deviceId = await _bootTempDevice(opts, claim);
      } else if (opts.bootAvd != null) {
        final avds = await devices.listAndroidAvds();
        if (!avds.contains(opts.bootAvd)) {
          throw DeviceException('no AVD named "${opts.bootAvd}"'
              '${avds.isEmpty ? '' : ' — available: ${avds.join(', ')}'}');
        }
        deviceId = await devices.bootAvd(opts.bootAvd!, claim: claim, onProgress: logStore.system);
      } else if (deviceId == null && opts.platform == 'android') {
        deviceId = await devices.bootAndroid(claim: claim, onProgress: logStore.system);
      } else if (deviceId == null && opts.platform == 'ios') {
        deviceId = await devices.bootIos(claim: claim, onProgress: logStore.system);
      } else if (deviceId != null && platformForDeviceId(deviceId) == 'ios') {
        // An explicit iOS simulator udid isn't visible to `flutter run` until
        // the simulator is booted. `bootIos` is idempotent (a booted device is
        // a no-op), so ensure it here — otherwise `-d <udid>` fails with
        // "No supported devices found" when the sim happens to be shut down.
        deviceId = await devices.bootIos(udid: deviceId, onProgress: logStore.system);
      }
      final args = FlutterEngine.buildRunArgs(
        deviceId: deviceId,
        flavor: opts.flavor,
        target: opts.target,
        dartDefines: opts.dartDefines,
        dartDefineFromFile: opts.dartDefineFromFile,
        dartEntrypointArgs: opts.dartEntrypointArgs,
        deviceTimeoutSec: opts.deviceTimeoutSec,
        deviceConnection: opts.deviceConnection,
        ddsPort: opts.ddsPort,
        noDds: opts.noDds,
        extra: opts.extra,
      );
      if (deviceId == null) {
        _claimOnceFlutterPicks(opts);
      } else {
        await (_preparing = _prepareDevice(deviceId));
      }
      await engine.start(args, deviceName: deviceName ?? deviceId);
    } on DeviceException catch (e) {
      logStore.add('device error: ${e.message}', level: LogLevel.error, source: 'system');
      engine.markFailed('device error: ${e.message}');
    } catch (e) {
      logStore.add('launch error: $e', level: LogLevel.error, source: 'system');
      engine.markFailed('launch error: $e');
    }
  }

  /// Create, record and boot a throwaway device on [opts.platform]. It is
  /// recorded before booting so `emu down` (or a later orphan sweep) can
  /// delete it even if the boot fails.
  Future<String> _bootTempDevice(LaunchOptions opts, Future<bool> Function(String) claim) async {
    final name = tempDeviceName(session.projectRoot.path);
    TempDevice record({String? udid}) {
      final d = TempDevice(
        platform: opts.platform!,
        name: name,
        udid: udid,
        ownerPid: pid,
        ownerPort: port,
        project: session.projectRoot.path,
      );
      tempDevices.record(d);
      return d;
    }

    switch (opts.platform) {
      case 'android':
        await devices.createTempAvd(name, onProgress: logStore.system);
        record();
        return devices.bootAvd(name, claim: claim, onProgress: logStore.system);
      case 'ios':
        final udid = await devices.createTempSim(name, onProgress: logStore.system);
        record(udid: udid);
        return devices.bootIos(udid: udid, claim: claim, onProgress: logStore.system);
      default:
        throw DeviceException('--temp-device needs --android or --ios');
    }
  }

  /// Map ports and run `onDeviceReady` hooks on [deviceId], once. Normally
  /// before `flutter run`; when flutter picks the device itself, as soon as
  /// it reports which (the app is then already installed).
  Future<void> _prepareDevice(String deviceId) async {
    if (_preparedDevice != null) return;
    _preparedDevice = deviceId;
    final platform = platformForDeviceId(deviceId);
    await setup.applyPorts(deviceId, platform);
    if (setup.onDeviceReady.isNotEmpty) {
      await setup.runHooks('onDeviceReady', setup.onDeviceReady,
          deviceId: deviceId, platform: platform);
    }
    if (setup.hasPorts && platform == 'android') {
      _portsMissing = await setup.missingPorts(deviceId);
      _portWatch = Timer.periodic(
          const Duration(seconds: 15), (_) => _reapplyRun = _reapplyPorts());
    }
  }

  bool _reapplying = false;
  Future<void> _reapplyPorts() async {
    final id = _preparedDevice;
    if (id == null || _reapplying || _disposed) return;
    _reapplying = true;
    try {
      final missing = _portsMissing = await setup.missingPorts(id);
      if (missing == null || missing.isEmpty) return;
      if (_disposed) return;
      logStore.add('port mappings lost on $id (adb restarted or device rebooted) — re-applying',
          level: LogLevel.warn, source: 'system');
      await DeviceSetup(
        reversePorts: [for (final (m, r) in missing) if (r) m],
        forwardPorts: [for (final (m, r) in missing) if (!r) m],
        projectRoot: setup.projectRoot,
        log: setup.log,
      ).applyPorts(id, 'android');
      _portsMissing = await setup.missingPorts(id);
    } finally {
      _reapplying = false;
    }
  }

  /// Late device setup (flutter picked the device) and `onAppStarted` hooks
  /// the first time the app reaches `running`; and auto re-attach when the
  /// `flutter` process dies under a running app (see [reattach]).
  void _watchSetup() {
    var started = false;
    var wasRunning = false;
    _setupWatch = engine.statusStream.listen((s) async {
      // Sticky until a new launch: the daemon may report `app.stop` while
      // the dying `flutter` process is still up, before the exit we act on.
      if (s.state == AppRunState.running) wasRunning = true;
      if (s.state == AppRunState.starting) wasRunning = false;
      final lost = wasRunning &&
          (s.state == AppRunState.stopped || s.state == AppRunState.failed) &&
          !engine.stoppedDeliberately &&
          !engine.hasProcess;
      if (lost && !_disposed) {
        wasRunning = false;
        unawaited(_autoReattach());
      }
      final id = s.deviceId;
      if (id != null && _preparedDevice == null) _preparing = _prepareDevice(id);
      if (s.state == AppRunState.running && !started && id != null) {
        started = true;
        await _preparing;
        if (setup.onAppStarted.isEmpty || _disposed) return;
        final platform = platformForDeviceId(id);
        await setup.runHooks('onAppStarted', setup.onAppStarted,
            deviceId: id,
            platform: platform,
            appId: builtAppId(session.projectRoot.path, platform));
      }
    });
  }

  DateTime? _lastAutoReattach;

  /// The `flutter` process went away while the app was running (adb server
  /// restarted by another session, `Lost connection to device`). If the app
  /// is still alive on the device, attach to it again — at most once a
  /// minute, so an app that really keeps dying isn't retried in a loop.
  Future<void> _autoReattach() async {
    final now = DateTime.now();
    if (_lastAutoReattach != null && now.difference(_lastAutoReattach!) < const Duration(minutes: 1)) {
      logStore.add('flutter lost the app again within a minute — not re-attaching automatically '
          '(run `emu attach` to retry)', level: LogLevel.warn, source: 'system');
      return;
    }
    _lastAutoReattach = now;
    logStore.add('flutter lost the connection to the app — trying to re-attach',
        level: LogLevel.warn, source: 'system');
    final r = await reattach();
    if (!r.ok) {
      logStore.add('re-attach failed: ${r.message}', level: LogLevel.error, source: 'system');
    }
  }

  /// Re-connect to the app still running on this session's device with
  /// `flutter attach` (`emu attach`, or automatically). Android: waits for
  /// adb to see the device again, then attaches through the VM Service URL
  /// the app logged at startup (falling back to its package id).
  Future<ActionResult> reattach() async {
    // Auto and manual (`emu attach`) can overlap; two `engine.attach` calls
    // would both spawn `flutter attach` and orphan one.
    if (_reattaching) return ActionResult(ok: false, message: 'attach already in progress');
    _reattaching = true;
    try {
      return await _reattach();
    } finally {
      _reattaching = false;
    }
  }

  bool _reattaching = false;

  Future<ActionResult> _reattach() async {
    if (engine.hasProcess) {
      return ActionResult(ok: false, message: 'flutter is still connected (state: ${engine.status.state.name})');
    }
    final id = engine.status.deviceId ?? _preparedDevice;
    if (id == null) return ActionResult(ok: false, message: 'no device known for this session');
    final platform = platformForDeviceId(id);
    if (platform == 'android' && !await devices.waitAndroidOnline(id)) {
      return ActionResult(ok: false, message: 'adb does not see $id (device gone?)');
    }
    final appId = builtAppId(session.projectRoot.path, platform);
    if (appId == null) {
      return ActionResult(ok: false, message: 'cannot tell the app id from the build outputs');
    }
    if (!await devices.appAlive(id, appId)) {
      return ActionResult(
          ok: false, message: '$appId is not running on $id — use `emu cold` to relaunch it');
    }
    final debugUrl = platform == 'android' ? await devices.androidVmServiceUrl(id, appId) : null;
    final args = FlutterEngine.buildAttachArgs(engine.lastRunArgs,
        deviceId: id, debugUrl: debugUrl, appId: appId);
    try {
      await engine.attach(args, deviceName: engine.status.deviceName ?? id);
    } catch (e) {
      return ActionResult(ok: false, message: 'flutter attach failed to start: $e');
    }
    return ActionResult(ok: true, message: 'attaching to $appId on $id');
  }

  /// With neither `--device` nor a platform, `flutter run` picks the device
  /// itself, so it can't be claimed up front. Claim it once the app reports
  /// which device it's on; on conflict the damage (install) is done, so warn
  /// loudly at error level — it lands in `up`'s verdict `errors`.
  void _claimOnceFlutterPicks(LaunchOptions opts) {
    var claimed = false;
    _postHocClaim = engine.statusStream.listen((s) async {
      final id = s.deviceId;
      if (id == null || claimed) return;
      claimed = true;
      await _postHocClaim?.cancel();
      if (!await _claim(id, opts)) {
        logStore.add(
            '${leaseConflictMessage(id, _lastConflict!)}\n'
            '  flutter picked this device itself — pass --android/--ios/--device '
            'so emu can choose a free one',
            level: LogLevel.error,
            source: 'system');
      }
    });
  }

  Future<void> _startMock(LaunchOptions opts) async {
    final server = MockServer(
      projectRoot: session.projectRoot.path,
      profile: opts.profile,
      log: (hit) {
        logStore.add('[mock] ${hit.line}',
            level: hit.error != null ? LogLevel.error : (hit.scenario != null ? LogLevel.info : LogLevel.debug),
            source: 'mock');
        _broadcast({'type': 'mock-hit', 'hit': hit.toJson()});
      },
    );
    for (final problem in server.load().problems) {
      logStore.add('emu.yaml $problem', level: LogLevel.warn, source: 'system');
    }
    try {
      await server.start(opts.mockPort!);
      mock = server;
      logStore.system('mock server on 127.0.0.1:${opts.mockPort} (http origins :${opts.mockPort! + 1}) — '
          'off until `emu mock use <scenario>`');
    } catch (e) {
      logStore.add('mock server could not listen on ${opts.mockPort}: $e', level: LogLevel.error, source: 'system');
    }
  }

  /// - `GET  /api/mock`                     config, scenarios (with rules), active
  /// - `POST /api/mock {scenario|null}`      switch scenario / off
  /// - `GET  /api/mock/log?n=`               recent requests
  /// - `GET  /api/mock/hits/<id>`            one request, with bodies
  /// - `PUT  /api/mock/scenarios/<name> {rules}`   write `<dir>/<name>.json`
  /// - `DELETE /api/mock/scenarios/<name>`  remove it
  /// - `POST /api/mock/overrides {rule, save?}`    `emu mock set` (in memory; save also writes a scenario)
  /// - `DELETE /api/mock/overrides[?key=GET /v1/x]` `emu mock unset` / `reset`
  Future<Response> _mockApi(Request req, String path) async {
    final server = mock;
    if (server == null) {
      return _json({'ok': false, 'error': 'mocks are off — add `mocks:` to emu.yaml and run `emu up` again'},
          status: 409);
    }
    if (path == '/api/mock/log') {
      final n = int.tryParse(req.url.queryParameters['n'] ?? '') ?? 50;
      final bodies = req.url.queryParameters['bodies'] == '1';
      final hits = server.recent;
      return _json({
        'ok': true,
        'hits': [for (final h in hits.skip(hits.length > n ? hits.length - n : 0)) h.toJson(bodies: bodies)],
      });
    }
    if (path.startsWith('/api/mock/hits/')) {
      final hit = server.hit(int.tryParse(path.substring('/api/mock/hits/'.length)) ?? -1);
      if (hit == null) return _json({'ok': false, 'error': 'no such request (only the last 200 are kept)'}, status: 404);
      return _json({'ok': true, 'hit': hit.toJson(bodies: true)});
    }
    var config = server.load();
    Map<String, dynamic> state() =>
        {'ok': true, 'active': server.active, 'port': server.port, ...config.toJson(), 'overrides': [
          for (final r in server.overrides) r.toJson(),
        ]};
    if (path == '/api/mock/overrides') {
      if (req.method == 'POST') {
        Object? body;
        try {
          body = jsonDecode(await req.readAsString());
        } catch (_) {}
        final problems = <String>[];
        final rule = parseMockRule(body is Map ? body['rule'] : null, problems);
        if (rule == null) return _json({'ok': false, 'error': problems.join('\n')}, status: 400);
        final save = body is Map ? body['save'] : null;
        if (save != null) {
          final name = '$save';
          final existing = config.sources[name] == null ? const <MockRule>[] : config.scenarios[name]!;
          final problems = writeScenario(config, session.projectRoot.path, name, upsertRule(existing, rule));
          if (problems.isNotEmpty) return _json({'ok': false, 'error': problems.join('\n')}, status: 400);
          config = server.load();
        }
        server.setOverride(rule);
        logStore.system('mock: ${rule.key} → ${rule.status} (emu mock set${save != null ? ', saved to "$save"' : ''})');
      } else if (req.method == 'DELETE') {
        final key = req.url.queryParameters['key'];
        if (key == null) {
          server.overrides.clear();
          logStore.system('mock: overrides cleared');
        } else if (!server.unsetOverride(key)) {
          return _json({
            'ok': false,
            'error': 'no override "$key" (${server.overrides.map((r) => r.key).join(', ')})',
          }, status: 404);
        }
      } else {
        return _json({'ok': false, 'error': 'use POST or DELETE'}, status: 405);
      }
      _broadcast({'type': 'mock', 'active': server.active});
      return _json(state());
    }
    if (path.startsWith('/api/mock/scenarios/')) {
      final name = Uri.decodeComponent(path.substring('/api/mock/scenarios/'.length));
      if (req.method == 'PUT') {
        Object? body;
        try {
          body = jsonDecode(await req.readAsString());
        } catch (_) {}
        final problems = writeScenario(config, session.projectRoot.path, name, body is Map ? body['rules'] : null);
        if (problems.isNotEmpty) return _json({'ok': false, 'error': problems.join('\n'), 'problems': problems}, status: 400);
        logStore.system('mock: saved scenario "$name" (${config.dir}/$name.json)');
      } else if (req.method == 'DELETE') {
        if (!deleteScenario(config, session.projectRoot.path, name)) {
          return _json({'ok': false, 'error': 'no scenario file "$name" (emu.yaml scenarios are edited there)'},
              status: 404);
        }
        if (server.active == name) server.active = null;
        logStore.system('mock: deleted scenario "$name"');
      } else {
        return _json({'ok': false, 'error': 'use PUT or DELETE'}, status: 405);
      }
      config = server.load();
      _broadcast({'type': 'mock', 'active': server.active});
      return _json(state());
    }
    if (req.method == 'POST') {
      Object? body;
      try {
        body = jsonDecode(await req.readAsString());
      } catch (_) {}
      final name = body is Map ? body['scenario'] : null;
      if (name != null && (name is! String || !config.scenarios.containsKey(name))) {
        return _json({
          'ok': false,
          'error': 'no scenario "$name" in emu.yaml mocks (${config.scenarios.keys.join(', ')})',
        }, status: 404);
      }
      server.active = name as String?;
      logStore.system(name == null ? 'mock: off — every request goes to the real server' : 'mock: using "$name"');
      _broadcast({'type': 'mock', 'active': name});
    }
    return _json(state());
  }

  Future<HttpServer> _bind(int requestedPort) async {
    // Try the requested port, then a small range, then an ephemeral port.
    for (final p in [requestedPort, requestedPort + 1, requestedPort + 2, 0]) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, p);
      } on SocketException {
        continue;
      }
    }
    throw StateError('could not bind a local port for the emu server');
  }

  Handler _handler() {
    return const Pipeline().addMiddleware(apiGuard(token)).addHandler(_route);
  }

  Future<Response> _route(Request req) async {
    final path = '/${req.url.path}';

    // WebSocket stream.
    if (path == '/api/stream') {
      final ws = webSocketHandler(_onSocket);
      return await ws(req);
    }

    // REST API.
    if (path.startsWith('/api/')) {
      return _api(req, path);
    }

    // Static dashboard.
    return await _static(path);
  }

  Future<Response> _api(Request req, String path) async {
    switch (path) {
      case '/api/status':
        // Without the token, only that the server is up (the device-lease
        // liveness ping): the full status holds the VM Service URI, whose
        // auth code is what lets a client run code in the app.
        if (req.context[authedContextKey] != true) {
          return _json({'ok': true, 'state': engine.status.state.name, 'serverPort': port});
        }
        final missing = _portsMissing;
        return _json({
          'status': engine.status.toJson(),
          'serverPort': port,
          'lastSeq': logStore.lastSeq,
          if (setup.hasPorts)
            'ports': {
              'declared': {
                'reverse': [for (final m in setup.reversePorts) '$m'],
                'forward': [for (final m in setup.forwardPorts) '$m'],
              },
              'active': missing == null
                  ? null
                  : {
                      'reverse': [
                        for (final m in setup.reversePorts)
                          if (!missing.contains((m, true))) '$m'
                      ],
                      'forward': [
                        for (final m in setup.forwardPorts)
                          if (!missing.contains((m, false))) '$m'
                      ],
                    },
            },
        });
      case '/api/session':
        // Token check only (the guard already ran): lets the dashboard tell a
        // restarted server (new token → 401) from one that is down.
        return _json({'ok': true});
      case '/api/reload':
        return _json((await engine.hotReload()).toJson());
      case '/api/restart':
        return _json((await engine.hotRestart()).toJson());
      case '/api/cold':
        return _json((await engine.coldRestart()).toJson());
      case '/api/attach':
        return _json((await reattach()).toJson());
      case '/api/stop':
        await engine.stop();
        return _json({'ok': true, 'message': 'stopped'});
      case '/api/devices':
        try {
          final list = await devices.listDevices();
          return _json({'devices': list.map((d) => d.toJson()).toList()});
        } catch (e) {
          return _json({'error': '$e'}, status: 500);
        }
      case '/api/logs':
        final q = req.url.queryParameters;
        final entries = logStore.query(
          grep: q['grep'],
          level: q['level'] != null ? LogLevel.fromName(q['level']) : null,
          sinceSeq: int.tryParse(q['sinceSeq'] ?? ''),
          limit: int.tryParse(q['limit'] ?? '') ?? 1000,
        );
        return _json({'logs': entries.map((e) => e.toJson()).toList(), 'lastSeq': logStore.lastSeq});
      case '/api/logs/clear':
        logStore.clear();
        return _json({'ok': true});
      case '/api/errors':
        final q = req.url.queryParameters;
        final sinceSeq = int.tryParse(q['since'] ?? '');
        final entries = logStore.query(sinceSeq: sinceSeq);
        final errors = parseErrorBanners(entries);
        // A banner still printing when this scan ran is reported unclosed
        // (best-effort). The next `--since` cursor must stop just before its
        // opening line — advancing past it (e.g. to logStore.lastSeq) would
        // permanently exclude that opening line from every future scan, so
        // the banner's real closing line (once it arrives) could never be
        // matched back up with it.
        final openBanner = errors.isNotEmpty && !errors.last.closed ? errors.last : null;
        final cursor = openBanner != null ? openBanner.startSeq - 1 : logStore.lastSeq;
        return _json({'errors': errors.map((e) => e.toJson()).toList(), 'lastSeq': cursor});
      case '/api/memory/snapshot':
        return _memorySnapshot(req);
      case '/api/screenshot':
        return _screenshot(req);
      case '/api/tap':
        return _tap(req);
      case '/api/swipe':
        return _swipe(req);
      case '/api/text':
        return _text(req);
      case '/api/open-url':
        return _openUrl(req);
      case '/api/diff/files':
        return _diffFiles(req);
      case '/api/diff/file':
        return _diffFile(req);
      case '/api/first-frame':
        return _firstFrame(req);
      case '/api/settle':
        return _settle(req);
      case '/api/find':
        return _find(req);
      case '/api/eval':
        return _eval(req);
      case '/api/probe':
        return _probe(req);
      case '/api/inspect':
        return _inspect(req);
      case '/api/shutdown':
        // Graceful server shutdown (used by `emu down`).
        scheduleMicrotask(() async {
          await dispose();
          exit(0);
        });
        return _json({'ok': true, 'message': 'shutting down'});
      default:
        if (path == '/api/mock' || path.startsWith('/api/mock/')) return _mockApi(req, path);
        if (path == '/api/pages' || path.startsWith('/api/pages/')) return pages.handle(req, path);
        if (path == '/api/report' || path.startsWith('/api/report/')) return report.handle(req, path);
        return _json({'error': 'not found'}, status: 404);
    }
  }

  /// What page commands see, like the hooks: the project, this server, and
  /// the device and app once known.
  Map<String, String> _pageEnvironment() {
    final id = engine.status.deviceId;
    final platform = id == null ? null : platformForDeviceId(id);
    return {
      'EMU_PROJECT': session.projectRoot.path,
      'EMU_PORT': '$port',
      'EMU_DEVICE': ?id,
      'EMU_PLATFORM': ?platform,
      'EMU_APP_ID': ?(platform == null ? null : builtAppId(session.projectRoot.path, platform)),
    };
  }

  /// A page item's `then:` — the same reload/restart as the buttons.
  Future<Map<String, dynamic>> _pageFollowUp(Then then) async {
    final r = switch (then) {
      Then.reload => await engine.hotReload(),
      Then.restart => await engine.hotRestart(),
      Then.none => null,
    };
    return {'action': then.name, ...?r?.toJson()};
  }

  String get _platform => platformForDeviceId(engine.status.deviceId);

  Future<Response> _screenshot(Request req) async {
    // Inline mode (dashboard): return the PNG bytes directly instead of saving a
    // timestamped file, reusing one temp path so refreshes don't clutter .emu/.
    if (req.url.queryParameters['inline'] == '1') {
      final tmp = '${session.stateDir.path}/_dashboard-shot.png';
      try {
        await devices.screenshot(tmp, platform: _platform, udid: engine.status.deviceId);
        final bytes = await File(tmp).readAsBytes();
        return Response.ok(bytes, headers: {
          'content-type': 'image/png',
          'cache-control': 'no-store',
        });
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 500);
      }
    }
    // An explicit `path` wins; otherwise timestamp into .emu/.
    final requested = req.url.queryParameters['path'];
    final String out;
    if (requested != null && requested.isNotEmpty) {
      // Relative paths resolve against the project root, not the server's cwd.
      final f = File(requested);
      out = f.isAbsolute ? requested : '${session.projectRoot.path}/$requested';
      await File(out).parent.create(recursive: true);
    } else {
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      out = '${session.stateDir.path}/shot-$ts.png';
    }
    try {
      await devices.screenshot(out, platform: _platform, udid: engine.status.deviceId);
      return _json({'ok': true, 'path': out});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  /// The running app's VM Service URI, or null with a 409 response — input goes
  /// through the framework, so it needs a live VM Service (as `probe` does).
  String? _vmOr409(void Function(Response) sink) {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      sink(_json({'ok': false, 'error': 'app is not running (no VM service)'}, status: 409));
    }
    return uri;
  }

  Future<Response> _tap(Request req) async {
    final q = req.url.queryParameters;
    final text = q['text'];
    final key = q['key'];
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;

    if (text != null || key != null) {
      final index = int.tryParse(q['index'] ?? '');
      final query = text != null ? '--text "$text"' : '--key "$key"';
      try {
        final matches = await locate(uri, text: text, key: key);
        final m = pickMatch(matches, index, query: query);
        return await _inject(() => runTap(uri, m.x, m.y),
            {'x': m.x, 'y': m.y, 'widgetType': m.widgetType, 'matchCount': matches.length,
              if (m.partial) 'partial': true});
      } on LocateException catch (e) {
        return _json({'ok': false, 'error': e.message}, status: 422);
      }
    }

    final x = int.tryParse(q['x'] ?? '');
    final y = int.tryParse(q['y'] ?? '');
    if (x == null || y == null) {
      return _json({'ok': false, 'error': 'x and y are required integers'}, status: 400);
    }
    return _inject(() => runTap(uri, x, y), {'x': x, 'y': y});
  }

  /// `find` — the same on-device widget query `tap --text/--key` runs, but
  /// reported instead of tapped (and with a `--type` mode on top).
  Future<Response> _find(Request req) async {
    final q = req.url.queryParameters;
    final text = q['text'];
    final key = q['key'];
    final type = q['type'];
    final given = [text, key, type].where((v) => v != null).length;
    if (given != 1) {
      return _json({'ok': false, 'error': 'give exactly one of text/key/type'}, status: 400);
    }
    final dump = q['dump'] == '1' || q['dump'] == 'true';
    final index = int.tryParse(q['index'] ?? '');
    final query = text != null
        ? '--text "$text"'
        : key != null
            ? '--key "$key"'
            : '--type "$type"';

    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;

    try {
      final matches = await locate(uri, text: text, key: key, type: type, dump: dump);
      // No `--index` means "report whatever matched", zero included — only an
      // explicit index can be wrong (out of range), and that's the 422 below.
      final result = index == null ? matches : [pickMatch(matches, index, query: query)];
      return _json({'ok': true, 'matches': result.map((m) => m.toJson()).toList()});
    } on LocateException catch (e) {
      return _json({'ok': false, 'error': e.message}, status: 422);
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  /// `eval` — evaluate an expression in the app's root library scope, with no
  /// breakpoint and no pause (unlike `probe`/`inspect`).
  Future<Response> _eval(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'invalid request body'}, status: 400);
    }
    final expr = body['expr'] as String?;
    if (expr == null || expr.trim().isEmpty) {
      return _json({'ok': false, 'error': 'expr is required'}, status: 400);
    }
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    try {
      return _json({'ok': true, 'result': await evalOnDevice(uri, expr)});
    } on EvalException catch (e) {
      return _json({'ok': false, 'error': e.message}, status: 422);
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  Future<Response> _swipe(Request req) async {
    final q = req.url.queryParameters;
    final c = ['x1', 'y1', 'x2', 'y2'].map((k) => int.tryParse(q[k] ?? '')).toList();
    if (c.any((v) => v == null)) {
      return _json({'ok': false, 'error': 'x1, y1, x2, y2 are required integers'}, status: 400);
    }
    final ms = int.tryParse(q['durationMs'] ?? '') ?? 300;
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    return _inject(
      () => runSwipe(uri, c[0]!, c[1]!, c[2]!, c[3]!, durationMs: ms),
      {'x1': c[0], 'y1': c[1], 'x2': c[2], 'y2': c[3], 'durationMs': ms},
    );
  }

  Future<Response> _text(Request req) async {
    final text = req.url.queryParameters['text'];
    if (text == null || text.isEmpty) {
      return _json({'ok': false, 'error': 'text is required'}, status: 400);
    }
    final append = req.url.queryParameters['append'] == 'true';
    Response? early;
    final uri = _vmOr409((r) => early = r);
    if (uri == null) return early!;
    return _inject(
      () => runText(uri, text, append: append),
      {'text': text, 'append': append},
    );
  }

  /// Entering `starting` (launch, cold restart) or `restarting` (hot
  /// reload/restart) is when new code reaches the app — capture the working
  /// tree then. Both the CLI and the dashboard drive reloads through the
  /// engine, so this sees every one.
  Future<void> _snapshotOnReload(AppStatus s) async {
    final prev = _lastRunState;
    _lastRunState = s.state;
    if (s.state == prev) return;
    final reason = switch (s.state) {
      AppRunState.starting => 'launch',
      AppRunState.restarting => 'reload',
      _ => null,
    };
    if (reason == null) return;
    await diff.record(reason);
    _broadcast({'type': 'diff', 'snapshots': diff.snapshots.map((e) => e.toJson()).toList()});
  }

  Future<void> _watchFiles() async {
    final repo = await diff.isRepo();
    if (_disposed || (!repo && pages.load().pages.isEmpty)) return;
    final root = session.projectRoot.path;
    try {
      _fileWatch = session.projectRoot.watch(recursive: true).listen((e) {
        // `root/` (not bare `root`): a sibling like `myapp2/` must not match `myapp`.
        final under = e.path.startsWith('$root/') || e.path.startsWith('$root${Platform.pathSeparator}');
        final rel = under ? e.path.substring(root.length + 1) : e.path;
        if (rel == 'emu.yaml' || rel == 'emu.local.yaml') {
          // Dashboards re-read the pages (the server reads the file per request).
          _pagesChangedDebounce?.cancel();
          _pagesChangedDebounce = Timer(const Duration(milliseconds: 400), () => _broadcast({'type': 'pages'}));
        }
        _queuePageWatch(rel);
        if (!repo || isWatchNoise(rel)) return;
        _fileWatchDebounce?.cancel();
        _fileWatchDebounce = Timer(const Duration(milliseconds: 400), () => _broadcast({'type': 'diff', 'reason': 'files'}));
      }, onError: (_) {});
    } catch (_) {
      // No recursive watch on this platform — the tab still updates on reload
      // and on its refresh button.
    }
  }

  /// A page block or an `auto:` action may watch any project path — `build/`
  /// or a git-ignored work folder included — but not emu's or git's own
  /// churn. Checked in batches: a save or a formatter run is a burst of events.
  void _queuePageWatch(String rel) {
    if (rel.isEmpty || rel.split(RegExp(r'[/\\]')).any(const {'.git', '.dart_tool', '.emu'}.contains)) return;
    _pageWatchPaths.add(rel.replaceAll(r'\', '/'));
    _pageWatchDebounce?.cancel();
    _pageWatchDebounce = Timer(const Duration(milliseconds: 300), () {
      final paths = _pageWatchPaths.toList();
      _pageWatchPaths.clear();
      final hits = pages.watching(paths);
      if (hits.isNotEmpty) {
        _broadcast({
          'type': 'ext-watch',
          'blocks': {for (final e in hits.entries) e.key: e.value.toList()},
        });
      }
      pages.filesChanged(paths);
    });
  }

  /// Resolves `scope`/`base` query params to a range (null: nothing to compare
  /// yet); throws [DiffException] for a bad scope or base.
  Future<(DiffScope, String?, (String, String)?)> _diffRange(Map<String, String> q) async {
    final scope = DiffScope.fromWire(q['scope'] ?? 'head');
    if (scope == null) throw DiffException('unknown scope: ${q['scope']} (head|base|reload|pending)');
    final base = q['base'] ?? (scope == DiffScope.base ? await diff.defaultBase() : null);
    return (scope, base, await diff.range(scope, base: base));
  }

  Future<Response> _diffFiles(Request req) async {
    if (!await diff.isRepo()) return _json({'git': false, 'files': []});
    try {
      final (scope, base, range) = await _diffRange(req.url.queryParameters);
      return _json({
        'git': true,
        'scope': scope.wire,
        if (base != null) 'base': base,
        'snapshots': diff.snapshots.map((e) => e.toJson()).toList(),
        // The exact trees compared: passing them back to /api/diff/file keeps
        // each patch consistent with this listing and skips re-snapshotting.
        if (range != null) ...{'from': range.$1, 'to': range.$2},
        'files': range == null ? [] : (await diff.files(range)).map((f) => f.toJson()).toList(),
        if (range == null) 'note': scope == DiffScope.base ? 'no base branch found' : 'no reload recorded yet',
      });
    } on DiffException catch (e) {
      return _json({'git': true, 'error': e.message}, status: 400);
    }
  }

  Future<Response> _diffFile(Request req) async {
    final path = req.url.queryParameters['path'];
    if (path == null || path.isEmpty) return _json({'error': 'path is required'}, status: 400);
    if (!isProjectRelativePath(path)) return _json({'error': 'path must be relative to the project'}, status: 400);
    if (!await diff.isRepo()) return _json({'git': false, 'patch': ''});
    try {
      final q = req.url.queryParameters;
      final (from, to) = (q['from'], q['to']);
      final (String, String)? range;
      if (from != null || to != null) {
        if (from == null || to == null || !isObjectId(from) || !isObjectId(to)) {
          throw DiffException('from/to must both be tree ids from /api/diff/files');
        }
        range = (from, to);
      } else {
        (_, _, range) = await _diffRange(q);
      }
      return _json({'git': true, 'path': path, 'patch': range == null ? '' : await diff.patch(range, path)});
    } on DiffException catch (e) {
      return _json({'git': true, 'error': e.message}, status: 400);
    }
  }

  /// The dashboard's deep link box.
  Future<Response> _openUrl(Request req) async {
    final url = req.url.queryParameters['url'];
    if (url == null || url.isEmpty) {
      return _json({'ok': false, 'error': 'url is required'}, status: 400);
    }
    final (status, body) = await _openDeepLink(url);
    return _json(body, status: status);
  }

  /// Deep link from the dashboard's box or a page's `openUrl:` action — same
  /// argv-only invocation as `emu open-url` (see [buildOpenUrlCommand]), then
  /// a best-effort settle so the caller's next screenshot shows the
  /// destination rather than the transition. The settle is capped well below
  /// the CLI's 10s: an app that never goes quiet (looping animation, streaming
  /// list) would otherwise stall the button. The outer timeout matters too —
  /// `timeout` only bounds the poll loop, and right after launch the first VM
  /// `evaluate` alone can take 10s+. Returns the HTTP status and body.
  Future<(int, Map<String, dynamic>)> _openDeepLink(String url) async {
    final deviceId = engine.status.deviceId;
    if (deviceId == null) {
      return (409, {'ok': false, 'error': 'no device connected'});
    }
    final cmd = buildOpenUrlCommand(platform: _platform, deviceId: deviceId, url: url);
    final seq = logStore.lastSeq;
    final ProcessResult result;
    try {
      // Bounded: an offline/unauthorized device can hang adb, and with it the
      // dashboard's request.
      result = await runWithTimeout(cmd.executable, cmd.arguments);
    } catch (e) {
      return (500, {'ok': false, 'url': url, 'error': '$e'});
    }
    if (result.exitCode != 0) {
      return (500, {'ok': false, 'url': url, 'error': '${result.stderr}'.trim()});
    }
    final uri = engine.status.vmServiceUri;
    if (uri != null) {
      await waitForSettle(uri, timeout: const Duration(seconds: 3))
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
    }
    return (200, {'ok': true, 'url': url, 'seq': seq});
  }

  /// Whether the app has painted yet — `running` alone doesn't mean tappable.
  Future<Response> _firstFrame(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'ok': false, 'error': 'app is not running (no VM service)'}, status: 409);
    }
    final ms = int.tryParse(req.url.queryParameters['timeoutMs'] ?? '') ?? 20000;
    final painted = await waitForFirstFrame(uri, timeout: Duration(milliseconds: ms));
    return _json({'ok': true, 'firstFrame': painted});
  }

  /// Whether the app has stopped animating/rebuilding since the last input —
  /// `tap`/`swipe` return as soon as the event is dispatched, not once the
  /// resulting transition or animation has finished.
  Future<Response> _settle(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'ok': false, 'error': 'app is not running (no VM service)'}, status: 409);
    }
    final q = req.url.queryParameters;
    final timeoutMs = int.tryParse(q['timeoutMs'] ?? '') ?? 10000;
    final quietMs = int.tryParse(q['quietMs'] ?? '') ?? 150;
    final settled = await waitForSettle(
      uri,
      timeout: Duration(milliseconds: timeoutMs),
      quiet: Duration(milliseconds: quietMs),
    );
    return _json({'ok': true, 'settled': settled});
  }

  /// Run an input injection, reporting the log cursor from *before* it fired.
  /// `assert --since <seq>` then sees exactly what the input caused — without
  /// this, the natural `tap` then `assert` order races, because assert's
  /// default window only opens once the effect has already been logged.
  Future<Response> _inject(
      Future<void> Function() action, Map<String, dynamic> detail) async {
    final seq = logStore.lastSeq;
    try {
      await action();
      return _json({'ok': true, ...detail, 'seq': seq});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, status: 500);
    }
  }

  Future<Response> _probe(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'error': 'app is not running (no VM service)'}, status: 409);
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'invalid request body'}, status: 400);
    }
    final file = body['file'] as String?;
    final line = (body['line'] as num?)?.toInt();
    if (file == null || line == null) {
      return _json({'error': 'file and line required'}, status: 400);
    }
    final capture = (body['capture'] as List?)?.cast<String>() ?? const [];
    final count = (body['count'] as num?)?.toInt() ?? 1;
    final timeoutMs = (body['timeoutMs'] as num?)?.toInt() ?? 10000;
    final pubspec = File('${session.projectRoot.path}/pubspec.yaml');
    try {
      final hits = await runProbe(
        wsUri: uri,
        pubspecContent: pubspec.existsSync() ? pubspec.readAsStringSync() : '',
        file: file,
        line: line,
        capture: capture,
        count: count,
        timeout: Duration(milliseconds: timeoutMs),
        onHit: (h) => logStore.add(
          '[probe $file:$line] ${h.values.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
          level: LogLevel.system,
          source: 'probe',
        ),
      );
      return _json({'hits': hits.map((h) => h.toJson()).toList()});
    } on ProbeException catch (e) {
      return _json({'error': e.message}, status: 422);
    } catch (e) {
      return _json({'error': '$e'}, status: 500);
    }
  }

  Future<Response> _inspect(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'error': 'app is not running (no VM service)'}, status: 409);
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'invalid request body'}, status: 400);
    }
    final file = body['file'] as String?;
    final line = (body['line'] as num?)?.toInt();
    if (file == null || line == null) {
      return _json({'error': 'file and line required'}, status: 400);
    }
    final timeoutMs = (body['timeoutMs'] as num?)?.toInt() ?? 10000;
    final pubspec = File('${session.projectRoot.path}/pubspec.yaml');
    try {
      final r = await runInspect(
        wsUri: uri,
        pubspecContent: pubspec.existsSync() ? pubspec.readAsStringSync() : '',
        file: file,
        line: line,
        timeout: Duration(milliseconds: timeoutMs),
      );
      if (r == null) return _json({'hit': false});
      logStore.add('[inspect $file:$line] ${r.locals.length} locals',
          level: LogLevel.system, source: 'probe');
      return _json({'hit': true, ...r.toJson()});
    } on ProbeException catch (e) {
      return _json({'error': e.message}, status: 422);
    } catch (e) {
      return _json({'error': '$e'}, status: 500);
    }
  }

  /// Heap instance-count snapshot for `emu memory --diff-across` — the CLI
  /// hits this once before and once after running the user's command and
  /// diffs the two results itself, so the server stays a stateless snapshot
  /// source (same shape as `assert`'s "read logs, compare client-side").
  Future<Response> _memorySnapshot(Request req) async {
    final uri = engine.status.vmServiceUri;
    if (uri == null) {
      return _json({'error': 'app is not running (no VM service)'}, status: 409);
    }
    try {
      final snapshot = await mem.takeHeapSnapshot(uri);
      final all = req.url.queryParameters['all'] == '1';
      if (all) return _json({'snapshot': snapshot});
      final pubspec = File('${session.projectRoot.path}/pubspec.yaml');
      final pkg = mem.appPackageName(pubspec.existsSync() ? pubspec.readAsStringSync() : '');
      if (pkg == null) {
        // Falling back to the unfiltered snapshot here would silently violate
        // the documented default (app-package-only) — surface it instead.
        return _json({
          'error': "could not determine the app's package name from pubspec.yaml "
              '(missing/unreadable, or no `name:` field) — pass --all to see the '
              'unfiltered snapshot',
        }, status: 422);
      }
      return _json({'snapshot': mem.filterToAppPackage(snapshot, pkg)});
    } catch (e) {
      return _json({'error': '$e'}, status: 500);
    }
  }

  void _onSocket(WebSocketChannel socket, _) {
    _sockets.add(socket);
    // Prime the new client with current status and recent logs.
    socket.sink.add(jsonEncode({'type': 'status', 'status': engine.status.toJson()}));
    for (final e in logStore.query(limit: 500)) {
      socket.sink.add(jsonEncode({'type': 'log', 'entry': e.toJson()}));
    }
    socket.stream.listen(
      (_) {},
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
    );
  }

  void _broadcast(Map<String, dynamic> msg) {
    if (_sockets.isEmpty) return;
    final data = jsonEncode(msg);
    for (final s in _sockets.toList()) {
      try {
        s.sink.add(data);
      } catch (_) {
        _sockets.remove(s);
      }
    }
  }

  Future<Response> _static(String path) async {
    var rel = path == '/' ? 'index.html' : path.substring(1);
    final bytes = readWebAsset(rel);
    if (bytes == null) return Response.notFound('not found: $rel');
    if (rel.startsWith('hub/')) return Response.notFound('not found: $rel'); // the hub's own page
    if (rel == 'index.html') {
      // Framed only by a running `emu hub` (its origin can't read the page —
      // the token stays in here), else by nothing.
      final ancestors = await hubFrameAncestors();
      return Response.ok(injectSessionToken(utf8.decode(bytes), token), headers: {
        'Content-Type': contentTypeFor(rel),
        // The page carries this session's token: never from cache (a restarted
        // server has a new one), never inside another site's frame.
        'Cache-Control': 'no-store',
        'Content-Security-Policy': 'frame-ancestors $ancestors',
        if (ancestors == "'none'") 'X-Frame-Options': 'DENY',
        // Sub-resource URLs carry ?token=; no link out of the page may leak them.
        'Referrer-Policy': 'no-referrer',
      });
    }
    return Response.ok(bytes, headers: {'Content-Type': contentTypeFor(rel)});
  }

  Response _json(Object data, {int status = 200}) =>
      Response(status, body: jsonEncode(data), headers: {'Content-Type': 'application/json'});

  Future<void> dispose() async {
    _disposed = true;
    await _postHocClaim?.cancel();
    _fileWatchDebounce?.cancel();
    _pagesChangedDebounce?.cancel();
    _pageWatchDebounce?.cancel();
    pages.dispose();
    await _fileWatch?.cancel();
    await _snapshotSub?.cancel(); // no git snapshots while shutting down
    await _setupWatch?.cancel();
    _portWatch?.cancel();
    await mock?.close();
    await _reapplyRun;
    final prepared = _preparedDevice;
    if (prepared != null && setup.hasPorts && platformForDeviceId(prepared) == 'android') {
      await setup.removePorts(prepared);
    }
    session.clearServerInfo();
    await _registrySub?.cancel();
    final entry = _entry;
    if (entry != null) registry.remove(entry.id, pid);
    if (_leasedDevice != null) leases.release(_leasedDevice!, pid);
    // Over a copy: closing a socket runs its onDone, which removes it from
    // [_sockets] — iterating the set itself threw there, and the server never
    // reached exit(). Bounded, so a client that never answers the close
    // handshake can't hold the shutdown either.
    for (final s in _sockets.toList()) {
      await s.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await engine.dispose();
    await logStore.close();
    await _http?.close(force: true);
  }
}

/// Read a dashboard asset: dev disk first (EMU_WEB_DIR or the tool's web/),
/// then the embedded base64 map.
List<int>? readWebAsset(String rel) {
  final devDir = Platform.environment['EMU_WEB_DIR'];
  if (devDir != null) {
    final f = File('$devDir/$rel');
    if (f.existsSync()) return f.readAsBytesSync();
  }
  final toolWeb = _toolWebDir();
  if (toolWeb != null) {
    final f = File('$toolWeb/$rel');
    if (f.existsSync()) return f.readAsBytesSync();
  }
  final b64 = kEmbeddedWebAssets[rel];
  if (b64 != null) return base64Decode(b64);
  return null;
}

/// Best-effort resolution of the emu tool's own web/ directory in dev.
String? _toolWebDir() {
  try {
    final script = Platform.script.toFilePath();
    if (script.endsWith('.dart')) {
      // .../emu/bin/emu.dart -> .../emu/web
      final binDir = File(script).parent;
      final web = Directory('${binDir.parent.path}/web');
      if (web.existsSync()) return web.path;
    }
  } catch (_) {}
  return null;
}

String contentTypeFor(String path) {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.png')) return 'image/png';
  return 'application/octet-stream';
}
