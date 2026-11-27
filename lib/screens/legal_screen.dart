import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_links.dart';
import '../data/distribution_channel.dart';
import '../data/update_service.dart' show appVersion;
import '../data/update_store.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import 'update_flow.dart';

/// Help & about — reachable from the channel-list AppBar and the first-run
/// empty state. Intentionally link-based (no in-app feedback form, no
/// analytics): support and issue reporting live on the web / GitHub, in
/// keeping with the app being open-source.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  Future<void> _open(BuildContext context, String value) async {
    final opened = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the web page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & about')),
      // Edge-to-edge (targetSdk 35+): the AppBar consumes the top inset, but the
      // body would otherwise run under the gesture/3-button bar — which in
      // landscape sits on the *side*, hiding the cards' trailing link icons.
      body: SafeArea(
        top: false,
        // Capped and centred: this screen is entirely running prose, which is
        // unreadable stretched across a maximised desktop window.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kSettingsMaxContentWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'IPTVS Player is a free, open-source player for the IPTV sources you '
                  'already have access to. It ships no channels — bring your own '
                  'Stalker portal, Xtream account, or M3U playlist, or try the '
                  'built-in Demo (no account needed). Cloud sync is optional.',
                  style: TextStyle(color: AppColors.textLo),
                ),
                const SizedBox(height: 10),
                const Text(
                  'This build is a fork of the original IPTVS Player, maintained at '
                  'github.com/SNBogdanov/iptvs. The original project lives at '
                  'github.com/GCHOfficial/iptvs. Please report problems with this '
                  'build in the fork, not upstream.',
                  style: TextStyle(color: AppColors.textLo),
                ),
                const SizedBox(height: 16),
                // The in-app update controls live here rather than on Sources:
                // that screen is about provider accounts, and a "Check for
                // updates" row buried under them was reported as impossible to
                // find. Help & about is where a user looks for "is my app
                // current", and it is reachable from the channel list's Help
                // action. Hidden entirely for builds that do not own their
                // updates (development, AltStore) — the same gate the installer
                // and the startup check use.
                if (DistributionConfig.devBuild ||
                    DistributionConfig.channel.offersReleaseInstall) ...[
                  const Text(
                    'Updates',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  // A developer build — an iteration APK or a `.dev` build — is
                  // not the published release, so the question is not "is there
                  // something newer" but "put me back on the release". Same card
                  // for both: the action and the version rule are identical
                  // (`runReleaseInstall` installs an equal or newer release).
                  const _ReleaseInstallCard(),
                  const SizedBox(height: 16),
                ] else if (DistributionConfig.directUpdaterEnabled) ...[
                  const Text(
                    'Updates',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const _UpdateTrackCard(),
                  const SizedBox(height: 8),
                  const _UpdateCard(),
                  const SizedBox(height: 16),
                ],
                _LinkCard(
                  // A D-pad user entering this screen should land on a visible focus
                  // ring immediately, not on an unfocused scaffold.
                  autofocus: true,
                  icon: Icons.help_outline,
                  title: 'Support',
                  subtitle: 'Troubleshooting and contact information',
                  onTap: () => _open(context, AppLinks.support),
                ),
                // Above the repository link on purpose: someone opening this
                // screen for help wants the guides, not the source.
                _LinkCard(
                  icon: Icons.menu_book_outlined,
                  title: 'Knowledge base',
                  subtitle: 'Guides for setup, pairing, and the TV remote',
                  onTap: () => _open(context, AppLinks.website),
                ),
                _LinkCard(
                  icon: Icons.code,
                  title: 'This fork on GitHub',
                  subtitle: 'Source code and issue tracker for this build',
                  onTap: () => _open(context, AppLinks.repository),
                ),
                _LinkCard(
                  icon: Icons.fork_right,
                  title: 'Original project',
                  subtitle:
                      'Upstream IPTVS Player, which this fork is based on',
                  onTap: () => _open(context, AppLinks.upstreamRepository),
                ),
                _LinkCard(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Privacy policy',
                  subtitle: 'What the app stores and sends',
                  onTap: () => _open(context, AppLinks.privacyPolicy),
                ),
                _LinkCard(
                  icon: Icons.delete_outline,
                  title: 'Delete cloud account',
                  subtitle:
                      'Permanently remove an optional panel account and its cloud data',
                  onTap: () => _open(context, AppLinks.deleteCloudAccount),
                ),
                const SizedBox(height: 20),
                const _VersionLine(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single D-pad-navigable link row (FocusableCard so the OK-ring convention
/// and "OK to activate" behaviour match the rest of the TV-facing UI).
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    this.autofocus = false,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool autofocus;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap,
      scrollOnFocus: false,
      semanticsLabel: '$title. $subtitle. Opens in your browser.',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.textLo),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.open_in_new, size: 18, color: AppColors.textLo),
          ],
        ),
      ),
    );
  }
}

