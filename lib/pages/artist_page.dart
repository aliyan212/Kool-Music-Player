import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../data/models/album_stat.dart';
import '../dialogs/batch_tag_editor_dialog.dart';
import '../services/app_state_controller.dart';
import '../services/playback_controller.dart';
import '../ui/shared/bottom_bars_gutter.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';
import '../utils/palette_compute.dart';
import '../utils/song_sort_utils.dart';
import '../widgets/universal_song_tile.dart';

class ArtistPage extends StatefulWidget {
  final AudioPlayer player;
  final String artistName;
  final List<ArtistAlbum> albums;
  final List<SongModel> librarySongs;
  final List<SongModel>? artistSongs;
  final Function(List<SongModel>) onQueueChanged;
  final int selectedTabIndex;
  final ValueChanged<int> onNavigateTab;
  final bool embeddedInHome;
  final VoidCallback? onClose;
  final Function(SongModel) onOpenNowPlaying;
  final Function(SongModel) onOpenAlbum;
  final Future<void> Function()? onPlayAll;
  final Future<void> Function()? onShuffleAll;

  const ArtistPage({
    super.key,
    required this.player,
    required this.artistName,
    required this.albums,
    required this.librarySongs,
    this.artistSongs,
    required this.onQueueChanged,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    this.embeddedInHome = false,
    this.onClose,
    required this.onOpenNowPlaying,
    required this.onOpenAlbum,
    required this.onPlayAll,
    this.onShuffleAll,
  });

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  static final Map<int, ({Color primary, Color secondary, Color tertiary})>
      _paletteCache = {};
  static const int _paletteCacheMax = 32;

