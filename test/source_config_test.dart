import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  const base = SourceConfig(
    id: 'id1',
    kind: SourceKind.xtream,
    label: 'Provider',
    fields: {'host': 'http://h:80', 'username': 'u', 'password': 'p'},
  );

  group('stable source identity', () {
    test('build uses SourceConfig.id instead of provider credentials', () {
      expect(base.build().id, base.id);
      final changedCredentials = base.copyWith(
        fields: const {
          'host': 'https://different.invalid',
          'username': 'other',
          'password': 'new-secret',
        },
      );
      expect(changedCredentials.build().id, base.id);
    });

    test('legacy namespace exactly matches pre-PR4 derivation', () {
      expect(base.legacyCacheId, 'xtream:http://h:80|u');
      expect(
        base
            .copyWith(
              fields: const {
                'host': 'provider.invalid/',
                'username': 'alice',
                'password': 'secret',
              },
            )
            .legacyCacheId,
        'xtream:http://provider.invalid|alice',
      );
    });
  });

  group('settings serialization', () {
    test('omits settings from JSON when empty (legacy-compatible)', () {
      expect(base.toJson().containsKey('settings'), isFalse);
    });

    test('round-trips settings through JSON', () {
      final cfg = base.withHiddenCategories(ContentKind.live, {'a', 'b'});
      final round = SourceConfig.fromJson(cfg.toJson());
      expect(round.hiddenCategoryIds(ContentKind.live), {'a', 'b'});
      expect(round.id, base.id);
      expect(round.kind, base.kind);
      expect(round.fields, base.fields);
    });

    test('fromJson tolerates legacy JSON without a settings key', () {
      final legacy = {
        'id': 'id2',
        'kind': 'demo',
        'label': 'Demo',
        'fields': <String, String>{},
      };
      final cfg = SourceConfig.fromJson(legacy);
      expect(cfg.settings, isEmpty);
      expect(cfg.hiddenCategoryIds(ContentKind.live), isEmpty);
    });

    test('build applies persisted catch-up overrides', () {
      final configured = base.copyWith(
        settings: const {
          'catchupTimezone': 'Europe/London',
          'catchupOffsetMinutes': 60,
          'catchupMaxDays': 14,
        },
      );
      final source = configured.build() as XtreamSource;
      expect(source.catchupCapability.timezone, 'Europe/London');
      expect(source.catchupCapability.fixedOffsetMinutes, 60);
      expect(
        source.catchupCapability.maxArchiveWindow,
        const Duration(days: 14),
      );
    });
  });

  group('hiddenCategoryIds / withHiddenCategories', () {
    test('defaults to an empty set per kind', () {
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.movie), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('tracks hidden ids independently per kind', () {
      final cfg = base
          .withHiddenCategories(ContentKind.live, {'live1'})
          .withHiddenCategories(ContentKind.movie, {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.live), {'live1'});
      expect(cfg.hiddenCategoryIds(ContentKind.movie), {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('clearing a kind removes its entry; empty clears all settings', () {
      final hidden = base.withHiddenCategories(ContentKind.live, {'x'});
      expect(hidden.settings.containsKey('hiddenCategories'), isTrue);

      final cleared = hidden.withHiddenCategories(ContentKind.live, {});
      expect(cleared.hiddenCategoryIds(ContentKind.live), isEmpty);
      // No leftover empty map, so it serializes back to no settings.
      expect(cleared.toJson().containsKey('settings'), isFalse);
    });

    test('does not mutate the original config', () {
      base.withHiddenCategories(ContentKind.live, {'x'});
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.settings, isEmpty);
    });

    test('copyWith preserves settings unless overridden', () {
      final cfg = base.withHiddenCategories(ContentKind.series, {'s1'});
      final relabeled = cfg.copyWith(label: 'New');
      expect(relabeled.label, 'New');
      expect(relabeled.hiddenCategoryIds(ContentKind.series), {'s1'});
    });
  });

  // `HomeShell._loadActive` reuses the loaded repository when this holds, which
  // is what keeps leaving the sources screen from re-running the whole channel
  // load. Every settings key a source-settings edit can write has to answer
  // "same catalog" here; every catalog input has to answer "different".
  group('hasSameCatalogInputs', () {
    test('an unchanged config matches itself', () {
      expect(base.hasSameCatalogInputs(base), isTrue);
      expect(
        base.hasSameCatalogInputs(base.copyWith(label: 'Renamed')),
        isTrue,
        reason: 'the label is display-only',
      );
    });

    test('hidden categories and catch-up overrides do not change the catalog',
        () {
      final hidden = base.withHiddenCategories(ContentKind.live, {'sport'});
      expect(base.hasSameCatalogInputs(hidden), isTrue);
      expect(
        base.hasSameCatalogInputs(
          hidden.copyWith(settings: {
            'catchupTimezone': 'Europe/Berlin',
            'catchupOffsetMinutes': 120,
            'catchupMaxDays': 7,
          }),
        ),
        isTrue,
      );
      expect(
        base.hasSameCatalogInputs(
          base.copyWith(settings: {'aspectMode': '16:9', 'bufferPreset': 'high'}),
        ),
        isTrue,
      );
      expect(
        base.hasSameCatalogInputs(
          base.copyWith(settings: {'useDirectUrl': true, 'streamExtension': 'm3u8'}),
        ),
        isTrue,
        reason: 'both are resolved per channel at play time, not while ingesting',
      );
    });

    test('credentials, playlist URL and EPG guides do change the catalog', () {
      expect(
        base.hasSameCatalogInputs(
          base.copyWith(fields: const {
            'host': 'http://h:80',
            'username': 'u',
            'password': 'rotated',
          }),
        ),
        isFalse,
      );
      expect(
        base.hasSameCatalogInputs(
          base.copyWith(fields: const {
            'host': 'http://h:80',
            'username': 'u',
            'password': 'p',
            'epgUrls': 'https://guide.invalid/a.xml',
          }),
        ),
        isFalse,
        reason: 'guide URLs are part of what the cached guide was built from',
      );
      expect(
        base.hasSameCatalogInputs(base.copyWith(fields: const {'host': 'http://h:80'})),
        isFalse,
        reason: 'a dropped credential key is a change, not a subset match',
      );
    });

    test('the id and the kind are catalog inputs', () {
      expect(base.hasSameCatalogInputs(base.copyWith(id: 'id2')), isFalse);
      expect(
        base.hasSameCatalogInputs(base.copyWith(kind: SourceKind.m3u)),
        isFalse,
      );
    });
  });

  // The second half of the reuse decision: the common settings edits must not
  // even rebuild the `Source`, so an already-loaded repository can keep the one
  // it holds (no swap, no retirement, no chance of aborting in-flight work).
  group('sameSourceInputs', () {
    test('a UI-only edit keeps the source', () {
      expect(base.sameSourceInputs(base), isTrue);
      expect(
        base.sameSourceInputs(
          base.withHiddenCategories(ContentKind.live, {'sport'}),
        ),
        isTrue,
      );
      expect(
        base.sameSourceInputs(
          base.copyWith(
            settings: {
              'aspectMode': '16:9',
              'bufferPreset': 'high',
              'autoResumeLastChannel': false,
              'channelDwellSeconds': 7,
            },
          ),
        ),
        isTrue,
      );
    });

    test('a rename rebuilds the source but not the catalog', () {
      // `build()` passes the label through as `displayName`, and the player
      // badge and zap banner print it — so the source must be rebuilt, while
      // every cached row is still correct.
      final renamed = base.copyWith(label: 'Renamed');
      expect(renamed.hasSameCatalogInputs(base), isTrue);
      expect(renamed.sameSourceInputs(base), isFalse);
    });

    test('a catch-up override or an Xtream lever rebuilds the source', () {
      for (final settings in const <Map<String, dynamic>>[
        {'catchupTimezone': 'Europe/Berlin'},
        {'catchupOffsetMinutes': 120},
        {'catchupMaxDays': 7},
        {'streamExtension': 'm3u8'},
        {'useDirectUrl': true},
      ]) {
        expect(
          base.sameSourceInputs(base.copyWith(settings: settings)),
          isFalse,
          reason: 'build() bakes $settings into the source',
        );
      }
    });

    test('a credential change rebuilds the source too', () {
      expect(
        base.sameSourceInputs(
          base.copyWith(fields: const {
            'host': 'http://h:80',
            'username': 'u',
            'password': 'rotated',
          }),
        ),
        isFalse,
      );
    });
  });
}
