import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../data/app_settings_store.dart';
import '../player/tray.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

/// Global, profile-independent settings (docs/player.md "System tray icon").
///
/// Reachable from the avatar menu whatever profile is active: the settings made
/// here are device preferences, never per-profile ones, and they must keep
/// working across a profile switch.
class SettingsScreen extends StatefulWidget {
  final AppSettingsStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _closeToTray;
  bool? _randomZapping;
  bool? _alwaysOnTop;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final closeToTray = await widget.store.closeToTray();
    final randomZapping = await widget.store.randomZapping();
    final alwaysOnTop = await widget.store.alwaysOnTop();
    if (mounted) {
      setState(() {
        _closeToTray = closeToTray;
        _randomZapping = randomZapping;
        _alwaysOnTop = alwaysOnTop;
      });
    }
  }

  Future<void> _toggleCloseToTray() async {
    final next = !(_closeToTray ?? true);
    setState(() => _closeToTray = next);
    await widget.store.setCloseToTray(next);
    await applyCloseToTray(next);
  }

  Future<void> _toggleRandomZapping() async {
    final next = !(_randomZapping ?? false);
    setState(() => _randomZapping = next);
    await widget.store.setRandomZapping(next);
  }

  Future<void> _toggleAlwaysOnTop() async {
    final next = !(_alwaysOnTop ?? false);
    setState(() => _alwaysOnTop = next);
    alwaysOnTopEnabled.value = next;
    await widget.store.setAlwaysOnTop(next);
    // Turning it off mid-playback must drop the style immediately; turning it
    // on mid-playback must raise it. The active screen re-syncs on its next
    // playback-state change, but this applies the setting's own effect now.
    if (!next) {
      await applyAlwaysOnTop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            if (Platform.isWindows)
              _SettingTile(
                icon: Icons.close_fullscreen_outlined,
                title: 'Close to tray',
                subtitle:
                    'Closing the window hides it to the tray instead of '
                    'quitting. Quit from the tray icon menu, or the in-app exit.',
                trailing: (_closeToTray ?? true) ? 'On' : 'Off',
                onTap: _toggleCloseToTray,
              ),
            _SettingTile(
              icon: Icons.shuffle,
              title: 'Random zapping',
              subtitle:
                  'Zapping and the auto-switch timer pick a random channel '
                  'instead of the next one.',
              trailing: (_randomZapping ?? false) ? 'On' : 'Off',
              onTap: _toggleRandomZapping,
            ),
            if (Platform.isWindows)
              _SettingTile(
                icon: Icons.vertical_align_top,
                title: 'Always on top in fullscreen',
                subtitle:
                    'While fullscreen playback is active, the window stays '
                    'above other windows. The windowed preview stays normal.',
                trailing: (_alwaysOnTop ?? false) ? 'On' : 'Off',
                onTap: _toggleAlwaysOnTop,
              ),
          ],
        ),
      ),
    );
  }
}

/// A single focus-stop toggle row, mirroring the source-settings tiles so the
/// D-pad needs no sub-menu and the trailing indicator is a "On"/"Off" label
/// rather than a separately-focusable [Switch].
class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;
  final VoidCallback onTap;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onTap,
      scrollOnFocus: false,
      debugLabel: 'settings.$title',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textLo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              trailing,
              style: TextStyle(
                color: trailing == 'On'
                    ? AppColors.accent
                    : AppColors.textLo,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
