import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/media_duration.dart';
import '../data/net.dart' show cleanImageUrl;
import '../data/source_hint_parser.dart';
import '../data/vod_card_orientation.dart';
import '../sources/release_date.dart' show formatReleaseDate;
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/favorite_controls.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';
import '../widgets/routed_focus_node.dart';
import '../widgets/source_error_view.dart';
import '../data/app_database.dart' show PlaybackPosition;
import 'media_tab_controller.dart' show ContinueWatchingEntry;

/// `1:23:45` / `12:34` style label for a resume position.
String _positionLabel(Duration position) {
  final hours = position.inHours;
  final minutes = position.inMinutes % 60;
  final seconds = position.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// Grid density for poster catalogues.
///
/// One continuous ladder for every platform: the column count is the viewport
/// width divided by [kMediaPosterTargetWidth], so a tile stays in a ~176–230 px
/// band from a 600 px window to a 4K TV. It replaced a two-branch rule
/// (`width >= 1280 ? 6 : 4`, forked on `defaultTargetPlatform == android`) with
/// no height input and no upper bound, under which a 1279 px window drew 303 px
/// tiles, a 3840 px one drew ~628 px posters with 1.2 rows on screen, and an
/// Android tablet showed 7 columns where an iPad of the same width showed 6 for
/// no user-visible reason. The ladder reproduces the Android TV column counts
/// the platform fork was introduced for (960 → 5, 1920 → 10) and the desktop
/// 1280 → 6 exactly, so the fork bought nothing but the divergence; only its
/// tighter gutters survive, keyed off viewport size rather than the platform.
@immutable
class MediaGridMetrics {
  /// [_MediaGridTile]'s own inner padding, each side.
  static const double tilePadding = 10;

  /// Border width [FocusableCard] reserves on each side.
  ///
  /// Taken from the widget itself rather than restated, because the number has
  /// to match exactly: it used to be 1 here while a focused card drew 2, on the
  /// reasoning that "the `Expanded` poster absorbs it" — true while the poster
  /// was flexible, false the moment it became a fixed [posterAspectRatio], and
  /// the focused tile overflowed by ~1.6 px. The card now reserves
  /// [kFocusableCardBorderWidth] in *every* state (the ring moved to a
  /// `foregroundDecoration`, so focus no longer resizes the poster and no
  /// longer re-decodes it), which is what makes one shared constant correct.
  static const double tileBorder = kFocusableCardBorderWidth;

  /// Gap between a tile's poster and its text block.
  static const double posterTextGap = 8;

  /// Posters are 2:3 by default — the shape TMDB and every provider panel ships,
  /// so a tile at this ratio crops nothing. [orientation] is the user's global
  /// card-shape preference (docs/player.md "VOD/series card shape"), and the
  /// only thing it changes here: everything else in this class is width-driven
  /// and identical in both shapes.
  final double posterAspectRatio;

  final int columns;
  final double spacing;
  final EdgeInsets padding;

  const MediaGridMetrics._({
    required this.posterAspectRatio,
    required this.columns,
    required this.spacing,
    required this.padding,
  });

  /// [viewport] is the **window** ([MediaQuery.sizeOf]), never a
  /// `LayoutBuilder`'s post-`SafeArea` constraints — see theme.dart's
  /// breakpoint note and docs/tv-navigation.md.
  ///
  /// [orientation] defaults to portrait, which is not a convenience but the
  /// contract: the column ladder and every existing metric below are pinned
  /// against the 2:3 shape, so a silent flip here would change the grid on every
  /// untouched install.
  factory MediaGridMetrics.forSize(
    Size viewport, {
    VodCardOrientation orientation = VodCardOrientation.portrait,
  }) {
    final columns = (viewport.width / kMediaPosterTargetWidth).round().clamp(
      3,
      16,
    );
    // A dense viewport (TV render targets at 960x540, phones, small windows)
    // gets tighter gutters so the extra pixels go to the artwork. This is the
    // only thing left of the old `compact` platform fork.
    final dense = viewport.shortestSide < 1000;
    return MediaGridMetrics._(
      posterAspectRatio: orientation.aspectRatio,
      columns: columns,
      spacing: dense ? 8 : 12,
      padding: dense
          ? const EdgeInsets.fromLTRB(10, 4, 10, 12)
          : const EdgeInsets.fromLTRB(16, 6, 16, 20),
    );
  }

  double get crossAxisSpacing => spacing;

  /// [FocusableCard] pads itself vertically, so a naive
  /// `mainAxisSpacing == spacing` produced a `spacing + 8` vertical gutter
  /// against a `spacing` horizontal one — visibly lopsided. Subtract it back
  /// out so both gutters measure [spacing].
  double get mainAxisSpacing =>
      math.max(0.0, spacing - kFocusableCardVerticalPadding * 2);

  /// Width of one tile when the grid is laid out in [availableWidth] — the
  /// same arithmetic `SliverGridDelegateWithFixedCrossAxisCount` does, needed
  /// here because [childAspectRatio] depends on the absolute tile width.
  double tileWidth(double availableWidth) =>
      (availableWidth - padding.horizontal - crossAxisSpacing * (columns - 1)) /
      columns;

  /// Cell aspect that leaves the poster exactly [posterAspectRatio] once
  /// [textBudget] logical pixels are reserved for the title/year/hint block.
  ///
  /// The tile used to be `Expanded(poster)` over a text block that varied by
  /// up to ~58 px (1 vs 2 title lines, optional year, optional source hints),
  /// so `Expanded` handed every poster a different remainder and the box
  /// aspect ranged 0.70–0.92. With `memCacheWidth`-only decoding restoring real
  /// `BoxFit.cover` cropping, that showed up as neighbouring tiles cropping the
  /// *same* poster differently. Reserving the budget (rather than letting it
  /// float) also keeps a large accessibility text scale from eating the poster:
  /// the tile grows taller instead.
  double childAspectRatio({
    required double tileWidth,
    required double textBudget,
  }) {
    final posterWidth = tileWidth - (tilePadding + tileBorder) * 2;
    if (posterWidth <= 0) return 0.64;
    final tileHeight =
        posterWidth / posterAspectRatio +
        posterTextGap +
        textBudget +
        (tilePadding + tileBorder) * 2 +
        kFocusableCardVerticalPadding * 2;
    return (tileWidth / tileHeight).clamp(0.2, 2.0);
  }
}

/// Vertical space a grid tile reserves under its poster: two title lines, a
/// year line, and one row of source-hint chips, at the current text scale.
///
/// Deliberately reserves the *maximum* a tile can render rather than measuring
/// each item: the reservation has to be identical for every cell (the grid has
/// one `childAspectRatio`), and probing `sourceHintLabels` across the visible
/// list to find out whether any tile needs the chip row would re-run its regex
/// pass on every build. Text scaling is intentionally not overridden anywhere
/// in this app, so the budget is derived from `MediaQuery.textScalerOf`.
double mediaTileTextBudget(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final titleStyle = Theme.of(context).textTheme.titleSmall;
  // 1.35 stands in for an unset `TextStyle.height` (the font's own metrics);
  // erring high only leaves slack at the bottom of the fixed text box, while
  // erring low would clip.
  final titleLine =
      scaler.scale(titleStyle?.fontSize ?? 14) * (titleStyle?.height ?? 1.35);
  final yearLine = scaler.scale(12) * 1.35;
  final hintRow =
      scaler.scale(10) * 1.35 +
      4 + // chip vertical padding
      2 + // chip border
      5; // gap above the chip row
  return titleLine * 2 + yearLine + hintRow;
}

/// The movies/series browsing body: the grid/list of [MediaItem]s with paging,
/// error/empty states, and D-pad focus. Extracted from `ChannelListScreen`'s
/// State as a widget with an explicit input contract so it rebuilds
/// independently of the rest of the (large) screen and so the media state can
/// later move behind a controller without touching this view. Live TV keeps its
/// own body; this handles [ContentKind.movie]/[ContentKind.series] only.
class MediaTabView extends StatelessWidget {
  final ContentKind kind;

  /// Filtered items to show (favorites/hidden/search already applied by the
  /// parent), and the underlying snapshot (drives "load more" / paging).
  final List<MediaItem> visible;
  final MediaLibrarySnapshot? snapshot;

  final bool loading;
  final bool loadingMore;
  final String? error;

  /// True when a live search query (>= 2 chars) is active — hides "load more"
  /// since search returns a flat, non-paged result set.
  final bool showingSearch;

  /// True when a category filter is active. Combined with [showingSearch] to
  /// pick the empty-state wording below: a genuinely unfiltered-empty source
  /// ("this provider returned nothing") reads very differently from a
  /// filtered-empty one ("nothing matches"). Defaults to false — category
  /// filtering lives in `ChannelListScreen`, which this view does not own;
  /// wire this through from the caller alongside the category selector.
  final bool categoryFilterActive;

  /// Id of the last-played item in this kind, autofocused on return when still
  /// visible (else the first item is).
  final String? lastPlayedId;

  final ScrollController scrollController;
  final FocusNode? firstFocusNode;

  /// Focus node for the "Next page" control, owned by the screen: after a press
  /// the card moves to a new index, so a node that lived on the widget would not
  /// survive the rebuild — the screen moves focus to this one, then scrolls it
  /// into view.
  final FocusNode? loadMoreFocusNode;

  /// How many *screens* of items are revealed. The catalogue is loaded whole
  /// (see `MediaTabController.load`'s `loadAll`, which global release-date
  /// sorting requires), so paging is purely a display window: this counts
  /// screenfuls, and the screenful size is computed from what actually fits the
  /// viewport (columns × visible rows for the grid, visible rows for the list)
  /// rather than a fixed item count. Defaults to one screen — an untouched call
  /// site (tests included) shows the first screenful.
  final int displayPages;

  /// A floor on the revealed item count (see
  /// `MediaTabController.shownCountFloor`): the window never shrinks below it
  /// within a dataset, so resizing the window smaller cannot unmount an
  /// already-shown card and steal the focus.
  final int minShown;

  /// Reports the revealed count after each build, so the owner raises its floor.
  final ValueChanged<int>? onShown;

  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onOpenMedia;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  /// Watched fraction per in-progress item id, published by
  /// [MediaTabController.resumeProgress]; empty means nothing is in progress.
  /// Reaches both the grid's poster cards and the narrow-layout list rows, so a
  /// phone in landscape reports the same progress the grid does.
  final Map<String, double> resumeProgress;

  /// In-progress items (saved playback positions) shown as a horizontal
  /// "Continue watching" rail above the grid; [onResume] plays one, resuming.
  /// [onRemoveContinueWatching] drops one entry (clears its saved position).
  final List<ContinueWatchingEntry> continueWatching;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemoveContinueWatching;

  /// Puts back an entry [onRemoveContinueWatching] just dropped — the Undo
  /// action of the confirmation snackbar. **Optional on purpose:** when it is
  /// null the snackbar still reports the removal, just without an Undo, so the
  /// view stays usable before the callback is wired up by the owning screen
  /// (`MediaTabController.restoreContinueWatching`).
  final ValueChanged<ContinueWatchingEntry>? onRestoreContinueWatching;

  const MediaTabView({
    super.key,
    required this.kind,
    required this.visible,
    required this.snapshot,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.showingSearch,
    this.categoryFilterActive = false,
    required this.lastPlayedId,
    required this.scrollController,
    required this.firstFocusNode,
    this.loadMoreFocusNode,
    this.displayPages = 1,
    this.minShown = 0,
    this.onShown,
    required this.isFavorite,
    required this.onOpenMedia,
    required this.onLoadMore,
    required this.onRetry,
    this.resumeProgress = const {},
    this.continueWatching = const [],
    required this.onResume,
    required this.onRemoveContinueWatching,
    this.onRestoreContinueWatching,
  });

  /// Removes an entry and offers an Undo. The removal itself is destructive
  /// (it deletes the saved resume position), the control sits directly under a
  /// tile whose tap starts playback, and the entry object is already in hand —
  /// so re-writing the position costs nothing and the confirmation is worth
  /// the snackbar.
  void _removeContinueWatching(
    BuildContext context,
    ContinueWatchingEntry entry,
  ) {
    onRemoveContinueWatching(entry);
    final restore = onRestoreContinueWatching;
    const visible = Duration(seconds: 6);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final shown = messenger.showSnackBar(
      SnackBar(
        content: Text('Removed “${entry.item.title}” from Continue watching'),
        duration: visible,
        action: restore == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: () => restore(entry)),
      ),
    );
    // **Close it ourselves rather than trusting `duration`.**
    // `ScaffoldMessengerState` only arms the auto-dismiss timer inside its
    // own `build`, and only while `ModalRoute.of(context)!.isCurrent` — so a
    // snackbar shown just before a route push (tap Remove, then open a
    // channel) can miss its one chance to schedule and then never leave. It
    // was seen sitting over fullscreen live TV for minutes, still offering to
    // undo something no longer on screen. `close()` is idempotent: if the
    // framework's timer did fire, this is a no-op on an already-gone bar.
    Timer(visible + const Duration(milliseconds: 250), shown.close);
  }

  /// How many items one screenful of this layout holds: the grid's column count
  /// times the rows that fit the body's height, or the list's rows that fit.
  /// Always at least one, so a body shorter than a single cell still reveals one
  /// item per page rather than nothing.
  ///
  /// The grid metrics mirror the grid path below verbatim (ladder from the
  /// window, tile width from the body) — the two must agree or the page would
  /// not match what is drawn.
  ///
  /// A row counts only when **at least half of it is visible** — a sliver of the
  /// next row peeking in is not "fitting", and counting it would put the next
  /// screen's first row half off-screen. So the last counted row's leading edge
  /// must sit no lower than half a row above the fold.
  ///
  /// [availableHeight] is the grid area's height for this call: the whole body
  /// for a normal page, or the body minus the Continue-watching rail for the
  /// first page (the rail is a leading sliver and eats into the first screen).
  /// Only the grid's **top** padding is subtracted — the trailing bottom padding
  /// is scroll-away space, not something that costs the first screen a row.
  int _screenCells(
    BoxConstraints constraints,
    double availableHeight, {
    required bool useGrid,
    required Size windowSize,
    required double textBudget,
  }) {
    final box = availableHeight < 0 ? 0.0 : availableHeight;
    if (!useGrid) {
      // A list row is the 58x84 thumbnail plus its 12px padding on each side
      // (see `_MediaListTile`) and there is no separator between rows.
      const rowExtent = 84.0 + 24.0;
      final rows = ((box - rowExtent / 2) / rowExtent).floor() + 1;
      final cells = rows < 1 ? 1 : rows;
      DiagnosticsLog.instance.add(
        'paging',
        'list available=${box.toStringAsFixed(1)} rowExtent=$rowExtent rows=$rows '
        'cells=$cells',
      );
      return cells;
    }
    final grid = MediaGridMetrics.forSize(windowSize);
    final tileWidth = grid.tileWidth(constraints.maxWidth);
    final aspect = grid.childAspectRatio(
      tileWidth: tileWidth,
      textBudget: textBudget,
    );
    if (aspect <= 0 || tileWidth <= 0) {
      DiagnosticsLog.instance.add(
        'paging',
        'grid degenerate available=${box.toStringAsFixed(1)} '
        'tileWidth=${tileWidth.toStringAsFixed(1)} aspect=${aspect.toStringAsFixed(3)}',
      );
      return 1;
    }
    final cellHeight = tileWidth / aspect;
    final usable = box - grid.padding.top;
    final rows =
        ((usable - cellHeight / 2) / (cellHeight + grid.mainAxisSpacing))
                .floor() +
            1;
    final perScreen = grid.columns * (rows < 1 ? 1 : rows);
    final cells = perScreen < 1 ? 1 : perScreen;
    DiagnosticsLog.instance.add(
      'paging',
      'grid available=${box.toStringAsFixed(1)} '
      'bodyW=${constraints.maxWidth.toStringAsFixed(1)} cols=${grid.columns} '
      'tileW=${tileWidth.toStringAsFixed(1)} aspect=${aspect.toStringAsFixed(3)} '
      'cellH=${cellHeight.toStringAsFixed(1)} gap=${grid.mainAxisSpacing} '
      'padTop=${grid.padding.top} usable=${usable.toStringAsFixed(1)} '
      'rows=$rows cells=$cells',
    );
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    // The rail rides in the *same* scroll view as the grid/list below (as a
    // leading sliver) rather than sitting above it in a fixed-height Column.
    // A fixed height there could exceed the whole available viewport on a
    // short screen (phone landscape, mainly) — Column+Expanded overflows in
    // that case, which broke the rail's own horizontal drag along with it.
    // As a sliver it just contributes to the (already scrollable) content
    // and never forces an overflow.
    final showRail = !showingSearch && continueWatching.isNotEmpty;
    // Built on demand rather than once above: whether the rail may claim the
    // initial focus depends on the grid's own autofocus decision, which is only
    // known inside the LayoutBuilder below.
    Widget? railSliverFor({required bool autofocusFirst}) => showRail
        ? SliverToBoxAdapter(
            child: _MeasureSize(
              onChange: (size) => DiagnosticsLog.instance.add(
                'paging',
                'rail actual=${size.height.toStringAsFixed(1)} '
                'estimated=${_ContinueWatchingRail.height(context).toStringAsFixed(1)}',
              ),
              child: _ContinueWatchingRail(
                entries: continueWatching,
                autofocusFirst: autofocusFirst,
                onResume: onResume,
                onRemove: (entry) => _removeContinueWatching(context, entry),
              ),
            ),
          )
        : null;

    if (loading || error != null || visible.isEmpty) {
      final status = _statusBody(context);
      // **The rail never takes focus in a body with no rows.** This body mounts
      // only on a failed/empty load, and it has to leave its focus where the
      // user needs it — `SourceErrorView` autofocuses its retry button for
      // exactly this reason, since a status line is not reachable by D-pad. See
      // docs/tv-navigation.md.
      final railSliver = railSliverFor(autofocusFirst: false);
      if (railSliver == null) return status;
      return CustomScrollView(
        slivers: [
          railSliver,
          SliverFillRemaining(hasScrollBody: false, child: status),
        ],
      );
    }

    // Two-dimensional, and measured against the **window** rather than this
    // body's own (SafeArea-shrunk) constraints — see theme.dart's breakpoint
    // note. Height matters as much as width: with a width-only rule an iPad in
    // portrait got the grid and in landscape the list, flipping layout on every
    // rotation; a 900x400 landscape phone has room for list rows but not for a
    // poster grid.
    final windowSize = MediaQuery.sizeOf(context);
    final useGrid =
        windowSize.width >= kMediaGridMinWidth &&
        windowSize.height >= kMediaGridMinHeight;
    final textBudget = mediaTileTextBudget(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The display window: a screenful per page, where a screenful is what
        // actually fits — the grid's column count times the rows that fit its
        // height, or the list's rows that fit — and a row counts only when at
        // least half of it is visible.
        //
        // **The Continue-watching rail does NOT shrink the first page.** It is a
        // sliver the user scrolls past, above the grid; folding its height into
        // the row count made page 1 one row short of every later page (2 rows vs
        // 3 on a real window). Every page is the same full screen of the grid.
        final railHeight = showRail
            ? _ContinueWatchingRail.height(context)
            : 0.0;
        final screen = _screenCells(
          constraints,
          constraints.maxHeight,
          useGrid: useGrid,
          windowSize: windowSize,
          textBudget: textBudget,
        );
        // **The "Next page" card takes the last cell of every screen**, so page
        // `p` shows `p * screen - 1` items and the card is cell `p * screen` —
        // the bottom-right corner.
        final pageLimit = displayPages * screen - 1;
        // Never shrink below the floor within this dataset (a resize cannot
        // unmount an already-shown card; see minShown).
        final shownLimit = pageLimit > minShown ? pageLimit : minShown;
        final shown = visible.length <= shownLimit
            ? visible
            : visible.sublist(0, shownLimit < 0 ? 0 : shownLimit);
        // Report the revealed count so the owner can raise its floor. Post-frame
        // because it mutates owner state, and idempotent on their side.
        final report = onShown;
        if (report != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => report(shown.length),
          );
        }
        DiagnosticsLog.instance.add(
          'paging',
          'window=${windowSize.width.toStringAsFixed(0)}x'
              '${windowSize.height.toStringAsFixed(0)} '
              'body=${constraints.maxHeight.toStringAsFixed(1)} '
              'rail=${railHeight.toStringAsFixed(1)} showRail=$showRail '
              'useGrid=$useGrid screen=$screen displayPages=$displayPages '
              'shownLimit=$shownLimit visible=${visible.length} '
              'shown=${shown.length} snapshotHasMore=${snapshot?.hasMore}',
        );
        final hasMoreToShow =
            shown.length < visible.length || (snapshot?.hasMore == true);
        final showLoadMore =
            !showingSearch && (loadingMore || hasMoreToShow);
        final hasLastVisible =
            lastPlayedId != null &&
            shown.any((media) => media.id == lastPlayedId);
        // **The rail takes the initial focus unless we have somewhere better to
        // put it.** `lastPlayedId` is set only by [MediaTabController.notePlayed],
        // so on a fresh open it is null and the old `i == 0` rule sent the D-pad
        // to the alphabetically/catalogurally first movie — under the Continue
        // watching rail the user had just been watching things on, and past. The
        // rail is what this tab is *about* when it exists, and it is the first
        // thing drawn, so it is where a first focus belongs.
        //
        // Deliberately *not* overriding [hasLastVisible]: coming back from a
        // details sheet should still land on the exact tile you left (and its
        // own rail entry too, since it is by construction the newest one).
        final railTakesFocus = showRail && !hasLastVisible;
        // Exactly one autofocus candidate per tab, or the two widgets race on
        // first frame and the winner depends on tree order.
        FocusNode? focusNodeFor(int i) => hasLastVisible
            ? (shown[i].id == lastPlayedId ? firstFocusNode : null)
            : (i == 0 && !railTakesFocus ? firstFocusNode : null);
        bool autofocusFor(int i) => hasLastVisible
            ? shown[i].id == lastPlayedId
            : (i == 0 && !railTakesFocus);
        final railSliver = railSliverFor(autofocusFirst: railTakesFocus);
        if (!useGrid) {
          return CustomScrollView(
            controller: scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            slivers: [
              ?railSliver,
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                sliver: SliverList.builder(
                  itemCount: shown.length + (showLoadMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == shown.length) {
                      return _MediaLoadMoreTile(
                        canLoad: hasMoreToShow,
                        loading: loadingMore,
                        focusNode: loadMoreFocusNode,
                        onPressed: onLoadMore,
                      );
                    }
                    return _MediaListTile(
                      item: shown[i],
                      favorite: isFavorite(shown[i].id),
                      progress: resumeProgress[shown[i].id],
                      position: i + 1,
                      total: visible.length,
                      autofocus: autofocusFor(i),
                      focusNode: focusNodeFor(i),
                      onTap: () => onOpenMedia(shown[i]),
                    );
                  },
                ),
              ),
            ],
          );
        }
        final grid = MediaGridMetrics.forSize(windowSize);
        // Deliberately still a fixed-cross-axis-count lattice: Flutter's
        // directional traversal walks a regular grid predictably, and
        // `SliverGridDelegateWithMaxCrossAxisExtent` can't express the
        // per-width `childAspectRatio` the fixed poster/text split needs.
        //
        // This instance is orientation-free on purpose: only `childAspectRatio`
        // reads `posterAspectRatio`, so padding and the column ladder are the
        // same numbers in both shapes and the tile width below is safe to
        // compute once, outside the listener.
        final tileWidth = grid.tileWidth(constraints.maxWidth);
        return CustomScrollView(
          controller: scrollController,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
          slivers: [
            ?railSliver,
            SliverPadding(
              padding: grid.padding,
              // Listens rather than reading the notifier's value once: the tile
              // is toggled from the Settings route pushed *over* this one, so
              // nothing here rebuilds on its own and the cards would keep the
              // old shape until some unrelated rebuild came along. Scoped to the
              // grid alone — the rail's thumbnails and the list layout below are
              // not cards, and stay as they are (see docs/player.md).
              sliver: ListenableBuilder(
                listenable: vodCardOrientation,
                builder: (context, _) {
                  final shaped = MediaGridMetrics.forSize(
                    windowSize,
                    orientation: vodCardOrientation.value,
                  );
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: shaped.columns,
                      crossAxisSpacing: shaped.crossAxisSpacing,
                      mainAxisSpacing: shaped.mainAxisSpacing,
                      childAspectRatio: shaped.childAspectRatio(
                        tileWidth: tileWidth,
                        textBudget: textBudget,
                      ),
                    ),
                    delegate: SliverChildBuilderDelegate((context, i) {
                      if (i == shown.length) {
                        return _MediaLoadMoreCard(
                          canLoad: hasMoreToShow,
                          loading: loadingMore,
                          focusNode: loadMoreFocusNode,
                          onPressed: onLoadMore,
                        );
                      }
                      return _MediaGridTile(
                        item: shown[i],
                        favorite: isFavorite(shown[i].id),
                        progress: resumeProgress[shown[i].id],
                        position: i + 1,
                        total: visible.length,
                        autofocus: autofocusFor(i),
                        focusNode: focusNodeFor(i),
                        textBudget: textBudget,
                        onTap: () => onOpenMedia(shown[i]),
                      );
                    }, childCount: shown.length + (showLoadMore ? 1 : 0)),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _statusBody(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      final what = kind == ContentKind.movie ? 'movies' : 'series';
      return SourceErrorView(
        message: 'Couldn\'t load $what.\n$error',
        onRetry: onRetry,
      );
    }
    final label = kind == ContentKind.movie ? 'movies' : 'series';
    final filtered = showingSearch || categoryFilterActive;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          filtered
              ? 'No $label match'
              : 'This source has no $label — try Reload from the toolbar '
                    'or check the source.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textLo),
        ),
      ),
    );
  }
}

