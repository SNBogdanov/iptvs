import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/media_watch_filter.dart';
import 'package:iptvs/sources/source.dart';

MediaItem _item(String id) =>
    MediaItem(id: id, title: id, kind: ContentKind.movie, year: '2020');

void main() {
  group('watched filtering', () {
    final items = [_item('a'), _item('b'), _item('c')];

    test('only a finished mark counts as watched', () {
      expect(isMediaWatched({'a': 1.0}, 'a'), isTrue);
      expect(isMediaWatched({'a': 0.5}, 'a'), isFalse);
      expect(isMediaWatched({}, 'a'), isFalse);
    });

    test('started titles stay in the unwatched list', () {
      final result = mediaWithoutWatched(items, {'a': 1.0, 'b': 0.4});
      expect(result.map((item) => item.id), ['b', 'c']);
    });

    test('an all-watched list becomes empty', () {
      final result = mediaWithoutWatched(items, {'a': 1.0, 'b': 1.0, 'c': 1.0});
      expect(result, isEmpty);
    });

    test('the first unwatched item skips finished ones and keeps started', () {
      final result = firstUnwatchedMedia(items, {'a': 1.0, 'b': 0.2});
      expect(result?.id, 'b');
    });

    test('there is no first unwatched item when everything finished', () {
      final result = firstUnwatchedMedia(items, {'a': 1.0, 'b': 1.0, 'c': 1.0});
      expect(result, isNull);
    });

    test('an empty progress map keeps the same list instance', () {
      expect(identical(mediaWithoutWatched(items, const {}), items), isTrue);
    });
  });
}
