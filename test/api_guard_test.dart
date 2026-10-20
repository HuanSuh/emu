import 'dart:convert';
import 'dart:io';

import 'package:emu/src/api_guard.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _token = 'a1b2c3';

/// Runs one request through the guard in front of a handler that always
/// answers 200, so the status says whether the guard let it through.
Future<Response> _send(String method, String path,
    {String host = '127.0.0.1:4577', Map<String, String> headers = const {}}) async {
  final handler = const Pipeline().addMiddleware(apiGuard(_token)).addHandler((_) => Response.ok('ok'));
  return handler(Request(method, Uri.parse('http://$host$path'), headers: {'host': host, ...headers}));
}

void main() {
  group('Host', () {
    test('loopback names pass, on any port (port forwarding)', () async {
      expect((await _send('GET', '/')).statusCode, 200);
      expect((await _send('GET', '/', host: 'localhost:9000')).statusCode, 200);
      expect((await _send('GET', '/', host: 'LOCALHOST:4577')).statusCode, 200);
    });

    test('any other name is refused, static pages included (DNS rebinding)', () async {
      expect((await _send('GET', '/', host: 'evil.example:4577')).statusCode, 403);
      expect((await _send('GET', '/api/status', host: '127.0.0.1.evil.example')).statusCode, 403);
      expect(isLoopbackHost(null), isFalse);
      expect(isLoopbackHost(''), isFalse);
    });
  });

  group('Origin', () {
    test('absent or this server is fine', () async {
      expect((await _send('POST', '/api/reload', headers: {tokenHeader: _token})).statusCode, 200);
      expect(
          (await _send('POST', '/api/reload',
                  headers: {tokenHeader: _token, 'origin': 'http://127.0.0.1:4577'}))
              .statusCode,
          200);
    });

    test('another site, another local port or "null" is refused even with the token', () async {
      for (final origin in ['https://evil.example', 'http://127.0.0.1:3000', 'http://localhost:4577', 'null']) {
        final r = await _send('POST', '/api/reload', headers: {tokenHeader: _token, 'origin': origin});
        expect(r.statusCode, 403, reason: origin);
      }
    });
  });

  group('session token', () {
    test('required on API routes — header or query', () async {
      expect((await _send('POST', '/api/reload')).statusCode, 401);
      expect((await _send('POST', '/api/reload', headers: {tokenHeader: 'wrong!'})).statusCode, 401);
      expect((await _send('POST', '/api/reload', headers: {'X-Emu-Token': _token})).statusCode, 200);
      expect((await _send('GET', '/api/stream?token=$_token')).statusCode, 200);
      expect((await _send('GET', '/api/screenshot?inline=1&token=nope')).statusCode, 401);
    });

    test('GETs are guarded too — every route used to accept any method', () async {
      expect((await _send('GET', '/api/tap?x=1&y=2')).statusCode, 401);
      expect((await _send('GET', '/api/shutdown')).statusCode, 401);
    });

    test('not needed for the liveness ping or the dashboard itself', () async {
      expect((await _send('GET', '/api/status')).statusCode, 200);
      expect((await _send('GET', '/')).statusCode, 200);
      expect((await _send('GET', '/app.js')).statusCode, 200);
      expect((await _send('POST', '/api/status')).statusCode, 401);
    });

    test('routes learn whether the token came, to answer less without it', () async {
      final handler = const Pipeline()
          .addMiddleware(apiGuard(_token))
          .addHandler((req) => Response.ok('${req.context[authedContextKey]}'));
      Future<String> seen(String path, [Map<String, String> headers = const {}]) async =>
          (await handler(Request('GET', Uri.parse('http://127.0.0.1:4577$path'), headers: {'host': '127.0.0.1:4577', ...headers})))
              .readAsString();
      expect(await seen('/api/status'), 'false');
      expect(await seen('/api/status', {tokenHeader: _token}), 'true');
      expect(await seen('/api/status?token=$_token'), 'true');
    });

    test('refusals are JSON the CLI can show', () async {
      final r = await _send('POST', '/api/reload');
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isFalse);
      expect(body['error'], contains('.emu/server.json'));
    });

    test('tokenMatches compares the whole value', () {
      expect(tokenMatches(_token, _token), isTrue);
      expect(tokenMatches('a1b2c4', _token), isFalse);
      expect(tokenMatches('a1b2c', _token), isFalse);
      expect(tokenMatches(null, _token), isFalse);
    });

    test('newSessionToken is 64 hex chars and new each time', () {
      final a = newSessionToken(), b = newSessionToken();
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a, isNot(b));
    });
  });

  test('the dashboard page has the placeholder the server fills in', () {
    final html = File('web/index.html').readAsStringSync();
    expect(html, contains(tokenPlaceholder));
    expect(injectSessionToken(html, 'tok'), allOf(contains('content="tok"'), isNot(contains(tokenPlaceholder))));
  });
}
