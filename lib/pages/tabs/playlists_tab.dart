import 'package:flutter/material.dart';
import '../../data/models/user_playlist.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/playback_controller.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import '../../dialogs/playlist_dialogs.dart';

class PlaylistsTab extends StatelessWidget {
  final List<SongModel> cachedMostPlayed;
  final List<SongModel> cachedRecentlyPlayed;
  final List<SongModel> cachedRecentlyAdded;
  final List<SongModel> songs;
  final PlaybackController controller;
  final List<UserPlaylist> userPlaylists;
  final Map<String, int> cachedUserPlaylistTrackCounts;
  
  final Function(Widget) onShowInlineDetail;
  final Function(SongModel) onOpenNowPlaying;
  final int selectedTabIndex;
  final Function(int) onNavigateTab;
  final VoidCallback onCloseInlineDetail;
  final bool isSelectionMode;
  final VoidCallback onExitSelectionMode;
  final bool nowPlayingRouteActive;
  final Function(String) onPlaylistCreated;
  final Function(UserPlaylist) onOpenUserPlaylistPage;
  final VoidCallback onImportPlaylist;
  final Function(int, int) onReorderUserPlaylists;

  const PlaylistsTab({
    super.key,
    required this.cachedMostPlayed,
    required this.cachedRecentlyPlayed,
    required this.cachedRecentlyAdded,
    required this.songs,
    required this.controller,
    required this.userPlaylists,
    required this.cachedUserPlaylistTrackCounts,
    required this.onShowInlineDetail,
    required this.onOpenNowPlaying,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    required this.onCloseInlineDetail,
    required this.isSelectionMode,
    required this.onExitSelectionMode,
    required this.nowPlayingRouteActive,
    required this.onPlaylistCreated,
    required this.onOpenUserPlaylistPage,
    required this.onImportPlaylist,
    required this.onReorderUserPlaylists,
  });

