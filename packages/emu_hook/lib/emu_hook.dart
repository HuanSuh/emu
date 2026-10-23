/// Routes an app's HTTP traffic for chosen hosts through a running emu
/// session, so `emu mock` can answer requests with canned responses or pass
/// them on to the real server — without the app's base URLs changing.
///
/// ```dart
/// import 'package:emu_hook/emu_hook.dart';
///
/// void main() {
///   if (kDebugMode && EmuHttp.enabled) EmuHttp.install();
///   runApp(const App());
/// }
/// ```
///
/// [EmuHttp.enabled] is true only in a build `emu up` launched with mocks
/// configured: emu passes `--dart-define=EMU_MOCK=<host:port>` and
/// `--dart-define=EMU_MOCK_HOSTS=<host,…>`. Both checks are compile-time
/// constants, so any other build drops the hook entirely.
///
/// How: every `HttpClient` (what `package:http` and Dio use underneath) gets
/// a connection factory that connects requests for the listed hosts to emu —
/// `https://` ones to `<port>`, `http://` ones to `<port + 1>` — as plain
/// HTTP. The request itself is unchanged (same URL, same `Host` header), so
/// emu knows where it was going and no certificate is involved. Every other
/// host connects as before, with the app's own certificate callback, proxy
/// and connection settings.
library;

import 'dart:async';
import 'dart:io';

/// Installs the hook; see the library docs.
abstract final class EmuHttp {
  /// `host:port` of the emu session's mock server, from `--dart-define`.
  static const target = String.fromEnvironment('EMU_MOCK');

  /// Comma-separated hosts to route (`api.example.com`, `*.example.com`).
  static const hosts = String.fromEnvironment('EMU_MOCK_HOSTS');

  /// Whether this build was launched by emu with mocks on.
  static const enabled = target != '';

  /// Route the listed hosts through emu, from here on. [target] and [hosts]
  /// default to what emu passed in. Wraps any [HttpOverrides] already
  /// installed, so call it after the app sets its own.
  static void install({String target = target, String hosts = hosts}) {
    final colon = target.lastIndexOf(':');
    final port = int.tryParse(target.substring(colon + 1));
    if (colon <= 0 || port == null) {
      throw ArgumentError.value(target, 'target', 'expected host:port');
    }
    HttpOverrides.global = EmuHttpOverrides(
      host: target.substring(0, colon),
      port: port,
      hosts: [for (final h in hosts.split(',')) if (h.trim().isNotEmpty) h.trim().toLowerCase()],
      previous: HttpOverrides.current,
    );
  }
}

/// Whether [host] is one of [patterns] (`*.example.com` matches subdomains).
bool hostMatches(String host, List<String> patterns) {
  final h = host.toLowerCase();
  for (final p in patterns) {
    if (p == h) return true;
    if (p.startsWith('*.') && h.endsWith(p.substring(1))) return true;
  }
  return false;
}

/// The [HttpOverrides] [EmuHttp.install] sets.
class EmuHttpOverrides extends HttpOverrides {
  EmuHttpOverrides({required this.host, required this.port, required this.hosts, this.previous});

  /// Where emu's mock server listens (`https://` origins; `http://` on port + 1).
  final String host;
  final int port;
  final List<String> hosts;
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _EmuHttpClient(previous?.createHttpClient(context) ?? super.createHttpClient(context), context, this);
}

/// Forwards everything to the real client and keeps what the app sets for
/// the connection (proxy, certificate callback, key log, connection
/// factory), so hosts that aren't routed connect exactly as before.
class _EmuHttpClient implements HttpClient {
  _EmuHttpClient(this._inner, this._context, this._emu) {
    _inner
      ..findProxy = _findProxy
      ..connectionFactory = _connect;
  }

  final HttpClient _inner;
  final SecurityContext? _context;
  final EmuHttpOverrides _emu;

  String Function(Uri url)? _appFindProxy;
  Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? _appFactory;
  bool Function(X509Certificate cert, String host, int port)? _appBadCertificate;
  void Function(String line)? _appKeyLog;

  bool _routed(Uri url) => hostMatches(url.host, _emu.hosts);

  // A routed host never goes through the app's proxy: the connection must
  // reach emu as plain HTTP, not as a CONNECT tunnel.
  String _findProxy(Uri url) => _routed(url) ? 'DIRECT' : (_appFindProxy?.call(url) ?? 'DIRECT');

  Future<ConnectionTask<Socket>> _connect(Uri url, String? proxyHost, int? proxyPort) {
    if (proxyHost == null && _routed(url)) {
      return Socket.startConnect(_emu.host, url.scheme == 'https' ? _emu.port : _emu.port + 1);
    }
    final app = _appFactory;
    if (app != null) return app(url, proxyHost, proxyPort);
    // What HttpClient does without a factory: a proxy (tunnel or plain) gets
    // a plain socket, a direct https connection is secured here.
    if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    if (url.scheme != 'https') return Socket.startConnect(url.host, port);
    final onBad = _appBadCertificate;
    return SecureSocket.startConnect(
      url.host,
      port,
      context: _context,
      onBadCertificate: onBad == null ? null : (cert) => onBad(cert, url.host, port),
      keyLog: _appKeyLog,
    );
  }

  @override
  set findProxy(String Function(Uri url)? f) => _appFindProxy = f;

  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f) =>
      _appFactory = f;

  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) {
    _appBadCertificate = callback;
    _inner.badCertificateCallback = callback; // still used for proxied https
  }

  @override
  set keyLog(Function(String line)? callback) {
    _appKeyLog = callback == null ? null : (line) => callback(line);
    _inner.keyLog = callback;
  }

  // ---- forwarded as is ----------------------------------------------------

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      _inner.open(method, host, port, path);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _inner.openUrl(method, url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) => _inner.get(host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _inner.getUrl(url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) => _inner.post(host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _inner.postUrl(url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) => _inner.put(host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _inner.putUrl(url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) => _inner.delete(host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _inner.deleteUrl(url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => _inner.patch(host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _inner.patchUrl(url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) => _inner.head(host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _inner.headUrl(url);

  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) => _inner.authenticate = f;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) =>
      _inner.authenticateProxy = f;
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);

  // A member a later SDK adds: fail loudly rather than not compile.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('emu_hook: HttpClient.${invocation.memberName} is not forwarded yet');
}
