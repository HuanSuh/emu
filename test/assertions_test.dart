import 'package:emu/src/assertions.dart';
import 'package:emu/src/log_store.dart';
import 'package:test/test.dart';

void main() {
  final store = LogStore();
  store.add('app started');
  store.add('[emu-demo] parsed value = 12500');
  store.add('Unhandled Exception: FormatException');
  final entries = store.query();

  test('expect passes when pattern present', () {
    final o = evaluateAssertion(entries, ['parsed value = 12500'], const []);
    expect(o.pass, isTrue);
    expect(o.expectsMet, isTrue);
  });

  test('expect fails when pattern absent', () {
    final o = evaluateAssertion(entries, ['checkout completed'], const []);
    expect(o.pass, isFalse);
    expect(o.expected['checkout completed'], isFalse);
  });

  test('deny fails when forbidden pattern present', () {
    final o = evaluateAssertion(entries, const [], ['Exception']);
    expect(o.pass, isFalse);
    expect(o.denied['Exception'], isNotEmpty);
  });

  test('deny passes when forbidden pattern absent', () {
    final o = evaluateAssertion(entries, const [], ['NullPointer']);
    expect(o.pass, isTrue);
    expect(o.denyClean, isTrue);
  });

  test('combined expect + deny', () {
    final o = evaluateAssertion(entries, ['app started'], ['NullPointer']);
    expect(o.pass, isTrue);
    final bad = evaluateAssertion(entries, ['app started'], ['FormatException']);
    expect(bad.pass, isFalse);
  });

  test('patterns are case-insensitive regex', () {
    final o = evaluateAssertion(entries, [r'parsed value = \d+'], ['EXCEPTION']);
    expect(o.expectsMet, isTrue);
    expect(o.denyClean, isFalse);
  });

  test('toJson reports verdict', () {
    final o = evaluateAssertion(entries, const [], ['Exception']);
    expect(o.toJson()['verdict'], 'fail');
  });
}
