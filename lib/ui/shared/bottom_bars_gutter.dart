// ignore_for_file: deprecated_member_use
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/playback_controller.dart';
import '../../widgets/mini_player.dart';

/// Reserves scrollable space at the bottom of list pages so the last item can
/// be scrolled fully above the mini-player and the navigation bar, which are
/// overlaid on top of the body via `extendBody: true`.
///
/// The gutter grows when a song is loaded (mini-player visible) so the last
/// row is never hidden behind the player.
Widget buildBottomBarsGutter(
  BuildContext context, {
  bool includeMiniPlayer = true,
  double extraPadding = 0,
}) {
  // NavigationBar reserve: 80px M3 NavigationBar + 16px bottom breathing clearance.
  const double navBarReserve = 96;
  // MiniPlayer reserve: 80px card + 6px bottom margin + 8px dynamic inset buffer + 16px clearance.
  const double miniPlayerReserve = 110;
  final double bottomInset = MediaQuery.of(context).padding.bottom;
  return SliverToBoxAdapter(
    child: ValueListenableBuilder<int?>(
      valueListenable: playbackController.currentSongIdNotifier,
      builder: (context, songId, _) {
        final double gutter =
            bottomInset +
            navBarReserve +
            (includeMiniPlayer && songId != null ? miniPlayerReserve : 0) +
            extraPadding;
        return SizedBox(height: gutter);
      },
    ),
  );
}

Widget buildDetailBottomBars({
  required BuildContext context,
  required AudioPlayer player,
  required List<SongModel> songs,
  required int? currentIndex,
  required ConcatenatingAudioSource? playlist,
  required Function(List<SongModel>) onQueueChanged,
  required Function(SongModel) onOpenNowPlaying,
  required int selectedTabIndex,
  required ValueChanged<int> onNavigateTab,
}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      MiniPlayer(
        controller: playbackController,
        songs: songs,
        currentIndex: currentIndex,
        playlist: playlist,
        onQueueChanged: onQueueChanged,
        onTap: onOpenNowPlaying,
      ),
      ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: isDark ? 0.82 : 0.90),
              border: Border(
                top: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 6),
              child: NavigationBar(
                selectedIndex: selectedTabIndex,
                onDestinationSelected: (index) {
                  if (index == selectedTabIndex) return;
                  HapticFeedback.selectionClick();
                  onNavigateTab(index);
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.people_outline_rounded),
                    selectedIcon: Icon(Icons.people_rounded),
                    label: 'Album Artists',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.album_outlined),
                    selectedIcon: Icon(Icons.album_rounded),
                    label: 'Albums',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.queue_music_outlined),
                    selectedIcon: Icon(Icons.queue_music_rounded),
                    label: 'Playlists',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
