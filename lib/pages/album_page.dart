import '../data/models/album_stat.dart';
import '../data/models/sort_mode.dart';
import '../data/models/isolate_data.dart';
import '../data/models/user_playlist.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:typed_data';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:audiotags/audiotags.dart';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/rendering.dart';
import '../core/theme/app_theme.dart';
import '../widgets/song_options_sheet.dart';
import '../app_audio_handler.dart';
import '../android_notifications.dart';
import '../platform_exit.dart';
import '../services/app_local_store.dart';
import '../services/playback_controller.dart';
import '../services/local_audio_scanner.dart';
import '../data/services/caching_service.dart';
import '../utils/file_ops.dart';
import '../utils/palette_compute.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../ui/shared/frosted_card.dart';
import '../ui/shared/squiggly_seek_bar.dart';
import '../widgets/now_playing_transport.dart';
import '../dialogs/lyrics_editor_dialog.dart';
import '../dialogs/playlist_dialogs.dart';
import '../dialogs/tag_editor_dialog.dart';
import '../pages/queue_page.dart';
import '../utils/lyrics.dart';
import '../utils/tag_write_access.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_search_delegate.dart';
import '../utils/format_utils.dart';
import '../utils/song_sort_utils.dart';
import '../dialogs/folder_management_dialog.dart';
import '../main.dart';

class AlbumPage extends StatefulWidget {
  final AudioPlayer player;
  final int albumId;
  final String albumTitle;
  final String albumArtist;
  final List<SongModel> songs;
  final List<SongModel> librarySongs;
  final ConcatenatingAudioSource? playlist;
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
    required this.playlist,
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

  static Future<({Color primary, Color secondary, Color tertiary})?> _loadAlbumPalette(
    int albumId,
    bool _isDark,
  ) async {
    try {
      final cached = _albumPaletteCache.remove(albumId);
      if (cached != null) {
        // LRU: re-insert as most recently used.
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

      final primary = _boostVibrance(
        Color(primaryColorInt),
        extraSaturation: 0.18,
        extraLightness: 0.04,
      );
      final secondary = _boostVibrance(
        Color(secondaryColorInt),
        extraSaturation: 0.14,
        extraLightness: -0.02,
      );
      final tertiary = _boostVibrance(
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

  int _totalDurationMs() {
    int sum = 0;
    for (final s in songs) {
      sum += (s.duration ?? 0);
    }
    return sum;
  }

  Widget _buildContent(
    BuildContext context,
    Future<({Color primary, Color secondary, Color tertiary})?> paletteFuture,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalMs = _totalDurationMs();
    final subtitle = '${songs.length} tracks • ${formatTime(totalMs)}';

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
                  bgA.withOpacity(isDark ? 0.20 : 0.10),
                  cs.surface,
                )
              : cs.surface;
          final mid = bgB != null
              ? Color.alphaBlend(
                  bgB.withOpacity(isDark ? 0.12 : 0.06),
                  cs.surface,
                )
              : cs.surface;
          final accent = bgC != null
              ? Color.alphaBlend(
                  bgC.withOpacity(isDark ? 0.08 : 0.04),
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
              CustomScrollView(
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
                      albumTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    centerTitle: false,
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                                      blurRadius: 16,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: FastArtworkWidget(
                                    id: albumId,
                                    type: ArtworkType.ALBUM,
                                    width: 110,
                                    height: 110,
                                    nullArtworkWidget: Container(
                                      width: 110,
                                      height: 110,
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Icon(
                                        Icons.album_rounded,
                                        color: cs.onSurfaceVariant,
                                        size: 44,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      albumTitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.4,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      albumArtist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: cs.secondaryContainer.withOpacity(
                                          isDark ? 0.30 : 0.60,
                                        ),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(
                                          color: cs.outlineVariant.withOpacity(0.35),
                                        ),
                                      ),
                                      child: Text(
                                        subtitle,
                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSecondaryContainer.withOpacity(0.92),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: songs.isEmpty
                                      ? null
                                      : () => onPlaySong(songs.first),
                                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                                  label: const Text('Play', style: TextStyle(fontWeight: FontWeight.w700)),
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 11),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed: songs.isEmpty
                                      ? null
                                      : () {
                                          if (onShuffle != null) {
                                            onShuffle!();
                                          } else {
                                            final shuffled = List<SongModel>.from(songs)..shuffle();
                                            onPlaySong(shuffled.first);
                                          }
                                        },
                                  icon: const Icon(Icons.shuffle_rounded, size: 18),
                                  label: const Text('Shuffle', style: TextStyle(fontWeight: FontWeight.w700)),
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 11),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
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
                  SliverList.separated(
                    itemCount: songs.length,
                    separatorBuilder: (context, index) => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(height: 1),
                    ),
                    itemBuilder: (context, i) {
                      final s = songs[i];
                      final trackNo = _normalizedTrackNo(s.track ?? 0);
                      final dur = s.duration ?? 0;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 2,
                        ),
                        leading: SizedBox(
                          width: 34,
                          child: Text(
                            trackNo > 0 ? trackNo.toString() : '–',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        title: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          s.artist ?? 'Unknown',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          formatTime(dur),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onPlaySong(s);
                        },
                      );
                    },
                  ),
                  if (embeddedInHome)
                    buildBottomBarsGutter(context)
                  else
                    const SliverToBoxAdapter(child: SizedBox(height: 18)),
                ],
              ),
            ],
          );
        },
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

class _AlbumPageState extends State<AlbumPage> {
  late Future<({Color primary, Color secondary, Color tertiary})?> _paletteFuture;
  Brightness? _lastBrightness;

  @override
  void initState() {
    super.initState();
    _lastBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _paletteFuture = AlbumPage._loadAlbumPalette(
      widget.albumId,
      _lastBrightness == Brightness.dark,
    );
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
    if (oldWidget.albumId == widget.albumId) return;
    _paletteFuture = AlbumPage._loadAlbumPalette(
      widget.albumId,
      Theme.of(context).brightness == Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget._buildContent(context, _paletteFuture);
  }
}

