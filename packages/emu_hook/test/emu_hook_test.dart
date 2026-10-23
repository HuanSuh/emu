import 'dart:convert';
import 'dart:io';

import 'package:emu_hook/emu_hook.dart';
import 'package:test/test.dart';

/// Two loopback servers on consecutive ports, standing in for emu's mock
/// server: [port] gets https:// origins, [port] + 1 http:// ones.
Future<(HttpServer, HttpServer)> _fakeEmu() async {
  for (var i = 0; i < 20; i++) {
    final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      return (a, await HttpServer.bind(InternetAddress.loopbackIPv4, a.port + 1));
    } on SocketException {
      await a.close(force: true);
    }
  }
  throw StateError('no two free consecutive ports');
}

/// Answers every request with what it saw: `<tag> <method> <uri> host=<Host>`.
void _echo(HttpServer s, String tag) => s.listen((req) async {
      await req.drain<void>();
      req.response.write('$tag ${req.method} ${req.uri} host=${req.headers.value('host')}');
      await req.response.close();
    });

Future<String> _get(HttpClient client, String url) async {
  final res = await (await client.getUrl(Uri.parse(url))).close();
  return res.transform(utf8.decoder).join();
}

void main() {
  late HttpServer https, http, other;
  late HttpOverrides overrides;

  setUp(() async {
    (https, http) = await _fakeEmu();
    _echo(https, 'emu-https');
    _echo(http, 'emu-http');
    other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _echo(other, 'direct');
    overrides = EmuHttpOverrides(host: '127.0.0.1', port: https.port, hosts: ['api.example.com', '*.cdn.test']);
  });
  tearDown(() async {
    for (final s in [https, http, other]) {
      await s.close(force: true);
    }
  });

  Future<T> withHook<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, overrides);

  test('not enabled without the dart-define', () {
    expect(EmuHttp.enabled, isFalse);
    expect(() => EmuHttp.install(target: 'nope'), throwsArgumentError);
  });

  test('hostMatches: exact and *.subdomain, case-insensitive', () {
    expect(hostMatches('API.example.com', ['api.example.com']), isTrue);
    expect(hostMatches('img.cdn.test', ['*.cdn.test']), isTrue);
    expect(hostMatches('cdn.test', ['*.cdn.test']), isFalse);
    expect(hostMatches('example.com', ['api.example.com']), isFalse);
  });

  test('a routed https request reaches emu as plain HTTP, URL and Host unchanged', () async {
    final body = await withHook(() => _get(HttpClient(), 'https://api.example.com/v1/items?page=2'));
    expect(body, 'emu-https GET /v1/items?page=2 host=api.example.com');
  });

  test('a routed http request goes to port + 1; a non-default port stays in Host', () async {
    final body = await withHook(() => _get(HttpClient(), 'http://img.cdn.test:8080/a.png'));
    expect(body, 'emu-http GET /a.png host=img.cdn.test:8080');
  });

  test('other hosts connect directly, as before', () async {
    final body = await withHook(() => _get(HttpClient(), 'http://127.0.0.1:${other.port}/x'));
    expect(body, 'direct GET /x host=127.0.0.1:${other.port}');
  });

  test("the app's proxy still applies to other hosts, never to routed ones", () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _echo(proxy, 'proxy');
    addTearDown(() => proxy.close(force: true));
    final (viaProxy, routed) = await withHook(() async {
      final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      return (await _get(client, 'http://elsewhere.test/y'), await _get(client, 'https://api.example.com/z'));
    });
    expect(viaProxy, startsWith('proxy GET http://elsewhere.test/y'));
    expect(routed, 'emu-https GET /z host=api.example.com');
  });

  test("the app's own connection factory still serves other hosts", () async {
    final body = await withHook(() {
      final client = HttpClient()
        ..connectionFactory = (url, _, __) => Socket.startConnect('127.0.0.1', other.port);
      return _get(client, 'http://anything.test/f');
    });
    expect(body, 'direct GET /f host=anything.test');
  });

  group('https to other hosts', () {
    late HttpServer tls;
    setUpAll(() async {
      final dir = Directory.systemTemp.createTempSync('emu_hook_tls');
      addTearDown(() => dir.deleteSync(recursive: true));
      final r = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost',
        '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
      ]);
      if (r.exitCode != 0) fail('openssl: ${r.stderr}');
      final ctx = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      tls = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
      _echo(tls, 'tls');
    });
    tearDownAll(() => tls.close(force: true));

    test("keep the app's certificate callback", () async {
      final seen = <String>[];
      final body = await withHook(() {
        final client = HttpClient()
          ..badCertificateCallback = (cert, host, port) {
            seen.add('$host:$port');
            return true;
          };
        return _get(client, 'https://localhost:${tls.port}/s');
      });
      expect(body, 'tls GET /s host=localhost:${tls.port}');
      expect(seen, ['localhost:${tls.port}']);
    });

    test('and still refuse a bad certificate without one', () async {
      await expectLater(withHook(() => _get(HttpClient(), 'https://localhost:${tls.port}/s')),
          throwsA(isA<HandshakeException>()));
    });
  });
}
