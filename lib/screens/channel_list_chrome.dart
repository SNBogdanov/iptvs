import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyEvent, KeyRepeatEvent;

import '../sources/source.dart';
import '../theme.dart';
import '../widgets/tv_text_field.dart';
import 'media_sort.dart';

const _toolbarControlHeight = 40.0;

/// Content-kind tabs at the top of [ChannelListScreen].
///
/// Focus nodes are supplied by the screen so the Back ladder can retain
/// ownership and jump directly to the selected tab.
class ChannelContentTabs extends StatelessWidget {
  final ContentKind value;
  final ValueChanged<ContentKind> onChanged;
  final Map<ContentKind, FocusNode> focusNodes;

  /// The sections to draw, in order. The screen hides the whole row when only
  /// one is left (see `ChannelListScreen._visibleTabs`), so this normally holds
  /// two or three.
  final List<ContentKind> kinds;

  const ChannelContentTabs({
    super.key,
    required this.value,
    required this.onChanged,
    required this.focusNodes,
    this.kinds = kContentSections,
  });

  static const _icons = {
    ContentKind.live: Icons.live_tv_rounded,
    ContentKind.movie: Icons.movie_outlined,
    ContentKind.series: Icons.tv_outlined,
  };

  static const _labels = {
    ContentKind.live: 'Live',
    ContentKind.movie: 'Movies',
    ContentKind.series: 'Series',
  };

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final kind in kinds) ...[
              if (kind != kinds.first) const SizedBox(width: 8),
              _TabChip(
                icon: _icons[kind] ?? Icons.live_tv_rounded,
                label: _labels[kind] ?? kind.name,
                selected: value == kind,
                focusNode: focusNodes[kind],
                onTap: () => onChanged(kind),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _TabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final background = active
        ? AppColors.accent
        : (_focused ? AppColors.panelHi : AppColors.panel);
    final foreground = active ? Colors.white : AppColors.textHi;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) {
        if (mounted) setState(() => _focused = value);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _toolbarControlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(
              color: _focused
                  ? (active ? Colors.white : AppColors.accent)
                  : AppColors.line,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search, category, and per-tab action controls.
class ChannelToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final String query;
  final String hintText;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final FocusNode? searchCellFocusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchCellKeyEvent;
  final Widget? categoryControl;
  final Widget? sortControl;
  final Widget? actionControl;

  const ChannelToolbar({
    super.key,
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    this.searchCellFocusNode,
    this.onSearchCellKeyEvent,
    this.categoryControl,
    this.sortControl,
    this.actionControl,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final search = TvTextField(
          controller: searchController,
          hintText: hintText,
          height: _toolbarControlHeight,
          cellFocusNode: searchCellFocusNode,
          onChanged: onQueryChanged,
          textInputAction: TextInputAction.search,
          prefixIcon: const Icon(Icons.search, size: 20),
          showClear: query.isNotEmpty,
          onClear: onClearQuery,
        );
        final trailing = _trailingControls(narrow: narrow);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: onSearchCellKeyEvent,
            child: narrow
                ? Column(
                    children: [
                      search,
                      if (trailing != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: double.infinity,
                            child: trailing,
                          ),
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: search),
                      if (categoryControl != null) ...[
                        const SizedBox(width: 12),
                        categoryControl!,
                      ],
                      if (sortControl != null) ...[
                        const SizedBox(width: 8),
                        sortControl!,
                      ],
                      if (actionControl != null) ...[
                        const SizedBox(width: 8),
                        actionControl!,
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget? _trailingControls({required bool narrow}) {
    final controls = <Widget>[?categoryControl, ?sortControl, ?actionControl];
    if (controls.isEmpty) return null;
    if (controls.length == 1) return controls.single;
    if (narrow) {
      // **The action rides beside the category picker**, never on a row of its
      // own: on a phone that was one 40 px icon under a full-width dropdown —
      // reported as "the EPG icon looks lonely on its line". The sort control,
      // which needs real width, keeps the row below.
      final header = <Widget>[
        if (categoryControl != null) Expanded(child: categoryControl!),
        if (categoryControl != null && actionControl != null)
          const SizedBox(width: 8),
        ?actionControl,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header.isNotEmpty) Row(children: header),
          if (sortControl != null) ...[
            if (header.isNotEmpty) const SizedBox(height: 8),
            sortControl!,
          ],
        ],
      );
    }
    // The category picker takes the slack; the rest are fixed-width, so on a
    // narrow window it is the one control that can usefully shrink.
    return Row(
      children: [
        Expanded(child: controls.first),
        for (final control in controls.skip(1)) ...[
          const SizedBox(width: 8),
          control,
        ],
      ],
    );
  }
}

class ChannelToolbarIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool busy;
  final bool selected;
  final VoidCallback? onPressed;

  const ChannelToolbarIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.busy = false,
    this.selected = false,
  });

  @override
  State<ChannelToolbarIconButton> createState() =>
      _ChannelToolbarIconButtonState();
}

class _ChannelToolbarIconButtonState extends State<ChannelToolbarIconButton> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox.square(
        dimension: _toolbarControlHeight,
        child: IconButton.filledTonal(
          focusNode: _node,
          style: IconButton.styleFrom(
            backgroundColor: _focused ? AppColors.panelHi : AppColors.panel,
            foregroundColor: widget.selected
                ? AppColors.accent
                : AppColors.textHi,
            disabledBackgroundColor: AppColors.panel,
            disabledForegroundColor: AppColors.textLo,
            overlayColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(
                color: _focused || widget.selected
                    ? AppColors.accent
                    : AppColors.line,
                width: _focused ? 2 : 1,
              ),
            ),
          ),
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 20),
        ),
      ),
    );
  }
}

