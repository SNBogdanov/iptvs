import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/source_refresh_store.dart';
import 'package:iptvs/sources/refresh_interval.dart';
import 'package:iptvs/sources/source_config.dart';

/// The per-source catalogue-refresh schedule: the stored choice, the pure "is it
/// due?" decision, and the device-local last-run record it reads. One file
/// because the three are one behaviour, and the failure that matters is a
/// disagreement between them (a value the enum cannot parse, a "never refreshed"
/// that reads as "not due").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceRefreshInterval', () {
    test('parses every stored value', () {
      for (final interval in SourceRefreshInterval.values) {
        expect(
          SourceRefreshInterval.parse(interval.storageValue),
          interval,
        );
      }
    });

    test('absent or unknown values read as the default (24h)', () {
      // Not "never" and not "every launch": a mangled preference must behave like
      // the untouched default rather than silently stopping or over-firing.
      expect(SourceRefreshInterval.parse(null), SourceRefreshInterval.every24h);
      expect(SourceRefreshInterval.parse(''), SourceRefreshInterval.every24h);
      expect(SourceRefreshInterval.parse('weekly'), SourceRefreshInterval.every24h);
      expect(SourceRefreshInterval.parse(7), SourceRefreshInterval.every24h);
    });

    test('every rung has a distinct label and storage value', () {
      final labels = SourceRefreshInterval.values.map((i) => i.label).toSet();
      final values = SourceRefreshInterval.values.map((i) => i.storageValue).toSet();
      expect(labels.length, SourceRefreshInterval.values.length);
      expect(values.length, SourceRefreshInterval.values.length);
    });
  });

  group('planSourceRefresh', () {
    final now = DateTime(2026, 10, 5, 12);

    test('at-startup is always due, however recent the last run', () {
      expect(
        planSourceRefresh(
          SourceRefreshInterval.atStartup,
          now.subtract(const Duration(minutes: 1)),
          now,
        ),
        isTrue,
      );
    });

    test('never refreshed is always due', () {
      for (final interval in SourceRefreshInterval.values) {
        expect(planSourceRefresh(interval, null, now), isTrue);
      }
    });

    test('hours compare against the elapsed time', () {
      expect(
        planSourceRefresh(
          SourceRefreshInterval.every6h,
          now.subtract(const Duration(hours: 5, minutes: 59)),
          now,
        ),
        isFalse,
      );
      expect(
        planSourceRefresh(
          SourceRefreshInterval.every6h,
          now.subtract(const Duration(hours: 6)),
          now,
        ),
        isTrue,
      );
      expect(
        planSourceRefresh(
          SourceRefreshInterval.every48h,
          now.subtract(const Duration(hours: 47)),
          now,
        ),
        isFalse,
      );
      expect(
        planSourceRefresh(
          SourceRefreshInterval.every48h,
          now.subtract(const Duration(days: 2)),
          now,
        ),
        isTrue,
      );
    });
  });

  group('SourceConfig.refreshInterval', () {
    SourceConfig configWith(Object? value) => SourceConfig(
      id: 's1',
      kind: SourceKind.xtream,
      label: 'Provider',
      fields: const {'host': 'http://x', 'username': 'u', 'password': 'p'},
      settings: value == null ? const {} : {'refreshInterval': value},
    );

    test('reads the stored value, defaulting when absent', () {
      expect(configWith(null).refreshInterval, SourceRefreshInterval.every24h);
      expect(configWith('6').refreshInterval, SourceRefreshInterval.every6h);
      expect(
        configWith('startup').refreshInterval,
        SourceRefreshInterval.atStartup,
      );
    });

    test('does not change the catalog inputs, so the repo is reused', () {
      // The schedule is read at load time, never by `build`, so editing it must
      // not force a re-ingest (HomeShell swaps/reuses on this predicate).
      final a = configWith(null);
      final b = configWith('6');
      expect(a.hasSameCatalogInputs(b), isTrue);
      expect(a.sameSourceInputs(b), isTrue);
    });
  });

  group('SourceRefreshStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('reads back what it wrote, per source', () async {
      const store = SourceRefreshStore();
      final when = DateTime(2026, 10, 5, 12, 34);
      await store.setLastRefresh('s1', when);

      expect(await store.lastRefresh('s1'), when);
      expect(await store.lastRefresh('s2'), isNull);
    });

    test('forget drops one source and leaves the rest', () async {
      const store = SourceRefreshStore();
      await store.setLastRefresh('s1', DateTime(2026));
      await store.setLastRefresh('s2', DateTime(2026, 2));

      await store.forget('s1');

      expect(await store.lastRefresh('s1'), isNull);
      expect(await store.lastRefresh('s2'), DateTime(2026, 2));
    });

    test('a malformed blob reads as never refreshed', () async {
      // Fails to "never", which the planner treats as due — the safe direction:
      // a corrupt record must not disable the feature.
      const storage = FlutterSecureStorage();
      await storage.write(key: 'source_last_refresh', value: 'not json');
      const store = SourceRefreshStore();
      expect(await store.lastRefresh('s1'), isNull);
    });
  });
}
