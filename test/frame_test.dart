import 'package:emu/src/frame.dart';
import 'package:test/test.dart';

void main() {
  group('firstFrameSent', () {
    test('accepts both the string and bool spellings of enabled', () {
      // Flutter renders this flag differently across versions.
      expect(firstFrameSent({'enabled': 'true'}), isTrue);
      expect(firstFrameSent({'enabled': true}), isTrue);
    });

    test('anything else means not painted yet', () {
      expect(firstFrameSent({'enabled': 'false'}), isFalse);
      expect(firstFrameSent({'enabled': false}), isFalse);
      expect(firstFrameSent({}), isFalse);
      expect(firstFrameSent(null), isFalse);
    });
  });
}
