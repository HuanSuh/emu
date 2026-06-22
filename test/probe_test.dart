import 'package:emu/src/probe.dart';
import 'package:test/test.dart';

void main() {
  group('packageNameFromPubspec', () {
    test('reads the name field', () {
      expect(packageNameFromPubspec('name: emu_demo\nversion: 1.0.0'), 'emu_demo');
    });
    test('ignores name elsewhere', () {
      expect(packageNameFromPubspec('description: my name is x\nname: real'), 'real');
    });
    test('null when absent', () {
      expect(packageNameFromPubspec('version: 1.0.0'), isNull);
    });
  });

  group('matchScriptUri', () {
    final uris = [
      'dart:core',
      'package:flutter/material.dart',
      'package:emu_demo/main.dart',
      'package:emu_demo/src/cart.dart',
    ];

    test('exact package uri for lib/ path', () {
      expect(matchScriptUri(uris, 'lib/main.dart', 'emu_demo'), 'package:emu_demo/main.dart');
      expect(matchScriptUri(uris, 'lib/src/cart.dart', 'emu_demo'),
          'package:emu_demo/src/cart.dart');
    });

    test('suffix match without package name', () {
      expect(matchScriptUri(uris, 'lib/src/cart.dart', null), 'package:emu_demo/src/cart.dart');
    });

    test('basename fallback', () {
      expect(matchScriptUri(uris, 'main.dart', null), 'package:emu_demo/main.dart');
    });

    test('null when no match', () {
      expect(matchScriptUri(uris, 'lib/nope.dart', 'emu_demo'), isNull);
    });
  });
}
