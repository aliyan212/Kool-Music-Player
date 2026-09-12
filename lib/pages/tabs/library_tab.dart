import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../../services/app_state_controller.dart';
import '../../data/models/sort_mode.dart';
import '../../main.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/playback_controller.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import '../../utils/format_utils.dart';
import '../../ui/shared/bottom_bars_gutter.dart';
import '../../widgets/universal_song_tile.dart';

enum AppMenuAction { refresh, manageFolders, toggleTheme, about, quit }

class LibraryTab extends StatelessWidget {
  final ScrollController scrollController;
  final SearchController searchController;
  final ValueNotifier<bool> showSearchInAppBar;

  const LibraryTab({
    super.key,
    required this.scrollController,
    required this.searchController,
    required this.showSearchInAppBar,
  });

  @override
  Widget build(BuildContext context) {
    final appState = AppStateController.instance;
    final controller = playbackController;
    final isVisible = appState.inlineDetailContent == null;
    final isSelectionMode = appState.isSelectionMode;
    final selectedSongIds = appState.selectedSongIds;
    final songs = appState.songs;

  
    final cs = Theme.of(context).colorScheme;

    Widget menuLabel(IconData icon, String label) {
      return Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label),
        ],
      );
    }

    return Scrollbar(
        controller: scrollController,
        interactive: true,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          // Helps avoid transient blanking while scrubbing the scrollbar quickly
          // by keeping more children alive and prefetched.
          cacheExtent: 1200,
          controller: scrollController,
          slivers: [
            SliverAppBar.large(
              title: isSelectionMode
                  ? Text('${selectedSongIds.length} selected')
                  : const Text('Library'),
              expandedHeight: 166,
              collapsedHeight: 86,
              toolbarHeight: 86,
              backgroundColor: cs.surface.withValues(alpha: 0.90),
              surfaceTintColor: Colors.transparent,
              centerTitle: false,
              foregroundColor: cs.onSurface,
              titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
              actions: [
                if (isSelectionMode) ...[
                  IconButton(
                    tooltip: 'Cancel',
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      appState.exitSelectionMode();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                  IconButton(
                    tooltip: 'Add to playlist',
                    onPressed: selectedSongIds.isEmpty
                        ? null
                        : () async {
                            HapticFeedback.selectionClick();
                            final ids = selectedSongIds.toList(
                              growable: false,
                            );
                            final didAdd = await appState.addSongsToPlaylistFlow(ids);
                            if (didAdd) appState.exitSelectionMode();
                          },
                    icon: const Icon(Icons.playlist_add_rounded),
                  ),
                ] else ...[
                  // Search "collapses" into this button when scrolled.
                  SearchAnchor(
                    searchController: searchController,
                    viewBackgroundColor: cs.surface,
                    viewSurfaceTintColor: Colors.transparent,
                    dividerColor: cs.outlineVariant.withValues(alpha: 0.28),
                    builder: (context, controller) {
                      return ValueListenableBuilder<bool>(
                        valueListenable: showSearchInAppBar,
                        builder: (context, showSearch, _) {
                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: showSearch
                                ? IconButton(
                                    key: const ValueKey('search_on'),
                                    icon: const Icon(Icons.search_rounded),
                                    tooltip: 'Search',
                                    onPressed: () {
                                      HapticFeedback.selectionClick();
                                      controller.openView();
                                    },
                                  )
                                : const SizedBox.shrink(
                                    key: ValueKey('search_off'),
                                  ),
                          );
                        },
                      );
                    },
                    suggestionsBuilder: (context, controller) {
                      final cs = Theme.of(context).colorScheme;
                      final q = controller.text.trim().toLowerCase();

                      String norm(String? v) => (v ?? '').trim().toLowerCase();
                      bool starts(String? v) => norm(v).startsWith(q);
                      bool contains(String? v) => norm(v).contains(q);
                      bool exact(String? v) => q.isNotEmpty && norm(v) == q;

                      // Artist hits (unique by artist name)
                      final Map<String, SongModel> firstSongByArtist = {};
                      for (final s in songs) {
                        final name = (s.artist ?? '').trim();
                        if (name.isEmpty) continue;
                        firstSongByArtist.putIfAbsent(
                          name.toLowerCase(),
                          () => s,
                        );
                      }

                      final artistHits = q.isEmpty
                          ? firstSongByArtist.values
                                .take(6)
                                .toList(growable: false)
                          : () {
                              final exactMatches = <SongModel>[];
                              final startMatches = <SongModel>[];
                              final containMatches = <SongModel>[];
                              for (final s in firstSongByArtist.values) {
                                if (exact(s.artist)) {
                                  exactMatches.add(s);
                                } else if (starts(s.artist)) {
                                  startMatches.add(s);
                                } else if (contains(s.artist)) {
                                  containMatches.add(s);
                                }
                              }
                              return [
                                ...exactMatches,
                                ...startMatches,
                                ...containMatches,
                              ].take(10).toList(growable: false);
                            }();

                      // Album hits (unique by albumId)
                      final Map<int, SongModel> firstSongByAlbumId = {};
                      for (final s in songs) {
                        final albumId = s.albumId;
                        if (albumId == null || albumId <= 0) continue;
                        firstSongByAlbumId.putIfAbsent(albumId, () => s);
                      }

                      final albumHits = q.isEmpty
                          ? firstSongByAlbumId.values
                                .take(6)
                                .toList(growable: false)
                          : () {
                              final exactMatches = <SongModel>[];
                              final startMatches = <SongModel>[];
                              final containMatches = <SongModel>[];
                              for (final s in firstSongByAlbumId.values) {
                                if (exact(s.album)) {
                                  exactMatches.add(s);
                                } else if (starts(s.album)) {
                                  startMatches.add(s);
                                } else if (contains(s.album)) {
                                  containMatches.add(s);
                                }
                              }
                              return [
                                ...exactMatches,
                                ...startMatches,
                                ...containMatches,
                              ].take(10).toList(growable: false);
                            }();

                      // Track hits (The biggest performance gain)
                      final trackHits = q.isEmpty
                          ? songs.take(12).toList(growable: false)
                          : () {
                              final exactMatches = <SongModel>[];
                              final startMatches = <SongModel>[];
                              final containMatches = <SongModel>[];
                              for (final s in songs) {
                                if (exact(s.title)) {
                                  exactMatches.add(s);
                                } else if (starts(s.title)) {
                                  startMatches.add(s);
                                } else if (contains(s.title)) {
                                  containMatches.add(s);
                                }
                              }
                              return [
                                ...exactMatches,
                                ...startMatches,
                                ...containMatches,
                              ].take(20).toList(growable: false);
                            }();

                      Widget header(String text) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Text(
                            text,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                          ),
                        );
                      }

                      Widget searchResultTile({
                        required Widget leading,
                        required Widget title,
                        Widget? subtitle,
                        Widget? trailing,
                        required VoidCallback onTap,
                      }) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: cs.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: BorderSide(
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: onTap,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      leading,
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            DefaultTextStyle(
                                              style:
                                                  Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        letterSpacing: -0.1,
                                                      ) ??
                                                  const TextStyle(),
                                              child: title,
                                            ),
                                            if (subtitle != null) ...[
                                              const SizedBox(height: 2),
                                              DefaultTextStyle(
                                                style:
                                                    Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: cs
                                                              .onSurfaceVariant,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ) ??
                                                    const TextStyle(),
                                                child: subtitle,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      if (trailing != null) ...[
                                        const SizedBox(width: 10),
                                        trailing,
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      final widgets = <Widget>[];

                      final hasExactTrack =
                          q.isNotEmpty && songs.any((s) => exact(s.title));
                      final hasExactAlbum =
                          q.isNotEmpty &&
                          firstSongByAlbumId.values.any((s) => exact(s.album));
                      final hasExactArtist =
                          q.isNotEmpty &&
                          firstSongByArtist.values.any((s) => exact(s.artist));

                      void addTracks() {
                        if (trackHits.isEmpty) return;
                        widgets.add(header('Tracks'));
                        for (final song in trackHits) {
                          final idx = songs.indexWhere((s) => s.id == song.id);
                          final artist = (song.artist ?? '').trim().isEmpty
                              ? 'Unknown Artist'
                              : song.artist!.trim();
                          final album = (song.album ?? '').trim().isEmpty
                              ? 'Unknown Album'
                              : song.album!.trim();
                          final duration = song.duration == null
                              ? null
                              : formatTime(song.duration);
                          final subtitle = duration == null
                              ? '$artist • $album'
                              : '$artist • $album • $duration';
                          widgets.add(
                            searchResultTile(
                              leading: ClipOval(
                                child: FastArtworkWidget(
                                  id: song.id,
                                  type: ArtworkType.AUDIO,
                                  width: 52,
                                  height: 52,
                                  nullArtworkWidget: Container(
                                    width: 52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: cs.surfaceContainerHighest,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      color: cs.onSurfaceVariant,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton.filledTonal(
                                icon: const Icon(Icons.play_arrow_rounded),
                                tooltip: 'Play',
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  controller.closeView(song.title);
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  if (idx != -1) playbackController.playFromQueue(songs, initialIndex: idx);
                                },
                              ),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.closeView(song.title);
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (idx != -1) playbackController.playFromQueue(songs, initialIndex: idx);
                              },
                            ),
                          );
                        }
                      }

                      void addAlbums() {
                        if (albumHits.isEmpty) return;
                        widgets.add(header('Albums'));
                        for (final song in albumHits) {
                          final albumId = song.albumId ?? 0;
                          final albumTitle = song.album ?? 'Unknown Album';
                          widgets.add(
                            searchResultTile(
                              leading: ClipOval(
                                child: FastArtworkWidget(
                                  id: albumId,
                                  type: ArtworkType.ALBUM,
                                  width: 52,
                                  height: 52,
                                  nullArtworkWidget: Container(
                                    width: 52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: cs.surfaceContainerHighest,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.album_rounded,
                                      color: cs.onSurfaceVariant,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                albumTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                song.artist ?? 'Unknown',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.closeView(albumTitle);
                                FocusManager.instance.primaryFocus?.unfocus();
                                appState.openAlbumPageFromSong(song);
                              },
                            ),
                          );
                        }
                      }

                      void addArtists() {
                        if (artistHits.isEmpty) return;
                        widgets.add(header('Artists'));
                        for (final song in artistHits) {
                          final name = (song.artist ?? '').trim();
                          if (name.isEmpty) continue;
                          widgets.add(
                            searchResultTile(
                              leading: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  Icons.person_rounded,
                                  color: cs.onSurfaceVariant,
                                  size: 22,
                                ),
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: const Text(
                                'Artist',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.closeView(name);
                                FocusManager.instance.primaryFocus?.unfocus();
                                appState.openArtistPageByName(name);
                              },
                            ),
                          );
                        }
                      }

                      // Section ordering:
                      // - Prefer exact matches: if exact album -> albums first; if exact artist -> artists first.
                      // - If all three have exact matches: Tracks -> Albums -> Artists.
                      // - Otherwise default: Tracks -> Albums -> Artists.
                      if (q.isEmpty) {
                        addTracks();
                        addAlbums();
                        addArtists();
                      } else if (hasExactTrack &&
                          hasExactAlbum &&
                          hasExactArtist) {
                        addTracks();
                        addAlbums();
                        addArtists();
                      } else if (hasExactAlbum && !hasExactTrack) {
                        addAlbums();
                        addTracks();
                        addArtists();
                      } else if (hasExactArtist &&
                          !hasExactTrack &&
                          !hasExactAlbum) {
                        addArtists();
                        addTracks();
                        addAlbums();
                      } else {
                        addTracks();
                        addAlbums();
                        addArtists();
                      }

                      if (widgets.isEmpty) {
                        widgets.add(
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              q.isEmpty
                                  ? 'Start typing to search.'
                                  : 'No results for "$q".',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        );
                      }

                      return widgets;
                    },
                  ),
                  PopupMenuButton<SortMode>(
                    icon: const Icon(Icons.sort_rounded),
                    initialValue: controller.sortMode,
                    tooltip: 'Sort library',
                    onSelected: (mode) {
                      HapticFeedback.selectionClick();
                      appState.applySort(mode);
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: SortMode.artist,
                        child: menuLabel(
                          Icons.person_rounded,
                          'Sort by Artist',
                        ),
                      ),
                      PopupMenuItem(
                        value: SortMode.albumArtist,
                        child: menuLabel(
                          Icons.person_outline_rounded,
                          'Sort by Album Artist',
                        ),
                      ),
                      PopupMenuItem(
                        value: SortMode.year,
                        child: menuLabel(Icons.event_rounded, 'Sort by Year'),
                      ),
                      PopupMenuItem(
                        value: SortMode.albumArtistYear,
                        child: menuLabel(
                          Icons.calendar_view_month_rounded,
                          'Sort by Album Artist/Year',
                        ),
                      ),
                    ],
                  ),
                  PopupMenuButton<AppMenuAction>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) {
                      HapticFeedback.selectionClick();
                      switch (action) {
                        case AppMenuAction.refresh:
                          appState.ensureLibraryPermissionAndLoad();
                          break;
                        case AppMenuAction.manageFolders:
                          appState.openManageFoldersDialog();
                          break;
                        case AppMenuAction.toggleTheme:
                          themeNotifier.toggle();
                          break;
                        case AppMenuAction.about:
                          appState.openAboutPage();
                          break;
                        case AppMenuAction.quit:
                          appState.confirmQuit();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: AppMenuAction.refresh,
                        child: menuLabel(
                          Icons.refresh_rounded,
                          'Scan/Refresh Library',
                        ),
                      ),
                      PopupMenuItem(
                        value: AppMenuAction.manageFolders,
                        child: menuLabel(
                          Icons.folder_copy_rounded,
                          'Manage Folders',
                        ),
                      ),
                      PopupMenuItem(
                        value: AppMenuAction.toggleTheme,
                        child: menuLabel(
                          Icons.palette_rounded,
                          themeNotifier.themeMenuLabel,
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: AppMenuAction.about,
                        child: menuLabel(Icons.info_outline_rounded, 'About'),
                      ),
                      PopupMenuItem(
                        value: AppMenuAction.quit,
                        child: Row(
                          children: [
                            Icon(
                              Icons.power_settings_new_rounded,
                              size: 18,
                              color: cs.error,
                            ),
                            const SizedBox(width: 12),
                            Text('Quit', style: TextStyle(color: cs.error)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (!isSelectionMode)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: SearchBar(
                    controller: searchController,
                    hintText: 'Search songs',
                    leading: const Icon(Icons.search_rounded),
                    trailing: [
                      if (searchController.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () =>
                              searchController.clear(),
                        ),
                    ],
                    onTap: () {
                      HapticFeedback.selectionClick();
                      searchController.openView();
                    },
                    onTapOutside: (_) {
                      if (searchController.isOpen) {
                        searchController.closeView(searchController.text);
                      }
                      FocusManager.instance.primaryFocus?.unfocus();
                    },
                  ),
                ),
              ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = songs[index];
                final isSelected = selectedSongIds.contains(song.id);

                // 1. Push the listeners DOWN to the individual item level
                return ValueListenableBuilder<int?>(
                  valueListenable: controller.currentSongIdNotifier,
                  builder: (context, currentSongId, _) {
                    return ValueListenableBuilder<int?>(
                      valueListenable: controller.currentPlayIndexNotifier,
                      builder: (context, currentPlayIndex, _) {
                        final isCurrent = currentSongId != null
                            ? currentSongId == song.id
                            : currentPlayIndex == index;

                        // 2. ONLY listen to the player state stream if THIS song is the active one!
                        // This avoids dozens of inactive tiles needlessly rebuilding on Play/Pause.
                        return StreamBuilder<PlayerState>(
                          stream: (isCurrent && isVisible)
                              ? controller.player.playerStateStream
                              : null,
                          builder: (context, snap) {
                            final playing = isCurrent
                                ? (snap.data?.playing ??
                                      controller.player.playing)
                                : false;
                            final showPause = isCurrent && playing;
                            final icon = showPause
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded;

                            final artistText =
                                (song.artist ?? '').trim().isEmpty
                                ? 'Unknown Artist'
                                : song.artist!.trim();
                            final albumText = (song.album ?? '').trim().isEmpty
                                ? 'Unknown Album'
                                : song.album!.trim();

                            final trailing = isSelectionMode
                                ? IconButton.filledTonal(
                                    icon: Icon(
                                      isSelected
                                          ? Icons.check_circle_rounded
                                          : Icons.radio_button_unchecked_rounded,
                                    ),
                                    tooltip: isSelected ? 'Deselect' : 'Select',
                                    onPressed: () {
                                      HapticFeedback.selectionClick();
                                      appState.toggleSelectedSongId(song.id);
                                    },
                                  )
                                : IconButton.filledTonal(
                                    icon: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      transitionBuilder: (child, animation) {
                                        return ScaleTransition(
                                          scale: CurvedAnimation(
                                            parent: animation,
                                            curve: Curves.easeOutBack,
                                          ),
                                          child: FadeTransition(
                                            opacity: animation,
                                            child: child,
                                          ),
                                        );
                                      },
                                      child: Icon(
                                        icon,
                                        key: ValueKey(icon),
                                      ),
                                    ),
                                    tooltip: showPause ? 'Pause' : 'Play',
                                    onPressed: () async {
                                      HapticFeedback.selectionClick();
                                      if (isCurrent) {
                                        if (playing) {
                                          await controller.player.pause();
                                        } else {
                                          await appState
                                              .checkNotificationPermission();
                                          await controller.player.play();
                                        }
                                        return;
                                      }
                                      controller.playSong(index);
                                    },
                                  );

                            return UniversalSongTile(
                              song: song,
                              title: song.title,
                              subtitle: artistText,
                              meta: albumText,
                              durationMs: song.duration,
                              isCurrent: isCurrent,
                              isPlaying: playing,
                              isSelected: isSelected,
                              isSelectionMode: isSelectionMode,
                              circularArtwork: true,
                              artworkSize: 56,
                              showArtworkBadges: true,
                              showShadows: true,
                              trailing: trailing,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                if (isSelectionMode) {
                                  appState.toggleSelectedSongId(song.id);
                                } else {
                                  controller.playSong(index);
                                }
                              },
                              onLongPress: () {
                                HapticFeedback.mediumImpact();
                                if (isSelectionMode) {
                                  appState.toggleSelectedSongId(song.id);
                                } else {
                                  appState.showSongOptions(song, index);
                                }
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              }, childCount: songs.length),
            ),
            buildBottomBarsGutter(context),
          ],
        ),
      );
  
  }
}
