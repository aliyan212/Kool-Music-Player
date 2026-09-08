import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/playback_controller.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import '../../utils/format_utils.dart';

class LibraryTab extends StatelessWidget {
  final bool isVisible;
  final ScrollController scrollController;
  final bool isSelectionMode;
  final Set<int> selectedSongIds;
  final SearchController searchController;
  final ValueNotifier<bool> showSearchInAppBar;
  final List<SongModel> songs;
  final bool isLoading;
  final dynamic permissionState;
  final List<SongModel> cachedMostPlayed;
  final List<SongModel> cachedRecentlyPlayed;
  final List<SongModel> cachedRecentlyAdded;
  final PlaybackController controller;
  
  final VoidCallback onExitSelectionMode;
  final Future<bool> Function(List<int>) onAddSongsToPlaylist;
  final Function(int) onToggleSelectedSongId;
  final VoidCallback onEnterSelectionMode;
  final Function(SongModel) onOpenAlbumPageFromSong;
  final Function(SongModel) onOpenArtistPage;
  final Function(SongModel) onShowSongOptions;
  final Function(Widget) onShowInlineDetail;
  final VoidCallback onRefreshLibrary;

  const LibraryTab({
    super.key,
    required this.isVisible,
    required this.scrollController,
    required this.isSelectionMode,
    required this.selectedSongIds,
    required this.searchController,
    required this.showSearchInAppBar,
    required this.songs,
    required this.isLoading,
    required this.permissionState,
    required this.cachedMostPlayed,
    required this.cachedRecentlyPlayed,
    required this.cachedRecentlyAdded,
    required this.controller,
    required this.onExitSelectionMode,
    required this.onAddSongsToPlaylist,
    required this.onToggleSelectedSongId,
    required this.onEnterSelectionMode,
    required this.onOpenAlbumPageFromSong,
    required this.onOpenArtistPage,
    required this.onShowSongOptions,
    required this.onShowInlineDetail,
    required this.onRefreshLibrary,
  });

