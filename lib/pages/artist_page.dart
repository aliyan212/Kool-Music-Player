import '../data/models/album_stat.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';
import '../main.dart';

class ArtistPage extends StatefulWidget {
  final AudioPlayer player;
  final String artistName;
  final List<ArtistAlbum> albums;
  final List<SongModel> librarySongs;
  final ConcatenatingAudioSource? playlist;
  final Function(List<SongModel>) onQueueChanged;
  final int selectedTabIndex;
  final ValueChanged<int> onNavigateTab;
  final bool embeddedInHome;
  final VoidCallback? onClose;
  final Function(SongModel) onOpenNowPlaying;
  final Function(SongModel) onOpenAlbum;
  final Future<void> Function()? onPlayAll;

  const ArtistPage({
    super.key,
    required this.player,
    required this.artistName,
    required this.albums,
    required this.librarySongs,
    required this.playlist,
    required this.onQueueChanged,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    this.embeddedInHome = false,
    this.onClose,
    required this.onOpenNowPlaying,
    required this.onOpenAlbum,
    required this.onPlayAll,
  });

  @override
  State<ArtistPage> createState() => _ArtistPageState();

  int _totalTracks() {
    int sum = 0;
    for (final a in albums) {
      sum += a.trackCount;
    }
    return sum;
  }

  int _totalDurationMs() {
    int sum = 0;
    for (final a in albums) {
      sum += a.totalDurationMs;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalTracks = _totalTracks();
    final totalMs = _totalDurationMs();
    final subtitle =
        '${albums.length} albums • $totalTracks tracks • ${formatTime(totalMs)}';

    final paletteAlbumId = albums.isNotEmpty ? albums.first.albumId : 0;

    final content = CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            elevation: 0,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            forceMaterialTransparency: true,
            foregroundColor: cs.onSurface,
            leading: (embeddedInHome || Navigator.of(context).canPop())
                ? IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                  )
                : null,
            title: Text(
              artistName,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            actions: [
              if (onPlayAll != null)
                IconButton(
                  tooltip: 'Play All',
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipOval(
                        child: FastArtworkWidget(
                          id: paletteAlbumId,
                          type: ArtworkType.ALBUM,
                          width: 86,
                          height: 86,
                          nullArtworkWidget: Container(
                            width: 86,
                            height: 86,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.person_rounded,
                              color: cs.onSurfaceVariant,
                              size: 34,
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
                              artistName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.4,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: cs.secondaryContainer.withValues(alpha: 0.52),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: cs.outlineVariant.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                subtitle,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSecondaryContainer
                                          .withValues(alpha: 0.92),
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
          SliverList.separated(
            itemCount: albums.length,
            separatorBuilder: (context, index) => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1),
            ),
            itemBuilder: (context, i) {
              final a = albums[i];
              final yearText = a.year > 0 ? a.year.toString() : '–';
              final meta =
                  '$yearText • ${a.trackCount} tracks • ${formatTime(a.totalDurationMs)}';
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 2,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: FastArtworkWidget(
                    id: a.albumId,
                    type: ArtworkType.ALBUM,
                    width: 52,
                    height: 52,
                    nullArtworkWidget: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.album_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                title: Text(
                  a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  HapticFeedback.selectionClick();
                  onOpenAlbum(a.representativeSong);
                },
              );
            },
          ),
          if (embeddedInHome)
            buildBottomBarsGutter(context)
          else
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
      );

    if (embeddedInHome) return content;

    return Scaffold(
      bottomNavigationBar: StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (context, snapshot) {
          return buildDetailBottomBars(
            context: context,
            player: player,
            songs: librarySongs,
            currentIndex: snapshot.data ?? player.currentIndex,
            playlist: playlist,
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

class _ArtistPageState extends State<ArtistPage> {
  @override
  Widget build(BuildContext context) {
    return widget.build(context);
  }
}