/// App version, read from package metadata. Useful in support requests; nothing
/// is sent anywhere.
class _VersionLine extends StatelessWidget {
  const _VersionLine();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: appVersion(),
      builder: (context, snapshot) {
        final version = snapshot.data;
        return Text(
          version == null ? 'IPTVS Player' : 'IPTVS Player $version',
          style: const TextStyle(color: AppColors.textLo, fontSize: 12),
        );
      },
    );
  }
}

/// Which GitHub release track this build follows (Stable / Beta).
///
/// Moved here from the Sources screen together with [_UpdateCard]: a TV user
/// looking for "is there a new version" opens Help & about, not the provider
/// list.
class _UpdateTrackCard extends StatefulWidget {
  const _UpdateTrackCard();

  @override
  State<_UpdateTrackCard> createState() => _UpdateTrackCardState();
}

class _UpdateTrackCardState extends State<_UpdateTrackCard> {
  UpdateTrack _track = UpdateTrack.stable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final track = await const UpdateStore().track();
    if (mounted) setState(() => _track = track);
  }

  Future<void> _choose() async {
    final selected = await showDialog<UpdateTrack>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: const Text('GitHub update track'),
        content: const Text(
          'Stable receives normal releases. Beta also receives signed GitHub '
          'prereleases intended for testing. Switching back to Stable never '
          'downgrades the app; it waits for a newer stable release.',
        ),
        actions: [
          TextButton(
            autofocus: _track == UpdateTrack.stable,
            onPressed: () => Navigator.pop(context, UpdateTrack.stable),
            child: const Text('Stable'),
          ),
          FilledButton(
            autofocus: _track == UpdateTrack.beta,
            onPressed: () => Navigator.pop(context, UpdateTrack.beta),
            child: const Text('Beta'),
          ),
        ],
      ),
    );
    if (selected == null || selected == _track) return;
    await const UpdateStore().setTrack(selected);
    if (mounted) setState(() => _track = selected);
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _choose,
      scrollOnFocus: false,
      debugLabel: 'help.updateTrack',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.science_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('GitHub update track'),
                  Text(
                    _track.displayName,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: AppColors.textLo),
          ],
        ),
      ),
    );
  }
}

/// "Check for updates" row. A single focus stop (like the update-track row);
/// OK/tap runs a manual GitHub check and drives the update flow. The hint shows
/// the running version (see [appVersion]).
class _UpdateCard extends StatefulWidget {
  const _UpdateCard();

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  String? _version; // null while loading
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final version = await appVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      // Leave the generic label if the platform version is unavailable.
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await runUpdateCheck(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _check,
      scrollOnFocus: false,
      debugLabel: 'help.checkUpdate',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.system_update_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Check for updates'),
                  Text(
                    _version == null ? 'Current version' : 'Version $_version',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textLo,
              ),
          ],
        ),
      ),
    );
  }
}

/// A **development build's** way back to the published release.
///
/// The ordinary updater is hidden here on purpose (a dev build owns no update
/// lifecycle), which left a side-loaded build with no in-app escape. This card
/// asks for the release explicitly: it checks `update.json`, refuses an older
/// release before downloading anything, and then reuses the verified
/// download+install path.
class _ReleaseInstallCard extends StatefulWidget {
  const _ReleaseInstallCard();

  @override
  State<_ReleaseInstallCard> createState() => _ReleaseInstallCardState();
}

class _ReleaseInstallCardState extends State<_ReleaseInstallCard> {
  bool _busy = false;

  Future<void> _install() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runReleaseInstall(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _install,
      scrollOnFocus: false,
      debugLabel: 'help.installRelease',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.science_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Return to release'),
                  Text(
                    'Developer build — install the published release',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            if (_busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textLo,
              ),
          ],
        ),
      ),
    );
  }
}