class ChannelCategoryDropdown extends StatelessWidget {
  final List<Category> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const ChannelCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // The selected id is restored before the categories arrive, and a provider
    // may also drop a category between sessions. `DropdownButton` asserts when
    // its value has no matching item (the transient red error screen), so a
    // value that is not in *this* list is shown as "All" until it appears.
    final selected = value != null && categories.any((c) => c.id == value)
        ? value
        : null;
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: selected,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: const Text(
          'All categories',
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All categories'),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// The phone/tablet **live** category control: a summary that opens a
/// checkbox sheet, because live supports a multi-select union (the media tabs
/// keep the single-category dropdown — their cache is keyed per category).
///
/// Tapping a row toggles it; "All channels" clears; Favorites stays exclusive
/// (it is a view, not a filter). A **long-press** on a row is "only this", and
/// the footer carries `Only <previous single>` — the one-press way back from a
/// union on a D-pad, where a long-press does not exist.
class ChannelCategoryMultiPicker extends StatelessWidget {
  final List<Category> categories;
  final String? selectedCategoryId;
  final Set<String> selectedCategoryIds;

  /// The synthetic Favorites id, passed in so this file needs no dependency on
  /// the controller's constants.
  final String favoritesCategoryId;

  /// The last single category (or null), offered as the one-tap "Only …".
  final String? previousSingleCategoryId;

  /// `(ids, exclusive)` — `exclusive` is a Favorites-style view id, or null for
  /// an ordinary union/single selection.
  final void Function(Set<String> ids, {String? exclusive}) onApply;

  const ChannelCategoryMultiPicker({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    required this.selectedCategoryIds,
    required this.favoritesCategoryId,
    required this.previousSingleCategoryId,
    required this.onApply,
  });

  String _titleFor(String id) {
    for (final category in categories) {
      if (category.id == id) return category.title;
    }
    return 'All categories';
  }

  String get _summary {
    if (selectedCategoryId != null) {
      return selectedCategoryId == favoritesCategoryId
          ? 'Favorites'
          : _titleFor(selectedCategoryId!);
    }
    if (selectedCategoryIds.length >= 2) {
      return '${selectedCategoryIds.length} categories';
    }
    if (selectedCategoryIds.length == 1) {
      return _titleFor(selectedCategoryIds.single);
    }
    return 'All categories';
  }

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      builder: (focusNode) => InkWell(
        focusNode: focusNode,
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: () => unawaited(_open(context)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textHi),
                ),
              ),
              const Icon(Icons.expand_more, color: AppColors.textLo),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    // State lives **outside** the `StatefulBuilder` closure: the builder re-runs
    // on every tap, so a set created inside it would forget the toggle and
    // rebuild the checkmarks from the original selection.
    final picked = Set<String>.of(selectedCategoryIds);
    String? exclusive = selectedCategoryId;

    final result = await showDialog<(Set<String>, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          void toggle(String? id) {
            setState(() {
              if (id == null) {
                picked.clear();
                exclusive = null;
              } else if (id == favoritesCategoryId) {
                picked.clear();
                exclusive = id;
              } else {
                exclusive = null;
                if (!picked.remove(id)) picked.add(id);
              }
            });
          }

          void only(String id) {
            Navigator.pop(
              context,
              id == favoritesCategoryId
                  ? (<String>{}, id)
                  : (<String>{id}, null),
            );
          }

          Widget row(String? id, String label) {
            final favorites = id != null && id == favoritesCategoryId;
            final checked = favorites
                ? exclusive == id
                : id == null
                ? picked.isEmpty && exclusive == null
                : picked.contains(id);
            return InkWell(
              borderRadius: BorderRadius.circular(AppRadius.tile),
              onTap: () => toggle(id),
              // Touch/mouse shortcut that mirrors the sidebar's long press.
              onLongPress: id == null ? null : () => only(id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: checked ? AppColors.textHi : AppColors.textLo,
                          fontWeight: checked
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(
                      // Square, like every other multi-select in the app: the
                      // round `check_circle`/`circle_outlined` pair read as a
                      // radio group, i.e. as "exactly one".
                      checked
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 22,
                      color: checked ? AppColors.accent : AppColors.textLo,
                    ),
                  ],
                ),
              ),
            );
          }

