import 'package:emu/src/locate.dart';
import 'package:test/test.dart';

void main() {
  group('locateExpr', () {
    test('by --text checks Semantics label, Text data, and Tooltip message', () {
      final e = locateExpr(text: '닫기');
      expect(e, contains('_emuMatchText(w, "닫기", loose)'));
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
      expect(locateExpr(text: 'a"b'), contains(r'_emuMatchText(w, "a\"b", loose)'));
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

    test('--dump computes toString() before any part of the record is written, '
        'so a throwing toString() drops the whole match instead of leaving a '
        'partial record for the next match to corrupt', () {
      final e = locateExpr(text: 'x', dump: true);
      final dumpVarAt = e.indexOf('final dumpStr');
      final firstWriteAt = e.indexOf('out.write(');
      expect(dumpVarAt, greaterThanOrEqualTo(0));
      expect(dumpVarAt, lessThan(firstWriteAt));
    });

    test('by --text falls back to a whitespace-normalized substring pass', () {
      final e = locateExpr(text: '동의');
      expect(e, contains('_emuMatchText(w, "동의", loose)'));
      expect(e, contains('d.textSpan?.toPlainText()'));
      expect(e, contains('loose = true; visit(root)'));
      expect(e, contains('return "~" + out.toString()'));
    });

    test('--key/--type have no substring fallback', () {
      expect(locateExpr(key: 'k'), isNot(contains('loose = true')));
      expect(locateExpr(type: 'Text'), isNot(contains('loose = true')));
    });

    test('without --dump no toString() field is emitted', () {
      expect(locateExpr(text: 'x'), isNot(contains('w.toString()')));
    });

    group('top route only', () {
      for (final (name, e) in [
        ('--text', locateExpr(text: 'x')),
        ('--key', locateExpr(key: 'k')),
        ('--type', locateExpr(type: 'Text', dump: true)),
      ]) {
        test('$name: a match on a covered route is counted, not kept', () {
          expect(e, contains('bool _emuOnTop(Element e)'));
          expect(e, contains('if (!_emuOnTop(e)) { hid++; } else try {'));
          expect(e, contains('if (out.isEmpty && hid > 0) return "!" + hid.toString();'));
        });
      }

      test('every route around the match must be current, nested Navigators included', () {
        final e = locateExpr(text: 'x');
        expect(e, contains('final r = ModalRoute.of(at);'));
        expect(e, contains('if (!r.isCurrent) return false;'));
        // Not just the nearest route: walk out to the route holding its Navigator.
        expect(e, contains('while (at != null) {'));
        expect(e, contains('at = box(n.context as Element);'));
      });

      test('a widget outside every route (builder, OverlayEntry) is kept', () {
        expect(locateExpr(text: 'x'), contains('if (r == null) return true;'));
      });

      test('asks ModalRoute.of of a render-object element, never the matched widget', () {
        final e = locateExpr(text: 'x');
        expect(e, contains('if (y is RenderObjectElement) { f = y; return; }'));
        expect(e, contains('var at = box(e);'));
        expect(e, isNot(contains('ModalRoute.of(e)')));
      });

      test('uses no private framework names', () {
        expect(locateExpr(text: 'x'), isNot(contains('_ModalScope')));
      });

      test('the loose pass keeps the exact pass\'s covered count when it has one', () {
        final e = locateExpr(text: 'x');
        expect(e, contains('final exactHid = hid; hid = 0; loose = true; visit(root);'));
        expect(e, contains('if (exactHid > 0) hid = exactHid;'));
      });

      test('allRoutes walks the whole tree as before', () {
        for (final e in [
          locateExpr(text: 'x', allRoutes: true),
          locateExpr(key: 'k', allRoutes: true),
          locateExpr(type: 'Text', allRoutes: true),
        ]) {
          expect(e, isNot(contains('_emuOnTop')));
          expect(e, isNot(contains('ModalRoute')));
          expect(e, contains('try {final c = ro.localToGlobal'));
        }
      });
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
    test('a leading ~ marks every match as partial', () {
      final m = parseLocateMatches('~1|2|3|4|Text;5|6|7|8|Semantics');
      expect(m.map((x) => x.partial), [true, true]);
      expect(m.first.toJson()['partial'], true);
      expect(parseLocateMatches('1|2|3|4|Text').single.toJson().containsKey('partial'), isFalse);
      expect(parseLocateMatches('~'), isEmpty);
    });

    test('empty string means no matches', () {
      expect(parseLocateMatches(''), isEmpty);
      expect(parseLocateMatches('').covered, 0);
    });

    test('!<n> is no match on top, n on covered routes', () {
      final m = parseLocateMatches('!2');
      expect(m, isEmpty);
      expect(m.covered, 2);
      expect(parseLocateMatches('1|2|3|4|Text').covered, 0);
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

    test('zero on top but some on covered routes says so, with the way to reach them', () {
      expect(
        () => pickMatch(LocateMatches(const [], covered: 2), null, query: '--text "확인"'),
        throwsA(isA<LocateException>().having((e) => e.message, 'message',
            'no widget matches --text "확인" on the top route (2 on covered routes — use --all-routes)')),
      );
      expect(noMatchMessage(LocateMatches(const []), '--key "k"'), 'no widget matches --key "k"');
      expect(noMatchMessage(LocateMatches(const [], covered: 1), 'text "a"', hint: null),
          'no widget matches text "a" on the top route (1 on covered routes)');
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
