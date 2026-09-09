import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show lerpDouble;
import '../../pages/playlist_page.dart';
import '../../services/app_state_controller.dart';
import '../../data/models/user_playlist.dart';
import '../../services/playback_controller.dart';
import '../../dialogs/playlist_dialogs.dart';
import '../../ui/shared/bottom_bars_gutter.dart';

class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateController.instance;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final controller = playbackController;
    final cachedMostPlayed = appState.cachedMostPlayed;
    final cachedRecentlyPlayed = appState.cachedRecentlyPlayed;
    final cachedRecentlyAdded = appState.cachedRecentlyAdded;
    final songs = appState.songs;
    final userPlaylists = appState.userPlaylists;
    final cachedUserPlaylistTrackCounts = appState.cachedUserPlaylistTrackCounts;
    final selectedTabIndex = appState.selectedTabIndex;
    final nowPlayingRouteActive = appState.nowPlayingRouteActive;


    final cs = Theme.of(context).colorScheme;

    final mostPlayedList = cachedMostPlayed;
    final recentlyPlayedList = cachedRecentlyPlayed;
    final recentlyAddedList = cachedRecentlyAdded;

    void open(SmartPlaylistKind kind) {
      final (title, description, icon, list) = switch (kind) {
        SmartPlaylistKind.mostPlayed => (
          'Most played',
          'Your top tracks based on how often you play them',
          Icons.local_fire_department_rounded,
          mostPlayedList,
        ),
        SmartPlaylistKind.recentlyPlayed => (
          'Recently played',
          'Tracks you listened to recently on this device',
          Icons.history_rounded,
          recentlyPlayedList,
        ),
        SmartPlaylistKind.recentlyAdded => (
          'Recently added',
          'Tracks added in the last 30 days',
          Icons.new_releases_rounded,
          recentlyAddedList,
        ),
      };

      appState.showInlineDetail(
        SmartPlaylistPage(
          player: controller.player,
          title: title,
          description: description,
          icon: icon,
          songs: list,
          librarySongs: songs,
          onQueueChanged: (_) {},
          selectedTabIndex: selectedTabIndex,
          onNavigateTab: appState.selectTab,
          embeddedInHome: true,
          onClose: appState.closeInlineDetail,
          onOpenNowPlaying: (s) {
            if (nowPlayingRouteActive) {
              Navigator.of(context).pop();
              return;
            }
            appState.openNowPlaying(s);
          },
          onPlayAll: list.isEmpty
              ? null
              : () async {
                  await controller.playFromQueue(list, initialIndex: 0);
                },
          onPlaySong: (song) async {
            final idx = list.indexWhere((s) => s.id == song.id);
            if (idx == -1) return;
            await controller.playFromQueue(list, initialIndex: idx);
          },
        ),
      );
    }

    Widget playlistCard({
      required String title,
      required String subtitle,
      required IconData icon,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
      Widget? trailing,
    }) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.08,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    trailing ??
                        Icon(
                          Icons.chevron_right_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final mostPlayedCount = mostPlayedList.length;
    final recentlyPlayedCount = recentlyPlayedList.length;
    final recentlyAddedCount = recentlyAddedList.length;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
          SliverAppBar.large(
            title: const Text('Playlists'),
            expandedHeight: 166,
            collapsedHeight: 86,
            toolbarHeight: 86,
            backgroundColor: cs.surface.withValues(alpha: 0.90),
            surfaceTintColor: Colors.transparent,
            foregroundColor: cs.onSurface,
            titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search',
                onPressed: () {
                  HapticFeedback.selectionClick();
                  appState.openSearch();
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                'Smart playlists',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                playlistCard(
                  title: 'Most played',
                  subtitle: mostPlayedCount == 0
                      ? 'No play history yet — start listening to build this'
                      : '$mostPlayedCount tracks',
                  icon: Icons.local_fire_department_rounded,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    open(SmartPlaylistKind.mostPlayed);
                  },
                ),
                playlistCard(
                  title: 'Recently played',
                  subtitle: recentlyPlayedCount == 0
                      ? 'Nothing yet'
                      : '$recentlyPlayedCount tracks',
                  icon: Icons.history_rounded,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    open(SmartPlaylistKind.recentlyPlayed);
                  },
                ),
                playlistCard(
                  title: 'Recently added',
                  subtitle: recentlyAddedCount == 0
                      ? 'No songs added in the last 30 days'
                      : '$recentlyAddedCount tracks',
                  icon: Icons.new_releases_rounded,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    open(SmartPlaylistKind.recentlyAdded);
                  },
                ),
              ],
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Your playlists',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Create or import',
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      showCreateOrImportPlaylistSheet(
                        context,
                        onNewPlaylist: () async {
                          final pl = await promptCreatePlaylist(
                            context,
                            onPlaylistCreated: appState.createNewPlaylist,
                          );
                          if (pl != null) appState.openUserPlaylistPage(pl);
                        },
                        onImportPlaylist: appState.importM3uPlaylistFlow,
                      );
                    },
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
          ),
          if (userPlaylists.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Long-press a song → Select to create a playlist.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                proxyDecorator:
                    (Widget child, int index, Animation<double> animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (BuildContext context, Widget? child) {
                          final double animValue = Curves.easeOutBack.transform(
                            animation.value,
                          );
                          final double scale = lerpDouble(
                            1.0,
                            1.04,
                            animValue,
                          )!;
                          final cs = Theme.of(context).colorScheme;

                          return Transform.scale(
                            scale: scale,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withValues(
                                      alpha: 0.35 * animValue,
                                    ),
                                    blurRadius: 24 * animValue,
                                    spreadRadius: 2 * animValue,
                                    offset: Offset(0, 8 * animValue),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.2 * animValue,
                                    ),
                                    blurRadius: 12 * animValue,
                                    offset: Offset(0, 4 * animValue),
                                  ),
                                ],
                              ),
                              child: Opacity(
                                opacity: lerpDouble(1.0, 0.95, animValue)!,
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: child,
                      );
                    },
                onReorder: appState.reorderUserPlaylists,
                children: [
                  for (var i = 0; i < userPlaylists.length; i++)
                    KeyedSubtree(
                      key: ValueKey(userPlaylists[i].id),
                      child: playlistCard(
                        title: userPlaylists[i].name,
                        subtitle:
                            '${cachedUserPlaylistTrackCounts[userPlaylists[i].id] ?? 0} tracks',
                        icon: Icons.playlist_play_rounded,
                        onLongPress: () {
                          HapticFeedback.selectionClick();
                          showUserPlaylistActionsSheet(
                            context,
                            userPlaylists[i],
                            onRenameClicked: () => promptRenamePlaylist(
                              context,
                              userPlaylists[i],
                              onPlaylistRenamed: (name) =>
                                  appState.renamePlaylist(userPlaylists[i], name),
                            ),
                            onDeleteClicked: () => confirmAndDeletePlaylist(
                              context,
                              userPlaylists[i],
                              onPlaylistDeleted: () =>
                                  appState.deletePlaylist(userPlaylists[i]),
                            ),
                          );
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.chevron_right_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 4,
                                ),
                                child: Icon(
                                  Icons.drag_handle_rounded,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          appState.openUserPlaylistPage(userPlaylists[i]);
                        },
                      ),
                    ),
                ],
              ),
            ),
          buildBottomBarsGutter(context),
        ],
      );
      },
    );
  }
}
