import 'package:flutter/material.dart';

import '../player/channel_number_entry.dart';
import '../theme.dart';

/// The typed-number chip: the digits on the first line, the channel they
/// resolve to on the second.
///
/// One widget for both surfaces that accept a number — the live list and the
/// fullscreen player — because a chip is a thing the user learns once, and two
/// copies of it would drift (this one grew a second line; the other would not).
///
/// The second line is what makes a partial number usable: the digits alone
/// can't be read as a jump, so the match is shown *while* it is being typed and
/// the no-match case is explicit rather than a blank gap
/// ([kNoChannelNumberMatch]).
class ChannelNumberChip extends StatelessWidget {
  const ChannelNumberChip({
    required this.digits,
    required this.matchLabel,
    this.matched = false,
    super.key,
  });

  /// The digits typed so far, printed as `Ch <digits>`.
  final String digits;

  /// The name of the channel the digits currently resolve to, or
  /// [kNoChannelNumberMatch]. Pass [ChannelNumberEntry.matchLabel] straight
  /// through.
  final String matchLabel;

  /// Whether [matchLabel] is a real channel name rather than the no-match
  /// label — the second line is dimmed when nothing matches.
  final bool matched;

  /// Long names must not stretch the chip across the window; the digits are the
  /// input, the name is a confirmation of it.
  static const _maxNameWidth = 260.0;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ch $digits',
              style: const TextStyle(
                color: AppColors.textHi,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxNameWidth),
              child: Text(
                matchLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: matched ? AppColors.textHi : AppColors.textLo,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
