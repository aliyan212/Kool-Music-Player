import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import '../utils/palette_compute.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';
import '../dialogs/batch_tag_editor_dialog.dart';
import '../services/app_state_controller.dart';
import '../utils/song_sort_utils.dart';
import '../services/playback_controller.dart';
import '../ui/shared/bottom_bars_gutter.dart';
import '../widgets/universal_song_tile.dart';

class AlbumPage extends StatefulWidget {
  final AudioPlayer player;
  final int albumId;
  final String albumTitle;
  final String albumArtist;
  final List<SongModel> songs;
  final List<SongModel> librarySongs;
  final Function(List<SongModel>) onQueueChanged;
  final int selectedTabIndex;
  final ValueChanged<int> onNavigateTab;
  final bool embeddedInHome;
  final VoidCallback? onClose;
  final Function(SongModel) onOpenNowPlaying;
  final Future<void> Function(SongModel song) onPlaySong;
  final Future<void> Function()? onShuffle;

  static final LinkedHashMap<int, ({Color primary, Color secondary, Color tertiary})>
  _albumPaletteCache =
      LinkedHashMap<int, ({Color primary, Color secondary, Color tertiary})>();
  static const int _albumPaletteCacheMax = 30;

  const AlbumPage({
    super.key,
    required this.player,
    required this.albumId,
    required this.albumTitle,
    required this.albumArtist,
    required this.songs,
    required this.librarySongs,
    required this.onQueueChanged,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    this.embeddedInHome = false,
    this.onClose,
    required this.onOpenNowPlaying,
    required this.onPlaySong,
    this.onShuffle,
  });

  @override
  State<AlbumPage> createState() => _AlbumPageState();

  static int _normalizedTrackNo(int raw) {
    if (raw <= 0) return 0;
    if (raw >= 1000) {
      final mod = raw % 1000;
      return mod == 0 ? raw : mod;
    }
    return raw;
  }