  @override
  Widget build(BuildContext context) {
  
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
                      onExitSelectionMode();
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
                            final didAdd = await onAddSongsToPlaylist(ids);
                            if (didAdd) onExitSelectionMode();
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
                                } else if (starts(s.artist))
                                  startMatches.add(s);
                                else if (contains(s.artist))
                                  containMatches.add(s);
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
                                } else if (starts(s.album))
                                  startMatches.add(s);
                                else if (contains(s.album))
                                  containMatches.add(s);
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
                                } else if (starts(s.title))
                                  startMatches.add(s);
                                else if (contains(s.title))
                                  containMatches.add(s);
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
                                  if (idx != -1) controller.playSong(idx);
                                },
                              ),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.closeView(song.title);
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (idx != -1) controller.playSong(idx);
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
                                onOpenAlbumPageFromSong(song);
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
                                _openArtistPageByName(name);
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
                      _applySort(mode);
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
                  PopupMenuButton<_AppMenuAction>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) {
                      HapticFeedback.selectionClick();
                      switch (action) {
                        case _AppMenuAction.refresh:
                          loadMusic();
                          break;
                        case _AppMenuAction.manageFolders:
                          _showManageFoldersDialog();
                          break;
                        case _AppMenuAction.toggleTheme:
                          themeNotifier.toggle();
                          break;
                        case _AppMenuAction.about:
                          _openAboutPage();
                          break;
                        case _AppMenuAction.quit:
                          _confirmQuit();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _AppMenuAction.refresh,
                        child: menuLabel(
                          Icons.refresh_rounded,
                          'Scan/Refresh Library',
                        ),
                      ),
                      PopupMenuItem(
                        value: _AppMenuAction.manageFolders,
                        child: menuLabel(
                          Icons.folder_copy_rounded,
                          'Manage Folders',
                        ),
                      ),
                      PopupMenuItem(
                        value: _AppMenuAction.toggleTheme,
                        child: menuLabel(
                          Icons.palette_rounded,
                          themeNotifier.themeMenuLabel,
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: _AppMenuAction.about,
                        child: menuLabel(Icons.info_outline_rounded, 'About'),
                      ),
                      PopupMenuItem(
                        value: _AppMenuAction.quit,
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
                              setState(() => searchController.clear()),
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
                final cs = Theme.of(context).colorScheme;

                // 1. Push the listeners DOWN to the individual item level
                return ValueListenableBuilder<int?>(
                  valueListenable: controller.currentSongIdNotifier,
                  builder: (context, currentSongId, _) {
                    return ValueListenableBuilder<int?>(
                      valueListenable: controller.currentPlayIndexNotifier,
                      builder: (context, currentPlayIndex, __) {
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

                            final tileColor = (isSelectionMode && isSelected)
                                ? Color.alphaBlend(
                                    cs.primaryContainer.withValues(
                                      alpha:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? 0.28
                                          : 0.55,
                                    ),
                                    cs.surface,
                                  )
                                : isCurrent
                                ? Color.alphaBlend(
                                    cs.secondaryContainer.withValues(
                                      alpha:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? 0.35
                                          : 0.55,
                                    ),
                                    cs.surface,
                                  )
                                : cs.surfaceContainerLow;

                            final borderColor = (isSelectionMode && isSelected)
                                ? cs.primary.withValues(
                                    alpha:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? 0.35
                                        : 0.30,
                                  )
                                : isCurrent
                                ? cs.secondary.withValues(
                                    alpha:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? 0.30
                                        : 0.22,
                                  )
                                : cs.outlineVariant.withValues(
                                    alpha:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? 0.28
                                        : 0.35,
                                  );

                            final artistText =
                                (song.artist ?? '').trim().isEmpty
                                ? 'Unknown Artist'
                                : song.artist!.trim();
                            final albumText = (song.album ?? '').trim().isEmpty
                                ? 'Unknown Album'
                                : song.album!.trim();
                            final durationText = song.duration == null
                                ? null
                                : formatTime(song.duration);
                            final metaText = albumText;

                            final baseShadows =
                                Theme.of(context).brightness == Brightness.dark
                                ? const <BoxShadow>[]
                                : [
                                    BoxShadow(
                                      blurRadius: 10,
                                      spreadRadius: -6,
                                      offset: const Offset(0, 6),
                                      color: Colors.black.withValues(
                                        alpha: isCurrent ? 0.12 : 0.08,
                                      ),
                                    ),
                                  ];
                            final highlightShadows = isCurrent
                                ? [
                                    BoxShadow(
                                      blurRadius: 18,
                                      spreadRadius: -8,
                                      offset: const Offset(0, 10),
                                      color: cs.primary.withValues(
                                        alpha:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? 0.28
                                            : 0.18,
                                      ),
                                    ),
                                  ]
                                : const <BoxShadow>[];

                            return RepaintBoundary(
                              key: ValueKey(song.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  decoration: ShapeDecoration(
                                    color: tileColor,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      side: BorderSide(
                                        color: borderColor,
                                        width: 1,
                                      ),
                                    ),
                                    shadows: <BoxShadow>[
                                      ...baseShadows,
                                      ...highlightShadows,
                                    ],
                                  ),
                                  child: Material(
                                    type: MaterialType.transparency,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: () {
                                        HapticFeedback.selectionClick();
                                        if (isSelectionMode) {
                                          onToggleSelectedSongId(song.id);
                                        } else {
                                          controller.playSong(index);
                                        }
                                      },
                                      onLongPress: () {
                                        HapticFeedback.mediumImpact();
                                        if (isSelectionMode) {
                                          onToggleSelectedSongId(song.id);
                                        } else {
                                          showSongOptionsSheet(
                                            context: context,
                                            song: song,
                                            index: index,
                                            onEnterSelectionMode: (songId) =>
                                                onEnterSelectionMode(
                                                  initialSongId: songId,
                                                ),
                                            onOpenNowPlaying: (s) =>
                                                _openNowPlaying(s),
                                            onOpenAlbum: (s) =>
                                                _openAlbumPageFromSong(s),
                                            onOpenArtist: (s) =>
                                                _openArtistPageFromSong(s),
                                            onSongUpdated:
                                                _updateSongMetadataInPlace,
                                            runWithPlaybackSuspended:
                                                _runWithPlaybackSuspendedForTagWrite,
                                            onPlaySong: () =>
                                                controller.playSong(index),
                                          );
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 14,
                                        ),
                                        child: Row(
                                          children: [
                                            Stack(
                                              children: [
                                                AnimatedScale(
                                                  scale: isCurrent ? 1.03 : 1.0,
                                                  duration: const Duration(
                                                    milliseconds: 220,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                  child: ClipOval(
                                                    child: FastArtworkWidget(
                                                      id: song.id,
                                                      type: ArtworkType.AUDIO,
                                                      width: 56,
                                                      height: 56,
                                                      nullArtworkWidget: Container(
                                                        width: 56,
                                                        height: 56,
                                                        decoration: BoxDecoration(
                                                          color: cs
                                                              .surfaceContainerHighest,
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                        child: Icon(
                                                          Icons
                                                              .music_note_rounded,
                                                          color: cs
                                                              .onSurfaceVariant,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                if (isSelectionMode)
                                                  Positioned(
                                                    left: 4,
                                                    top: 4,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            4,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Color.alphaBlend(
                                                          cs.surface.withValues(
                                                            alpha: 0.75,
                                                          ),
                                                          cs.surfaceContainerHigh,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              999,
                                                            ),
                                                        border: Border.all(
                                                          color: cs
                                                              .outlineVariant
                                                              .withValues(
                                                                alpha: 0.35,
                                                              ),
                                                        ),
                                                      ),
                                                      child: Icon(
                                                        isSelected
                                                            ? Icons
                                                                  .check_circle_rounded
                                                            : Icons
                                                                  .radio_button_unchecked_rounded,
                                                        size: 14,
                                                        color: isSelected
                                                            ? cs.primary
                                                            : cs.onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                if (isCurrent)
                                                  Positioned(
                                                    right: 4,
                                                    bottom: 4,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            4,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Color.alphaBlend(
                                                          cs.surface.withValues(
                                                            alpha: 0.75,
                                                          ),
                                                          cs.surfaceContainerHigh,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              999,
                                                            ),
                                                        border: Border.all(
                                                          color: cs
                                                              .outlineVariant
                                                              .withValues(
                                                                alpha: 0.35,
                                                              ),
                                                        ),
                                                      ),
                                                      child: Icon(
                                                        playing
                                                            ? Icons
                                                                  .graphic_eq_rounded
                                                            : Icons
                                                                  .pause_circle_filled_rounded,
                                                        size: 14,
                                                        color: cs.onSurface
                                                            .withValues(
                                                              alpha: 0.85,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(width: 14),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    song.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          letterSpacing: -0.05,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    artistText,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: cs
                                                              .onSurfaceVariant,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                        ),
                                                  ),
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          metaText,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: cs
                                                                    .onSurfaceVariant
                                                                    .withValues(
                                                                      alpha:
                                                                          0.75,
                                                                    ),
                                                              ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      SizedBox(
                                                        width: 48,
                                                        child: Text(
                                                          durationText ??
                                                              '--:--',
                                                          maxLines: 1,
                                                          textAlign:
                                                              TextAlign.right,
                                                          overflow: TextOverflow
                                                              .visible,
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .labelMedium
                                                              ?.copyWith(
                                                                color: cs
                                                                    .onSurfaceVariant
                                                                    .withValues(
                                                                      alpha:
                                                                          durationText ==
                                                                              null
                                                                          ? 0.45
                                                                          : 0.8,
                                                                    ),
                                                                fontFeatures:
                                                                    const [
                                                                      FontFeature.tabularFigures(),
                                                                    ],
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            isSelectionMode
                                                ? IconButton.filledTonal(
                                                    icon: Icon(
                                                      isSelected
                                                          ? Icons
                                                                .check_circle_rounded
                                                          : Icons
                                                                .radio_button_unchecked_rounded,
                                                    ),
                                                    tooltip: isSelected
                                                        ? 'Deselect'
                                                        : 'Select',
                                                    onPressed: () {
                                                      HapticFeedback.selectionClick();
                                                      onToggleSelectedSongId(
                                                        song.id,
                                                      );
                                                    },
                                                  )
                                                : IconButton.filledTonal(
                                                    icon: AnimatedSwitcher(
                                                      duration: const Duration(
                                                        milliseconds: 220,
                                                      ),
                                                      transitionBuilder:
                                                          (child, animation) {
                                                            return ScaleTransition(
                                                              scale: CurvedAnimation(
                                                                parent:
                                                                    animation,
                                                                curve: Curves
                                                                    .easeOutBack,
                                                              ),
                                                              child:
                                                                  FadeTransition(
                                                                    opacity:
                                                                        animation,
                                                                    child:
                                                                        child,
                                                                  ),
                                                            );
                                                          },
                                                      child: Icon(
                                                        icon,
                                                        key: ValueKey(icon),
                                                      ),
                                                    ),
                                                    tooltip: showPause
                                                        ? 'Pause'
                                                        : 'Play',
                                                    onPressed: () async {
                                                      HapticFeedback.selectionClick();
                                                      if (isCurrent) {
                                                        if (playing) {
                                                          await controller
                                                              .player
                                                              .pause();
                                                        } else {
                                                          await _ensureNotificationPermissionIfNeeded();
                                                          await controller
                                                              .player
                                                              .play();
                                                        }
                                                        return;
                                                      }
                                                      controller.playSong(
                                                        index,
                                                      );
                                                    },
                                                  ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
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
