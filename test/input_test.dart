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
}
