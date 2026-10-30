import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emu/src/eval.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show RPCError, SentinelException;

const _iso = 'isolates/1';
const _lib = 'libraries/1';

/// A VM Service in this process that answers `getVM`, `getIsolate`,
/// `evaluate` and `getObject` with what the test sets — enough of the
/// protocol for [evalOnDevice]. One server per file, a fresh connection per
/// call (as `evalOnDevice` makes); [methods] records what was asked.
class _FakeVmService {
  _FakeVmService._(this._server) {
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      opened++;
      ws.listen((m) {
        final msg = jsonDecode(m as String) as Map<String, dynamic>;
        final method = msg['method'] as String;
        methods.add(method);
        final answer = _answer(method);
        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': msg['id'],
          if (answer case {'error': final Object e}) 'error': e else 'result': answer,
        }));
      }, onDone: () => closed++);
    });
  }

  static Future<_FakeVmService> start() async =>
      _FakeVmService._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  String get uri => 'ws://127.0.0.1:${_server.port}/ws';

  final List<String> methods = [];

  /// Connections the client opened and closed, over the whole file.
  int opened = 0, closed = 0;

  List<Map<String, dynamic>> isolates = [_isolateRef];
  Map<String, dynamic>? rootLib = _libraryRef;
  Map<String, dynamic> evaluate = _instance('Null', 'null');
  Map<String, dynamic> object = _instance('Null', 'null');

  void reset() {
    methods.clear();
    isolates = [_isolateRef];
    rootLib = _libraryRef;
    evaluate = _instance('Null', 'null');
    object = _instance('Null', 'null');
  }

  Map<String, dynamic> _answer(String method) => switch (method) {
        'getVM' => {
            'type': 'VM',
            'name': 'vm',
            'architectureBits': 64,
            'hostCPU': '',
            'operatingSystem': '',
            'targetCPU': '',
            'version': '',
            'pid': 1,
            'startTime': 0,
            'isolates': isolates,
            'isolateGroups': <Object>[],
            'systemIsolates': <Object>[],
            'systemIsolateGroups': <Object>[],
          },
        'getIsolate' => {
            ..._isolateRef,
            'type': 'Isolate',
            'runnable': true,
            'livePorts': 0,
            'pauseOnExit': false,
            'startTime': 0,
            'pauseEvent': {'type': 'Event', 'kind': 'Resume', 'timestamp': 0},
            'rootLib': ?rootLib,
            'libraries': <Object>[],
            'breakpoints': <Object>[],
            'exceptionPauseMode': 'None',
          },
        'evaluate' => evaluate,
        'getObject' => object,
        _ => {
            'error': {'code': -32601, 'message': 'Method not found', 'data': {'details': method}}
          },
      };

  Future<void> close() => _server.close(force: true);
}

const _isolateRef = {'type': '@Isolate', 'id': _iso, 'number': '1', 'name': 'main', 'isSystemIsolate': false};
const _libraryRef = {'type': '@Library', 'id': _lib, 'name': '', 'uri': 'package:app/main.dart'};

Map<String, dynamic> _instance(String kind, String? value,
        {String className = '', bool truncated = false, String id = 'objects/1'}) =>
    {
      'type': '@Instance',
      'id': id,
      'kind': kind,
      'class': {'type': '@Class', 'id': 'classes/1', 'name': className, 'library': _libraryRef},
      'valueAsString': ?value,
      if (truncated) 'valueAsStringIsTruncated': true,
    };

