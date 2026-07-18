import 'package:emu/src/input.dart';
import 'package:test/test.dart';

void main() {
  group('dartStringLiteral', () {
    test('wraps plain text in double quotes', () {
      expect(dartStringLiteral('hello world'), '"hello world"');
    });

    test('escapes characters that would break the embedded expression', () {
      // Quote, backslash, and $ (interpolation) must not escape the literal.
      expect(dartStringLiteral('say "hi"'), r'"say \"hi\""');
      expect(dartStringLiteral(r'a\b'), r'"a\\b"');
      expect(dartStringLiteral(r'$var ${x}'), r'"\$var \${x}"');
    });

    test('escapes control characters', () {
      expect(dartStringLiteral('a\nb\tc'), r'"a\nb\tc"');
    });

    test('keeps Unicode verbatim — the whole point over adb', () {
      expect(dartStringLiteral('한글 😀'), '"한글 😀"');
    });
  });

  group('tapExpr', () {
    test('dispatches a down then up pair', () {
      final e = tapExpr(670, 678);
      expect('PointerDownEvent'.allMatches(e).length, 1);
      expect('PointerUpEvent'.allMatches(e).length, 1);
      expect(e, startsWith('WidgetsBinding.instance'));
    });

    test('converts physical pixels to logical by dividing by dpr', () {
      // Coordinates are embedded raw and divided by the view dpr on-device.
      expect(tapExpr(670, 678), contains('670 / ('));
      expect(tapExpr(670, 678), contains('678 / ('));
      expect(tapExpr(670, 678), contains('devicePixelRatio'));
    });
  });

  group('swipeExpr', () {
    test('emits one down, N moves, one up', () {
      final e = swipeExpr(100, 900, 100, 300, steps: 5);
      expect('PointerDownEvent'.allMatches(e).length, 1);
      expect('PointerMoveEvent'.allMatches(e).length, 5);
      expect('PointerUpEvent'.allMatches(e).length, 1);
    });

    test('carries the pieces the scroll recognizer needs', () {
      final e = swipeExpr(100, 900, 100, 300, durationMs: 300, steps: 3);
      expect(e, contains('pointer: 1'));   // stable pointer id
      expect(e, contains('delta:'));        // movement, not just position
      expect(e, contains('timeStamp:'));    // for velocity / fling
      expect(e, contains('Duration(milliseconds: 300)')); // ends at duration
    });

    test('move timestamps increase across steps', () {
      final e = swipeExpr(0, 0, 0, 100, durationMs: 100, steps: 10);
      // 10 steps over 100ms → 10ms each: 10,20,...,100
      expect(e, contains('Duration(milliseconds: 10)'));
      expect(e, contains('Duration(milliseconds: 100)'));
    });
  });

  group('textExpr', () {
    test('embeds the escaped literal and a cascade (not .toString on void)', () {
      final e = textExpr('hi');
      expect(e, contains('updateEditingValue(TextEditingValue(text: "hi"'));
      expect(e, contains('..updateEditingValue')); // cascade returns the state
      expect(e, endsWith('.runtimeType.toString()'));
    });

    test('selection offset is the UTF-16 length (emoji = surrogate pair = 2)', () {
      expect(textExpr('abc'), contains('offset: 3'));
      expect(textExpr('한글'), contains('offset: 2'));
      expect(textExpr('😀'), contains('offset: 2')); // surrogate pair
    });

    test('escapes injection-prone text so the expression stays valid', () {
      expect(textExpr('a"b'), contains(r'text: "a\"b"'));
    });
  });
}
