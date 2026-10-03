// End-to-end cover for the wiring between the XMLTV parser and
// `XmltvChannelResolver`: real guide bytes in, mapped programmes out.
//
// `epg_matching_test.dart` pins the claim rules against the resolver directly.
// This file pins the half that unit test cannot see — that the parser actually
// *feeds* it, i.e. that `<channel>` declarations are selected (they used to be
// discarded), reach `declareChannel` with their `<display-name>`s, and do so
// before the first `<programme>` freezes the claims. That wiring is easy to
// break without any resolver test noticing.
//
// Both size paths are exercised deliberately: below the isolate threshold the
// parse runs inline, above it the whole thing — bytes and both index maps —
// crosses an isolate boundary and the resolver is rebuilt on the far side.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/epg_matching.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xmltv.dart';

Uint8List _xmltv(String body) =>
    Uint8List.fromList(utf8.encode('<?xml version="1.0"?><tv>$body</tv>'));

String _channel(String id, List<String> names) =>
    '<channel id="$id">'
    '${names.map((n) => '<display-name>$n</display-name>').join()}'
    '</channel>';

String _programme(String channel, {String title = 'Show', int hour = 12}) =>
    '<programme channel="$channel" start="202401011${hour ~/ 10}'
    '${hour % 10}0000 +0000" '
    'stop="20240101235900 +0000"><title>$title</title></programme>';

Channel _ch(String id, String name, {String? tvgId}) => Channel(
  id: id,
  name: name,
  extra: tvgId == null ? const {} : {'tvgId': tvgId},
);

/// Parses [body] against [channels] with name matching on.
Future<List<Programme>> _parse(String body, List<Channel> channels) =>
    parseXmltv(
      _xmltv(body),
      buildTvgIdIndex(channels),
      nameToChannelIds: buildChannelNameIndex(channels),
    );

