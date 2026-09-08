import 'package:emu/src/locate.dart';
import 'package:test/test.dart';

void main() {
  group('locateExpr', () {
    test('by --text checks Semantics label, Text data, and Tooltip message', () {
      final e = locateExpr(text: '닫기');
      expect(e, contains('_emuMatchText(w, "닫기")'));
      expect(e, contains('d.data == want'));
      expect(e, contains('d.properties.label == want'));
      expect(e, contains('d.message == want'));
      expect(e, isNot(contains('_emuMatchKey(w.key')));
    });

    test('by --key checks ValueKey.value', () {
      final e = locateExpr(key: 'myButtonKey');
      expect(e, contains('_emuMatchKey(w.key, "myButtonKey")'));
      expect(e, contains('k is ValueKey && k.value.toString() == want'));
      expect(e, isNot(contains('_emuMatchText(w,')));
    });

    test('escapes injection-prone query text', () {
      expect(locateExpr(text: 'a"b'), contains(r'_emuMatchText(w, "a\"b")'));
    });

    test('by --type checks the widget runtime type name', () {
      final e = locateExpr(type: 'ElevatedButton');
      expect(e, contains('_emuMatchType(w, "ElevatedButton")'));
      expect(e, contains('w.runtimeType.toString() == want'));
      expect(e, isNot(contains('_emuMatchText(w,')));
      expect(e, isNot(contains('_emuMatchKey(w.key')));
    });

    test('exactly one of text/key/type must be given', () {
      expect(() => locateExpr(), throwsA(isA<AssertionError>()));
      expect(() => locateExpr(text: 'a', key: 'b'), throwsA(isA<AssertionError>()));
      expect(() => locateExpr(text: 'a', type: 'b'), throwsA(isA<AssertionError>()));
      expect(() => locateExpr(key: 'a', type: 'b'), throwsA(isA<AssertionError>()));
      expect(() => locateExpr(text: 'a', key: 'b', type: 'c'),
          throwsA(isA<AssertionError>()));
    });

    test('--dump appends a toString() field, sanitized of the delimiters', () {
      final e = locateExpr(text: 'x', dump: true);
      expect(e, contains('w.toString()'));
      expect(e, contains(r'.replaceAll("|", " ")'));
      expect(e, contains(r'.replaceAll(";", " ")'));
      expect(e, contains(r'.replaceAll("\n", " ")'));
    });

    test('without --dump no toString() field is emitted', () {
      expect(locateExpr(text: 'x'), isNot(contains('w.toString()')));
    });

    test('walks the element tree from the root and converts to physical pixels', () {
      final e = locateExpr(text: 'x');
      expect(e, contains('WidgetsBinding.instance.rootElement'));
      expect(e, contains('e.visitChildren(visit)'));
      expect(e, contains('localToGlobal'));
      expect(e, contains('devicePixelRatio'));
    });
  });

  group('parseLocateMatches', () {
    test('empty string means no matches', () {
      expect(parseLocateMatches(''), isEmpty);
    });

    test('parses a single record', () {
      final m = parseLocateMatches('100|200|50.0|20.0|Text');
      expect(m, hasLength(1));
      expect(m.single.x, 100);
      expect(m.single.y, 200);
      expect(m.single.width, 50.0);
      expect(m.single.height, 20.0);
      expect(m.single.widgetType, 'Text');
    });

    test('rounds fractional physical coordinates to the nearest pixel', () {
      final m = parseLocateMatches('100.6|200.4|10|10|Text');
      expect(m.single.x, 101);
      expect(m.single.y, 200);
    });

    test('parses multiple records in order', () {
      final m = parseLocateMatches('10|10|5|5|Text;20|20|5|5|Semantics');
      expect(m, hasLength(2));
      expect(m[0].widgetType, 'Text');
      expect(m[1].widgetType, 'Semantics');
    });

    test('a sixth field is the widget dump; without it dump is null', () {
      expect(parseLocateMatches('1|2|3|4|Text').single.dump, isNull);
      final m = parseLocateMatches('1|2|3|4|Text|Text("hi")').single;
      expect(m.widgetType, 'Text');
      expect(m.dump, 'Text("hi")');
    });

    test('dump survives alongside other records', () {
      final m = parseLocateMatches('1|2|3|4|Text|A;5|6|7|8|Icon|B');
      expect(m.map((e) => e.dump), ['A', 'B']);
    });

    test('a dumped match serializes its dump; a plain one omits the field', () {
      expect(LocateMatch(1, 2, 3, 4, 'Text', 'A').toJson()['dump'], 'A');
      expect(LocateMatch(1, 2, 3, 4, 'Text').toJson().containsKey('dump'), isFalse);
    });

    test('skips malformed records instead of throwing', () {
      final m = parseLocateMatches('10|10|5|5|Text;garbage;20|20|5|5|Semantics');
      expect(m, hasLength(2));
    });
  });

  group('pickMatch', () {
    final matches = [
      LocateMatch(1, 1, 1, 1, 'Text'),
      LocateMatch(2, 2, 1, 1, 'Semantics'),
    ];

    test('a single match is picked with no index', () {
      final m = pickMatch([matches[0]], null, query: '--text "x"');
      expect(m.x, 1);
    });

    test('zero matches throws with the query in the message', () {
      expect(
        () => pickMatch(const [], null, query: '--text "닫기"'),
        throwsA(isA<LocateException>().having(
            (e) => e.message, 'message', contains('--text "닫기"'))),
      );
    });

    test('several matches without --index throws, naming the count', () {
      expect(
        () => pickMatch(matches, null, query: '--text "x"'),
        throwsA(isA<LocateException>().having(
            (e) => e.message, 'message', allOf(contains('2'), contains('--index')))),
      );
    });

    test('--index selects the matching entry', () {
      expect(pickMatch(matches, 1, query: '--text "x"').widgetType, 'Semantics');
    });

    test('--index out of range throws', () {
      expect(
        () => pickMatch(matches, 5, query: '--text "x"'),
        throwsA(isA<LocateException>()),
      );
    });
  });
}
