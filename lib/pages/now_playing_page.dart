import 'dart:async';
import 'dart:collection';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audiotags/audiotags.dart';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../android_notifications.dart';
import '../utils/palette_compute.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../ui/shared/squiggly_seek_bar.dart';
import '../widgets/now_playing_transport.dart';
import '../dialogs/lyrics_editor_dialog.dart';
import '../dialogs/tag_editor_dialog.dart';
import '../pages/queue_page.dart';
import '../utils/lyrics.dart';
import '../utils/tag_write_access.dart';
import '../utils/format_utils.dart';
import '../main.dart';

class NowPlayingPage extends StatefulWidget {
  final AudioPlayer player;
  final SongModel song;
  final List<SongModel> songs;
  final ConcatenatingAudioSource? playlist;
  final Function(List<SongModel>)? onQueueChanged;
  final void Function(SongModel song) onOpenAlbum;
  final void Function(SongModel song) onOpenArtist;
  final ValueChanged<SongModel>? onSongUpdated;
  const NowPlayingPage({
    super.key,
    required this.player,
    required this.song,
    required this.songs,
    this.playlist,
    this.onQueueChanged,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    this.onSongUpdated,
  });
  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with TickerProviderStateMixin {
  static final LinkedHashMap<int, ({Color primary, Color secondary, Color tertiary})>
  _paletteCache = LinkedHashMap<int, ({Color primary, Color secondary, Color tertiary})>();
  static const int _paletteCacheMax = 30;

  final ItemScrollController _lyricItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _lyricItemPositionsListener =
      ItemPositionsListener.create();
  Color? _primaryColor;
  Color? _secondaryColor;
  Color? _tertiaryColor;
  Color? _prevPrimaryColor;
  Color? _prevSecondaryColor;
  Color? _prevTertiaryColor;
  late SongModel _displayedSong;
  bool _showLyrics = false;
  String? _rawLyrics;
  List<LyricLine> _lrcLines = [];
  List<int> _lrcTimesMs = const <int>[];
  bool _isSynced = false;
  int _currentLyricIndex = -1;
  final ValueNotifier<int> _activeLyricIndex = ValueNotifier<int>(0);
  StreamSubscription<int?>? _indexSub;
  bool _autoScrollEnabled = true;
  Timer? _resumeAutoScrollTimer;
  final Map<int, GlobalKey> _lyricLineKeys = {};

  Timer? _paletteDebounceTimer;
  Timer? _paletteLockTimer;
  Timer? _artworkBytesDebounceTimer;
  int _paletteToken = 0;
  int _artworkBytesToken = 0;
  Uint8List? _displayedArtworkBytes;
  DateTime? _lastPaletteAppliedAt;
  static const Duration _paletteMinDisplayWindow = Duration(milliseconds: 440);
  ({
    int songId,
    int token,
    Color? primary,
    Color? secondary,
    Color? tertiary,
  })? _pendingPalette;

  late final AnimationController _bgGradientController;
  late final AnimationController _artworkPulseController;
  late final PageController _pageController;
  StreamSubscription<PlayerState>? _nowPlayingPlayerStateSub;
  StreamSubscription<Duration>? _positionSub;

  bool _disableMotion = false;
  bool _fullscreenLandscape = false;
  bool _fullscreenControlsVisible = false;

  @override
  void initState() {
    super.initState();
    _displayedSong = widget.song;
    _pageController = PageController(
      initialPage: widget.player.currentIndex ?? 0,
    );
    if (hasCachedArtworkBytes(_displayedSong.id, size: 900)) {
      _displayedArtworkBytes = peekCachedArtworkBytes(
        _displayedSong.id,
        size: 900,
      );
    } else if (hasCachedArtworkBytes(_displayedSong.id, size: 200)) {
      _displayedArtworkBytes = peekCachedArtworkBytes(
        _displayedSong.id,
        size: 200,
      );
    }

    _bgGradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );

    _artworkPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    appIsForeground.addListener(_handleForegroundChanged);

    _nowPlayingPlayerStateSub = widget.player.playerStateStream.listen((state) {
      // Keep pulse only while playing.
      if (_disableMotion) {
        if (_artworkPulseController.isAnimating) _artworkPulseController.stop();
        return;
      }
      if (!appIsForeground.value) {
        if (_artworkPulseController.isAnimating) _artworkPulseController.stop();
        return;
      }
      if (state.playing) {
        if (!_artworkPulseController.isAnimating) {
          _artworkPulseController.repeat(reverse: true);
        }
      } else {
        if (_artworkPulseController.isAnimating) {
          _artworkPulseController.stop();
        }
      }
    });

    // Start/stop controllers based on current state.
    _syncMotionControllers();
    if (widget.player.playing && appIsForeground.value && !_disableMotion) {
      _artworkPulseController.repeat(reverse: true);
    }

    _loadLyrics();
    _scheduleArtworkBytesUpdate(_displayedSong.id, delay: Duration.zero);
    // Delay palette extraction until slide animation completes.
    _schedulePaletteUpdate(
      _displayedSong.id,
      delay: const Duration(milliseconds: 350),
    );

    _indexSub = widget.player.currentIndexStream.listen((index) {
      if (!mounted) return;
      if (index == null || index < 0) return;

      // Get the current song from the player's sequence to handle queue changes correctly
      final sequence = widget.player.sequence;
      if (index >= sequence.length) return;

      final currentSource = sequence[index];
      final tag = currentSource.tag;

      // Find the song by matching the tag (which contains song id or MediaItem)
      SongModel? newSong;
      if (tag is MediaItem) {
        final songId = int.tryParse(tag.id);
        if (songId != null) {
          newSong = widget.songs.cast<SongModel?>().firstWhere(
            (s) => s?.id == songId,
            orElse: () => null,
          );
        }
      } else if (tag is SongModel) {
        newSong = tag;
      }

      if (newSong == null || newSong.id == _displayedSong.id) return;

      if (_pageController.hasClients && _pageController.page?.round() != index) {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }

      final hasHighRes = hasCachedArtworkBytes(newSong.id, size: 900);
      final hasLowRes = hasCachedArtworkBytes(newSong.id, size: 200);

      HapticFeedback.mediumImpact();
      setState(() {
        _displayedSong = newSong!;
        if (hasHighRes) {
          _displayedArtworkBytes = peekCachedArtworkBytes(
            newSong.id,
            size: 900,
          );
        } else if (hasLowRes) {
          _displayedArtworkBytes = peekCachedArtworkBytes(
            newSong.id,
            size: 200,
          );
        } else {
          _displayedArtworkBytes = null;
        }
        _showLyrics = false;
        _currentLyricIndex = -1;
        _prevPrimaryColor = _primaryColor;
        _prevSecondaryColor = _secondaryColor;
        _prevTertiaryColor = _tertiaryColor;
      });
      WakelockPlus.disable();
      _scheduleArtworkBytesUpdate(newSong.id);
      _schedulePaletteUpdate(newSong.id);
      _loadLyrics();
    });

    _positionSub = widget.player.positionStream.listen((position) {
      if (!mounted || !_isSynced || _lrcLines.isEmpty || !_showLyrics) return;

      final activeIndex = _activeLyricIndexForPosition(position);
      if (activeIndex != _currentLyricIndex) {
        _currentLyricIndex = activeIndex;
        _activeLyricIndex.value = activeIndex;

        if (_autoScrollEnabled) {
          _scrollToActiveLine(activeIndex);
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disable = MediaQuery.of(context).disableAnimations;
    _disableMotion = disable;
    _syncMotionControllers();
  }

  void _syncMotionControllers() {
    if (!mounted) return;
    final shouldAnimate = appIsForeground.value && !_disableMotion;
    if (shouldAnimate) {
      if (!_bgGradientController.isAnimating) {
        _bgGradientController.repeat();
      }
    } else {
      if (_bgGradientController.isAnimating) _bgGradientController.stop();
    }

    // Artwork pulse depends on player state; if we can't animate, stop.
    if (!shouldAnimate) {
      if (_artworkPulseController.isAnimating) _artworkPulseController.stop();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _positionSub = null;

    _indexSub?.cancel();
    _resumeAutoScrollTimer?.cancel();
    _paletteDebounceTimer?.cancel();
    _paletteDebounceTimer = null;
    _paletteLockTimer?.cancel();
    _paletteLockTimer = null;
    _artworkBytesDebounceTimer?.cancel();
    _artworkBytesDebounceTimer = null;

    if (_fullscreenLandscape) {
      try {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      } catch (_) {
        // Ignore platform-specific failures.
      }
    }

    _activeLyricIndex.dispose();
    _pageController.dispose();

    appIsForeground.removeListener(_handleForegroundChanged);
    _bgGradientController.dispose();

    _nowPlayingPlayerStateSub?.cancel();
    _nowPlayingPlayerStateSub = null;
    _artworkPulseController.dispose();

    WakelockPlus.disable();
    super.dispose();
  }

  void _scheduleArtworkBytesUpdate(
    int songId, {
    Duration delay = const Duration(milliseconds: 80),
  }) {
    _artworkBytesDebounceTimer?.cancel();
    final token = ++_artworkBytesToken;
    _artworkBytesDebounceTimer = Timer(delay, () {
      _updateArtworkBytes(songId, token);
    });
  }

  Future<void> _updateArtworkBytes(int songId, int token) async {
    try {
      final bytes = await queryArtworkBytesCached(
        songId,
        type: ArtworkType.AUDIO,
        size: 900,
        quality: 100,
      );
      if (!mounted) return;
      if (token != _artworkBytesToken) return;
      if (songId != _displayedSong.id) return;
      if (identical(_displayedArtworkBytes, bytes)) return;
      setState(() => _displayedArtworkBytes = bytes);
    } catch (_) {
      // Keep previously rendered artwork if fetch fails.
    }
  }

  Widget _buildNowPlayingArtwork({required double side}) {
    if (_displayedArtworkBytes != null) {
      return Image.memory(
        _displayedArtworkBytes!,
        width: side,
        height: side,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    }
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(28),
      ),
      child: const Icon(
        Icons.music_note,
        size: 100,
        color: Colors.white38,
      ),
    );
  }

  void _queueOrApplyPalette({
    required int songId,
    required int token,
    required Color? primary,
    required Color? secondary,
    required Color? tertiary,
  }) {
    if (!mounted) return;
    if (token != _paletteToken) return;
    if (songId != _displayedSong.id) return;

    final now = DateTime.now();
    final last = _lastPaletteAppliedAt;
    final remaining =
        last == null ? Duration.zero : _paletteMinDisplayWindow - now.difference(last);

    if (remaining <= Duration.zero) {
      _paletteLockTimer?.cancel();
      _paletteLockTimer = null;
      _pendingPalette = null;
      setState(() {
        _primaryColor = primary;
        _secondaryColor = secondary;
        _tertiaryColor = tertiary;
      });
      _lastPaletteAppliedAt = now;
      return;
    }

    _pendingPalette = (
      songId: songId,
      token: token,
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
    );

    _paletteLockTimer?.cancel();
    _paletteLockTimer = Timer(remaining, () {
      if (!mounted) return;
      final pending = _pendingPalette;
      if (pending == null) return;
      if (pending.token != _paletteToken) {
        _pendingPalette = null;
        return;
      }
      if (pending.songId != _displayedSong.id) {
        _pendingPalette = null;
        return;
      }
      setState(() {
        _primaryColor = pending.primary;
        _secondaryColor = pending.secondary;
        _tertiaryColor = pending.tertiary;
      });
      _lastPaletteAppliedAt = DateTime.now();
      _pendingPalette = null;
    });
  }

  Future<void> _setFullscreenLandscape(bool enabled) async {
    if (_fullscreenLandscape == enabled) return;
    setState(() {
      _fullscreenLandscape = enabled;
      if (enabled) {
        _showLyrics = true;
        _autoScrollEnabled = true;
        _currentLyricIndex = -1;
      }
    });

    try {
      if (enabled) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
    } catch (_) {
      // Ignore platform-specific failures.
    }

    if (!mounted) return;
    if (enabled && _isSynced && _lrcLines.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final idx = _activeLyricIndexForPosition(widget.player.position);
        _scrollToActiveLine(idx);
      });
    }
  }

  void _handleForegroundChanged() {
    if (!mounted) return;
    _syncMotionControllers();
    if (appIsForeground.value && _showLyrics) {
      _setLyricsVisible(true, force: true);
    }
  }

  void _openDetailAfterClosingNowPlaying(
    void Function(SongModel song) open,
  ) {
    final song = _displayedSong;
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      open(song);
    });
  }

