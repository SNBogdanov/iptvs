import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/channel_list_screen.dart';

void main() {
  group('multiLiveCategoryId', () {
    test('is order-independent', () {
      expect(
        multiLiveCategoryId(['news', 'sport']),
        multiLiveCategoryId(['sport', 'news']),
      );
    });

    test('round-trips through multiLiveCategoryIds', () {
      final id = multiLiveCategoryId(['news', 'sport', 'movies']);
      expect(id.startsWith(kMultiLiveCategoryPrefix), isTrue);
      expect(multiLiveCategoryIds(id), ['movies', 'news', 'sport']);
    });

    test('ids may contain the characters a plain separator would break on', () {
      // Provider category ids are opaque; a set with a space, a colon and a
      // slash must still survive the round trip.
      final id = multiLiveCategoryId(['a b', 'c:d', 'e/f']);
      expect(multiLiveCategoryIds(id), ['a b', 'c:d', 'e/f']);
    });

    test('empty ids are dropped, so the id never ends in a separator', () {
      final id = multiLiveCategoryId(['', 'sport', '']);
      expect(multiLiveCategoryIds(id), ['sport']);
      expect(id.endsWith(kLiveCategorySeparator), isFalse);
    });
  });
}