          final previous = previousSingleCategoryId;
          final onlyButton = previous == null || previous.isEmpty
              ? null
              : previous;
          return AlertDialog(
            backgroundColor: AppColors.panelHi,
            title: const Text('Categories'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    row(null, 'All channels'),
                    if (categories.any((c) => c.id == favoritesCategoryId))
                      row(favoritesCategoryId, 'Favorites'),
                    for (final category in categories)
                      if (category.id != favoritesCategoryId)
                        row(category.id, category.title),
                  ],
                ),
              ),
            ),
            actions: [
              // One press back to a single category — the D-pad path to what a
              // long press does on touch. Hidden when it would change nothing.
              if (onlyButton != null && onlyButton != selectedCategoryId)
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, (<String>{onlyButton}, null)),
                  child: Text(
                    'Only ${_titleFor(onlyButton)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, (picked, exclusive)),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    onApply(result.$1, exclusive: result.$2);
  }
}

class MediaCategoryDropdown extends StatelessWidget {
  final List<MediaCategory> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const MediaCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // The selected id is restored before the categories arrive, and a provider
    // may also drop a category between sessions. `DropdownButton` asserts when
    // its value has no matching item (the transient red error screen), so a
    // value that is not in *this* list is shown as "All" until it appears.
    final selected = value != null && categories.any((c) => c.id == value)
        ? value
        : null;
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: selected,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: const Text(
          'All categories',
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All categories'),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// The movies/series grid's ordering picker.
///
/// A dropdown beside the category picker rather than an icon + menu, because the
/// active order has to be answerable **without opening anything**: the same grid
/// silently reshuffled by a setting nobody can see is what this replaces, so the
/// current mode is the control's own label.
class MediaSortDropdown extends StatelessWidget {
  final MediaSort value;
  final ValueChanged<MediaSort> onChanged;

  const MediaSortDropdown({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      // Narrower than the category picker: the longest label is "Oldest first".
      maxWidth: 150,
      builder: (focusNode) => DropdownButton<MediaSort>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: value,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        items: [
          for (final mode in MediaSort.values)
            DropdownMenuItem<MediaSort>(
              value: mode,
              child: Text(
                mode.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (mode) {
          if (mode != null) onChanged(mode);
        },
      ),
    );
  }
}

class _DropdownFrame extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;
  final double maxWidth;

  const _DropdownFrame({required this.builder, this.maxWidth = 220});

  @override
  State<_DropdownFrame> createState() => _DropdownFrameState();
}

class _DropdownFrameState extends State<_DropdownFrame> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _toolbarControlHeight,
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : AppColors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => event is KeyRepeatEvent
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: DropdownButtonHideUnderline(child: widget.builder(_node)),
      ),
    );
  }
}