/// Remaining watch time as `23 min left` / `1 hr 12 min left`, or null when
/// the duration is unknown or the item is effectively finished.
String? _remainingLabel(PlaybackPosition position) {
  if (position.duration <= Duration.zero) return null;
  final remaining = position.duration - position.position;
  if (remaining.inSeconds < 30) return null;
  final minutes = remaining.inMinutes;
  if (minutes < 1) return 'Less than a min left';
  if (minutes < 60) return '$minutes min left';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  return mins == 0 ? '$hours hr left' : '$hours hr $mins min left';
}

/// `S2 · E5 · 23 min left` style second line — season/episode (episodes
/// only) and remaining time, whichever of the two apply.
String? _continueWatchingSubtitle(ContinueWatchingEntry entry) {
  final item = entry.item;
  final parts = <String>[
    if (item.seasonNumber != null && item.episodeNumber != null)
      'S${item.seasonNumber} · E${item.episodeNumber}',
    ?_remainingLabel(entry.position),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Everything the tile knows, for a screen reader: the series, the episode by
/// name, where it sits, and how much is left. The visible tile has room for a
/// series line and one meta line, so the episode title only survives here.
String _continueWatchingSemantics(ContinueWatchingEntry entry) {
  final item = entry.item;
  final parts = <String>[
    entry.displayTitle,
    // Only when it isn't already the line above — a movie would repeat itself.
    if (entry.seriesTitle != null) item.title,
    if (item.seasonNumber != null && item.episodeNumber != null)
      'season ${item.seasonNumber} episode ${item.episodeNumber}',
    ?_remainingLabel(entry.position),
  ];
  return parts.join(', ');
}

/// How far a title has been watched, drawn as a bar across the bottom of its
/// artwork — on the "Continue watching" rail's thumbnail and on a poster card in
/// the grid.
///
/// **One widget for both, on purpose.** Same question ("how far through is
/// this?"), so it gets one colour and one geometry: a green bar over a dark
/// scrim. The rail used to draw it in [AppColors.accent], which is the *brand*
/// hue — it reads as "this is an interactive control", not "this is your
/// progress", and the moment a card drew the same bar in a second colour the two
/// answers to the same question stopped agreeing. [AppColors.success] is the
/// theme's existing "healthy / done" green, so nothing new is invented.
///
/// The scrim is what makes it legible: a bright poster (a snow field, a white
/// title card) otherwise swallows a 4 px bar, and this sits *over* artwork
/// rather than on the panel behind it. It fades from fully transparent so it
/// costs no visible poster area above the bar.
///
/// **Absolutely positioned by both callers, never in a layout.** A poster card's
/// cell is a fixed extent derived from `childAspectRatio` and a fixed
/// [mediaTileTextBudget]; adding a row to the card would either change that
/// extent (re-deriving every pinned metric) or clip. Inside the poster's own
/// [Stack] it costs no geometry at all, which is why it is a sibling of the
/// rating and favorite badges rather than a child of the text column.
class WatchProgressBar extends StatelessWidget {
  /// Watched fraction, 0..1. Clamped here so a bad value can only ever draw a
  /// full or empty bar, never a `LinearProgressIndicator` assertion.
  final double value;

  /// Padding between the artwork's edges and the bar. The rail insets its bar
  /// (with a taller top pad, so the scrim fades in above it); a card runs it
  /// flush, which is the shape a viewer already reads as "this poster".
  final EdgeInsets inset;

  static const double _height = 4;
  static const double _radius = 3;

  const WatchProgressBar({
    super.key,
    required this.value,
    this.inset = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: inset,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.7),
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: _height,
          backgroundColor: Colors.white.withValues(alpha: 0.3),
          color: AppColors.success,
        ),
      ),
    );
  }
}