  @override
  Widget build(BuildContext context) {
  
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

      onShowInlineDetail(
        SmartPlaylistPage(
          player: controller.player,
          title: title,
          description: description,
          icon: icon,
          songs: list,
          librarySongs: songs,
          playlist: controller.currentPlaylist,
          onQueueChanged: (_) {},
          selectedTabIndex: selectedTabIndex,
          onNavigateTab: (index) {
            if (!mounted) return;
            if (isSelectionMode) onExitSelectionMode();
            setState(() => selectedTabIndex = index);
          },
          embeddedInHome: true,
          onClose: onCloseInlineDetail,
          onOpenNowPlaying: (s) {
            if (nowPlayingRouteActive) {
              Navigator.of(context).pop();
              return;
            }
            onOpenNowPlaying(s);
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
                            onPlaylistCreated: onPlaylistCreated,
                          );
                          if (pl != null) onOpenUserPlaylistPage(pl);
                        },
                        onImportPlaylist: onImportPlaylist,
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
                onReorder: onReorderUserPlaylists,
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
                                  _renamePlaylist(userPlaylists[i], name),
                            ),
                            onDeleteClicked: () => confirmAndDeletePlaylist(
                              context,
                              userPlaylists[i],
                              onPlaylistDeleted: () =>
                                  _deletePlaylist(userPlaylists[i]),
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
                          _openUserPlaylistPage(userPlaylists[i]);
                        },
                      ),
                    ),
                ],
              ),
            ),
          buildBottomBarsGutter(context),
        ],
      );
  }

  Future<void> onOpenNowPlaying(SongModel song) async {
    if (!mounted) return;
    if (nowPlayingRouteActive) return;
    final lastClosed = _lastNowPlayingClosedAt;
    if (lastClosed != null &&
        DateTime.now().difference(lastClosed) <
            const Duration(milliseconds: 500)) {
      return;
    }

    nowPlayingRouteActive = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          barrierLabel: 'Now Playing',
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 350),
          pageBuilder: (_, __, ___) => NowPlayingPage(
            player: controller.player,
            song: song,
            songs: songs,
            playlist: controller.currentPlaylist,
            onQueueChanged: (_) {},
            onOpenAlbum: _openAlbumPageFromSong,
            onOpenArtist: _openArtistPageFromSong,
            onSongUpdated: _updateSongMetadataInPlace,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curve = CurveTween(curve: Curves.easeOutCubic);
            final fade = Tween<double>(begin: 0.0, end: 1.0).chain(curve);
            final scale = Tween<double>(begin: 0.95, end: 1.0).chain(curve);
            return FadeTransition(
              opacity: animation.drive(fade),
              child: ScaleTransition(
                scale: animation.drive(scale),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      nowPlayingRouteActive = false;
      _lastNowPlayingClosedAt = DateTime.now();
    }
  }

  void _openAlbumPageFromSong(SongModel song) {
    final albumId = song.albumId;
    if (albumId == null || albumId <= 0) return;

    final albumTitle = (song.album ?? '').trim().isEmpty
        ? 'Unknown Album'
        : song.album!.trim();
    final albumArtist =
        (song.getMap["album_artist"]?.toString().trim().isNotEmpty ?? false)
        ? song.getMap["album_artist"].toString().trim()
        : ((song.artist ?? '').trim().isEmpty
              ? 'Unknown Artist'
              : song.artist!.trim());

    // Use album identity key to group tracks with the same album artist + album
    // name, even if MediaStore assigned different album IDs (e.g. guest features).
    final targetKey = albumIdentityKey(song);
    final albumSongs = songs
        .where((s) => albumIdentityKey(s) == targetKey)
        .toList();
    albumSongs.sort(compareDiscAndTrack);

    onShowInlineDetail(
      AlbumPage(
        player: controller.player,
        albumId: albumId,
        albumTitle: albumTitle,
        albumArtist: albumArtist,
        songs: albumSongs,
        librarySongs: songs,
        playlist: controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: (index) {
          if (!mounted) return;
          if (isSelectionMode) onExitSelectionMode();
          setState(() => selectedTabIndex = index);
        },
        embeddedInHome: true,
        onClose: onCloseInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          onOpenNowPlaying(s);
        },
        onPlaySong: (s) async {
          final albumIndex = albumSongs.indexWhere((x) => x.id == s.id);
          if (albumIndex == -1) return;
          await controller.playFromQueue(albumSongs, initialIndex: albumIndex);
        },
        onShuffle: () async {
          if (albumSongs.isEmpty) return;
          final shuffled = List<SongModel>.from(albumSongs)..shuffle();
          await controller.playFromQueue(shuffled, initialIndex: 0);
        },
      ),
    );
  }

  void _openArtistPageFromSong(SongModel song) {
    final name = (song.artist ?? '').trim().isEmpty
        ? 'Unknown Artist'
        : song.artist!.trim();
    _openArtistPageByName(name);
  }

  void _openArtistPageByName(String artistName) {
    final normalizedArtist = artistName.trim();
    if (normalizedArtist.isEmpty) return;

    String norm(String? v) => (v ?? '').trim().toLowerCase();
    final target = norm(normalizedArtist);

    final artistSongs = songs
        .where((s) {
          final a = norm(s.artist);
          final aa = norm(albumArtistFor(s));
          return a == target || aa == target;
        })
        .toList(growable: false);

    if (artistSongs.isEmpty) return;

    // Group into albums by identity key (albumArtist + albumName) instead of
    // raw MediaStore albumId to prevent fragmentation from guest features.
    final Map<String, List<SongModel>> songsByAlbumKey = {};
    for (final s in artistSongs) {
      final key = albumIdentityKey(s);
      (songsByAlbumKey[key] ??= <SongModel>[]).add(s);
    }

    final albums = <ArtistAlbum>[];
    for (final entry in songsByAlbumKey.entries) {
      final songs = entry.value;
      songs.sort(compareDiscAndTrack);

      final title = (songs.first.album ?? '').trim().isEmpty
          ? 'Unknown Album'
          : songs.first.album!.trim();
      int year = 0;
      for (final s in songs) {
        final y = yearFromSong(s);
        if (y > 0 && (year == 0 || y < year)) year = y;
      }

      int totalMs = 0;
      for (final s in songs) {
        totalMs += (s.duration ?? 0);
      }

      // Use the first song's albumId as the representative for artwork lookups.
      final repAlbumId = songs.first.albumId ?? 0;

      albums.add(
        ArtistAlbum(
          albumId: repAlbumId,
          title: title,
          year: year,
          trackCount: songs.length,
          totalDurationMs: totalMs,
          representativeSong: songs.first,
        ),
      );
    }

    // Sort artist's albums chronologically by release year.
    albums.sort((a, b) {
      final ay = a.year == 0 ? 9999 : a.year;
      final by = b.year == 0 ? 9999 : b.year;
      final yc = ay.compareTo(by);
      if (yc != 0) return yc;
      final tc = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (tc != 0) return tc;
      return a.albumId.compareTo(b.albumId);
    });

    // Build album songs lookup by identity key for Play All.
    final albumKeyForAlbum = <int, String>{};
    for (final entry in songsByAlbumKey.entries) {
      final repId = entry.value.first.albumId ?? 0;
      albumKeyForAlbum[repId] = entry.key;
    }

    onShowInlineDetail(
      ArtistPage(
        player: controller.player,
        artistName: normalizedArtist,
        albums: albums,
        librarySongs: songs,
        playlist: controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: (index) {
          if (!mounted) return;
          if (isSelectionMode) onExitSelectionMode();
          setState(() => selectedTabIndex = index);
        },
        embeddedInHome: true,
        onClose: onCloseInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          onOpenNowPlaying(s);
        },
        onOpenAlbum: (s) => _openAlbumPageFromSong(s),
        onPlayAll: albums.isEmpty
            ? null
            : () async {
                final queue = <SongModel>[];
                for (final a in albums) {
                  final key = albumKeyForAlbum[a.albumId] ?? '';
                  final list = songsByAlbumKey[key] ?? const <SongModel>[];
                  final sorted = List<SongModel>.from(list);
                  sorted.sort(compareDiscAndTrack);
                  queue.addAll(sorted);
                }
                if (queue.isEmpty) return;
                await controller.playFromQueue(queue, initialIndex: 0);
              },
      ),
    );
  }
}

