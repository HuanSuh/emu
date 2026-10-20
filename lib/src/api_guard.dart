/// Who may call the server. The API drives the app, and a browser lets any
/// web page send requests to `127.0.0.1` — so a request must show it comes
/// from this session's own dashboard or CLI:
///
/// - **Host** must name the loopback interface (`127.0.0.1` / `localhost`,
///   any port) — a DNS-rebinding page arrives with its own domain here.
/// - **Origin**, when a browser sends one, must be this server's own origin —
///   other sites and other local ports are refused.
/// - **The session token** (`X-Emu-Token` header, or a `token` query
///   parameter where a header can't be set: WebSocket, `<img>`) on every
///   `/api/` route except `GET /api/status`, the liveness ping other emu
///   sessions use (see `device_lease.dart`). The server makes a new token on
///   every start and records it in `.emu/server.json` for the CLI; the
///   dashboard gets it inside `index.html`, which other origins can't read.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';

/// `Request.context` key: whether the request carried the session token —
/// routes open without it (`GET /api/status`) answer less to those that didn't.
const authedContextKey = 'emu.authed';

/// Header the CLI and dashboard send the session token in.
const tokenHeader = 'x-emu-token';

/// Placeholder in `web/index.html` replaced with the session token.
const tokenPlaceholder = '__EMU_SESSION_TOKEN__';

/// 32 random bytes as hex.
String newSessionToken() {
  final rnd = Random.secure();
  return [for (var i = 0; i < 32; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// Whether the `Host` header names this machine's loopback interface. The
/// port is not checked: a port-forwarded dashboard arrives under another one.
bool isLoopbackHost(String? host) {
  if (host == null || host.isEmpty) return false;
  final name = host.toLowerCase().replaceFirst(RegExp(r':\d+$'), '');
  return name == '127.0.0.1' || name == 'localhost';
}

/// Whether a browser `Origin` header is this server's own origin, i.e. the
/// page making the request was served from the same `http://<host>`. A
/// missing Origin (CLI, same-origin GET) is fine; `null` (sandboxed frames,
/// `file://`) is not.
bool isSameOrigin(String? origin, String? host) =>
    origin == null || (host != null && origin.toLowerCase() == 'http://${host.toLowerCase()}');

/// Whether [path] (with a leading slash) needs the session token for
/// [method]. Only the liveness ping and the static dashboard don't.
bool needsToken(String method, String path) {
  if (!path.startsWith('/api/')) return false;
  if (path == '/api/status' && (method == 'GET' || method == 'HEAD')) return false;
  return true;
}

/// Constant-time comparison, so response timing doesn't leak the token.
bool tokenMatches(String? given, String token) {
  if (given == null || given.length != token.length) return false;
  var diff = 0;
  for (var i = 0; i < token.length; i++) {
    diff |= given.codeUnitAt(i) ^ token.codeUnitAt(i);
  }
  return diff == 0;
}

/// `index.html` with the session token filled in.
String injectSessionToken(String html, String token) => html.replaceAll(tokenPlaceholder, token);

/// Rejects requests that fail the checks above before they reach a route.
Middleware apiGuard(String token) => (Handler inner) => (Request req) {
      final host = req.headers['host'];
      if (!isLoopbackHost(host)) {
        return _refuse(403, 'host "$host" is not this machine — open the dashboard at http://127.0.0.1:<port>');
      }
      if (!isSameOrigin(req.headers['origin'], host)) {
        return _refuse(403, 'cross-origin request refused (origin ${req.headers['origin']})');
      }
      final path = '/${req.url.path}';
      final authed = tokenMatches(req.headers[tokenHeader] ?? req.url.queryParameters['token'], token);
      if (needsToken(req.method, path) && !authed) {
        return _refuse(401,
            'missing or wrong session token — the CLI reads it from .emu/server.json; reload the dashboard after `emu up`');
      }
      return inner(req.change(context: {authedContextKey: authed}));
    };

Response _refuse(int status, String error) =>
    Response(status, body: jsonEncode({'ok': false, 'error': error}), headers: {'Content-Type': 'application/json'});
