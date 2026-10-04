import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_dwell.dart';
import 'package:iptvs/sources/source_config.dart';

SourceConfig _config({Map<String, dynamic>? settings}) => SourceConfig(
  id: 'src1',
  kind: SourceKind.m3u,
  label: 'One',
  fields: const {'playlistUrl': 'http://example.test/list.m3u'},
  settings: settings ?? const {},
);

void main() {
  group('channelDwellFromSeconds', () {
    test('parses every rung of the ladder', () {
      for (final dwell in ChannelDwell.values) {
        expect(channelDwellFromSeconds(dwell.seconds), dwell);
      }
    });

    test('a value transported as a string still parses', () {
      // `settings` rides the source row into the cloud as JSON, and a panel or
      // an older build can hand a number back as a string.
      expect(channelDwellFromSeconds('30'), ChannelDwell.seconds30);
    });

    test('absent is the default', () {
      expect(channelDwellFromSeconds(null), kDefaultChannelDwell);
    });

    test('anything off the ladder is the default, not a clamp', () {
      // Deliberately the default rather than the nearest rung: a mangled
      // preference should land on the documented behaviour, and a rung the user
      // never picked is a lie about what they chose.
      expect(channelDwellFromSeconds(0), kDefaultChannelDwell);
      expect(channelDwellFromSeconds(1), kDefaultChannelDwell);
      expect(channelDwellFromSeconds(600), kDefaultChannelDwell);
      expect(channelDwellFromSeconds(-15), kDefaultChannelDwell);
      expect(channelDwellFromSeconds('soon'), kDefaultChannelDwell);
    });
  });

  group('nextChannelDwell', () {
    test('cycles the whole ladder and wraps', () {
      var dwell = ChannelDwell.values.first;
      for (var i = 0; i < ChannelDwell.values.length; i++) {
        dwell = nextChannelDwell(dwell);
      }
      expect(dwell, ChannelDwell.values.first);
    });

    test('a cycle returns to where it started', () {
      for (final start in ChannelDwell.values) {
        expect(nextChannelDwell(start) == start, isFalse);
      }
    });
  });

  group('the ladder', () {
    test('the floor clears the zap settle delay', () {
      // A zap's stop → resolve → play is one `create_link` on a
      // single-connection portal. A dwell at or under the 600 ms settle asks for
      // a second link before the first is handed back, so the shortest rung has
      // to be above it with room for the provider round trip.
      const settle = Duration(milliseconds: 600);
      for (final dwell in ChannelDwell.values) {
        expect(
          dwell.duration,
          greaterThan(settle),
          reason: '${dwell.seconds}s is too short to settle a zap first',
        );
      }
    });

    test('the default is a rung, and is 10 s', () {
      expect(
        ChannelDwell.values.contains(kDefaultChannelDwell),
        isTrue,
      );
      expect(kDefaultChannelDwellSeconds, kDefaultChannelDwell.seconds);
    });

    test('the ladder is strictly increasing', () {
      for (var i = 1; i < ChannelDwell.values.length; i++) {
        expect(
          ChannelDwell.values[i].seconds,
          greaterThan(ChannelDwell.values[i - 1].seconds),
        );
      }
    });
  });

  group('labels', () {
    test('every rung has a hint and a value label', () {
      for (final dwell in ChannelDwell.values) {
        expect(channelDwellLabel(dwell), isNotEmpty);
        expect(channelDwellLabel(dwell), contains('${dwell.seconds}'));
        expect(channelDwellHint(dwell), isNotEmpty);
      }
    });
  });

  group('SourceConfig.channelDwellSeconds', () {
    test('absent reads as null so the caller can apply the default', () {
      // Null rather than the default number: the *setting* is what was stored,
      // and collapsing "unset" into a value here would make the settings screen
      // write a default it was never given.
      expect(_config().channelDwellSeconds, isNull);
    });

    test('reads an int and a transported string', () {
      expect(_config(settings: {'channelDwellSeconds': 5}).channelDwellSeconds, 5);
      expect(
        _config(settings: {'channelDwellSeconds': '20'}).channelDwellSeconds,
        20,
      );
    });

    test('an untouched source carries no key at all', () {
      // The load-bearing property for cloud churn: absent means default, so a
      // source nobody touched keeps serializing byte-for-byte as it did before
      // this setting existed — no migration, no `updated_at` bump on every pull.
      expect(_config().settings.containsKey('channelDwellSeconds'), isFalse);
    });

    test('the parse composes with the accessor', () {
      final config = _config(settings: {'channelDwellSeconds': 60});
      expect(
        channelDwellFromSeconds(config.channelDwellSeconds),
        ChannelDwell.seconds60,
      );
    });
  });

  group('SourceConfig.enrichMetadata', () {
    test('on unless explicitly off, and only false is ever stored', () {
      // Same shape as autoResumeLastChannel: absent means on, so a source nobody
      // touched serializes byte-for-byte as it did before the setting existed —
      // no cloud churn, no migration.
      expect(_config().enrichMetadata, isTrue);
      expect(_config(settings: {'enrichMetadata': false}).enrichMetadata, isFalse);
    });

    test('a stray value reads as on, never silently off', () {
      // The failure mode of a mangled preference is the default behaviour, not a
      // silent loss of enrichment.
      expect(_config(settings: {'enrichMetadata': 'no'}).enrichMetadata, isTrue);
    });

    test('an untouched source carries no key at all', () {
      expect(_config().settings.containsKey('enrichMetadata'), isFalse);
    });
  });
}