void main() {
  group('parseXmltv with name matching', () {
    test('a guide whose ids miss still matches on display names', () async {
      // The motivating case: the playlist's tvg-ids are provider-specific
      // junk, so nothing lines up by id.
      final channels = [
        _ch('c1', 'RO: Pro TV HD', tvgId: 'provider-8821'),
        _ch('c2', 'Digi Sport 1', tvgId: 'provider-9110'),
      ];
      final progs = await _parse(
        _channel('ProTV.ro', ['Pro TV']) +
            _channel('DigiSport1.ro', ['Digi Sport 1']) +
            _programme('ProTV.ro', title: 'Stirile') +
            _programme('DigiSport1.ro', title: 'Fotbal'),
        channels,
      );
      expect(progs.map((p) => '${p.channelId}:${p.title}'), [
        'c1:Stirile',
        'c2:Fotbal',
      ]);
    });

    test('an exact tvg-id still wins over a name declared earlier', () async {
      final channels = [_ch('c1', 'Pro TV', tvgId: 'protv.ro')];
      final progs = await _parse(
        _channel('decoy', ['Pro TV']) +
            _channel('protv.ro', ['Pro TV Romania']) +
            _programme('decoy', title: 'Wrong') +
            _programme('protv.ro', title: 'Right'),
        channels,
      );
      expect(progs.map((p) => p.title), ['Right']);
      expect(progs.single.channelId, 'c1');
    });

    test('one guide channel fans out to every HD/SD variant', () async {
      final channels = [
        _ch('hd', 'Digi Sport 1 HD'),
        _ch('sd', 'Digi Sport 1 SD'),
      ];
      final progs = await _parse(
        _channel('ds1', ['Digi Sport 1']) + _programme('ds1', title: 'Fotbal'),
        channels,
      );
      expect(progs.map((p) => p.channelId), ['hd', 'sd']);
      expect(progs.every((p) => p.title == 'Fotbal'), isTrue);
    });

    test('a non-Latin guide reaches every feed of the channel', () async {
      // A Russian portal, as reported: two streams of one channel, both named
      // for their quality, and one guide entry declaring *both* names under one
      // id. Non-Latin names used to normalise to the empty key, so nothing
      // matched at all and the rows that still showed a programme were getting
      // it from the provider's own feed, not from this guide.
      final channels = [
        _ch('uhd', 'Первый канал UHD'),
        _ch('fhd', 'Первый канал FHD'),
      ];
      final progs = await _parse(
        _channel('146', ['Первый канал UHD', 'Первый канал FHD']) +
            _programme('146', title: 'Новости'),
        channels,
      );
      expect(progs.map((p) => p.channelId), containsAll(['uhd', 'fhd']));
      expect(progs.every((p) => p.title == 'Новости'), isTrue);
    });

    test('a contested name yields nothing for either guide channel', () async {
      final channels = [_ch('c1', 'Sport 1')];
      final progs = await _parse(
        _channel('sport1.de', ['Sport 1']) +
            _channel('sport1.pl', ['Sport 1']) +
            _programme('sport1.de') +
            _programme('sport1.pl'),
        channels,
      );
      expect(progs, isEmpty);
    });

    test(
      'a guide with no <channel> elements behaves exactly as before',
      () async {
        final channels = [_ch('c1', 'Pro TV', tvgId: 'protv.ro')];
        final progs = await _parse(
          _programme('protv.ro', title: 'Stirile') + _programme('other.ro'),
          channels,
        );
        expect(progs.map((p) => p.channelId), ['c1']);
      },
    );

    test('declarations survive the isolate boundary on a large guide', () async {
      // Above _isolateXmltvThreshold the bytes and BOTH index maps are sent to
      // a worker and the resolver is rebuilt there — a path the inline tests
      // never touch.
      final channels = [_ch('c1', 'Pro TV', tvgId: 'provider-1')];
      final body = StringBuffer(_channel('ProTV.ro', ['Pro TV']));
      for (var i = 0; i < 1500; i++) {
        body.write(_programme('ProTV.ro', title: 'Episode $i'));
      }
      final bytes = _xmltv(body.toString());
      expect(bytes.length, greaterThan(64 * 1024));

      final progs = await parseXmltv(
        bytes,
        buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      );
      expect(progs, hasLength(1500));
      expect(progs.every((p) => p.channelId == 'c1'), isTrue);
    });
  });

  group('parseXmltvBatched with name matching', () {
    test('batches carry name-matched programmes, inline path', () async {
      final channels = [_ch('c1', 'Pro TV')];
      final batches = <List<Programme>>[];
      await for (final b in parseXmltvBatched(
        _xmltv(_channel('ProTV.ro', ['Pro TV']) + _programme('ProTV.ro')),
        buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
      )) {
        batches.add(b);
      }
      expect(batches.expand((b) => b).map((p) => p.channelId), ['c1']);
    });

    test('batches carry name-matched programmes across the isolate', () async {
      final channels = [_ch('c1', 'Pro TV')];
      final body = StringBuffer(_channel('ProTV.ro', ['Pro TV']));
      for (var i = 0; i < 1500; i++) {
        body.write(_programme('ProTV.ro', title: 'Episode $i'));
      }
      final bytes = _xmltv(body.toString());
      expect(bytes.length, greaterThan(64 * 1024));

      var total = 0;
      await for (final b in parseXmltvBatched(
        bytes,
        buildTvgIdIndex(channels),
        nameToChannelIds: buildChannelNameIndex(channels),
        batchSize: 400,
      )) {
        expect(b.every((p) => p.channelId == 'c1'), isTrue);
        total += b.length;
      }
      expect(total, 1500);
    });
  });

  group('XtreamCodes: the panel guide plus a user-specified link', () {
    // The report as it actually came in: an Xtream Codes panel whose live
    // entries carry the panel's `epg_channel_id` as their tvg-id, and the guide
    // fetched from a link the user typed into the source's EPG settings. One
    // feed of a channel has the id, the other has none — so the id-less feed can
    // only be matched by name, and only through the user-specified link, because
    // the panel's own `xmltv.php` is deliberately id-only.
    // The report as it came in, with the panel payload the user supplied: an
    // Xtream Codes panel where **both** feeds of one channel carry the same
    // `epg_channel_id` (146), and the guide — fetched from a link typed into the
    // source's EPG settings — has a single entry for it, declaring both names.
    //
    // `tvgIdToChannelId` used to be `tvg-id → one channel`, so the two feeds
    // collided and the last one in catalogue order took everything: one of the
    // pair had a schedule and the other was permanently bare — on the panel's own
    // guide as much as on the specified link, since that path is id-only.
    List<Channel> panelChannels() => [
      _ch('1', 'Первый канал UHD', tvgId: '146'),
      _ch('2', 'Первый канал FHD', tvgId: '146'),
    ];

    EpgGuideFeed feedFor(
      String url,
      String body,
      List<Channel> channels, {
      required bool withNames,
    }) => xmltvGuideFeed(
      url: url,
      download: (_, file) => file.writeAsBytes(_xmltv(body)),
      tvgIdToChannelId: buildTvgIdIndex(channels),
      nameToChannelIds: withNames
          ? epgNameIndexFor(channels, extraCount: 1)
          : const {},
    );

    Future<List<Programme>> merge(List<EpgGuideFeed> feeds) async {
      final out = <Programme>[];
      await for (final batch in mergeEpgGuides(feeds)) {
        out.addAll(batch);
      }
      return out;
    }

    test("the panel's own guide lights both feeds of the channel", () async {
      // No names on this path at all: `epgNameIndexFor` leaves a provider's own
      // guide id-only by design, so the shared id is the only thing that can
      // reach the second feed — and it has to reach it.
      final channels = panelChannels();
      final panel = feedFor(
        'http://panel/xmltv.php',
        _channel('146', ['Первый канал UHD', 'Первый канал FHD']) +
            _programme('146', title: 'Новости'),
        channels,
        withNames: false,
      );
      final progs = await merge([panel]);
      expect(progs.map((p) => p.channelId), containsAll(['1', '2']));
      expect(progs.every((p) => p.title == 'Новости'), isTrue);
    });

    test('the specified link lights both feeds too', () async {
      final channels = panelChannels();
      final link = feedFor(
        'http://links/guide.xml',
        _channel('146', ['Первый канал UHD', 'Первый канал FHD']) +
            _programme('146', title: 'Новости'),
        channels,
        withNames: true,
      );
      final progs = await merge([link]);
      expect(progs.map((p) => p.channelId), containsAll(['1', '2']));
    });

    test('the panel guide never claims a channel on its name alone', () async {
      // The counterpart: feed 0 is id-only, so a guide entry whose ids miss
      // contributes nothing however well its display names line up.
      final channels = panelChannels();
      final panel = feedFor(
        'http://panel/xmltv.php',
        _channel('p146', ['Первый канал UHD', 'Первый канал FHD']) +
            _programme('p146', title: 'Панельный'),
        channels,
        withNames: false,
      );
      expect(await merge([panel]), isEmpty);
    });
  });
}
