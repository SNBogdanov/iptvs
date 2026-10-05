// The movies/series grid's column ladder.
//
// This replaced a two-branch rule (`width >= 1280 ? 6 : 4`) forked on
// `defaultTargetPlatform == android`, which had no height input and no upper
// bound: a 1279 px window drew 303 px tiles, a 3840 px one drew ~628 px
// posters with barely one row on screen, and an Android tablet showed 7
// columns where an iPad of the same width showed 6.
//
// The single ladder divides the viewport by `kMediaPosterTargetWidth`. The
// pins below are the contract: it must keep reproducing the column counts the
// Android-TV fork was originally introduced to get (960 -> 5, 1920 -> 10) and
// the desktop 1280 -> 6, while staying bounded at both ends.

import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/vod_card_orientation.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/theme.dart' show kMediaPosterTargetWidth;

void main() {
  int columnsAt(double width, {double height = 800}) =>
      MediaGridMetrics.forSize(Size(width, height)).columns;

  test('reproduces the column counts the platform fork existed to produce', () {
    // Android TV render targets. Matching these is what made deleting the
    // fork safe rather than a behaviour change for TV users.
    expect(columnsAt(960, height: 540), 5);
    expect(columnsAt(1920, height: 1080), 10);
    // Desktop's established breakpoint.
    expect(columnsAt(1280), 6);
  });

  test('scales continuously instead of stepping between two extremes', () {
    // The old rule gave 4 columns for everything below 1280 and 6 above it,
    // so 1279 and 1280 differed by 50% in tile width.
    expect(columnsAt(1279), 6);
    expect(columnsAt(1280), 6);
    expect(columnsAt(1600), 8);
    expect(columnsAt(2560), 13);
  });

  test('stays bounded at both ends', () {
    // A 4K TV used to show six ~628 px posters at barely one row.
    expect(columnsAt(3840, height: 2160), 16);
    expect(columnsAt(600), 3);
    // The clamp floor holds even for an absurdly narrow viewport.
    expect(columnsAt(120), 3);
  });

  test('tiles stay in a narrow width band across the whole ladder', () {
    // The point of the ladder: a poster is roughly the same physical size on
    // a small window and on a 4K panel.
    for (final width in const [600.0, 960.0, 1280.0, 1920.0, 2560.0, 3840.0]) {
      final metrics = MediaGridMetrics.forSize(Size(width, 900));
      final tile = metrics.tileWidth(width);
      expect(
        tile,
        inInclusiveRange(150, 260),
        reason: '$width px viewport produced a ${tile.round()} px tile',
      );
    }
  });

  test('density affects gutters only, never the column count', () {
    // All that survives of the old `compact` fork, and it is keyed off
    // viewport size rather than the platform.
    final dense = MediaGridMetrics.forSize(const Size(960, 540));
    final roomy = MediaGridMetrics.forSize(const Size(1920, 1080));
    expect(dense.spacing, lessThan(roomy.spacing));
    expect(dense.padding.left, lessThan(roomy.padding.left));
  });

  test('the poster target width is the ladder divisor', () {
    // Guards against the constant drifting away from the arithmetic.
    expect(columnsAt(kMediaPosterTargetWidth * 7), 7);
  });

  test('a reserved text budget keeps the poster at a fixed 2:3', () {
    final metrics = MediaGridMetrics.forSize(const Size(1280, 800));
    final tile = metrics.tileWidth(1280);
    final ratio = metrics.childAspectRatio(tileWidth: tile, textBudget: 60);
    // A taller text budget must produce a taller cell (smaller ratio), never
    // eat into the poster — that is what made neighbouring tiles crop the
    // same poster differently.
    final tallerText = metrics.childAspectRatio(
      tileWidth: tile,
      textBudget: 90,
    );
    expect(tallerText, lessThan(ratio));
  });

  group('card shape', () {
    // The user's global VOD/series card-shape preference. One number in the
    // grid, but two things had to be decided deliberately rather than falling
    // out of the change, so both are pinned here.
    test('portrait is the default, not merely a fallback', () {
      // Every metric below was pinned against 2:3, so a default that quietly
      // meant landscape would change the grid on every untouched install.
      final metrics = MediaGridMetrics.forSize(const Size(1280, 800));
      expect(metrics.posterAspectRatio, closeTo(2 / 3, 1e-9));
      expect(
        MediaGridMetrics.forSize(
          const Size(1280, 800),
          orientation: VodCardOrientation.portrait,
        ).posterAspectRatio,
        metrics.posterAspectRatio,
      );
    });

    test('landscape cards are shorter, never wider than portrait', () {
      final portrait = MediaGridMetrics.forSize(
        const Size(1280, 800),
        orientation: VodCardOrientation.portrait,
      );
      final landscape = MediaGridMetrics.forSize(
        const Size(1280, 800),
        orientation: VodCardOrientation.landscape,
      );
      expect(landscape.posterAspectRatio, closeTo(16 / 9, 1e-9));
      final tile = portrait.tileWidth(1280);
      expect(
        landscape.childAspectRatio(tileWidth: tile, textBudget: 60),
        greaterThan(portrait.childAspectRatio(tileWidth: tile, textBudget: 60)),
      );
    });

    test('the column ladder is identical in both shapes', () {
      // Density is a width decision; the setting changes the card's height, not
      // how many fit across. If this ever moved, choosing landscape would also
      // silently change tile *width*, which would re-decode every poster in the
      // catalogue (memCacheWidth is part of the cache key) for no stated reason.
      for (final width in const [600.0, 960.0, 1280.0, 1920.0, 3840.0]) {
        expect(
          MediaGridMetrics.forSize(
            Size(width, 900),
            orientation: VodCardOrientation.landscape,
          ).columns,
          MediaGridMetrics.forSize(Size(width, 900)).columns,
          reason: '$width px viewport',
        );
      }
    });

    test('landscape stays inside the clamp across the whole ladder', () {
      // A 16:9 band is short enough that a large text scale could otherwise
      // push the computed ratio past the guard, and the clamp would silently
      // squash the poster instead of growing the cell.
      for (final width in const [600.0, 960.0, 1280.0, 1920.0, 3840.0]) {
        final metrics = MediaGridMetrics.forSize(
          Size(width, 900),
          orientation: VodCardOrientation.landscape,
        );
        for (final textBudget in const [40.0, 60.0, 90.0, 140.0]) {
          final ratio = metrics.childAspectRatio(
            tileWidth: metrics.tileWidth(width),
            textBudget: textBudget,
          );
          expect(ratio, inInclusiveRange(0.2, 2.0));
          expect(
            ratio,
            lessThan(2.0),
            reason: '$width px / $textBudget px text hit the clamp',
          );
        }
      }
    });

    test('a taller text budget never eats the poster in either shape', () {
      for (final orientation in VodCardOrientation.values) {
        final metrics = MediaGridMetrics.forSize(
          const Size(1280, 800),
          orientation: orientation,
        );
        final tile = metrics.tileWidth(1280);
        expect(
          metrics.childAspectRatio(tileWidth: tile, textBudget: 120),
          lessThan(metrics.childAspectRatio(tileWidth: tile, textBudget: 40)),
          reason: '$orientation',
        );
      }
    });
  });
}
