// `MetadataConfig.sameConfiguration` — the metadata half of the decision
// `HomeShell._loadActive` makes when it returns from the sources screen: a
// settings-only source edit reuses the loaded `LibraryRepository` (so the
// channel list is not re-ingested), but the repository's `MetadataProvider`s are
// `final`, so anything that would build a different set of them has to rebuild
// the repository instead. Getting this wrong in the permissive direction leaves
// enrichment holding credentials the user just replaced.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/metadata_config.dart';

void main() {
  const configured = MetadataConfig(
    provider: 'tvdb',
    tmdbApiKey: 'tmdb-key',
    tvdbApiKey: 'tvdb-key',
    tvdbPin: '1234',
    mdblistApiKey: 'mdblist-key',
    autoEnrich: true,
  );

  group('sameConfiguration', () {
    test('an identical config matches itself', () {
      expect(configured.sameConfiguration(configured), isTrue);
      expect(
        configured.sameConfiguration(
          const MetadataConfig(
            provider: 'tvdb',
            tmdbApiKey: 'tmdb-key',
            tvdbApiKey: 'tvdb-key',
            tvdbPin: '1234',
            mdblistApiKey: 'mdblist-key',
          ),
        ),
        isTrue,
        reason: 'autoEnrich defaults to true, so this is the same config',
      );
    });

    // Every field `_buildMetadataProviders` reads. Written out rather than via a
    // `copyWith` so the list cannot drift from the constructor.
    test('every field that changes the provider set is compared', () {
      const variants = <MetadataConfig>[
        MetadataConfig(
          provider: 'tmdb',
          tmdbApiKey: 'tmdb-key',
          tvdbApiKey: 'tvdb-key',
          tvdbPin: '1234',
          mdblistApiKey: 'mdblist-key',
        ),
        MetadataConfig(
          provider: 'tvdb',
          tmdbApiKey: 'other',
          tvdbApiKey: 'tvdb-key',
          tvdbPin: '1234',
          mdblistApiKey: 'mdblist-key',
        ),
        MetadataConfig(
          provider: 'tvdb',
          tmdbApiKey: 'tmdb-key',
          tvdbApiKey: 'other',
          tvdbPin: '1234',
          mdblistApiKey: 'mdblist-key',
        ),
        MetadataConfig(
          provider: 'tvdb',
          tmdbApiKey: 'tmdb-key',
          tvdbApiKey: 'tvdb-key',
          tvdbPin: '9999',
          mdblistApiKey: 'mdblist-key',
        ),
        MetadataConfig(
          provider: 'tvdb',
          tmdbApiKey: 'tmdb-key',
          tvdbApiKey: 'tvdb-key',
          tvdbPin: '1234',
          mdblistApiKey: 'other',
        ),
        MetadataConfig(
          provider: 'tvdb',
          tmdbApiKey: 'tmdb-key',
          tvdbApiKey: 'tvdb-key',
          tvdbPin: '1234',
          mdblistApiKey: 'mdblist-key',
          autoEnrich: false,
        ),
      ];
      for (final variant in variants) {
        expect(
          configured.sameConfiguration(variant),
          isFalse,
          reason: 'a differing field must force a repository rebuild',
        );
        expect(variant.sameConfiguration(configured), isFalse);
      }
    });
  });
}