/// Horizontal "Continue watching" strip: poster tiles with a progress bar,
/// newest first. One `FocusTraversalGroup` so the D-pad walks the rail as a
/// row between the toolbar and the grid. Sized noticeably larger than the
/// other rails so the title and remaining-time text stay legible on phones.
/// Reports its child's laid-out size once per change, for the paging
/// diagnostics. Purely a probe — it renders [child] unchanged.
class _MeasureSize extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onChange;
  const _MeasureSize({required this.child, required this.onChange});
  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  Size? _last;
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = context.size;
      if (size == null || size == _last) return;
      _last = size;
      widget.onChange(size);
    });
    return widget.child;
  }
}

class _ContinueWatchingRail extends StatelessWidget {
  final List<ContinueWatchingEntry> entries;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemove;

  /// Autofocus the newest entry (index 0 — the rail is newest-first), so the
  /// D-pad lands on the recents when this tab opens. Off in the loading/error/
  /// empty body, which owns the focus itself.
  final bool autofocusFirst;

  const _ContinueWatchingRail({
    required this.entries,
    required this.onResume,
    required this.onRemove,
    this.autofocusFirst = false,
  });

  /// The vertical space the rail occupies, so the media tab can subtract it when
  /// deciding how many grid rows fit *on the first page* (the rail is a leading
  /// sliver, so it eats into the first screen's grid area — and, with a
  /// screen-sized page, ignoring it pushed the "Next page" card below the fold).
  /// Mirrors the header + tile arithmetic in [build]/[_ContinueWatchingTile.height].
  static double height(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final header = 8 + (scaler.scale(15) * 1.2).ceilToDouble() + 8;
    return header + _ContinueWatchingTile.height(context);
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: Text(
              'Continue watching',
              style: TextStyle(
                color: AppColors.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            // Only tall enough for the tile's own content (16:9 thumbnail +
            // title + subtitle + the Remove row below the card) — not sized
            // against the screen, so it can never itself overflow a short
            // viewport (phone landscape). It scrolls away with the rest of
            // the tab content.
            //
            // Derived from the text scale rather than hard-coded: the three
            // text runs grow ~13 px at Android's "Large" (1.3x) and more at the
            // accessibility sizes above it, which a fixed 224 could not absorb.
            height: _ContinueWatchingTile.height(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => _ContinueWatchingTile(
                entry: entries[i],
                autofocus: autofocusFirst && i == 0,
                onTap: () => onResume(entries[i].item),
                onRemove: () => onRemove(entries[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingTile extends StatelessWidget {
  // 16:9 — these thumbnails are usually a video-frame screenshot or a
  // backdrop still, both landscape; cropping them into a portrait poster
  // box (the old design) zoomed in hard and made compression noise obvious.
  static const double _width = 224.0;
  static const double _thumbHeight = 126.0;

  static const double _titleFontSize = 13.0;
  static const double _titleHeight = 1.2;
  static const double _subtitleFontSize = 11.0;

  /// Natural height of one rail tile: the thumbnail, the two text runs, and
  /// the Remove row below the card, at the current text scale. The rail's
  /// `ListView` hands its children a *tight* cross-axis extent, so this is what
  /// the tile has to live inside.
  ///
  /// **It is a hint, not a guarantee** — [build] lays the tile out unconstrained
  /// inside a `ClipRect`, so being wrong here costs at most a sub-pixel trim off
  /// the bottom of the Remove row's (transparent) tap padding. It used to be
  /// load-bearing, and it was wrong: this rail was the source of the persistent
  /// `BOTTOM OVERFLOWED BY 1.6 PIXELS` on a windowed desktop layout, not the
  /// poster grid it sits above.
  ///
  /// Two corrections came out of measuring the real font (see
  /// `test/layout_overflow_test.dart`, which loads Inter rather than the
  /// widget-test font): the engine **rounds each laid-out line up to a whole
  /// logical pixel**, so a predicted run has to be ceiled; and Inter's real
  /// line-height ratio for a run with no explicit `TextStyle.height` is ~1.41,
  /// not the 1.35 assumed here. The border term is the **focused** width
  /// ([FocusableCard] draws 2 px a side when focused, 1 at rest) because unlike
  /// the poster grid nothing in this tile is flexible enough to absorb it.
  static double height(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = (scaler.scale(_titleFontSize) * _titleHeight).ceilToDouble();
    final subtitle = (scaler.scale(_subtitleFontSize) * 1.45).ceilToDouble();
    return _thumbHeight +
        6 + // thumbnail → title
        title +
        2 + // title → subtitle
        subtitle +
        10 + // breathing room above the card's bottom border
        kFocusableCardVerticalPadding * 2 +
        2 * 2 + // focused card border, both sides
        4 + // card → Remove row
        _RemoveButton.height(context);
  }

  final ContinueWatchingEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  /// See [_ContinueWatchingRail.autofocusFirst]. Only index 0 ever passes true;
  /// the field is per-tile so the rail, not the caller, owns which entry is the
  /// landing spot.
  final bool autofocus;

  const _ContinueWatchingTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final subtitle = _continueWatchingSubtitle(entry);
    // The series name for an episode, the item's own title otherwise. The
    // episode name is not lost — it moves into the semantics label below,
    // because the tile has exactly two single-line text runs and its rail
    // height is derived from that (see [height]); a third line would have to be
    // paid for by every tile including the movie tab's.
    final title = entry.displayTitle;
    return SizedBox(
      width: _width,
      // **Laid out unconstrained, then clipped.** The rail's `ListView` hands
      // this tile a *tight* height derived from [height] — a prediction built
      // from font metrics, which is exactly the kind of thing that is quietly
      // 1–2 px short on a real font. Giving the `Column` an unbounded main axis
      // makes the tile structurally incapable of reporting an overflow, and the
      // `ClipRect` turns any residual into a trim off the bottom of the Remove
      // row's transparent tap padding rather than a striped bar under every
      // card in the rail. `topLeft` keeps the thumbnail pinned to the top, which
      // is where the alignment matters.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FocusableCard(
                onTap: onTap,
                autofocus: autofocus,
                debugLabel: 'media.continue.${item.id}',
                // Spells out what the two visible runs compress: the series,
                // then the episode by name, then position and time left. This
                // is where the episode title stays readable once the visible
                // title leads with the series.
                semanticsLabel: _continueWatchingSemantics(entry),
                child: SizedBox(
                  width: _width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: _width,
                          height: _thumbHeight,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _Thumb(
                                item: item,
                                width: _width,
                                height: _thumbHeight,
                              ),
                              // Resume affordance — makes it obvious at a glance
                              // that these tiles play mid-way through, not from
                              // the start.
                              Center(
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                              // Progress bar overlaid on the thumbnail (with a
                              // scrim behind it for contrast on bright artwork)
                              // rather than a separate row, so the freed-up
                              // space goes to the title.
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: WatchProgressBar(
                                  value: entry.position.progress,
                                  inset: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHi,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textLo,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                      // Breathing room between the text and the card's bottom
                      // border — the card itself adds no internal padding.
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
              // A genuine sibling *below* the card, not overlaid on top of it.
              // An overlaid corner badge is unreachable by D-pad: Flutter's
              // directional focus search matches against candidates' screen
              // rects, and a badge nested inside the card's own rect never reads
              // as "up/down/left/right" of it — confirmed by testing an
              // overlaid version, where arrow keys skipped straight over it to
              // the next card. A non-overlapping rect below it works exactly
              // like moving between adjacent cards in the row.
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: _RemoveButton(
                  onPressed: onRemove,
                  // Names what leaves the rail — the series, as displayed.
                  itemTitle: title,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Clears one continue-watching entry — a genuine sibling stop below its
/// card (see [_ContinueWatchingTile]'s doc comment on why it can't overlay
/// the card instead).
class _RemoveButton extends StatefulWidget {
  final VoidCallback onPressed;

  /// Title of the entry this removes, so the control announces what it acts
  /// on instead of a bare "Remove".
  final String itemTitle;

  /// Font size of the "Remove" label, shared with [height].
  static const double _labelFontSize = 11;

  /// Minimum tap target. The visible chip is deliberately much smaller — it
  /// sits under a poster thumb — but this is a destructive control directly
  /// below a tile whose tap starts playback, so the *hit* area is padded out.
  static const double _minTapTarget = 44;

  /// Height one of these occupies, for [_ContinueWatchingTile.height]'s rail
  /// sizing. Normally the flat [_minTapTarget], but the chip's own content is
  /// measured too so an extreme accessibility text scale grows the rail
  /// instead of overflowing it.
  static double height(BuildContext context) {
    final label = MediaQuery.textScalerOf(context).scale(_labelFontSize) * 1.35;
    final chip =
        label +
        3 * 2 + // vertical padding
        2; // focus border
    return math.max(_minTapTarget, chip);
  }

  const _RemoveButton({required this.onPressed, required this.itemTitle});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _focused = false;

  // A plain `FocusableActionDetector` node carries no route key, so the root
  // Back ladder read `''` here and fell through to the exit prompt.
  late final FocusNode _focusNode = RoutedFocusNode('media.continue.remove');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Remove ${widget.itemTitle} from Continue watching',
      child: FocusableActionDetector(
        focusNode: _focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (mounted) setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          // The visual chip stays small (it sits under a poster thumb), but
          // the *hit* area is padded out to the 44px minimum — this is a
          // destructive control immediately below a tile whose tap starts
          // playback, so a mis-tap here is expensive. `behavior: opaque`
          // makes the transparent padding hit-testable. This adds no focus
          // stop: the SizedBox is inside the existing detector.
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: _RemoveButton._minTapTarget,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: appMotion(context, const Duration(milliseconds: 120)),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: _focused ? AppColors.panelHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: _focused ? Border.all(color: AppColors.accent) : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: _focused ? AppColors.accent : AppColors.textLo,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Remove',
                      style: TextStyle(
                        fontSize: _RemoveButton._labelFontSize,
                        fontWeight: FontWeight.w600,
                        color: _focused ? AppColors.accent : AppColors.textLo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A landscape (16:9) artwork tile for the continue-watching rail — prefers
/// [MediaItem.backdrop] (a proper cinematic still) and falls back to
/// [MediaItem.poster] (often a video-frame screenshot for episodes), since
/// either is landscape-shaped content, unlike [_Poster]'s portrait crop.
class _Thumb extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Thumb({required this.item, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        item.kind == ContentKind.movie
            ? Icons.movie_outlined
            : Icons.tv_outlined,
        color: AppColors.textLo,
      ),
    );
    final backdrop = cleanImageUrl(item.backdrop);
    final poster = cleanImageUrl(item.poster);
    final image = (backdrop != null && backdrop.isNotEmpty)
        ? backdrop
        : (poster != null && poster.isNotEmpty)
        ? poster
        : null;
    if (image == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: image,
        width: width,
        height: height,
        fit: BoxFit.cover,
        // Width only — see [imageCacheSize]. Passing both dimensions decodes
        // the bitmap pre-distorted to this box's 16:9, which matters most
        // here: when a title has no backdrop this falls back to the *poster*,
        // and squashing 2:3 into 16:9 makes the entry unrecognisable.
        memCacheWidth: imageCacheSize(context, width),
        // Same widget for both states by design; the log is what tells them
        // apart (see [logImageFailure]).
        errorWidget: (_, url, error) {
          logImageFailure(error, url);
          return fallback;
        },
        placeholder: (_, _) => fallback,
      ),
    );
  }
}

class _MediaListTile extends StatelessWidget {
  final MediaItem item;
  final bool favorite;
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  /// See [_MediaGridTile.progress]. On this layout the bar rides the bottom of
  /// the 58x84 thumb rather than the card, because the row's height is set by
  /// the text block beside it and a full-width bar under the row would need a
  /// height this row does not have.
  final double? progress;

  const _MediaListTile({
    required this.item,
    required this.favorite,
    required this.position,
    required this.total,
    required this.autofocus,
    this.focusNode,
    this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Parsed once per tile build — see [_MediaGridTile.build].
    final duration = formatMediaDuration(item.durationSeconds);
    // The provider's own date string is reprinted in the OS's short-date
    // format; a bare year or an unmatched shape comes back unchanged.
    final date = formatReleaseDate(item.year);
    return FocusableCard(
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: 'media.item.${item.id}',
      semanticsLabel: [
        item.title,
        if (date.isNotEmpty) date,
        ?duration,
        '$position of $total',
        if (favorite) 'Favorite',
        if (progress != null)
          progress == 1.0 ? 'Watched' : '${(progress! * 100).ceil()}% watched',
      ].join(', '),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // The thumb's own [ClipRRect] is *below* [WatchProgressBar] so the
            // bar sits on the artwork's clipped edge instead of hanging a pixel
            // outside the rounded corner.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  _Poster(item: item, width: 58, height: 84),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: WatchProgressBar(value: progress!),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (date.isNotEmpty ||
                      _hasRating(item) ||
                      duration != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
if (date.isNotEmpty)
                              Expanded(
                                child: Text(
                                  date,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textLo,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            // Keeps the runtime right-aligned in the year row
                            // even for a title the panel dated nothing. A
                            // `Spacer` alongside an `Expanded` date would split
                            // the row 1:1 on flex - the date then had half the
                            // width and ellipsised the moment a runtime
                            // appeared, which is exactly the squeeze this
                            // layout is supposed to put on the date alone.
                            else if (duration != null)
                              const Spacer(),
                            if (date.isNotEmpty && _hasRating(item))
                              const SizedBox(width: 10),
                            _RatingBadge(rating: item.rating),
                            // The runtime is rigid and laid out after the
                            // flexible date, so a long date ellipsises rather
                            // than pushing the runtime out of the tile.
                            if (duration != null)
                              Text(
                                duration,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: AppColors.textLo,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                  ],
                  // Parsed once per tile build: the pattern binds the list so
                  // the emptiness test and the widget share one parse.
                  if (sourceHintLabels(item) case final hints
                      when hints.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _SourceHints(hints: hints),
                  ],
                  if (item.description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (favorite) ...[const SizedBox(width: 8), const FavoriteBadge()],
            const SizedBox(width: 8),
            Icon(
              item.kind == ContentKind.movie
                  ? Icons.play_arrow_rounded
                  : Icons.chevron_right_rounded,
              color: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaGridTile extends StatelessWidget {
  final MediaItem item;
  final bool favorite;
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;

  /// How far this title has been watched, or null when nothing is in progress —
  /// which is most cards, and every card on the series tab (see
  /// [MediaTabController.resumeProgress] for why a series card has none).
  ///
  /// Read once per tile from the map the controller publishes, never fetched:
  /// a card cannot ask the database, and a per-card read would be a query per
  /// visible tile on a grid that can hold 200 of them.
  final double? progress;

  /// Fixed height reserved for the text under the poster
  /// ([mediaTileTextBudget]) — the same value the grid's `childAspectRatio`
  /// was computed from, so the `Expanded` poster above it lands on
  /// [MediaGridMetrics.posterAspectRatio] in *every* cell instead of varying
  /// with how much text each item happens to carry.
  final double textBudget;

  final VoidCallback onTap;

  const _MediaGridTile({
    required this.item,
    required this.favorite,
    required this.position,
    required this.total,
    required this.autofocus,
    this.focusNode,
    this.progress,
    required this.textBudget,
    required this.onTap,
  });

  /// Whole percent, for the semantics label — a D-pad user cannot see the bar,
  /// and "Resume" is the one thing about an in-progress title they would
  /// otherwise have to guess. Rounded *up*, so 0.4% still reads "1%" rather than
  /// claiming nothing is watched. A full bar means the title was played to the
  /// end, which reads as "Watched", not "100%" — the two states are different.
  String get _progressSemantics => progress == 1.0
      ? 'Watched'
      : '${(progress! * 100).ceil()}% watched';

  @override
  Widget build(BuildContext context) {
    // Parsed once per tile build: the pattern binds the list so the emptiness
    // test and the widget share one parse, and this formats for every visible
    // tile rather than only for the ones that print it.
    final duration = formatMediaDuration(item.durationSeconds);
    // See [_MediaListTile.build]: the provider's date string reprinted in the
    // OS's short-date format.
    final date = formatReleaseDate(item.year);
    return FocusableCard(
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: 'media.item.${item.id}',
      semanticsLabel: [
        item.title,
        if (date.isNotEmpty) date,
        ?duration,
        '$position of $total',
        if (favorite) 'Favorite',
        if (progress != null) _progressSemantics,
      ].join(', '),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(MediaGridMetrics.tilePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.expand(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Poster(
                      item: item,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                    if (_hasRating(item))
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _RatingBadge(
                            rating: item.rating,
                            compact: true,
                          ),
                        ),
                      ),
                    if (favorite)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const FavoriteBadge(size: 16),
                        ),
                      ),
                    // Watched-so-far, flush across the poster's bottom edge.
                    // **Inside this [Stack], not below it** — see
                    // [WatchProgressBar]: the cell's extent is fixed by
                    // `childAspectRatio`, so any row added to the card would
                    // either move that extent or clip.
                    if (progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: WatchProgressBar(value: progress!),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: MediaGridMetrics.posterTextGap),
            // Fixed-height text block. `OverflowBox` + `ClipRect` rather than a
            // bare `SizedBox`: the budget is an estimate built from font
            // metrics, and a font whose real line height runs a hair taller
            // than the estimate must clip quietly instead of throwing a
            // RenderFlex overflow across every tile in the catalogue.
            SizedBox(
              width: double.infinity,
              height: textBudget,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      // The catalogue's runtime, right-aligned in the same row as
                      // the date — never a row of its own. [textBudget] is the
                      // budget `childAspectRatio` was computed from, so an added
                      // line would move every cell's poster height; a sibling in
                      // the year row costs nothing and the year ellipsises first.
                      if (date.isNotEmpty || duration != null)
                        Row(
                          children: [
if (date.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    date,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.textLo,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              // See the list row: a `Spacer` here would take half
                              // the row's flex and ellipsise the date the moment
                              // a runtime appeared.
                              else if (duration != null)
                                const Spacer(),
                            if (duration != null)
                              Text(
                                duration,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: AppColors.textLo,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      if (sourceHintLabels(item) case final hints
                          when hints.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        _SourceHints(hints: hints, compact: true),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders already-parsed hint labels. It deliberately takes the parsed list
/// rather than the `MediaItem`: `sourceHintLabels` is not cheap (regexes + the
/// language alias table) and every call site already has to test the result for
/// emptiness, so parsing here too would double the cost on every tile build.
class _SourceHints extends StatelessWidget {
  final List<String> hints;
  final bool compact;

  const _SourceHints({required this.hints, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (hints.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final hint in hints.take(compact ? 2 : 4))
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 6,
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.line),
            ),
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textLo,
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Whether an item has a real (non-zero) score worth showing. Many items come
/// back with `rating == 0.0`, which means "unrated", not a literal zero.
bool _hasRating(MediaItem item) => (item.rating ?? 0) > 0;

/// A small `★ 8.5` rating chip, shown when an item carries a non-zero 0–10
/// score (TMDB or MDBList). Renders nothing otherwise.
class _RatingBadge extends StatelessWidget {
  final double? rating;
  final bool compact;

  const _RatingBadge({required this.rating, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null || value <= 0) return const SizedBox.shrink();
    final fontSize = compact ? 11.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: fontSize + 3, color: AppColors.accent),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: TextStyle(
            color: AppColors.textHi,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MediaLoadMoreTile extends StatefulWidget {
  final bool canLoad;
  final bool loading;
  final FocusNode? focusNode;
  final VoidCallback onPressed;

  const _MediaLoadMoreTile({
    required this.canLoad,
    required this.loading,
    this.focusNode,
    required this.onPressed,
  });

  @override
  State<_MediaLoadMoreTile> createState() => _MediaLoadMoreTileState();
}

class _MediaLoadMoreTileState extends State<_MediaLoadMoreTile> {
  // Owned fallback for when the screen supplies no node: a plain `FilledButton`
  // focus node carries no route key, so the root Back ladder read `''` from it
  // and fell through to the exit prompt instead of climbing to the tabs.
  final FocusNode _ownedNode = RoutedFocusNode('media.loadMore');
  FocusNode get _node => widget.focusNode ?? _ownedNode;

  @override
  void dispose() {
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loading = widget.loading;
    final canLoad = widget.canLoad;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: FilledButton.icon(
          focusNode: _node,
          onPressed: canLoad && !loading ? widget.onPressed : null,
          icon: loading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more_rounded),
          label: Text(
            loading
                ? 'Loading'
                : canLoad
                ? 'Next page'
                : 'All loaded',
          ),
        ),
      ),
    );
  }
}

class _MediaLoadMoreCard extends StatelessWidget {
  final bool canLoad;
  final bool loading;
  final FocusNode? focusNode;
  final VoidCallback onPressed;

  const _MediaLoadMoreCard({
    required this.canLoad,
    required this.loading,
    this.focusNode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: false,
      focusNode: focusNode,
      // Without an explicit label this minted the route key `FocusableCard`,
      // which is non-empty and not `media.`-prefixed — so the root Back ladder
      // matched neither its `media.` rung nor its empty-label recovery, and
      // Back from the end of the grid dropped straight to the exit prompt.
      debugLabel: 'media.loadMore',
      onTap: canLoad && !loading ? onPressed : () {},
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                canLoad ? Icons.expand_more_rounded : Icons.check_rounded,
                color: canLoad ? AppColors.accent : AppColors.textLo,
                size: 32,
              ),
            const SizedBox(height: 8),
            Text(
              loading
                  ? 'Loading'
                  : canLoad
                  ? 'Next page'
                  : 'All loaded',
              style: const TextStyle(color: AppColors.textLo),
            ),
          ],
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Poster({
    required this.item,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderedWidth = width.isFinite && width > 0
            ? width
            : constraints.maxWidth;
        final renderedHeight = height.isFinite && height > 0
            ? height
            : constraints.maxHeight;
        final fallback = Container(
          width: renderedWidth,
          height: renderedHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            item.kind == ContentKind.movie
                ? Icons.movie_outlined
                : Icons.tv_outlined,
            color: AppColors.textLo,
          ),
        );
        final poster = cleanImageUrl(item.poster);
        if (poster == null || poster.isEmpty) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: poster,
            width: renderedWidth,
            height: renderedHeight,
            fit: BoxFit.cover,
            // Width only — see [imageCacheSize]. Decoding to both dimensions
            // selects `ResizeImagePolicy.exact`, which is `BoxFit.fill` at
            // decode time and leaves the `BoxFit.cover` below nothing to crop.
            // The tile's box aspect is fixed now (see
            // [MediaGridMetrics.childAspectRatio]), so the stretch would be
            // uniform rather than per-tile — still wrong, just less obviously.
            memCacheWidth: imageCacheSize(context, renderedWidth),
            // Same widget for both states by design; the log is what tells
            // them apart (see [logImageFailure]).
            errorWidget: (_, url, error) {
              logImageFailure(error, url);
              return fallback;
            },
            placeholder: (_, _) => fallback,
          ),
        );
      },
    );
  }
}

/// Plays one episode, together with the list it was picked from.
///
/// The sibling list travels with the episode because that list **is** what the
/// previous/next pair steps through: it is the season, in the season's own
/// order. Passing only the episode — as this used to — makes "next" mean
/// something the route has to invent, and the only invented answer (a second
/// query, or the whole series) steps across a season boundary the user never
/// crossed on screen.
typedef PlayEpisode = void Function(MediaItem episode, List<MediaItem> siblings);

class MediaDetailsSheet extends StatefulWidget {
  final LibraryRepository repo;
  final MediaItem item;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPlay;
  final ValueChanged<MediaItem>? onChanged;

  /// Plays one episode picked from the series browser. Routed back through the
  /// screen's own play path (rather than pushing a player here) so the
  /// "Continue watching" rail reloads on return, exactly like a movie does.
  final PlayEpisode? onPlayEpisode;

  const MediaDetailsSheet({
    super.key,
    required this.repo,
    required this.item,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onPlay,
    this.onChanged,
    this.onPlayEpisode,
    this.resume,
    this.onPlayFromStart,
  });

  /// Saved resume point for this item, if any — turns the Play button into
  /// "Resume from h:mm:ss" and surfaces [onPlayFromStart] beside it.
  final PlaybackPosition? resume;
  final VoidCallback? onPlayFromStart;

  @override
  State<MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<MediaDetailsSheet> {
  late MediaItem _item = widget.item;
  late bool _favorite = widget.favorite;
  late Future<ExternalMetadata?> _metadataFuture = _loadMetadata();
  late final Future<List<MediaItem>>? _seasonsFuture = _loadSeasonsIfNeeded();
  final Map<String, Future<List<MediaItem>>> _episodeFutures = {};
  bool _refreshingMetadata = false;

  /// Captured by `_SeriesBrowser.onFirstSeasonFocusNode` once the first
  /// season header builds — see that field's doc comment.
  FocusNode? _firstSeasonFocusNode;

  @override
  void initState() {
    super.initState();
    // Movies/episodes autofocus their Play button directly. A series has no
    // top-level Play button, so once the seasons load, nudge focus onto the
    // first season tile. `FocusScope.nextFocus()` used to be called here, but
    // with nothing focused yet in this sheet it just lands on the very first
    // focusable stop — the title row's favorite star — not the season list.
    // Request the season header's own captured node directly instead; fall
    // back to nextFocus() if it somehow wasn't captured (e.g. no seasons).
    if (widget.onPlay == null) {
      _seasonsFuture?.whenComplete(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final node = _firstSeasonFocusNode;
          if (node != null && node.canRequestFocus) {
            node.requestFocus();
          } else {
            FocusScope.of(context).nextFocus();
          }
        });
      });
    }
  }

  /// Clears the repository's cancellation token for the drill-down about to
  /// run, in the synchronous prologue the field's contract requires.
  ///
  /// These loads are the sheet's own, and they are the only `loadMedia` callers
  /// that are not a [MediaTabController]. Every controller path sets
  /// `repo.loadToken` immediately before its own call; the sheet set nothing,
  /// so it inherited whatever was left on the shared repository — and it *is*
  /// shared: the movie and series controllers are built over one
  /// [LibraryRepository] and each cancels only its own token, while
  /// `MediaTabController.dispose` cancels one outright. So a season or episode
  /// fetch could begin already-cancelled, through no act of its own, and
  /// quietly decline to cache its result: a drill-down that re-hit the provider
  /// on every open.
  ///
  /// Null rather than a token of its own, deliberately. A token would only earn
  /// its keep if something could supersede these loads, and nothing can — they
  /// write to their own `(kind, parentId)` cache key, which no other caller
  /// touches, so there is no staler writer to lose a race to.
  void _clearInheritedLoadToken() => widget.repo.loadToken = null;

  Future<List<MediaItem>>? _loadSeasonsIfNeeded() {
    if (_item.kind != ContentKind.series) return null;
    _clearInheritedLoadToken();
    return widget.repo
        .loadMedia(ContentKind.season, parent: _item)
        .then((snapshot) => snapshot.items);
  }

  Future<List<MediaItem>> _episodes(MediaItem season) =>
      _episodeFutures.putIfAbsent(season.id, () {
        _clearInheritedLoadToken();
        return widget.repo
            .loadMedia(ContentKind.episode, parent: season)
            .then((snapshot) => snapshot.items);
      });

  Future<ExternalMetadata?> _loadMetadata() =>
      widget.repo.cachedExternalMetadata(_item, 'tmdb');

  Future<void> _refreshMetadata() async {
    if (_refreshingMetadata) return;
    setState(() => _refreshingMetadata = true);
    try {
      final metadata = await widget.repo.refreshExternalMetadata(_item);
      if (!mounted) return;
      setState(() {
        if (metadata != null) {
          _item = widget.repo.mergeExternalMetadata(_item, metadata);
          widget.onChanged?.call(_item);
        }
        _metadataFuture = _loadMetadata();
        _refreshingMetadata = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _refreshingMetadata = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Metadata refresh failed: $error')),
      );
    }
  }

  void _play(MediaItem item, List<MediaItem> siblings) {
    // Close the sheet, then hand the episode to the screen's play path (which
    // resolves, plays, and — critically — reloads "Continue watching" on
    // return). Pushing a player straight from here bypassed that reload, so the
    // series rail went stale until a manual refresh.
    Navigator.of(context).pop();
    widget.onPlayEpisode?.call(item, siblings);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 520;
            final poster = _Poster(item: _item, width: 124, height: 180);
            final seasonsFuture = _seasonsFuture;
            // See [_MediaListTile.build]: the provider's date string reprinted
            // in the OS's short-date format.
            final date = formatReleaseDate(_item.year);
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    FavoriteButton(
                      favorite: _favorite,
                      onPressed: () {
                        setState(() => _favorite = !_favorite);
                        widget.onToggleFavorite();
                      },
                    ),
                  ],
                ),
                if (date.isNotEmpty || _hasRating(_item)) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (date.isNotEmpty)
                        Text(
                          date,
                          style: const TextStyle(color: AppColors.textLo),
                        ),
                      if (date.isNotEmpty && _hasRating(_item))
                        const SizedBox(width: 12),
                      _RatingBadge(rating: _item.rating),
                    ],
                  ),
                ],
                if (sourceHintLabels(_item) case final hints
                    when hints.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _SourceHints(hints: hints),
                ],
                if (providerSourceTitle(_item) case final sourceTitle?) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Source title: $sourceTitle',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_item.description != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _item.description!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textLo),
                  ),
                ],
                const SizedBox(height: 16),
                if (widget.onPlay != null)
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: widget.onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          widget.resume != null
                              ? 'Resume from ${_positionLabel(widget.resume!.position)}'
                              : 'Play',
                        ),
                      ),
                      if (widget.resume != null &&
                          widget.onPlayFromStart != null)
                        OutlinedButton.icon(
                          onPressed: widget.onPlayFromStart,
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('From start'),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                _MetadataStatus(
                  metadata: _metadataFuture,
                  refreshing: _refreshingMetadata,
                  onRefresh: _refreshMetadata,
                ),
                if (seasonsFuture != null) ...[
                  const SizedBox(height: 18),
                  _SeriesBrowser(
                    seasons: seasonsFuture,
                    episodesFor: _episodes,
                    onPlayEpisode: _play,
                    onFirstSeasonFocusNode: (node) =>
                        _firstSeasonFocusNode = node,
                  ),
                ],
              ],
            );
            if (narrow) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: poster),
                    const SizedBox(height: 14),
                    details,
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  poster,
                  const SizedBox(width: 18),
                  Expanded(child: details),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MetadataStatus extends StatelessWidget {
  final Future<ExternalMetadata?> metadata;
  final bool refreshing;
  final VoidCallback onRefresh;

  const _MetadataStatus({
    required this.metadata,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ExternalMetadata?>(
      future: metadata,
      builder: (context, snapshot) {
        final value = snapshot.data;
        final label = value == null
            ? 'Provider metadata'
            : '${value.provider.toUpperCase()} · ${_ago(value.refreshedAt)}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              Icon(
                value == null
                    ? Icons.auto_awesome_outlined
                    : Icons.check_circle_outline,
                color: value == null ? AppColors.textLo : AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Refresh metadata',
                visualDensity: VisualDensity.compact,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        );
      },
    );
  }

  String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// `S2E5, Episode Title` style concise label for an episode's D-pad focus
/// ring (`FocusableCard.semanticsLabel`) — season/episode number first so a
/// screen reader announces position before the (possibly long) title.
String _episodeSemanticsLabel(MediaItem episode) {
  final sxe = episode.seasonNumber != null && episode.episodeNumber != null
      ? 'S${episode.seasonNumber}E${episode.episodeNumber}'
      : null;
  return sxe == null ? episode.title : '$sxe, ${episode.title}';
}

class _SeriesBrowser extends StatelessWidget {
  final Future<List<MediaItem>> seasons;
  final Future<List<MediaItem>> Function(MediaItem season) episodesFor;
  final PlayEpisode onPlayEpisode;

  /// Called once, during build, with the first season header's own
  /// (ExpansionTile-internal) [FocusNode] as soon as it exists — so the
  /// sheet can [FocusNode.requestFocus] it directly after seasons load,
  /// instead of `FocusScope.nextFocus()`, which lands on the title row's
  /// favorite star (the first focusable stop in the sheet when there's no
  /// top-level Play button). Null when there's nothing to capture yet.
  final ValueChanged<FocusNode>? onFirstSeasonFocusNode;

  const _SeriesBrowser({
    required this.seasons,
    required this.episodesFor,
    required this.onPlayEpisode,
    this.onFirstSeasonFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: seasons,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            'Could not load seasons: ${snapshot.error}',
            style: const TextStyle(color: AppColors.textLo),
          );
        }
        final seasons = snapshot.data ?? const <MediaItem>[];
        if (seasons.isEmpty) {
          return const Text(
            'No seasons found',
            style: TextStyle(color: AppColors.textLo),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < seasons.length; i++)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                // The first season's title carries a `Builder` so it can hand
                // its own (ExpansionTile-internal) focus node back up to the
                // sheet — see `onFirstSeasonFocusNode`'s doc comment for why:
                // the sheet needs to request focus on this exact node rather
                // than `FocusScope.nextFocus()`, which currently lands on the
                // title row's favorite star instead of the season list.
                title: i == 0 && onFirstSeasonFocusNode != null
                    ? Builder(
                        builder: (context) {
                          onFirstSeasonFocusNode!(
                            Focus.of(context, createDependency: false),
                          );
                          return Text(seasons[i].title);
                        },
                      )
                    : Text(seasons[i].title),
                subtitle:
                    seasons[i].seasonNumber == null ||
                        seasons[i].title.trim().toLowerCase() ==
                            'season ${seasons[i].seasonNumber}'.toLowerCase()
                    ? null
                    : Text(
                        'Season ${seasons[i].seasonNumber}',
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                children: [
                  // The future is created inside a `Builder` so it only fires
                  // when this season's subtree is actually mounted. A closed
                  // `ExpansionTile` drops its children (there is no
                  // `maintainState` here), but the `children:` *list* is still
                  // constructed on every build of the browser — so calling
                  // `episodesFor` directly at this point fired one provider
                  // catalog request per season the instant the sheet opened,
                  // which on a long-running series meant a dozen-plus
                  // concurrent requests nobody asked for.
                  Builder(
                    builder: (context) => FutureBuilder<List<MediaItem>>(
                      future: episodesFor(seasons[i]),
                      builder: (context, episodeSnapshot) {
                        if (episodeSnapshot.connectionState !=
                            ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: LinearProgressIndicator(minHeight: 2),
                          );
                        }
                        if (episodeSnapshot.hasError) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Could not load episodes: ${episodeSnapshot.error}',
                              style: const TextStyle(color: AppColors.textLo),
                            ),
                          );
                        }
                        final episodes =
                            episodeSnapshot.data ?? const <MediaItem>[];
                        if (episodes.isEmpty) {
                          return const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'No episodes found',
                              style: TextStyle(color: AppColors.textLo),
                            ),
                          );
                        }
                        return Column(
                          children: [
                            // FocusableCard (not ListTile) — the series browser
                            // was the only browsing surface without the app's
                            // accent D-pad focus ring; season headers stay
                            // ExpansionTile (see the doc comment above on why
                            // that one isn't wrapped).
                            for (final episode in episodes)
                              FocusableCard(
                                debugLabel: 'media.episode.${episode.id}',
                                semanticsLabel: _episodeSemanticsLabel(episode),
                                onTap: () => onPlayEpisode(episode, episodes),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        color: AppColors.accent,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              episode.episodeNumber == null
                                                  ? episode.title
                                                  : '${episode.episodeNumber}. ${episode.title}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodyLarge,
                                            ),
                                            if (episode.description !=
                                                null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                episode.description!,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: AppColors.textLo,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