class _LibraryPermissionGate extends StatelessWidget {
  final _LibraryPermissionState state;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  const _LibraryPermissionGate({
    required this.state,
    required this.onGrant,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = switch (state) {
      _LibraryPermissionState.permanentlyDenied => 'Music access blocked',
      _LibraryPermissionState.denied => 'Allow access to your music',
      _LibraryPermissionState.unknown => 'Preparing your library',
      _LibraryPermissionState.granted => 'Ready',
    };

    final body = switch (state) {
      _LibraryPermissionState.permanentlyDenied =>
        'Permission was denied permanently. Open Settings and enable Music/Audio access to scan your library.',
      _LibraryPermissionState.denied =>
        'To show your on-device songs, the app needs permission to read your audio library. Nothing is uploaded.',
      _LibraryPermissionState.unknown =>
        'We’ll ask for access only when you’re ready.',
      _LibraryPermissionState.granted => '',
    };

    final primaryLabel = state == _LibraryPermissionState.permanentlyDenied
        ? 'Open Settings'
        : 'Grant access';
    final primaryAction = state == _LibraryPermissionState.permanentlyDenied
        ? onOpenSettings
        : onGrant;

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark
                          ? 0.25
                          : 0.6,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(
                    Icons.library_music_rounded,
                    size: 42,
                    color: cs.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                if (state == _LibraryPermissionState.unknown) ...[
                  const CircularProgressIndicator(),
                ] else ...[
                  FilledButton.icon(
                    onPressed: primaryAction,
                    icon: Icon(
                      state == _LibraryPermissionState.permanentlyDenied
                          ? Icons.settings_rounded
                          : Icons.lock_open_rounded,
                    ),
                    label: Text(primaryLabel),
                  ),
                  if (state != _LibraryPermissionState.permanentlyDenied) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: onOpenSettings,
                      child: const Text('Settings'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  }
}
