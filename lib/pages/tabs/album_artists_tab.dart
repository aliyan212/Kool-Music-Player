import 'package:flutter/material.dart';
import '../../data/models/album_stat.dart';
import '../../data/models/sort_mode.dart';
import '../../utils/format_utils.dart';
import '../../ui/shared/fast_artwork_widget.dart';
import 'package:on_audio_query/on_audio_query.dart';

class AlbumArtistsTab extends StatelessWidget {
  final List<AlbumArtistStat> cachedAlbumArtists;
  final AlbumArtistsSort albumArtistsSort;
  final Function(AlbumArtistsSort) onSortChanged;
  final Function(String) onOpenArtistPageByName;

  const AlbumArtistsTab({
    super.key,
    required this.cachedAlbumArtists,
    required this.albumArtistsSort,
    required this.onSortChanged,
    required this.onOpenArtistPageByName,
  });

  @override
  Widget build(BuildContext context) {
  
    final artists = cachedAlbumArtists;

    String sortLabel(AlbumArtistsSort s) {
      switch (s) {
        case AlbumArtistsSort.nameAsc:
          return 'Name (A → Z)';
        case AlbumArtistsSort.nameDesc:
          return 'Name (Z → A)';
        case AlbumArtistsSort.mostAlbums:
          return 'Most albums';
        case AlbumArtistsSort.leastAlbums:
          return 'Least albums';
        case AlbumArtistsSort.mostTracks:
          return 'Most tracks';
        case AlbumArtistsSort.leastTracks:
          return 'Least tracks';
      }
    }

    final cs = Theme.of(context).colorScheme;

    return Scrollbar(
        child: CustomScrollView(
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
                PopupMenuButton<AlbumArtistsSort>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sort',
                  initialValue: albumArtistsSort,
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      onSortChanged(mode);
                      
                    });
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
                child: Center(child: Text('No artists found')),
              )
            else
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
                            onOpenArtistPageByName(stat.name);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    Icons.person_rounded,
                                    color: cs.onSurfaceVariant,
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
        ),
      );
  
  }
}