  static String _formatAlbumDuration(int totalMs) {
    final d = Duration(milliseconds: totalMs);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) {
      return '$h hr ${m > 0 ? '$m min' : ''}';
    }
    return '$m min';
  }

  static Future<({Color primary, Color secondary, Color tertiary})?> _loadAlbumPalette(
    int albumId,
    bool isDark,
  ) async {
    try {
      final cached = _albumPaletteCache.remove(albumId);
      if (cached != null) {
        _albumPaletteCache[albumId] = cached;
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
      _albumPaletteCache.remove(albumId);
      _albumPaletteCache[albumId] = value;
      while (_albumPaletteCache.length > _albumPaletteCacheMax) {
        _albumPaletteCache.remove(_albumPaletteCache.keys.first);
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  int _totalDurationMs(List<SongModel> trackList) {
    int sum = 0;
    for (final s in trackList) {
      sum += (s.duration ?? 0);
    }
    return sum;
  }

  Widget _buildContent(
    BuildContext context,
    Future<({Color primary, Color secondary, Color tertiary})?> paletteFuture, {
    required List<SongModel> currentSongs,
    required String currentTitle,
    required String currentArtist,
    required ValueChanged<List<SongModel>> onBatchUpdated,
    required ScrollController scrollController,
    required bool isScrolled,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalMs = _totalDurationMs(currentSongs);
    final albumYear = computeAlbumYearFromYears(currentSongs.map(yearFromSong));

    final metaParts = <String>[];
    if (albumYear > 0) metaParts.add('$albumYear');
    metaParts.add('${currentSongs.length} ${currentSongs.length == 1 ? 'track' : 'tracks'}');
    if (totalMs > 0) metaParts.add(_formatAlbumDuration(totalMs));
    final metaText = metaParts.join(' • ');

    final hasMultipleDiscs = currentSongs.map(discFromSong).toSet().length > 1;

    final content = FutureBuilder<({Color primary, Color secondary, Color tertiary})?>(
        future: paletteFuture,
        initialData: _albumPaletteCache[albumId],
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
                stream: player.currentIndexStream,
                builder: (context, indexSnap) {
                  return StreamBuilder<bool>(
                    stream: player.playingStream,
                    builder: (context, playSnap) {
                      final currentSongId = playbackController.currentSongId;
                      final isAudioPlaying = playSnap.data ?? player.playing;

                      final trackListWidgets = <Widget>[];
                      int currentDisc = -1;

                      for (int i = 0; i < currentSongs.length; i++) {
                        final song = currentSongs[i];
                        final disc = discFromSong(song);

                        if (hasMultipleDiscs && disc != currentDisc) {
                          currentDisc = disc;
                          trackListWidgets.add(
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                              child: Row(
                                children: [
                                  Icon(Icons.album_rounded, size: 16, color: cs.primary),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Disc $disc',
                                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Divider(
                                      color: cs.outlineVariant.withValues(alpha: 0.35),
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        final isCurrent = currentSongId == song.id;
                        final isPlayingThisSong = isCurrent && isAudioPlaying;
                        final trackNo = AlbumPage._normalizedTrackNo(song.track ?? 0);
                        final dur = song.duration ?? 0;
                        final songArtist = (song.artist ?? '').trim();
                        final isFeaturedArtist = songArtist.isNotEmpty &&
                            songArtist.toLowerCase() != currentArtist.toLowerCase() &&
                            songArtist.toLowerCase() != 'unknown artist';

                        trackListWidgets.add(
                          UniversalSongTile(
                            song: song,
                            title: song.title,
                            subtitle: isFeaturedArtist ? songArtist : null,
                            isCurrent: isCurrent,
                            isPlaying: isPlayingThisSong,
                            showMetaDuration: false,
                            leading: SizedBox(
                              width: 36,
                              height: 36,
                              child: Center(
                                child: isCurrent
                                    ? Icon(
                                        isPlayingThisSong
                                            ? Icons.graphic_eq_rounded
                                            : Icons.pause_rounded,
                                        color: cs.primary,
                                        size: 20,
                                      )
                                    : Text(
                                        trackNo > 0 ? '$trackNo' : '–',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                          color: cs.onSurfaceVariant.withValues(alpha: 0.75),
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: const [FontFeature.tabularFigures()],
                                        ),
                                      ),
                              ),
                            ),
                            trailing: Text(
                              formatTime(dur),
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: isCurrent
                                    ? cs.primary
                                    : cs.onSurfaceVariant.withValues(alpha: 0.7),
                                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            backgroundColor: isCurrent
                                ? cs.primaryContainer.withValues(
                                    alpha: isDark ? 0.32 : 0.50,
                                  )
                                : Colors.transparent,
                            borderColor: Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              onPlaySong(song);
                            },
                            onLongPress: () {
                              HapticFeedback.selectionClick();
                              AppStateController.instance.showSongOptions(song, i);
                            },
                          ),
                        );
                      }

                      return CustomScrollView(
                        controller: scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverAppBar(
                            pinned: true,
                            elevation: 0,
                            scrolledUnderElevation: 0,
                            backgroundColor: isScrolled
                                ? Color.alphaBlend(
                                    cs.surface.withValues(alpha: isDark ? 0.92 : 0.96),
                                    top,
                                  )
                                : Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            foregroundColor: cs.onSurface,
                            leading: (embeddedInHome || Navigator.of(context).canPop())
                                ? IconButton(
                                    tooltip: 'Back',
                                    icon: const Icon(Icons.arrow_back_rounded),
                                    onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                                  )
                                : null,
                            title: AnimatedOpacity(
                              duration: const Duration(milliseconds: 220),
                              opacity: isScrolled ? 1.0 : 0.0,
                              child: Text(
                                currentTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            centerTitle: false,
                            actions: [
                              IconButton(
                                tooltip: 'Edit album tags',
                                icon: const Icon(Icons.tune_rounded),
                                onPressed: () async {
                                  HapticFeedback.selectionClick();
                                  final appState = AppStateController.instance;
                                  final currentAlbumSongs = List<SongModel>.from(currentSongs);
                                  if (currentAlbumSongs.isEmpty) return;
                                  await showDialog<void>(
                                    context: context,
                                    builder: (ctx) => BatchTagEditorDialog(
                                      songs: currentAlbumSongs,
                                      onSaved: () {},
                                      onSongsUpdated: (updatedSongs) {
                                        appState.updateSongsMetadataInPlace(updatedSongs);
                                        onBatchUpdated(updatedSongs);
                                      },
                                      runWithPlaybackSuspended: (action) =>
                                          appState.runWithPlaybackSuspendedForBatchTagWrite(
                                            action,
                                            targetFilePaths: currentAlbumSongs
                                                .map((s) => s.data)
                                                .toSet(),
                                            itemCount: currentAlbumSongs.length,
                                          ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 170,
                                    height: 170,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(22),
                                      boxShadow: [
                                        BoxShadow(
                                          color: (bgA ?? Colors.black).withValues(
                                            alpha: isDark ? 0.42 : 0.16,
                                          ),
                                          blurRadius: 28,
                                          offset: const Offset(0, 12),
                                          spreadRadius: -2,
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(22),
                                      child: FastArtworkWidget(
                                        id: albumId,
                                        type: ArtworkType.ALBUM,
                                        width: 170,
                                        height: 170,
                                        artworkFit: BoxFit.cover,
                                        nullArtworkWidget: Container(
                                          width: 170,
                                          height: 170,
                                          decoration: BoxDecoration(
                                            color: cs.surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(22),
                                          ),
                                          child: Icon(
                                            Icons.album_rounded,
                                            color: cs.onSurfaceVariant,
                                            size: 64,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    currentTitle,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      if (currentSongs.isNotEmpty) {
                                        AppStateController.instance.openArtistPageFromSong(currentSongs.first);
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              currentArtist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                color: cs.primary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Icon(
                                            Icons.chevron_right_rounded,
                                            size: 18,
                                            color: cs.primary.withValues(alpha: 0.8),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (metaText.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: cs.secondaryContainer.withValues(
                                          alpha: isDark ? 0.35 : 0.65,
                                        ),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(
                                          color: cs.outlineVariant.withValues(alpha: 0.35),
                                        ),
                                      ),
                                      child: Text(
                                        metaText,
                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSecondaryContainer.withValues(alpha: 0.95),
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 18),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton.icon(
                                          onPressed: currentSongs.isEmpty
                                              ? null
                                              : () => onPlaySong(currentSongs.first),
                                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                                          label: const Text(
                                            'Play',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(16),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: FilledButton.tonalIcon(
                                          onPressed: currentSongs.isEmpty
                                              ? null
                                              : () {
                                                  if (onShuffle != null) {
                                                    onShuffle!();
                                                  } else {
                                                    final shuffled = List<SongModel>.from(currentSongs)..shuffle();
                                                    onPlaySong(shuffled.first);
                                                  }
                                                },
                                          icon: const Icon(Icons.shuffle_rounded, size: 20),
                                          label: const Text(
                                            'Shuffle',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(16),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SliverList(
                            delegate: SliverChildListDelegate(trackListWidgets),
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

class _AlbumPageState extends State<AlbumPage> {
  late Future<({Color primary, Color secondary, Color tertiary})?> _paletteFuture;
  Brightness? _lastBrightness;
  late List<SongModel> _songs;
  late String _albumTitle;
  late String _albumArtist;
  late final ScrollController _scrollController;
  bool _isScrolled = false;

  @override
  void initState() {
    super.initState();
    _songs = List<SongModel>.from(widget.songs)..sort(compareDiscAndTrack);
    _albumTitle = widget.albumTitle;
    _albumArtist = widget.albumArtist;
    _scrollController = ScrollController()..addListener(_onScroll);
    _lastBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _paletteFuture = AlbumPage._loadAlbumPalette(
      widget.albumId,
      _lastBrightness == Brightness.dark,
    );
  }

  void _onScroll() {
    final isScrolled = _scrollController.hasClients && _scrollController.offset > 160;
    if (isScrolled != _isScrolled) {
      setState(() => _isScrolled = isScrolled);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness == brightness) return;
    _lastBrightness = brightness;
    _paletteFuture = AlbumPage._loadAlbumPalette(
      widget.albumId,
      brightness == Brightness.dark,
    );
  }

  @override
  void didUpdateWidget(covariant AlbumPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songs != widget.songs) {
      _songs = List<SongModel>.from(widget.songs)..sort(compareDiscAndTrack);
    }
    if (oldWidget.albumTitle != widget.albumTitle) {
      _albumTitle = widget.albumTitle;
    }
    if (oldWidget.albumArtist != widget.albumArtist) {
      _albumArtist = widget.albumArtist;
    }
    if (oldWidget.albumId == widget.albumId) return;
    _paletteFuture = AlbumPage._loadAlbumPalette(
      widget.albumId,
      Theme.of(context).brightness == Brightness.dark,
    );
  }

  void _onBatchUpdated(List<SongModel> updatedSongs) {
    final map = {for (final s in updatedSongs) s.id: s};
    setState(() {
      _songs = _songs.map((s) => map[s.id] ?? s).toList()..sort(compareDiscAndTrack);
      if (updatedSongs.isNotEmpty) {
        final first = updatedSongs.first;
        if ((first.album ?? '').trim().isNotEmpty) {
          _albumTitle = first.album!.trim();
        }
        final a = (first.artist ?? '').trim();
        if (a.isNotEmpty) {
          _albumArtist = a;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget._buildContent(
      context,
      _paletteFuture,
      currentSongs: _songs,
      currentTitle: _albumTitle,
      currentArtist: _albumArtist,
      onBatchUpdated: _onBatchUpdated,
      scrollController: _scrollController,
      isScrolled: _isScrolled,
    );
  }
}