  late final ScrollController _scrollController;
  bool _isScrolled = false;
  Future<({Color primary, Color secondary, Color tertiary})?>? _paletteFuture;
  int? _paletteAlbumId;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final scrolled = _scrollController.offset > 50;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final repAlbumId =
        widget.albums.isNotEmpty ? widget.albums.first.albumId : 0;
    if (_paletteFuture == null || _paletteAlbumId != repAlbumId) {
      _paletteAlbumId = repAlbumId;
      _paletteFuture = _loadPalette(repAlbumId, isDark);
    }
  }

  Future<({Color primary, Color secondary, Color tertiary})?> _loadPalette(
    int albumId,
    bool isDark,
  ) async {
    if (albumId <= 0) return null;
    try {
      final cached = _paletteCache.remove(albumId);
      if (cached != null) {
        _paletteCache[albumId] = cached;
        return cached;
      }

      final bytes = await queryArtworkBytesCached(
        albumId,
        type: ArtworkType.ALBUM,
        size: 320,
      );
      if (bytes == null) return null;

      final result = await computePaletteFromBytes(bytes);
      final primaryColorInt = result['primary'] ?? 0xFF303030;
      final secondaryColorInt = result['secondary'] ?? primaryColorInt;
      final tertiaryColorInt = result['tertiary'] ?? secondaryColorInt;

      final primary = boostVibrance(
        Color(primaryColorInt),
        extraSaturation: 0.18,
        extraLightness: 0.04,
      );
      final secondary = boostVibrance(
        Color(secondaryColorInt),
        extraSaturation: 0.14,
        extraLightness: -0.02,
      );
      final tertiary = boostVibrance(
        Color(tertiaryColorInt),
        extraSaturation: 0.14,
        extraLightness: 0.02,
      );

      final value = (
        primary: primary,
        secondary: secondary,
        tertiary: tertiary,
      );
      _paletteCache.remove(albumId);
      _paletteCache[albumId] = value;
      while (_paletteCache.length > _paletteCacheMax) {
        _paletteCache.remove(_paletteCache.keys.first);
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  int _totalTracks() {
    int sum = 0;
    for (final a in widget.albums) {
      sum += a.trackCount;
    }
    return sum;
  }

  int _totalDurationMs() {
    int sum = 0;
    for (final a in widget.albums) {
      sum += a.totalDurationMs;
    }
    return sum;
  }

  List<SongModel> _songsForAlbum(ArtistAlbum a) {
    final targetKey = albumIdentityKey(a.representativeSong);
    final list = widget.librarySongs
        .where((s) => albumIdentityKey(s) == targetKey)
        .toList();
    list.sort(compareDiscAndTrack);
    return list;
  }

  List<SongModel> _allArtistSongs() {
    if (widget.artistSongs != null && widget.artistSongs!.isNotEmpty) {
      return widget.artistSongs!;
    }
    final norm = widget.artistName.toLowerCase().trim();
    return widget.librarySongs.where((s) {
      final a = (s.artist ?? '').toLowerCase().trim();
      final aa = albumArtistFor(s).toLowerCase().trim();
      return a == norm || aa == norm;
    }).toList();
  }

  void _showAlbumOptionsModal(BuildContext context, ArtistAlbum album) {
    final cs = Theme.of(context).colorScheme;
    final albumSongs = _songsForAlbum(album);

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
                        borderRadius: BorderRadius.circular(10),
                        child: FastArtworkWidget(
                          id: album.albumId,
                          type: ArtworkType.ALBUM,
                          width: 48,
                          height: 48,
                          nullArtworkWidget: Container(
                            width: 48,
                            height: 48,
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
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              album.title,
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
                              '${widget.artistName} • ${album.year > 0 ? '${album.year} • ' : ''}${album.trackCount} tracks',
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
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('Play Album'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (albumSongs.isNotEmpty) {
                      await playbackController
                          .playFromQueue(albumSongs, initialIndex: 0);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.shuffle_rounded),
                  title: const Text('Shuffle Album'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (albumSongs.isNotEmpty) {
                      final shuffled = List<SongModel>.from(albumSongs)..shuffle();
                      await playbackController
                          .playFromQueue(shuffled, initialIndex: 0);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('Edit Album Tags'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (albumSongs.isEmpty) return;
                    final appState = AppStateController.instance;
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => BatchTagEditorDialog(
                        songs: albumSongs,
                        onSaved: () {},
                        onSongsUpdated: (updatedSongs) {
                          appState.updateSongsMetadataInPlace(updatedSongs);
                        },
                        runWithPlaybackSuspended: (action) =>
                            appState.runWithPlaybackSuspendedForBatchTagWrite(
                          action,
                          targetFilePaths:
                              albumSongs.map((s) => s.data).toSet(),
                          itemCount: albumSongs.length,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.album_rounded),
                  title: const Text('Open Album'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    widget.onOpenAlbum(album.representativeSong);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openBatchEdit(
    BuildContext context,
    List<SongModel> songs,
  ) async {
    if (songs.isEmpty) return;
    HapticFeedback.selectionClick();
    final appState = AppStateController.instance;
    await showDialog<void>(
      context: context,
      builder: (ctx) => BatchTagEditorDialog(
        songs: songs,
        onSaved: () {},
        onSongsUpdated: (updatedSongs) {
          appState.updateSongsMetadataInPlace(updatedSongs);
        },
        runWithPlaybackSuspended: (action) =>
            appState.runWithPlaybackSuspendedForBatchTagWrite(
          action,
          targetFilePaths: songs.map((s) => s.data).toSet(),
          itemCount: songs.length,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalTracks = _totalTracks();
    final totalMs = _totalDurationMs();
    final paletteAlbumId =
        widget.albums.isNotEmpty ? widget.albums.first.albumId : 0;
    final allSongs = _allArtistSongs();

    final content = FutureBuilder<
        ({Color primary, Color secondary, Color tertiary})?>(
      future: _paletteFuture,
      initialData: _paletteCache[paletteAlbumId],
      builder: (context, snap) {
        final p = snap.data;
        final bgA = p?.primary;
        final bgB = p?.secondary;
        final bgC = p?.tertiary;
        final top = bgA != null
            ? Color.alphaBlend(
                bgA.withValues(alpha: isDark ? 0.22 : 0.12),
                cs.surface,
              )
            : cs.surface;
        final mid = bgB != null
            ? Color.alphaBlend(
                bgB.withValues(alpha: isDark ? 0.12 : 0.06),
                cs.surface,
              )
            : cs.surface;
        final accent = bgC != null
            ? Color.alphaBlend(
                bgC.withValues(alpha: isDark ? 0.08 : 0.04),
                cs.surface,
              )
            : cs.surface;

        return Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [top, mid, accent, cs.surface],
                    stops: const [0.0, 0.35, 0.70, 1.0],
                  ),
                ),
              ),
            ),
            StreamBuilder<int?>(
              stream: widget.player.currentIndexStream,
              builder: (context, indexSnap) {
                return StreamBuilder<bool>(
                  stream: widget.player.playingStream,
                  builder: (context, playSnap) {
                    final currentSongId =
                        playbackController.currentSongId;
                    final isAudioPlaying =
                        playSnap.data ?? widget.player.playing;

                    return CustomScrollView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverAppBar(
                          pinned: true,
                          elevation: 0,
                          scrolledUnderElevation: 0,
                          backgroundColor: _isScrolled
                              ? Color.alphaBlend(
                                  cs.surface.withValues(
                                      alpha: isDark ? 0.92 : 0.96),
                                  top,
                                )
                              : Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          foregroundColor: cs.onSurface,
                          leading: (widget.embeddedInHome ||
                                  Navigator.of(context).canPop())
                              ? IconButton(
                                  tooltip: 'Back',
                                  icon: const Icon(Icons.arrow_back_rounded),
                                  onPressed: widget.onClose ??
                                      () => Navigator.of(context).maybePop(),
                                )
                              : null,
                          title: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            opacity: _isScrolled ? 1.0 : 0.0,
                            child: Text(
                              widget.artistName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ),
                          actions: [
                            if (_isScrolled) ...[
                              if (widget.onPlayAll != null)
                                IconButton(
                                  tooltip: 'Play All',
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  onPressed: widget.onPlayAll,
                                ),
                              if (widget.onShuffleAll != null)
                                IconButton(
                                  tooltip: 'Shuffle All',
                                  icon: const Icon(Icons.shuffle_rounded),
                                  onPressed: widget.onShuffleAll,
                                ),
                            ],
                            if (allSongs.isNotEmpty)
                              IconButton(
                                tooltip: 'Edit artist tags',
                                icon: const Icon(Icons.tune_rounded),
                                onPressed: () =>
                                    _openBatchEdit(context, allSongs),
                              ),
                            const SizedBox(width: 4),
                          ],
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: (bgA ?? Colors.black).withValues(
                                          alpha: isDark ? 0.40 : 0.16,
                                        ),
                                        blurRadius: 28,
                                        offset: const Offset(0, 10),
                                        spreadRadius: -2,
                                      ),
                                    ],
                                  ),
                                  child: ClipOval(
                                    child: FastArtworkWidget(
                                      id: paletteAlbumId,
                                      type: ArtworkType.ALBUM,
                                      width: 140,
                                      height: 140,
                                      artworkFit: BoxFit.cover,
                                      nullArtworkWidget: Container(
                                        width: 140,
                                        height: 140,
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerHighest,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.person_rounded,
                                          color: cs.onSurfaceVariant,
                                          size: 56,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.artistName,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.secondaryContainer
                                        .withValues(alpha: isDark ? 0.35 : 0.5),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: cs.outlineVariant
                                          .withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Text(
                                    '${widget.albums.length} ${widget.albums.length == 1 ? 'album' : 'albums'} • $totalTracks tracks • ${formatTime(totalMs)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSecondaryContainer,
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (widget.onPlayAll != null)
                                      FilledButton.icon(
                                        onPressed: () {
                                          HapticFeedback.selectionClick();
                                          widget.onPlayAll!();
                                        },
                                        icon: const Icon(
                                            Icons.play_arrow_rounded,
                                            size: 22),
                                        label: const Text(
                                          'Play All',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700),
                                        ),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                        ),
                                      ),
                                    if (widget.onPlayAll != null &&
                                        widget.onShuffleAll != null)
                                      const SizedBox(width: 12),
                                    if (widget.onShuffleAll != null)
                                      FilledButton.tonalIcon(
                                        onPressed: () {
                                          HapticFeedback.selectionClick();
                                          widget.onShuffleAll!();
                                        },
                                        icon: const Icon(Icons.shuffle_rounded,
                                            size: 20),
                                        label: const Text(
                                          'Shuffle',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700),
                                        ),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                        ),
                                      ),
                                    if (allSongs.isNotEmpty) ...[
                                      const SizedBox(width: 10),
                                      IconButton.filledTonal(
                                        tooltip: 'Edit artist tags',
                                        icon: const Icon(Icons.tune_rounded,
                                            size: 20),
                                        style: IconButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(16),
                                          ),
                                          padding: const EdgeInsets.all(12),
                                        ),
                                        onPressed: () =>
                                            _openBatchEdit(context, allSongs),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (widget.albums.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                              child: Row(
                                children: [
                                  Text(
                                    'Albums',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.2,
                                          color: cs.primary,
                                        ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Divider(
                                      color: cs.outlineVariant
                                          .withValues(alpha: 0.35),
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final a = widget.albums[i];
                              final yearText =
                                  a.year > 0 ? a.year.toString() : '–';
                              final meta =
                                  '$yearText • ${a.trackCount} ${a.trackCount == 1 ? 'track' : 'tracks'}';

                              final isThisAlbumPlaying = currentSongId !=
                                      null &&
                                  widget.librarySongs.any((s) =>
                                      s.id == currentSongId &&
                                      albumIdentityKey(s) ==
                                          albumIdentityKey(
                                              a.representativeSong));

                              return UniversalSongTile(
                                artworkId: a.albumId,
                                artworkType: ArtworkType.ALBUM,
                                artworkSize: 54,
                                artworkBorderRadius:
                                    BorderRadius.circular(12),
                                fallbackIcon: Icons.album_rounded,
                                title: a.title,
                                subtitle: meta,
                                showMetaDuration: false,
                                isCurrent: isThisAlbumPlaying,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isThisAlbumPlaying) ...[
                                      Icon(
                                        isAudioPlaying
                                            ? Icons.graphic_eq_rounded
                                            : Icons.pause_rounded,
                                        color: cs.primary,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Text(
                                      formatTime(a.totalDurationMs),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: isThisAlbumPlaying
                                                ? cs.primary
                                                : cs.onSurfaceVariant,
                                            fontWeight: isThisAlbumPlaying
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures()
                                            ],
                                          ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      color: cs.onSurfaceVariant
                                          .withValues(alpha: 0.5),
                                      size: 18,
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 3,
                                ),
                                backgroundColor: isThisAlbumPlaying
                                    ? cs.primaryContainer.withValues(
                                        alpha: isDark ? 0.32 : 0.45)
                                    : Colors.transparent,
                                borderColor: Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  widget.onOpenAlbum(a.representativeSong);
                                },
                                onLongPress: () {
                                  HapticFeedback.mediumImpact();
                                  _showAlbumOptionsModal(context, a);
                                },
                              );
                            },
                            childCount: widget.albums.length,
                          ),
                        ),
                        buildBottomBarsGutter(context),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );

    if (widget.embeddedInHome) return content;

    return Scaffold(
      extendBody: true,
      bottomNavigationBar: StreamBuilder<int?>(
        stream: widget.player.currentIndexStream,
        builder: (context, snapshot) {
          return buildDetailBottomBars(
            context: context,
            player: widget.player,
            songs: widget.librarySongs,
            currentIndex: snapshot.data ?? widget.player.currentIndex,
            onQueueChanged: widget.onQueueChanged,
            onOpenNowPlaying: widget.onOpenNowPlaying,
            selectedTabIndex: widget.selectedTabIndex,
            onNavigateTab: widget.onNavigateTab,
          );
        },
      ),
      body: content,
    );
  }
}