  void _setLyricsVisible(bool show, {bool force = false}) {
    if (!force && _showLyrics == show) return;
    setState(() {
      _showLyrics = show;
      if (show) {
        _autoScrollEnabled = true;
        _currentLyricIndex = -1;
      }
    });
    if (show) {
      WakelockPlus.enable();
      if (_rawLyrics == null) {
        _loadLyrics();
      } else {
        _primeLyricsScroll();
      }
    } else {
      WakelockPlus.disable();
    }
  }

  void _primeLyricsScroll() {
    if (!_isSynced || _lrcLines.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final idx = _activeLyricIndexForPosition(widget.player.position);
      _scrollToActiveLine(idx);
    });
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _rawLyrics = null;
      _lrcLines = [];
      _lrcTimesMs = const <int>[];
      _isSynced = false;
      _currentLyricIndex = -1;
    });
    String? lyrics = await LyricsHelper.getLyrics(_displayedSong.data);
    if (lyrics != null && lyrics.isNotEmpty) {
      bool isSynced = LyricsHelper.isLRC(lyrics);
      if (isSynced && mounted) {
        final parsed = LyricsHelper.parseLRC(lyrics);
        setState(() {
          _lrcLines = parsed;
          _lrcTimesMs = parsed
              .map((e) => e.time.inMilliseconds)
              .toList(growable: false);
          _isSynced = true;
          _rawLyrics = lyrics;
        });

        // Seed the active index so long lyric files don't rebuild the whole UI.
        final idx = _activeLyricIndexForPosition(widget.player.position);
        _currentLyricIndex = idx;
        _activeLyricIndex.value = idx;
      } else if (mounted) {
        setState(() {
          _rawLyrics = lyrics;
          _isSynced = false;
          _lrcLines = [];
          _lrcTimesMs = const <int>[];
        });
        _currentLyricIndex = -1;
        _activeLyricIndex.value = 0;
      }
    }
  }

  Future<void> _reloadDisplayedSongMetadata() async {
    try {
      final tag = await AudioTags.read(_displayedSong.data);
      if (!mounted || tag == null) return;

      final updatedMap = Map<dynamic, dynamic>.from(_displayedSong.getMap);
      updatedMap['title'] = tag.title ?? _displayedSong.title;
      updatedMap['artist'] = tag.trackArtist ?? _displayedSong.artist;
      updatedMap['album'] = tag.album ?? _displayedSong.album;
      updatedMap['album_artist'] = tag.albumArtist ?? updatedMap['album_artist'];
      updatedMap['genre'] = tag.genre ?? updatedMap['genre'];
      updatedMap['year'] = tag.year ?? updatedMap['year'];
      updatedMap['track'] = tag.trackNumber ?? updatedMap['track'];
      updatedMap['disc_number'] = tag.discNumber ?? updatedMap['disc_number'];
      updatedMap['track_total'] = tag.trackTotal ?? updatedMap['track_total'];
      updatedMap['disc_total'] = tag.discTotal ?? updatedMap['disc_total'];

      setState(() {
        _displayedSong = SongModel(updatedMap);
      });
    } catch (_) {}
  }

  int _activeLyricIndexForPosition(Duration position) {
    final times = _lrcTimesMs;
    if (times.isEmpty) return 0;

    final ms = position.inMilliseconds;
    if (ms <= times.first) return 0;
    if (ms >= times.last) return times.length - 1;

    // Find the last timestamp <= current position.
    int lo = 0;
    int hi = times.length - 1;
    int best = 0;
    while (lo <= hi) {
      final mid = lo + ((hi - lo) >> 1);
      final t = times[mid];
      if (t <= ms) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  void _schedulePaletteUpdate(
    int songId, {
    Duration delay = const Duration(milliseconds: 320),
  }) {
    _paletteDebounceTimer?.cancel();
    final token = ++_paletteToken;
    _paletteDebounceTimer = Timer(delay, () {
      _updatePalette(songId, token);
    });
  }

  Future<void> _updatePalette(int songId, int token) async {
    try {
      final cached = _paletteCache.remove(songId);
      if (cached != null) {
        // LRU: re-insert as most recently used.
        _paletteCache[songId] = cached;
        if (!mounted) return;
        if (token != _paletteToken) return;
        if (songId != _displayedSong.id) return;
        _queueOrApplyPalette(
          songId: songId,
          token: token,
          primary: cached.primary,
          secondary: cached.secondary,
          tertiary: cached.tertiary,
        );
        return;
      }

      Uint8List? bytes = await queryArtworkBytesCached(
        songId,
        type: ArtworkType.AUDIO,
        size: 200,
      );
      if (!mounted) return;
      if (token != _paletteToken) return;
      if (songId != _displayedSong.id) return;
      if (bytes == null) {
        _queueOrApplyPalette(
          songId: songId,
          token: token,
          primary: null,
          secondary: null,
          tertiary: null,
        );
        return;
      }
      try {
        // Compute a lightweight palette from artwork bytes.
        final Map<String, int> result = await computePaletteFromBytes(bytes);
        if (!mounted) return;
        if (token != _paletteToken) return;
        if (songId != _displayedSong.id) return;

        final primaryColorInt = result['primary'] ?? 0xFF000000;
        final secondaryColorInt = result['secondary'] ?? primaryColorInt;
        final tertiaryColorInt = result['tertiary'] ?? secondaryColorInt;
        final primary = boostVibrance(
          Color(primaryColorInt),
          extraSaturation: 0.5,
          extraLightness: 0.08,
        );
        final secondary = boostVibrance(
          Color(secondaryColorInt),
          extraSaturation: 0.42,
          extraLightness: -0.02,
        );
        final tertiary = boostVibrance(
          Color(tertiaryColorInt),
          extraSaturation: 0.46,
          extraLightness: 0.03,
        );

        _queueOrApplyPalette(
          songId: songId,
          token: token,
          primary: primary,
          secondary: secondary,
          tertiary: tertiary,
        );

        _paletteCache.remove(songId);
        _paletteCache[songId] = (
          primary: primary,
          secondary: secondary,
          tertiary: tertiary,
        );
        while (_paletteCache.length > _paletteCacheMax) {
          _paletteCache.remove(_paletteCache.keys.first);
        }
      } catch (_) {
        // Swallow errors; palette is a nicety, not critical.
      }
    } catch (_) {}
  }

  void _scrollToActiveLine(int index) {
    if (!_lyricItemScrollController.isAttached) return;
    // ScrollablePositionedList can jump/scroll to offscreen items efficiently.
    _lyricItemScrollController.scrollTo(
      index: index.clamp(0, (_lrcLines.isEmpty ? 0 : _lrcLines.length - 1)),
      alignment: 0.35,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _pauseAutoScroll() {
    _autoScrollEnabled = false;
    _resumeAutoScrollTimer?.cancel();
    _resumeAutoScrollTimer = Timer(const Duration(milliseconds: 4500), () {
      if (mounted) setState(() => _autoScrollEnabled = true);
    });
  }

  Widget _buildFullscreenLandscapeView({
    required bool isDark,
    required Color textColor,
    required Color textColorSecondary,
    required Color iconBgColor,
    required Color iconFgColor,
  }) {
    final lyricsPanelBg = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Theme.of(context).colorScheme.primary.withValues(alpha: isDark ? 0.10 : 0.06),
        Theme.of(context).colorScheme.surface.withValues(alpha: isDark ? 0.14 : 0.10),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 6.0;
          final maxW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 800.0;

          // Keep left pane tight so it doesn't "look" like a big empty gap.
          double leftW = (maxW * 0.42).clamp(280.0, 420.0);
          final minRightW = 280.0;
          if (leftW > maxW - minRightW - gap) {
            leftW = (maxW - minRightW - gap).clamp(240.0, 520.0);
          }

          return Row(
            children: [
              SizedBox(
                width: leftW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final maxSide = math.min(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          final side = (maxSide.isFinite ? maxSide : 320.0)
                              .clamp(160.0, 340.0);

                          final pulse = Tween<double>(begin: 1.0, end: 1.02)
                              .animate(
                                CurvedAnimation(
                                  parent: _artworkPulseController,
                                  curve: Curves.easeInOut,
                                ),
                              );

                          final artwork = ScaleTransition(
                            scale: pulse,
                            child: SizedBox(
                              width: side,
                              height: side,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: [
                                    BoxShadow(
                                      color: (_primaryColor ?? Colors.black)
                                          .withValues(alpha: 0.5),
                                      blurRadius: 40,
                                      spreadRadius: 10,
                                      offset: const Offset(0, 15),
                                    ),
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.3),
                                      blurRadius: 20,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: _buildArtworkPageView(side: side),
                              ),
                            ),
                          );

                          return Align(
                            alignment: Alignment.centerLeft,
                            child: GestureDetector(
                              onTap: () => setState(
                                () => _fullscreenControlsVisible =
                                    !_fullscreenControlsVisible,
                              ),
                              child: SizedBox(
                                width: side,
                                height: side,
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: TweenAnimationBuilder<double>(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        curve: Curves.easeOut,
                                        tween: Tween<double>(
                                          begin: 0,
                                          end: _fullscreenControlsVisible
                                              ? 8
                                              : 0,
                                        ),
                                        builder: (context, sigma, _) {
                                          return ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              28,
                                            ),
                                            child: ImageFiltered(
                                              imageFilter: ImageFilter.blur(
                                                sigmaX: sigma,
                                                sigmaY: sigma,
                                              ),
                                              child: artwork,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 10,
                                      child: AnimatedOpacity(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        opacity: _fullscreenControlsVisible
                                            ? 1
                                            : 0,
                                        child: IgnorePointer(
                                          ignoring: !_fullscreenControlsVisible,
                                          child: Center(
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .surface
                                                      .withValues(alpha: 
                                                        isDark ? 0.28 : 0.40,
                                                      ),
                                                  border: Border.all(
                                                    color: isDark
                                                        ? Colors.white10
                                                        : Colors.black12,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    IconButton.filledTonal(
                                                      onPressed:
                                                          widget
                                                              .player
                                                              .hasPrevious
                                                          ? () => widget.player
                                                                .seekToPrevious()
                                                          : null,
                                                      icon: const Icon(
                                                        Icons
                                                            .skip_previous_rounded,
                                                      ),
                                                      style:
                                                          IconButton.styleFrom(
                                                            backgroundColor:
                                                                iconBgColor
                                                                    .withValues(alpha: 
                                                                      0.30,
                                                                    ),
                                                            foregroundColor:
                                                                iconFgColor,
                                                          ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    StreamBuilder<PlayerState>(
                                                      stream: widget
                                                          .player
                                                          .playerStateStream,
                                                      builder: (context, snap) {
                                                        final playing =
                                                            snap
                                                                .data
                                                                ?.playing ??
                                                            false;
                                                        return IconButton.filledTonal(
                                                          onPressed: playing
                                                              ? widget
                                                                    .player
                                                                    .pause
                                                              : widget
                                                                    .player
                                                                    .play,
                                                          icon: Icon(
                                                            playing
                                                                ? Icons
                                                                      .pause_rounded
                                                                : Icons
                                                                      .play_arrow_rounded,
                                                          ),
                                                          style: IconButton.styleFrom(
                                                            backgroundColor:
                                                                iconBgColor
                                                                    .withValues(alpha: 
                                                                      0.30,
                                                                    ),
                                                            foregroundColor:
                                                                iconFgColor,
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                    const SizedBox(width: 6),
                                                    IconButton.filledTonal(
                                                      onPressed:
                                                          widget.player.hasNext
                                                          ? () => widget.player
                                                                .seekToNext()
                                                          : null,
                                                      icon: const Icon(
                                                        Icons.skip_next_rounded,
                                                      ),
                                                      style:
                                                          IconButton.styleFrom(
                                                            backgroundColor:
                                                                iconBgColor
                                                                    .withValues(alpha: 
                                                                      0.30,
                                                                    ),
                                                            foregroundColor:
                                                                iconFgColor,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _displayedSong.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: textColor,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _openDetailAfterClosingNowPlaying(widget.onOpenArtist);
                      },
                      child: Text(
                        _displayedSong.artist ?? "Unknown Artist",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: textColor.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _openDetailAfterClosingNowPlaying(widget.onOpenAlbum);
                      },
                      child: Text(
                        _displayedSong.album ?? "Unknown Album",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColorSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: lyricsPanelBg,
                      border: Border.all(
                        color: isDark ? Colors.white10 : Colors.black12,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: _buildLyricsView(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    // Adjust colors based on theme - lighter in light mode, darker in dark mode
    Color adjustColorForTheme(Color color) {
      final hsl = HSLColor.fromColor(color);
      if (isDark) {
        // Deep, rich colors for dark mode.
        return hsl
            .withSaturation((hsl.saturation * 0.95).clamp(0.0, 1.0))
            .withLightness((hsl.lightness * 0.5).clamp(0.25, 0.45))
            .toColor();
      } else {
        // Lighter colors for light mode
        return hsl
            .withLightness((hsl.lightness * 0.5 + 0.5).clamp(0.6, 0.9))
            .toColor();
      }
    }

    // If there's no artwork, lean into Material You (wallpaper) colors.
    final defaultTopColor = cs.primaryContainer;
    final defaultMidColor = cs.tertiaryContainer;
    final defaultAccentColor = cs.primary;
    final defaultBottomColor = cs.surface;

    final targetTopColor = _primaryColor != null
        ? adjustColorForTheme(_primaryColor!)
        : defaultTopColor;
    final targetMidColor = _secondaryColor != null
        ? adjustColorForTheme(_secondaryColor!)
        : defaultMidColor;
    final targetAccentColor = _tertiaryColor != null
      ? adjustColorForTheme(_tertiaryColor!)
      : Color.lerp(targetTopColor, targetMidColor, 0.45) ?? defaultAccentColor;
    final hasColors =
      _primaryColor != null && _secondaryColor != null && _tertiaryColor != null;
    final bottomColor = hasColors ? cs.surface : defaultBottomColor;

    final textColor = isDark ? Colors.white : Colors.black87;
    final textColorSecondary = isDark ? Colors.white70 : Colors.black54;
    final iconBgColor = isDark
        ? Colors.white10
        : Colors.black.withValues(alpha: 0.08);
    final iconFgColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Dismissible(
        key: const Key('play_screen_dismiss'),
        direction: _fullscreenLandscape
            ? DismissDirection.none
            : DismissDirection.down,
        onDismissed: (_) => Navigator.pop(context),
        child: TweenAnimationBuilder<Color?>(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          tween: ColorTween(end: targetTopColor),
          builder: (context, topColor, child) {
            return TweenAnimationBuilder<Color?>(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              tween: ColorTween(end: targetMidColor),
              builder: (context, midColor, child) {
                return TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  tween: ColorTween(end: targetAccentColor),
                  builder: (context, accentColor, child) {
                    final c1 = topColor ?? targetTopColor;
                    final c2 = midColor ?? targetMidColor;
                    final c3 = accentColor ?? targetAccentColor;

                    return AnimatedBuilder(
                      animation: _bgGradientController,
                      builder: (context, _) {
                        final size = MediaQuery.of(context).size;
                        final maxDim = math.max(size.width, size.height);
                        final blobSize = maxDim * 1.2;

                        final t = _bgGradientController.value;
                        
                        // Lissajous curve paths mapped to [0, 1] for Positioned
                        final x1 = (math.sin(t * math.pi * 2) + 1) / 2;
                        final y1 = (math.cos(t * math.pi * 4) + 1) / 2;
                        
                        final x2 = (math.cos(t * math.pi * 2 + math.pi) + 1) / 2;
                        final y2 = (math.sin(t * math.pi * 6) + 1) / 2;
                        
                        final x3 = (math.sin(t * math.pi * 4 + math.pi / 4) + 1) / 2;
                        final y3 = (math.cos(t * math.pi * 2 + math.pi / 4) + 1) / 2;

                        final x4 = (math.cos(t * math.pi * 2 + math.pi / 2) + 1) / 2;
                        final y4 = (math.sin(t * math.pi * 4 + math.pi / 2) + 1) / 2;

                        Widget buildBlob(double xOffset, double yOffset, Color color, double scale) {
                          return Positioned(
                            left: xOffset * size.width - (blobSize * scale) / 2,
                            top: yOffset * size.height - (blobSize * scale) / 2,
                            child: Container(
                              width: blobSize * scale,
                              height: blobSize * scale,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    color.withValues(alpha: 1.0),
                                    color.withValues(alpha: 0.75),
                                    color.withValues(alpha: 0.0),
                                  ],
                                  stops: const [0.0, 0.45, 1.0],
                                ),
                              ),
                            ),
                          );
                        }

                        final gradientLayer = DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [c1.withValues(alpha: 0.8), c3.withValues(alpha: 0.8)],
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              buildBlob(x1, y1 * 0.5, c1, 1.4),
                              buildBlob(x2, (y2 * 0.5) + 0.5, c2, 1.5),
                              buildBlob(x3, y3, c3, 1.3),
                              buildBlob(x4, (y4 * 0.3) + 0.7, c2, 1.6), // Bottom coverage
                            ],
                          ),
                        );

                        final vignette = DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment.topCenter,
                              radius: 1.1,
                              colors: [
                                Colors.transparent,
                                (isDark ? Colors.black : Colors.white).withValues(alpha: 
                                  isDark ? 0.22 : 0.16,
                                ),
                              ],
                              stops: const [0.55, 1.0],
                            ),
                          ),
                        );

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            gradientLayer,
                            IgnorePointer(child: vignette),
                            child!,
                          ],
                        );

                      },
                    );
                  },
                  child: child,
                );
              },
              child: child,
            );
          },
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(
                        icon: const Icon(Icons.keyboard_arrow_down),
                        onPressed: () => Navigator.pop(context),
                        style: IconButton.styleFrom(
                          backgroundColor: iconBgColor,
                          foregroundColor: iconFgColor,
                        ),
                      ),
                      Text(
                        "Now Playing",
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: textColorSecondary,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_fullscreenLandscape) ...[
                            IconButton.filledTonal(
                              icon: const Icon(Icons.queue_music_rounded),
                              onPressed: () => Navigator.push(
                                context,
                                PageRouteBuilder(
                                  opaque: false,
                                  pageBuilder: (_, __, ___) => QueuePage(
                                    player: widget.player,
                                    songs: widget.songs,
                                    currentIndex:
                                        widget.player.currentIndex ?? 0,
                                    onPlayIndex: (index) => widget.player.seek(
                                      Duration.zero,
                                      index: index,
                                    ),
                                    playlist: widget.playlist,
                                    onQueueChanged:
                                        widget.onQueueChanged ?? (_) {},
                                  ),
                                  transitionsBuilder:
                                      (
                                        context,
                                        animation,
                                        secondaryAnimation,
                                        child,
                                      ) {
                                        return SlideTransition(
                                          position:
                                              Tween(
                                                    begin: const Offset(
                                                      0.0,
                                                      1.0,
                                                    ),
                                                    end: Offset.zero,
                                                  )
                                                  .chain(
                                                    CurveTween(
                                                      curve:
                                                          Curves.easeOutCubic,
                                                    ),
                                                  )
                                                  .animate(animation),
                                          child: child,
                                        );
                                      },
                                ),
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: iconBgColor,
                                foregroundColor: iconFgColor,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton.filledTonal(
                              icon: Icon(
                                _showLyrics
                                    ? Icons.image_rounded
                                    : Icons.lyrics_rounded,
                              ),
                              onPressed: () => _setLyricsVisible(!_showLyrics),
                              style: IconButton.styleFrom(
                                backgroundColor: iconBgColor,
                                foregroundColor: iconFgColor,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          PopupMenuButton<String>(
                            icon: Icon(
                              Icons.more_vert_rounded,
                              color: textColorSecondary,
                            ),
                            tooltip: 'More actions',
                            color: cs.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            onSelected: (value) async {
                              HapticFeedback.selectionClick();
                              if (value == 'fullscreen_toggle') {
                                await _setFullscreenLandscape(
                                  !_fullscreenLandscape,
                                );
                              } else if (value == 'edit_tags') {
                                final result = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => TagEditorDialog(
                                    song: _displayedSong,
                                    onSaved: _reloadDisplayedSongMetadata,
                                    onSongUpdated: (updatedSong) {
                                      setState(() {
                                        _displayedSong = updatedSong;
                                      });
                                      widget.onSongUpdated?.call(updatedSong);
                                    },
                                    runWithPlaybackSuspended: (action) =>
                                        runWithPlayerPlaybackSuspended(
                                          widget.player,
                                          widget.playlist,
                                          action,
                                          targetFilePath: _displayedSong.data,
                                        ),
                                  ),
                                );
                                if (result == true) {
                                  _reloadDisplayedSongMetadata();
                                }
                              } else if (value == 'edit_lyrics') {
                                final result = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => LyricsEditorDialog(
                                    song: _displayedSong,
                                    currentLyrics: _rawLyrics,
                                    onSaved: () => _loadLyrics(),
                                    onLyricsSaved: (lyrics) {
                                      _loadLyrics();
                                    },
                                    runWithPlaybackSuspended: (action) =>
                                        runWithPlayerPlaybackSuspended(
                                          widget.player,
                                          widget.playlist,
                                          action,
                                          targetFilePath: _displayedSong.data,
                                        ),
                                  ),
                                );
                                if (result == true) {
                                  _loadLyrics();
                                }
                              }
                            },
                            itemBuilder: (context) {
                              final menuTextColor = isDark
                                  ? Colors.white
                                  : Colors.black87;
                              final menuIconColor = isDark
                                  ? Colors.white70
                                  : Colors.black54;
                              final fullscreenLabel = _fullscreenLandscape
                                  ? 'Exit fullscreen'
                                  : 'Fullscreen';
                              final fullscreenIcon = _fullscreenLandscape
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded;
                              return [
                                PopupMenuItem(
                                  value: 'fullscreen_toggle',
                                  child: Row(
                                    children: [
                                      Icon(
                                        fullscreenIcon,
                                        size: 20,
                                        color: menuIconColor,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        fullscreenLabel,
                                        style: TextStyle(color: menuTextColor),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!_fullscreenLandscape) ...[
                                  PopupMenuItem(
                                    value: 'edit_tags',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.edit_rounded,
                                          size: 20,
                                          color: menuIconColor,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          'Edit Tags',
                                          style: TextStyle(
                                            color: menuTextColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit_lyrics',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.lyrics_rounded,
                                          size: 20,
                                          color: menuIconColor,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          'Edit Lyrics',
                                          style: TextStyle(
                                            color: menuTextColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ];
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _fullscreenLandscape
                      ? _buildFullscreenLandscapeView(
                          isDark: isDark,
                          textColor: textColor,
                          textColorSecondary: textColorSecondary,
                          iconBgColor: iconBgColor,
                          iconFgColor: iconFgColor,
                        )
                      : OrientationBuilder(
                          builder: (context, orientation) {
                            final isLandscape =
                                orientation == Orientation.landscape;

                            Widget artworkOrLyrics() {
                              return GestureDetector(
                                onTap: () => _setLyricsVisible(!_showLyrics),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 400),
                                  child: _showLyrics
                                      ? _buildLyricsView()
                                      : _buildArtworkView(),
                                ),
                              );
                            }

                            Widget songMeta({double titleSize = 22}) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _displayedSong.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                          letterSpacing: -0.5,
                                          fontSize: titleSize,
                                        ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      _openDetailAfterClosingNowPlaying(
                                        widget.onOpenArtist,
                                      );
                                    },
                                    child: Text(
                                      _displayedSong.artist ?? "Unknown Artist",
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: textColor.withValues(alpha: 0.8),
                                            fontWeight: FontWeight.w500,
                                          ),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      _openDetailAfterClosingNowPlaying(
                                        widget.onOpenAlbum,
                                      );
                                    },
                                    child: Text(
                                      _displayedSong.album ?? "Unknown Album",
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: textColorSecondary,
                                            fontWeight: FontWeight.w400,
                                          ),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              );
                            }

                            Widget seekAndTime() {
                              return ValueListenableBuilder<bool>(
                                valueListenable: appIsForeground,
                                builder: (context, isFg, _) {
                                  if (!isFg) {
                                    final position = widget.player.position;
                                    final total =
                                        widget.player.duration ?? Duration.zero;
                                    final isPlaying = widget.player.playing;
                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SquigglySeekBar(
                                          position: position,
                                          duration: total,
                                          isPlaying: isPlaying,
                                          onChanged: (val) =>
                                              widget.player.seek(val),
                                          isDark: isDark,
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                formatTime(
                                                  position.inMilliseconds,
                                                ),
                                                style: TextStyle(
                                                  color: textColorSecondary,
                                                ),
                                              ),
                                              Text(
                                                formatTime(
                                                  total.inMilliseconds,
                                                ),
                                                style: TextStyle(
                                                  color: textColorSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  }

                                  return StreamBuilder<PlayerState>(
                                    stream: widget.player.playerStateStream,
                                    builder: (context, playerSnapshot) {
                                      final isPlaying =
                                          playerSnapshot.data?.playing ?? false;
                                      return StreamBuilder<Duration>(
                                        stream: widget.player.positionStream,
                                        builder: (context, snapshot) {
                                          final position =
                                              snapshot.data ?? Duration.zero;
                                          final total =
                                              widget.player.duration ??
                                              Duration.zero;
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SquigglySeekBar(
                                                position: position,
                                                duration: total,
                                                isPlaying: isPlaying,
                                                onChanged: (val) =>
                                                    widget.player.seek(val),
                                                isDark: isDark,
                                              ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                    ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Text(
                                                      formatTime(
                                                        position.inMilliseconds,
                                                      ),
                                                      style: TextStyle(
                                                        color:
                                                            textColorSecondary,
                                                      ),
                                                    ),
                                                    Text(
                                                      formatTime(
                                                        total.inMilliseconds,
                                                      ),
                                                      style: TextStyle(
                                                        color:
                                                            textColorSecondary,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              );
                            }

                            

                            if (!isLandscape) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24.0,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(child: artworkOrLyrics()),
                                    const SizedBox(height: 32),
                                    songMeta(titleSize: 22),
                                    const SizedBox(height: 28),
                                    seekAndTime(),
                                    const SizedBox(height: 24),
                                    NowPlayingTransport(
                                      player: widget.player,
                                      isDark: isDark,
                                      iconFgColor: iconFgColor,
                                      accentColor: _primaryColor ?? _secondaryColor,
                                      onPlayPressed: () async {
                                        final ok = await ensureNotificationPermissionIfNeeded();
                                        if (!ok && context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: const Text(
                                                'Notifications are blocked, so the player notification can\'t be shown.',
                                              ),
                                              behavior: SnackBarBehavior.floating,
                                              action: SnackBarAction(
                                                label: 'Settings',
                                                onPressed: () => AndroidNotifications.openAppNotificationSettings(),
                                              ),
                                            ),
                                          );
                                        }
                                        widget.player.play();
                                      },
                                    ),
                                    const SizedBox(height: 40),
                                  ],
                                ),
                              );
                            }

                            // Landscape: use two columns and allow the right side to scroll if needed.
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: Center(child: artworkOrLyrics()),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 6,
                                    child: SingleChildScrollView(
                                      physics: const BouncingScrollPhysics(),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(height: 8),
                                          songMeta(titleSize: 20),
                                          const SizedBox(height: 16),
                                          seekAndTime(),
                                          const SizedBox(height: 14),
                                          NowPlayingTransport(
                                            player: widget.player,
                                            isDark: isDark,
                                            iconFgColor: iconFgColor,
                                            accentColor: _primaryColor ?? _secondaryColor,
                                            onPlayPressed: () async {
                                              final ok = await ensureNotificationPermissionIfNeeded();
                                              if (!ok && context.mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: const Text(
                                                      'Notifications are blocked, so the player notification can\'t be shown.',
                                                    ),
                                                    behavior: SnackBarBehavior.floating,
                                                    action: SnackBarAction(
                                                      label: 'Settings',
                                                      onPressed: () => AndroidNotifications.openAppNotificationSettings(),
                                                    ),
                                                  ),
                                                );
                                              }
                                              widget.player.play();
                                            },
                                          ),
                                          const SizedBox(height: 16),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircleButton(
    IconData icon,
    Color color,
    VoidCallback? onPressed, {
    double size = 24,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onPressed == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onPressed();
              },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }

  Widget _buildArtworkPageView({required double side}) {
    final sequence = widget.player.sequence;
    if (sequence.isEmpty) {
      return _buildNowPlayingArtwork(side: side);
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: sequence.length,
      onPageChanged: (index) {
        if (index != widget.player.currentIndex) {
          widget.player.seek(Duration.zero, index: index);
        }
      },
      itemBuilder: (context, index) {
        final currentSource = sequence[index];
        final tag = currentSource.tag;
        
        int? songId;
        if (tag is MediaItem) {
          songId = int.tryParse(tag.id);
        } else if (tag is SongModel) {
          songId = tag.id;
        }

        if (songId == null) {
          return _buildNowPlayingArtwork(side: side);
        }

        final artworkWidget = FastArtworkWidget(
          id: songId,
          type: ArtworkType.AUDIO,
          size: 900,
          quality: 100,
          width: side,
          height: side,
          keepOldArtwork: true,
          nullArtworkWidget: Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Icon(
              Icons.music_note,
              size: 100,
              color: Colors.white38,
            ),
          ),
        );

        if (songId == _displayedSong.id) {
          return Hero(
            tag: 'mini_artwork_$songId',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: artworkWidget,
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: artworkWidget,
        );
      },
    );
  }

  Widget _buildArtworkView({Alignment alignment = Alignment.center}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSide = math.min(constraints.maxWidth, constraints.maxHeight);
        final side = (maxSide.isFinite ? maxSide : 320.0).clamp(160.0, 340.0);

        final pulse = Tween<double>(begin: 1.0, end: 1.02).animate(
          CurvedAnimation(
            parent: _artworkPulseController,
            curve: Curves.easeInOut,
          ),
        );

        return Align(
          alignment: alignment,
          child: ScaleTransition(
            scale: pulse,
            child: SizedBox(
              width: side,
              height: side,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: (_primaryColor ?? Colors.black).withValues(alpha: 0.5),
                      blurRadius: 40,
                      spreadRadius: 10,
                      offset: const Offset(0, 15),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: _buildArtworkPageView(side: side),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLyricsView() {
    if (_rawLyrics == null) {
      return Container(
        alignment: Alignment.center,
        child: const Text(
          "No Lyrics Found",
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
      );
    }

    // Non-synced lyrics: keep it simple (no auto-scroll).
    if (!_isSynced || _lrcLines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Text(
            _rawLyrics!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification ||
                notification is UserScrollNotification) {
              _pauseAutoScroll();
            }
            return false;
          },
          child: ScrollablePositionedList.builder(
            itemScrollController: _lyricItemScrollController,
            itemPositionsListener: _lyricItemPositionsListener,
            itemCount: _lrcLines.length,
            padding: const EdgeInsets.symmetric(vertical: 20),
            physics: const BouncingScrollPhysics(),
            itemBuilder: (context, index) {
              final line = _lrcLines[index];
              return _LyricLineTile(
                index: index,
                line: line,
                activeIndex: _activeLyricIndex,
                onTap: () {
                  _pauseAutoScroll();
                  widget.player.seek(line.time);
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _LyricLineTile extends StatefulWidget {
  final int index;
  final LyricLine line;
  final ValueListenable<int> activeIndex;
  final VoidCallback onTap;

  const _LyricLineTile({
    required this.index,
    required this.line,
    required this.activeIndex,
    required this.onTap,
  });

  @override
  State<_LyricLineTile> createState() => _LyricLineTileState();
}

class _LyricLineTileState extends State<_LyricLineTile> {
  static const int _nearWindow = 2;

  late _LyricTileMode _mode;

  _LyricTileMode _computeMode(int active) {
    if (widget.index == active) return _LyricTileMode.active;
    if ((widget.index - active).abs() <= _nearWindow) {
      return _LyricTileMode.near;
    }
    return _LyricTileMode.normal;
  }

  void _handleActiveChanged() {
    final next = _computeMode(widget.activeIndex.value);
    if (next == _mode) return;
    if (!mounted) return;
    setState(() => _mode = next);
  }

  @override
  void initState() {
    super.initState();
    _mode = _computeMode(widget.activeIndex.value);
    widget.activeIndex.addListener(_handleActiveChanged);
  }

  @override
  void didUpdateWidget(covariant _LyricLineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      oldWidget.activeIndex.removeListener(_handleActiveChanged);
      widget.activeIndex.addListener(_handleActiveChanged);
    }
    final next = _computeMode(widget.activeIndex.value);
    if (next != _mode) _mode = next;
  }

  @override
  void dispose() {
    widget.activeIndex.removeListener(_handleActiveChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _mode == _LyricTileMode.active;
    final isNear = _mode == _LyricTileMode.near;
    final opacity = isActive ? 1.0 : (isNear ? 0.75 : 0.55);
    final scale = isActive ? 1.0 : (isNear ? 0.98 : 0.96);
    final weight = isActive ? FontWeight.w700 : FontWeight.w500;
    final shadows = isActive
        ? <Shadow>[
            Shadow(
              color: Colors.white.withValues(alpha: 0.28),
              blurRadius: 14,
              offset: Offset.zero,
            ),
          ]
        : const <Shadow>[];

    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: opacity,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 220),
            scale: scale,
            child: Text(
              widget.line.content,
              textAlign: TextAlign.center,
              softWrap: true,
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: weight,
                height: 1.30,
                shadows: shadows,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _LyricTileMode { active, near, normal }
