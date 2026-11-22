import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/stream_kind.dart';
import 'package:iptvs/sources/source.dart' show ContentKind;

/// Settings offers exactly three stream switches — Live, Movies, Series — and
/// every content kind the app can play has to land on one of them. A season or
/// an episode is a *series* to a viewer; it is not a fourth route.
void main() {
  test('every content kind maps to one of the three switches', () {
    for (final kind in ContentKind.values) {
      expect(StreamKind.values, contains(streamKindOf(kind)), reason: '$kind');
    }
  });

  test('the catalogue kinds map straight across', () {
    expect(streamKindOf(ContentKind.live), StreamKind.live);
    expect(streamKindOf(ContentKind.movie), StreamKind.movie);
    expect(streamKindOf(ContentKind.series), StreamKind.series);
  });

  test('seasons and episodes are the series switch', () {
    expect(streamKindOf(ContentKind.season), StreamKind.series);
    expect(streamKindOf(ContentKind.episode), StreamKind.series);
  });

  test('the storage names are the three switch labels, in order', () {
    expect(
      StreamKind.values.map((kind) => kind.storageName),
      ['live', 'movie', 'series'],
    );
    expect(
      StreamKind.values.map((kind) => kind.label),
      ['Live', 'Movies', 'Series'],
    );
  });
}
