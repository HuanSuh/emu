import 'package:emu/src/error_parser.dart';
import 'package:emu/src/models.dart';
import 'package:test/test.dart';

List<LogEntry> _entries(List<String> lines) {
  var seq = 0;
  return [
    for (final l in lines)
      LogEntry(seq: ++seq, timestamp: DateTime(2024), level: LogLevel.info, text: l),
  ];
}

void main() {
  group('parseErrorBanners', () {
    test('no banners → empty', () {
      final entries = _entries(['hello', 'world', 'I/flutter: some log line']);
      expect(parseErrorBanners(entries), isEmpty);
    });

    test('parses a single well-formed banner', () {
      final entries = _entries([
        'normal line before',
        '═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════════════════════',
        'The following NullCheckError was thrown building MyWidget(...):',
        'Null check operator used on a null value',
        '',
        'When the exception was thrown, this was the stack:',
        '#0  MyWidget.build',
        '════════════════════════════════════════════════════════════════════════════',
        'normal line after',
      ]);
      final result = parseErrorBanners(entries);
      expect(result, hasLength(1));
      final e = result.single;
      expect(e.library, 'EXCEPTION CAUGHT BY WIDGETS LIBRARY');
      expect(e.exceptionType, 'NullCheckError');
      expect(e.startSeq, 2);
      expect(e.endSeq, 8);
      expect(e.raw, contains('Null check operator used on a null value'));
      expect(e.raw, contains('#0  MyWidget.build'));
      expect(e.closed, isTrue);
    });

    test('parses multiple banners independently', () {
      final entries = _entries([
        '═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════',
        'The following StateError was thrown building A(...):',
        'bad state',
        '════════════════════════════════════════════════════════════════',
        'unrelated log line',
        '═══╡ EXCEPTION CAUGHT BY GESTURE ╞════════════════════',
        'The following RangeError was thrown handling a gesture:',
        'index out of range',
        '════════════════════════════════════════════════════════════════',
      ]);
      final result = parseErrorBanners(entries);
      expect(result, hasLength(2));
      expect(result[0].exceptionType, 'StateError');
      expect(result[0].library, 'EXCEPTION CAUGHT BY WIDGETS LIBRARY');
      expect(result[1].exceptionType, 'RangeError');
      expect(result[1].library, 'EXCEPTION CAUGHT BY GESTURE');
    });

    test('malformed thrown-by line: library still parsed, type null, raw preserved', () {
      final entries = _entries([
        '═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════',
        'Something unexpected happened here',
        'more detail',
        '════════════════════════════════════════════════════════════════',
      ]);
      final result = parseErrorBanners(entries);
      expect(result, hasLength(1));
      expect(result.single.library, 'EXCEPTION CAUGHT BY WIDGETS LIBRARY');
      expect(result.single.exceptionType, isNull);
      expect(result.single.raw, contains('Something unexpected happened here'));
    });

    test('malformed opening banner: library and type both null, raw preserved', () {
      final entries = _entries([
        '═══ not quite a banner opening ═══',
        'The following FooError was thrown:',
        '════════════════════════════════════════════════════════════════',
      ]);
      final result = parseErrorBanners(entries);
      // The malformed "opening" line doesn't match _openBanner, so it's just a
      // normal line — no banner is recognized at all here.
      expect(result, isEmpty);
    });

    test('unterminated banner is still returned, closed at the last entry', () {
      final entries = _entries([
        '═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════',
        'The following TimeoutException was thrown resolving a future:',
        'took too long',
      ]);
      final result = parseErrorBanners(entries);
      expect(result, hasLength(1));
      expect(result.single.exceptionType, 'TimeoutException');
      expect(result.single.endSeq, 3);
      // Unclosed — a caller polling with a seq cursor must not advance past
      // startSeq - 1, or the eventual real closing line can never be matched
      // back up with this banner's opening line.
      expect(result.single.closed, isFalse);
    });

    test('processes entries in seq order regardless of input order', () {
      final ordered = _entries([
        '═══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════════',
        'The following FooError was thrown building X:',
        'detail',
        '════════════════════════════════════════════════════════════════',
      ]);
      final shuffled = [ordered[2], ordered[0], ordered[3], ordered[1]];
      final result = parseErrorBanners(shuffled);
      expect(result, hasLength(1));
      expect(result.single.exceptionType, 'FooError');
    });
  });
}