void main() {
  late _FakeVmService vm;
  setUpAll(() async => vm = await _FakeVmService.start());
  tearDownAll(() => vm.close());
  setUp(() => vm.reset());

  Future<String> eval([String expr = 'x']) => evalOnDevice(vm.uri, expr);

  /// Every connection is closed, also when evaluation throws.
  Future<void> expectClosed() async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (vm.closed < vm.opened && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(vm.closed, vm.opened);
  }

  group('can not evaluate', () {
    test('no isolate', () async {
      vm.isolates = [];
      await expectLater(eval(), throwsA(isA<EvalException>().having((e) => e.message, 'message', 'no isolate available')));
      expect(vm.methods, ['getVM']);
      await expectClosed();
    });

    test('no root library', () async {
      vm.rootLib = null;
      await expectLater(
          eval(), throwsA(isA<EvalException>().having((e) => e.message, 'message', 'isolate has no root library')));
      expect(vm.methods, ['getVM', 'getIsolate']);
      await expectClosed();
    });

    test('the expression fails: the error message', () async {
      vm.evaluate = {
        'type': '@Error',
        'id': 'objects/9',
        'kind': 'UnhandledException',
        'message': 'Unhandled exception:\nBad state: no',
      };
      await expectLater(
          eval('boom()'),
          throwsA(isA<EvalException>()
              .having((e) => e.message, 'message', 'evaluate failed: Unhandled exception:\nBad state: no')));
      await expectClosed();
    });

    test('a result that is not an instance', () async {
      vm.evaluate = {'type': '@Library', 'id': 'libraries/2', 'name': 'x', 'uri': 'package:app/x.dart'};
      await expectLater(eval(),
          throwsA(isA<EvalException>().having((e) => e.message, 'message', 'unexpected result: LibraryRef')));
      await expectClosed();
    });

    test('a compile error from the VM comes through as the RPC error', () async {
      vm.evaluate = {
        'error': {'code': 113, 'message': 'Expression compilation error', 'data': {'details': 'nope'}}
      };
      await expectLater(eval('nope'), throwsA(isA<RPCError>().having((e) => e.code, 'code', 113)));
      await expectClosed();
    });
  });

  group('sentinel', () {
    // package:vm_service throws a Sentinel answer as SentinelException rather
    // than returning it, so evalOnDevice's `r is Sentinel` branch is not
    // reached: the exception comes through, and the connection still closes.
    test('comes through as SentinelException', () async {
      vm.evaluate = {'type': 'Sentinel', 'kind': 'Expired', 'valueAsString': '<expired>'};
      await expectLater(
          eval(), throwsA(isA<SentinelException>().having((e) => e.sentinel.valueAsString, 'valueAsString', '<expired>')));
      await expectClosed();
    });
  });

  group('instances', () {
    test('evaluated in the root library of the first isolate', () async {
      vm.isolates = [_isolateRef, {..._isolateRef, 'id': 'isolates/2', 'number': '2'}];
      vm.evaluate = _instance('Int', '42');
      expect(await eval('6 * 7'), '42');
      expect(vm.methods, ['getVM', 'getIsolate', 'evaluate']);
      await expectClosed();
    });

    test('primitives bare, strings quoted', () async {
      for (final (kind, value, shown) in [
        ('Int', '3', '3'),
        ('Double', '1.5', '1.5'),
        ('Bool', 'true', 'true'),
        ('Null', 'null', 'null'),
        ('String', 'hi', '"hi"'),
      ]) {
        vm.evaluate = _instance(kind, value);
        expect(await eval(), shown, reason: kind);
      }
    });

    test('no literal form: the class name, else the kind', () async {
      vm.evaluate = _instance('PlainInstance', null, className: 'Cart');
      expect(await eval(), '<Cart>');
      vm.evaluate = {..._instance('List', null)}..remove('class');
      expect(await eval(), '<List>');
    });

    test('a truncated string is read whole from the object', () async {
      vm.evaluate = _instance('String', 'aaa...', truncated: true, id: 'objects/7');
      vm.object = {..._instance('String', 'a' * 200, id: 'objects/7'), 'type': 'Instance', 'length': 200};
      expect(await eval(), '"${'a' * 200}"');
      expect(vm.methods, ['getVM', 'getIsolate', 'evaluate', 'getObject']);
    });

    test('a truncated string whose object is not an Instance keeps the preview', () async {
      vm.evaluate = _instance('String', 'aaa...', truncated: true);
      vm.object = {'type': 'Error', 'id': 'objects/1', 'kind': 'InternalError', 'message': 'gone'};
      expect(await eval(), '"aaa..."');
    });

    test('a truncated string whose object was collected: SentinelException', () async {
      vm.evaluate = _instance('String', 'aaa...', truncated: true);
      vm.object = {'type': 'Sentinel', 'kind': 'Collected', 'valueAsString': '<collected>'};
      await expectLater(eval(), throwsA(isA<SentinelException>()));
      await expectClosed();
    });

    test('a truncated non-string is not quoted', () async {
      vm.evaluate = _instance('Int', '1234...', truncated: true);
      vm.object = {..._instance('Int', '12345678901234567890'), 'type': 'Instance'};
      expect(await eval(), '12345678901234567890');
    });
  });
}
