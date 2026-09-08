import 'package:emu/src/memory_diff.dart';
import 'package:test/test.dart';

void main() {
  group('diffSnapshots', () {
    test('no change → empty diff', () {
      final before = {'a|A': 3, 'b|B': 5};
      final after = {'a|A': 3, 'b|B': 5};
      expect(diffSnapshots(before, after), isEmpty);
    });

    test('increase and decrease both reported', () {
      final before = {'a|A': 3, 'b|B': 5};
      final after = {'a|A': 7, 'b|B': 2};
      expect(diffSnapshots(before, after), {'a|A': 4, 'b|B': -3});
    });

    test('class only in after counts as a full increase from zero', () {
      final before = {'a|A': 3};
      final after = {'a|A': 3, 'b|B': 2};
      expect(diffSnapshots(before, after), {'b|B': 2});
    });

    test('class only in before counts as a full decrease to zero', () {
      final before = {'a|A': 3, 'b|B': 2};
      final after = {'a|A': 3};
      expect(diffSnapshots(before, after), {'b|B': -2});
    });

    test('both empty → empty diff', () {
      expect(diffSnapshots({}, {}), isEmpty);
    });
  });

  group('filterToAppPackage', () {
    test('keeps only classes from the given package library', () {
      final snapshot = {
        'package:my_app/cart.dart|Cart': 3,
        'package:flutter/src/widgets/framework.dart|Element': 100,
        'dart:core|String': 50,
      };
      expect(filterToAppPackage(snapshot, 'my_app'), {'package:my_app/cart.dart|Cart': 3});
    });

    test('empty when nothing matches the package', () {
      final snapshot = {'package:flutter/foo.dart|Foo': 1};
      expect(filterToAppPackage(snapshot, 'my_app'), isEmpty);
    });
  });

  group('classNameOf', () {
    test('strips the library prefix', () {
      expect(classNameOf('package:my_app/cart.dart|Cart'), 'Cart');
    });

    test('returns the key unchanged when there is no separator', () {
      expect(classNameOf('Cart'), 'Cart');
    });
  });

  group('appPackageName', () {
    test('delegates to the pubspec name field', () {
      expect(appPackageName('name: my_app\nversion: 1.0.0'), 'my_app');
      expect(appPackageName('version: 1.0.0'), isNull);
    });
  });
}
