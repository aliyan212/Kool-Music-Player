import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/app_state_controller.dart';
import '../../data/models/album_stat.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import '../../ui/shared/bottom_bars_gutter.dart';
import 'package:on_audio_query/on_audio_query.dart';

class AlbumsTab extends StatelessWidget {
  const AlbumsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateController.instance;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final albums = appState.cachedAlbums;
        final albumsSort = appState.albumsSort;

    String sortLabel(AlbumsSort s) {
      switch (s) {
        case AlbumsSort.titleAsc:
          return 'Title (A → Z)';
        case AlbumsSort.titleDesc:
          return 'Title (Z → A)';
        case AlbumsSort.artistAsc:
          return 'Artist (A → Z)';
        case AlbumsSort.artistDesc:
          return 'Artist (Z → A)';
        case AlbumsSort.yearAsc:
          return 'Year (Oldest First)';
        case AlbumsSort.yearDesc:
          return 'Year (Newest First)';
        case AlbumsSort.albumArtistYear:
          return 'Album Artist / Year';
        case AlbumsSort.mostTracks:
          return 'Most Tracks';
        case AlbumsSort.leastTracks:
          return 'Least Tracks';
      }
    }

    final cs = Theme.of(context).colorScheme;

    return Scrollbar(
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar.large(
              title: const Text('Albums'),
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
                PopupMenuButton<AlbumsSort>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sort',
                  initialValue: albumsSort,
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    appState.applyAlbumsSort(mode);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: AlbumsSort.titleAsc,
                      child: Text('Title (A → Z)'),
                    ),
                    PopupMenuItem(
                      value: AlbumsSort.titleDesc,
                      child: Text('Title (Z → A)'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: AlbumsSort.artistAsc,
                      child: Text('Artist (A → Z)'),
                    ),
                    PopupMenuItem(
                      value: AlbumsSort.artistDesc,
                      child: Text('Artist (Z → A)'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: AlbumsSort.yearDesc,
                      child: Text('Year (newest first)'),
                    ),
                    PopupMenuItem(
                      value: AlbumsSort.yearAsc,
                      child: Text('Year (oldest first)'),
                    ),
                    PopupMenuItem(
                      value: AlbumsSort.albumArtistYear,
                      child: Text('Album artist / year'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: AlbumsSort.mostTracks,
                      child: Text('Most tracks'),
                    ),
                    PopupMenuItem(
                      value: AlbumsSort.leastTracks,
                      child: Text('Least tracks'),
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
                  '${albums.length} albums • Sort: ${sortLabel(albumsSort)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (albums.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 80),
                    child: Text('No albums found'),
                  ),
                ),
              )
            else ...[
              SliverList(
                delegate: SliverChildBuilderDelegate((context, i) {
                  final album = albums[i];
                  final albumId = album.albumId;
                  final song = album.representativeSong;
                  final title = album.title;
                  final artist = album.artist;
                  final tracks = album.trackCount;
                  final year = album.year;

                  final subtitle = year > 0
                      ? '$artist • $tracks tracks • $year'
                      : '$artist • $tracks tracks';

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
                            appState.openAlbumPageFromSong(song);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: FastArtworkWidget(
                                    id: albumId,
                                    type: ArtworkType.ALBUM,
                                    width: 54,
                                    height: 54,
                                    nullArtworkWidget: Container(
                                      width: 54,
                                      height: 54,
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        Icons.album_rounded,
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
                                        title,
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
                }, childCount: albums.length),
              ),
              buildBottomBarsGutter(context),
            ],
          ],
        ),
      );
      },
    );
  }
}
