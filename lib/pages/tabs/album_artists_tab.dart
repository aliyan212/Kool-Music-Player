import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/app_state_controller.dart';
import '../../data/models/album_stat.dart';
import '../../ui/shared/bottom_bars_gutter.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import '../../utils/song_sort_utils.dart';

class AlbumArtistsTab extends StatelessWidget {
  const AlbumArtistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateController.instance;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final cachedAlbumArtists = appState.cachedAlbumArtists;
        final albumArtistsSort = appState.albumArtistsSort;

  
    final artists = cachedAlbumArtists;

    String sortLabel(AlbumArtistsSort s) {
      switch (s) {
        case AlbumArtistsSort.nameAsc:
          return 'Name (A → Z)';
        case AlbumArtistsSort.nameDesc:
          return 'Name (Z → A)';
        case AlbumArtistsSort.mostAlbums:
          return 'Most Albums';
        case AlbumArtistsSort.leastAlbums:
          return 'Least Albums';
        case AlbumArtistsSort.mostTracks:
          return 'Most Tracks';
        case AlbumArtistsSort.leastTracks:
          return 'Least Tracks';
      }
    }

    final cs = Theme.of(context).colorScheme;

    return Scrollbar(
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar.large(
              title: const Text('Album Artists'),
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
                PopupMenuButton<AlbumArtistsSort>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sort',
                  initialValue: albumArtistsSort,
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    appState.applyAlbumArtistsSort(mode);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: AlbumArtistsSort.nameAsc,
                      child: Text('Name (A → Z)'),
                    ),
                    PopupMenuItem(
                      value: AlbumArtistsSort.nameDesc,
                      child: Text('Name (Z → A)'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: AlbumArtistsSort.mostAlbums,
                      child: Text('Most Albums'),
                    ),
                    PopupMenuItem(
                      value: AlbumArtistsSort.leastAlbums,
                      child: Text('Least Albums'),
                    ),
                    PopupMenuItem(
                      value: AlbumArtistsSort.mostTracks,
                      child: Text('Most Tracks'),
                    ),
                    PopupMenuItem(
                      value: AlbumArtistsSort.leastTracks,
                      child: Text('Least Tracks'),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(
                  '${artists.length} artists • Sort: ${sortLabel(albumArtistsSort)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (artists.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 80),
                    child: Text('No artists found'),
                  ),
                ),
              )
            else ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, i) {
                  final stat = artists[i];
                  final subtitle =
                      '${stat.albumCount} albums • ${stat.trackCount} tracks';

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: cs.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: cs.outlineVariant.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            appState.openArtistPageByName(stat.name);
                          },
                          onLongPress: () {
                            HapticFeedback.mediumImpact();
                            _showArtistOptionsModal(context, appState, stat);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: FastArtworkWidget(
                                    id: stat.representativeSong?.albumId ??
                                        stat.representativeSong?.id ??
                                        0,
                                    type: ArtworkType.ALBUM,
                                    width: 48,
                                    height: 48,
                                    nullArtworkWidget: Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(
                                        Icons.person_rounded,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        stat.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: -0.1,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
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
                }, childCount: artists.length),
              ),
              buildBottomBarsGutter(context),
            ],
          ],
        ),
      );
      },
    );
  }

  void _showArtistOptionsModal(
    BuildContext context,
    AppStateController appState,
    AlbumArtistStat stat,
  ) {
    final cs = Theme.of(context).colorScheme;
    final repId = stat.representativeSong?.albumId ??
        stat.representativeSong?.id ??
        0;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: FastArtworkWidget(
                          id: repId,
                          type: ArtworkType.ALBUM,
                          width: 48,
                          height: 48,
                          nullArtworkWidget: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.person_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              stat.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${stat.albumCount} albums • ${stat.trackCount} tracks',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 16),
                ListTile(
                  leading: const Icon(Icons.person_rounded),
                  title: const Text('Open Artist'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    appState.openArtistPageByName(stat.name);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('Play All'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final target = stat.name.toLowerCase().trim();
                    final artistSongs = appState.songs.where((s) {
                      final a = (s.artist ?? '').toLowerCase().trim();
                      final aa = albumArtistFor(s).toLowerCase().trim();
                      return a == target || aa == target;
                    }).toList();
                    if (artistSongs.isNotEmpty) {
                      await appState.playFromQueue(artistSongs, initialIndex: 0);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.shuffle_rounded),
                  title: const Text('Shuffle All'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final target = stat.name.toLowerCase().trim();
                    final artistSongs = appState.songs.where((s) {
                      final a = (s.artist ?? '').toLowerCase().trim();
                      final aa = albumArtistFor(s).toLowerCase().trim();
                      return a == target || aa == target;
                    }).toList();
                    if (artistSongs.isNotEmpty) {
                      artistSongs.shuffle();
                      await appState.playFromQueue(artistSongs, initialIndex: 0);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
