import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../ui/shared/bottom_bars_gutter.dart';
import '../widgets/universal_song_tile.dart';

class SmartPlaylistPage extends StatelessWidget {
  const SmartPlaylistPage({
    super.key,
    required this.player,
    required this.title,
    required this.description,
    required this.icon,
    required this.songs,
    required this.librarySongs,
    required this.onQueueChanged,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    this.embeddedInHome = false,
    this.onClose,
    required this.onOpenNowPlaying,
    required this.onPlayAll,
    required this.onPlaySong,
  });

  final AudioPlayer player;
  final String title;
  final String description;
  final IconData icon;
  final List<SongModel> songs;
  final List<SongModel> librarySongs;
  final Function(List<SongModel>) onQueueChanged;
  final int selectedTabIndex;
  final ValueChanged<int> onNavigateTab;
  final bool embeddedInHome;
  final VoidCallback? onClose;
  final Function(SongModel) onOpenNowPlaying;
  final Future<void> Function()? onPlayAll;
  final Future<void> Function(SongModel) onPlaySong;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = '${songs.length} tracks';

    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverAppBar.large(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          expandedHeight: 166,
          collapsedHeight: 86,
          toolbarHeight: 86,
          scrolledUnderElevation: 0,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          forceMaterialTransparency: true,
          foregroundColor: cs.onSurface,
          leading: embeddedInHome
              ? IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: onClose,
                )
              : null,
          titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
          actions: [
            IconButton(
              tooltip: 'Play',
              onPressed: onPlayAll,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(icon, color: cs.onSurfaceVariant, size: 30),
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
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.4,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer.withValues(
                                alpha: isDark ? 0.25 : 0.55,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: cs.outlineVariant.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              subtitle,
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: cs.onSecondaryContainer.withValues(
                                      alpha: 0.92,
                                    ),
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (songs.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Nothing here yet')),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = songs[index];
                final artistText = (song.artist ?? '').trim().isEmpty
                    ? 'Unknown Artist'
                    : song.artist!.trim();
                final albumText = (song.album ?? '').trim().isEmpty
                    ? 'Unknown Album'
                    : song.album!.trim();

                return UniversalSongTile(
                  song: song,
                  title: song.title,
                  subtitle: artistText,
                  meta: albumText,
                  durationMs: song.duration,
                  circularArtwork: true,
                  artworkSize: 54,
                  showShadows: false,
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  borderRadius: BorderRadius.circular(20),
                  trailing: IconButton.filledTonal(
                    icon: const Icon(Icons.play_arrow_rounded),
                    tooltip: 'Play',
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      onPlaySong(song);
                    },
                  ),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onPlaySong(song);
                  },
                );
              },
              childCount: songs.length,
            ),
          ),
        buildBottomBarsGutter(context),
      ],
    );

    if (embeddedInHome) return content;

    return Scaffold(
      extendBody: true,
      bottomNavigationBar: StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (context, snapshot) {
          return buildDetailBottomBars(
            context: context,
            player: player,
            songs: librarySongs,
            currentIndex: snapshot.data ?? player.currentIndex,
            onQueueChanged: onQueueChanged,
            onOpenNowPlaying: onOpenNowPlaying,
            selectedTabIndex: selectedTabIndex,
            onNavigateTab: onNavigateTab,
          );
        },
      ),
      body: content,
    );
  }
}

