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

enum PlaylistSort { manual, artist, albumArtist, year, albumArtistYear }
class SmartPlaylistPage extends StatelessWidget {

  const SmartPlaylistPage({
    required this.player,
    required this.title,
    required this.description,
    required this.icon,
    required this.songs,
    required this.librarySongs,
    required this.playlist,
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
  final ConcatenatingAudioSource? playlist;
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
                    color: cs.outlineVariant.withOpacity(0.35),
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
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.4,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
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
                                color: cs.secondaryContainer.withOpacity(
                                  isDark ? 0.25 : 0.55,
                                ),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: cs.outlineVariant.withOpacity(0.35),
                                ),
                              ),
                              child: Text(
                                subtitle,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSecondaryContainer
                                          .withOpacity(0.92),
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
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = songs[index];
                final cs = Theme.of(context).colorScheme;
                final artistText = (song.artist ?? '').trim().isEmpty
                    ? 'Unknown Artist'
                    : song.artist!.trim();
                final albumText = (song.album ?? '').trim().isEmpty
                    ? 'Unknown Album'
                    : song.album!.trim();

                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: cs.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: cs.outlineVariant.withOpacity(0.35),
                        ),
                      ),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onPlaySong(song);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              ClipOval(
                                child: FastArtworkWidget(
                                  id: song.id,
                                  type: ArtworkType.AUDIO,
                                  width: 54,
                                  height: 54,
                                  nullArtworkWidget: Container(
                                    width: 54,
                                    height: 54,
                                    decoration: BoxDecoration(
                                      color: cs.surfaceContainerHighest,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.music_note_rounded,
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
                                      song.title,
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
                                      artistText,
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
                                    Text(
                                      albumText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant
                                                .withOpacity(0.75),
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              IconButton.filledTonal(
                                icon: const Icon(Icons.play_arrow_rounded),
                                tooltip: 'Play',
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  onPlaySong(song);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: songs.length),
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

class UserPlaylistPage extends StatefulWidget {
  const UserPlaylistPage({
    required this.player,
    required this.playlistId,
    required this.playlistName,
    required this.initialSongIds,
    required this.librarySongs,
    required this.playlist,
    required this.onQueueChanged,
    required this.selectedTabIndex,
    required this.onNavigateTab,
    this.embeddedInHome = false,
    this.onClose,
    required this.onOpenNowPlaying,
    required this.playFromQueue,
    required this.onUpdateSongIds,
  });

  final AudioPlayer player;
  final String playlistId;
  final String playlistName;
  final List<int> initialSongIds;
  final List<SongModel> librarySongs;
  final ConcatenatingAudioSource? playlist;
  final Function(List<SongModel>) onQueueChanged;
  final int selectedTabIndex;
  final ValueChanged<int> onNavigateTab;
  final bool embeddedInHome;
  final VoidCallback? onClose;
  final Function(SongModel) onOpenNowPlaying;
  final Future<void> Function(List<SongModel> songs, int initialIndex)
  playFromQueue;
  final Future<void> Function(String playlistId, List<int> newSongIds)
  onUpdateSongIds;

  @override
  State<UserPlaylistPage> createState() => UserPlaylistPageState();
}

class UserPlaylistPageState extends State<UserPlaylistPage> {
  late List<int> _songIds;
  late List<int> _manualSongIds;
  PlaylistSort _playlistSort = PlaylistSort.manual;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearching = false;
  bool _selectionMode = false;
  final Set<int> _selectedSongIds = <int>{};

  static final Map<int, ({Color primary, Color secondary, Color tertiary})>
  _playlistPaletteCache = {};
  static const int _playlistPaletteCacheMax = 64;

  Future<({Color primary, Color secondary, Color tertiary})?>? _paletteFuture;
  int? _paletteSongId;
  Brightness? _lastBrightness;

  static Future<({Color primary, Color secondary, Color tertiary})?> _loadPlaylistPalette(
    int songId,
  ) async {
    try {
      final cached = _playlistPaletteCache.remove(songId);
      if (cached != null) {
        _playlistPaletteCache[songId] = cached;
        return cached;
      }

      final bytes = await queryArtworkBytesCached(
        songId,
        type: ArtworkType.AUDIO,
        size: 320,
      );
      if (bytes == null) return null;

      final result = await computePaletteFromBytes(bytes);
      final primaryColorInt = result['primary'] ?? 0xFF303030;
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

      final value = (
        primary: primary,
        secondary: secondary,
        tertiary: tertiary,
      );
      _playlistPaletteCache.remove(songId);
      _playlistPaletteCache[songId] = value;
      while (_playlistPaletteCache.length > _playlistPaletteCacheMax) {
        _playlistPaletteCache.remove(_playlistPaletteCache.keys.first);
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  void _syncPalette(int? leadSongId) {
    if (leadSongId == _paletteSongId && _paletteFuture != null) return;
    _paletteSongId = leadSongId;
    if (leadSongId != null) {
      _paletteFuture = _loadPlaylistPalette(leadSongId);
    } else {
      _paletteFuture = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _songIds = List<int>.from(widget.initialSongIds);
    _manualSongIds = List<int>.from(widget.initialSongIds);
    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next == _searchQuery) return;
      setState(() => _searchQuery = next);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Map<int, SongModel> _idToSong() {
    return {for (final s in widget.librarySongs) s.id: s};
  }

  List<int> _visibleSongIds(Map<int, SongModel> map) {
    return _songIds.where(map.containsKey).toList();
  }

  Future<void> _persistSongIds() async {
    await widget.onUpdateSongIds(widget.playlistId, _songIds);
  }



  Future<void> _playShuffledQueue(List<SongModel> songs) async {
    if (songs.isEmpty) return;
    final shuffled = List<SongModel>.from(songs);
    shuffled.shuffle(math.Random());
    await widget.playFromQueue(shuffled, 0);
  }

  void _enterSelectionMode(int songId) {
    setState(() {
      _selectionMode = true;
      _selectedSongIds.add(songId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedSongIds.clear();
    });
  }

  void _toggleSelection(int songId) {
    setState(() {
      if (_selectedSongIds.contains(songId)) {
        _selectedSongIds.remove(songId);
      } else {
        _selectedSongIds.add(songId);
      }
      if (_selectedSongIds.isEmpty) _selectionMode = false;
    });
  }

  Future<void> _removeSongsByIds(List<int> ids, {bool showUndo = true}) async {
    final removeSet = ids.toSet();
    if (removeSet.isEmpty) return;

    final prevSongIds = List<int>.from(_songIds);
    final prevManual = List<int>.from(_manualSongIds);
    final prevSort = _playlistSort;

    setState(() {
      _songIds = _songIds.where((id) => !removeSet.contains(id)).toList();
      _manualSongIds = _manualSongIds
          .where((id) => !removeSet.contains(id))
          .toList();
      _selectedSongIds.removeAll(removeSet);
      if (_selectedSongIds.isEmpty) _selectionMode = false;
    });

    if (_playlistSort == PlaylistSort.manual) {
      await _persistSongIds();
    } else {
      await _applyPlaylistSort(_playlistSort);
    }

    if (!mounted || !showUndo || removeSet.length != 1) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('Removed from playlist'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              setState(() {
                _songIds = List<int>.from(prevSongIds);
                _manualSongIds = List<int>.from(prevManual);
                _playlistSort = prevSort;
              });
              unawaited(_persistSongIds());
            },
          ),
        ),
      );
  }

  Future<void> _confirmRemoveSelected() async {
    if (_selectedSongIds.isEmpty) return;
    final count = _selectedSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove songs?'),
        content: Text(
          'Remove $count song${count == 1 ? '' : 's'} from this playlist?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ids = _selectedSongIds.toList(growable: false);
    await _removeSongsByIds(ids, showUndo: false);
  }

  Future<void> _copyPlaylistText(List<SongModel> songs) async {
    final lines = <String>[];
    for (final s in songs) {
      final artist = (s.artist ?? '').trim();
      final text = artist.isEmpty ? s.title : '${s.title} - $artist';
      lines.add(text);
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Playlist copied to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _copyPlaylistM3u(List<SongModel> songs) async {
    final lines = <String>['#EXTM3U'];
    for (final s in songs) {
      final seconds = ((s.duration ?? 0) / 1000).round();
      final artist = (s.artist ?? '').trim();
      final info = artist.isEmpty ? s.title : '${artist} - ${s.title}';
      lines.add('#EXTINF:$seconds,$info');
      lines.add(s.data);
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('M3U playlist copied to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _sanitizeFileName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'playlist';
    final sanitized = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return sanitized.isEmpty ? 'playlist' : sanitized;
  }

  Future<void> _exportPlaylistM3u(List<SongModel> songs) async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Export is not supported on web builds.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose export folder',
    );
    if (dir == null || dir.trim().isEmpty) return;

    final base = _sanitizeFileName(widget.playlistName);
    final sep = dir.contains('\\') ? '\\' : '/';
    final basePath = dir.endsWith(sep) ? dir : '$dir$sep';
    var path = '${basePath}${base}.m3u';
    if (await fileExists(path)) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      path = '${basePath}${base}_$stamp.m3u';
    }

    final lines = <String>['#EXTM3U'];
    for (final s in songs) {
      final seconds = ((s.duration ?? 0) / 1000).round();
      final artist = (s.artist ?? '').trim();
      final info = artist.isEmpty ? s.title : '${artist} - ${s.title}';
      lines.add('#EXTINF:$seconds,$info');
      lines.add(s.data);
    }

    await writeFile(path, lines.join('\n'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Playlist exported to $path'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _playlistSortLabel(PlaylistSort mode) {
    switch (mode) {
      case PlaylistSort.manual:
        return 'Manual';
      case PlaylistSort.artist:
        return 'Artist';
      case PlaylistSort.albumArtist:
        return 'Album Artist';
      case PlaylistSort.year:
        return 'Year';
      case PlaylistSort.albumArtistYear:
        return 'Album Artist/Year';
    }
  }

  static final RegExp _playlistYearRegex = RegExp(r'(19|20)\d{2}');













  Future<void> _applyPlaylistSort(PlaylistSort mode) async {
    if (!mounted) return;
    final map = _idToSong();

    if (mode == PlaylistSort.manual) {
      setState(() {
        _playlistSort = mode;
        _songIds = List<int>.from(_manualSongIds);
      });
      await _persistSongIds();
      return;
    }

    final visible = _visibleSongIds(
      map,
    ).map((id) => map[id]!).toList(growable: false);

    // Precompute album-level year so all tracks in the same album sort together
    // regardless of per-track year tag differences.
    final Map<String, int> albumYearMap = {};
    for (final s in visible) {
      final key = albumIdentityKey(s);
      final y = yearFromSong(s);
      if (y > 0) {
        final existing = albumYearMap[key];
        if (existing == null || y < existing) {
          albumYearMap[key] = y;
        }
      }
    }
    int albumYear(SongModel s) {
      final y = albumYearMap[albumIdentityKey(s)] ?? 0;
      return y == 0 ? 99999 : y;
    }

    final sorted = List<SongModel>.from(visible);
    sorted.sort((a, b) {
      switch (mode) {
        case PlaylistSort.artist:
          final artistComp = compareSortStrings(
            a.artist ?? "",
            b.artist ?? "",
          );
          if (artistComp != 0) return artistComp;
          final titleComp = compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case PlaylistSort.albumArtist:
          final artistComp = compareSortStrings(
            albumArtistFor(a),
            albumArtistFor(b),
          );
          if (artistComp != 0) return artistComp;
          final albumComp = compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case PlaylistSort.year:
          final yearComp = albumYear(a).compareTo(albumYear(b));
          if (yearComp != 0) return yearComp;
          final artistComp = compareSortStrings(
            albumArtistFor(a),
            albumArtistFor(b),
          );
          if (artistComp != 0) return artistComp;
          final albumComp = compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case PlaylistSort.albumArtistYear:
        default:
          final artistComp = compareSortStrings(
            albumArtistFor(a),
            albumArtistFor(b),
          );
          if (artistComp != 0) return artistComp;
          final yearComp = albumYear(a).compareTo(albumYear(b));
          if (yearComp != 0) return yearComp;
          final albumComp = compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
      }
    });

    final missing = _songIds
        .where((id) => !map.containsKey(id))
        .toList(growable: false);
    setState(() {
      _playlistSort = mode;
      _songIds = <int>[...sorted.map((s) => s.id), ...missing];
      _manualSongIds = List<int>.from(_songIds);
    });
    await _persistSongIds();
  }

  void _reorderVisible(int oldIndex, int newIndex) {
    final map = _idToSong();
    final visible = _visibleSongIds(map);
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    if (newIndex < 0 || newIndex > visible.length) return;
    if (newIndex > oldIndex) newIndex -= 1;

    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);

    // Preserve any missing ids by appending them at the end.
    final missing = _songIds
        .where((id) => !map.containsKey(id))
        .toList(growable: false);

    setState(() {
      _songIds = <int>[...visible, ...missing];
      _manualSongIds = List<int>.from(_songIds);
      _playlistSort = PlaylistSort.manual;
    });
    unawaited(_persistSongIds());
  }

  Future<List<int>> _pickSongsToAdd() async {
    if (!mounted) return const <int>[];
    final existing = _songIds.toSet();
    final selected = <int>{};

    final result = await showModalBottomSheet<List<int>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: StatefulBuilder(
              builder: (ctx, setSheetState) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Add songs',
                              style: Theme.of(ctx).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer.withOpacity(
                                Theme.of(ctx).brightness == Brightness.dark
                                    ? 0.25
                                    : 0.55,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: cs.outlineVariant.withOpacity(0.35),
                              ),
                            ),
                            child: Text(
                              '${selected.length} selected',
                              style: Theme.of(ctx).textTheme.labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: cs.onSecondaryContainer.withOpacity(
                                      0.92,
                                    ),
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: widget.librarySongs.length,
                        separatorBuilder: (_, __) => const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Divider(height: 1),
                        ),
                        itemBuilder: (ctx, i) {
                          final s = widget.librarySongs[i];
                          final alreadyAdded = existing.contains(s.id);
                          final isChecked = selected.contains(s.id);
                          final artist = (s.artist ?? '').trim().isEmpty
                              ? 'Unknown Artist'
                              : s.artist!.trim();
                          return ListTile(
                            enabled: !alreadyAdded,
                            leading: ClipOval(
                              child: FastArtworkWidget(
                                id: s.id,
                                type: ArtworkType.AUDIO,
                                width: 44,
                                height: 44,
                                nullArtworkWidget: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              alreadyAdded ? 'Already in playlist' : artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: alreadyAdded
                                ? Icon(
                                    Icons.check_rounded,
                                    color: cs.onSurfaceVariant,
                                  )
                                : Checkbox(
                                    value: isChecked,
                                    onChanged: (v) {
                                      setSheetState(() {
                                        if (v == true) {
                                          selected.add(s.id);
                                        } else {
                                          selected.remove(s.id);
                                        }
                                      });
                                    },
                                  ),
                            onTap: alreadyAdded
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    setSheetState(() {
                                      if (selected.contains(s.id)) {
                                        selected.remove(s.id);
                                      } else {
                                        selected.add(s.id);
                                      }
                                    });
                                  },
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: selected.isEmpty
                                  ? null
                                  : () => Navigator.pop(
                                      ctx,
                                      selected.toList(growable: false),
                                    ),
                              child: const Text('Add'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    return result ?? const <int>[];
  }

  Future<void> _addSongs() async {
    final toAdd = await _pickSongsToAdd();
    if (toAdd.isEmpty) return;

    final existing = _songIds.toSet();
    final added = <int>[];
    for (final id in toAdd) {
      if (existing.add(id)) added.add(id);
    }
    if (added.isEmpty) return;

    setState(() {
      _songIds = <int>[..._songIds, ...added];
      _manualSongIds = <int>[..._manualSongIds, ...added];
    });
    if (_playlistSort == PlaylistSort.manual) {
      await _persistSongIds();
    } else {
      await _applyPlaylistSort(_playlistSort);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${added.length} song${added.length == 1 ? '' : 's'}',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final map = _idToSong();
    final visibleIds = _visibleSongIds(map);
    final allSongs = visibleIds.map((id) => map[id]!).toList(growable: false);

    // Synchronize palette with the leading song in the playlist
    final leadSongId = allSongs.isNotEmpty ? allSongs.first.id : null;
    _syncPalette(leadSongId);

    final query = _searchQuery.trim().toLowerCase();
    final songs = query.isEmpty
        ? allSongs
        : allSongs
              .where((s) {
                final title = s.title.toLowerCase();
                final artist = (s.artist ?? '').toLowerCase();
                final album = (s.album ?? '').toLowerCase();
                return title.contains(query) ||
                    artist.contains(query) ||
                    album.contains(query);
              })
              .toList(growable: false);
    final totalMs = allSongs.fold<int>(0, (sum, s) => sum + (s.duration ?? 0));
    final subtitle =
        '${allSongs.length} tracks • ${formatPlaylistDuration(totalMs)}';
    final canReorder =
        _playlistSort == PlaylistSort.manual &&
        query.isEmpty &&
        !_selectionMode &&
        !_isSearching;

    final content = FutureBuilder<({Color primary, Color secondary, Color tertiary})?>(
      future: _paletteFuture,
      builder: (context, snap) {
        final p = snap.data;
        final bgA = p?.primary;
        final bgB = p?.secondary;
        final bgC = p?.tertiary;
        final top = bgA != null
            ? Color.alphaBlend(
                bgA.withOpacity(isDark ? 0.22 : 0.12),
                cs.surface,
              )
            : cs.surfaceContainerLow;
        final mid = bgB != null
            ? Color.alphaBlend(
                bgB.withOpacity(isDark ? 0.15 : 0.08),
                cs.surface,
              )
            : cs.surface;
        final accent = bgC != null
            ? Color.alphaBlend(
                bgC.withOpacity(isDark ? 0.12 : 0.06),
                cs.surface,
              )
            : cs.surface;

        return Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [top, mid, accent, cs.surface],
                    stops: const [0.0, 0.38, 0.72, 1.0],
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
                  leading: widget.embeddedInHome
                      ? IconButton(
                          tooltip: 'Back',
                          icon: const Icon(Icons.arrow_back_rounded),
                          onPressed: widget.onClose,
                        )
                      : (Navigator.canPop(context)
                          ? IconButton(
                              tooltip: 'Back',
                              icon: const Icon(Icons.arrow_back_rounded),
                              onPressed: () => Navigator.pop(context),
                            )
                          : null),
                  title: _isSearching
                      ? TextField(
                          controller: _searchController,
                          autofocus: true,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: cs.onSurface,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search playlist...',
                            hintStyle: TextStyle(
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                            border: InputBorder.none,
                          ),
                        )
                      : (_selectionMode
                          ? Text(
                              '${_selectedSongIds.length} selected',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null),
                  actions: [
                    if (_isSearching) ...[
                      IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          setState(() {
                            _isSearching = false;
                            _searchController.clear();
                            _searchQuery = '';
                          });
                        },
                      ),
                    ] else if (_selectionMode) ...[
                      IconButton(
                        tooltip: _selectedSongIds.length == songs.length
                            ? 'Deselect all'
                            : 'Select all',
                        icon: Icon(
                          _selectedSongIds.length == songs.length
                              ? Icons.deselect_rounded
                              : Icons.select_all_rounded,
                        ),
                        onPressed: () {
                          setState(() {
                            if (_selectedSongIds.length == songs.length) {
                              _selectedSongIds.clear();
                            } else {
                              _selectedSongIds.addAll(songs.map((s) => s.id));
                            }
                          });
                        },
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        onPressed: _selectedSongIds.isEmpty
                            ? null
                            : _confirmRemoveSelected,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                      IconButton(
                        tooltip: 'Cancel',
                        onPressed: _exitSelectionMode,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ] else ...[
                      IconButton(
                        tooltip: 'Search in playlist',
                        icon: const Icon(Icons.search_rounded),
                        onPressed: () {
                          setState(() => _isSearching = true);
                        },
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded),
                        tooltip: 'More options',
                        onSelected: (val) {
                          HapticFeedback.selectionClick();
                          if (val == 'add') {
                            _addSongs();
                          } else if (val == 'copy_list') {
                            _copyPlaylistText(allSongs);
                          } else if (val == 'copy_m3u') {
                            _copyPlaylistM3u(allSongs);
                          } else if (val == 'export_m3u') {
                            _exportPlaylistM3u(allSongs);
                          } else if (val.startsWith('sort_')) {
                            final sortName = val.substring(5);
                            final sortType = PlaylistSort.values.firstWhere(
                              (e) => e.name == sortName,
                              orElse: () => PlaylistSort.manual,
                            );
                            _applyPlaylistSort(sortType);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'add',
                            child: Row(
                              children: [
                                Icon(Icons.add_rounded, color: cs.onSurfaceVariant, size: 20),
                                const SizedBox(width: 12),
                                const Text('Add songs'),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            enabled: false,
                            child: Text(
                              'SORT BY',
                              style: TextStyle(
                                color: cs.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'sort_manual',
                            child: Row(
                              children: [
                                Icon(
                                  _playlistSort == PlaylistSort.manual
                                      ? Icons.check_rounded
                                      : Icons.drag_indicator_rounded,
                                  color: _playlistSort == PlaylistSort.manual
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                const Text('Custom order (drag)'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'sort_artist',
                            child: Row(
                              children: [
                                Icon(
                                  _playlistSort == PlaylistSort.artist
                                      ? Icons.check_rounded
                                      : Icons.person_outline_rounded,
                                  color: _playlistSort == PlaylistSort.artist
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                const Text('Artist'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'sort_albumArtist',
                            child: Row(
                              children: [
                                Icon(
                                  _playlistSort == PlaylistSort.albumArtist
                                      ? Icons.check_rounded
                                      : Icons.album_outlined,
                                  color: _playlistSort == PlaylistSort.albumArtist
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                const Text('Album Artist'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'sort_year',
                            child: Row(
                              children: [
                                Icon(
                                  _playlistSort == PlaylistSort.year
                                      ? Icons.check_rounded
                                      : Icons.calendar_today_rounded,
                                  color: _playlistSort == PlaylistSort.year
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                const Text('Year'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'sort_albumArtistYear',
                            child: Row(
                              children: [
                                Icon(
                                  _playlistSort == PlaylistSort.albumArtistYear
                                      ? Icons.check_rounded
                                      : Icons.auto_awesome_rounded,
                                  color: _playlistSort == PlaylistSort.albumArtistYear
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                const Text('Album Artist & Year'),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'copy_list',
                            child: Row(
                              children: [
                                Icon(Icons.copy_rounded, color: cs.onSurfaceVariant, size: 20),
                                const SizedBox(width: 12),
                                const Text('Copy track list'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'copy_m3u',
                            child: Row(
                              children: [
                                Icon(Icons.playlist_add_check_rounded, color: cs.onSurfaceVariant, size: 20),
                                const SizedBox(width: 12),
                                const Text('Copy M3U'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'export_m3u',
                            child: Row(
                              children: [
                                Icon(Icons.file_download_outlined, color: cs.onSurfaceVariant, size: 20),
                                const SizedBox(width: 12),
                                const Text('Export M3U file'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                if (!_isSearching)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Column(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                                      blurRadius: 18,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: SizedBox(
                                    width: 114,
                                    height: 114,
                                    child: allSongs.isEmpty
                                        ? Container(
                                            decoration: BoxDecoration(
                                              color: cs.surfaceContainerHighest,
                                            ),
                                            child: Icon(
                                              Icons.playlist_play_rounded,
                                              color: cs.onSurfaceVariant,
                                              size: 48,
                                            ),
                                          )
                                        : FastArtworkWidget(
                                            id: allSongs.first.id,
                                            type: ArtworkType.AUDIO,
                                            width: 114,
                                            height: 114,
                                            artworkFit: BoxFit.cover,
                                            nullArtworkWidget: Container(
                                              color: cs.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.playlist_play_rounded,
                                                color: cs.onSurfaceVariant,
                                                size: 48,
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.playlistName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      subtitle,
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (_playlistSort != PlaylistSort.manual) ...[
                                      const SizedBox(height: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.secondaryContainer.withOpacity(
                                            isDark ? 0.35 : 0.6,
                                          ),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'Sorted: ${_playlistSortLabel(_playlistSort)}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: cs.onSecondaryContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: songs.isEmpty
                                      ? null
                                      : () async => widget.playFromQueue(songs, 0),
                                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
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
                              const SizedBox(width: 10),
                              FilledButton.tonal(
                                onPressed: allSongs.isEmpty
                                    ? null
                                    : () async => _playShuffledQueue(allSongs),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Icon(Icons.shuffle_rounded, size: 20),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: _addSongs,
                                icon: const Icon(Icons.add_rounded, size: 20),
                                label: const Text('Add'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  side: BorderSide(
                                    color: cs.outlineVariant.withOpacity(0.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (songs.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isSearching
                                ? Icons.search_off_rounded
                                : Icons.music_note_rounded,
                            size: 48,
                            color: cs.onSurfaceVariant.withOpacity(0.5),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _isSearching
                                ? 'No songs match "$_searchQuery"'
                                : 'No songs in this playlist yet',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!_isSearching) ...[
                            const SizedBox(height: 16),
                            FilledButton.tonalIcon(
                              onPressed: _addSongs,
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('Add songs'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  SliverReorderableList(
                    proxyDecorator: (Widget child, int index, Animation<double> animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (BuildContext context, Widget? child) {
                          final double animValue = Curves.easeOutBack.transform(animation.value);
                          final double scale = lerpDouble(1.0, 1.03, animValue)!;
                          final cs = Theme.of(context).colorScheme;

                          return Transform.scale(
                            scale: scale,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withOpacity(0.25 * animValue),
                                    blurRadius: 18 * animValue,
                                    offset: Offset(0, 6 * animValue),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2 * animValue),
                                    blurRadius: 10 * animValue,
                                    offset: Offset(0, 3 * animValue),
                                  ),
                                ],
                              ),
                              child: child,
                            ),
                          );
                        },
                        child: child,
                      );
                    },
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      final artistText = (song.artist ?? '').trim().isEmpty
                          ? 'Unknown Artist'
                          : song.artist!.trim();
                      final isSelected = _selectedSongIds.contains(song.id);
                      final canDismiss = !_selectionMode && !_isSearching;

                      Widget trailing;
                      if (_selectionMode) {
                        trailing = Checkbox(
                          value: isSelected,
                          onChanged: (_) => _toggleSelection(song.id),
                        );
                      } else if (canReorder) {
                        trailing = ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        );
                      } else {
                        trailing = PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant.withOpacity(0.7),
                          ),
                          tooltip: 'Track options',
                          onSelected: (action) {
                            HapticFeedback.selectionClick();
                            if (action == 'remove') {
                              _removeSongsByIds([song.id]);
                            } else if (action == 'play_next') {
                              playbackController.insertInQueue(song);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Playing next'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } else if (action == 'add_queue') {
                              playbackController.addToQueueEnd(song);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Added to queue'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'play_next',
                              child: Row(
                                children: [
                                  Icon(Icons.playlist_play_rounded, size: 20),
                                  SizedBox(width: 12),
                                  Text('Play next'),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'add_queue',
                              child: Row(
                                children: [
                                  Icon(Icons.queue_music_rounded, size: 20),
                                  SizedBox(width: 12),
                                  Text('Add to queue'),
                                ],
                              ),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'remove',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline_rounded, size: 20, color: cs.error),
                                  const SizedBox(width: 12),
                                  Text('Remove from playlist', style: TextStyle(color: cs.error)),
                                ],
                              ),
                            ),
                          ],
                        );
                      }

                      final tile = Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        child: Material(
                          color: isSelected
                              ? cs.secondaryContainer.withOpacity(isDark ? 0.35 : 0.6)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              if (_selectionMode) {
                                _toggleSelection(song.id);
                                return;
                              }
                              HapticFeedback.selectionClick();
                              widget.playFromQueue(songs, index);
                            },
                            onLongPress: () {
                              if (_selectionMode) {
                                _toggleSelection(song.id);
                                return;
                              }
                              HapticFeedback.selectionClick();
                              _enterSelectionMode(song.id);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: FastArtworkWidget(
                                      id: song.id,
                                      type: ArtworkType.AUDIO,
                                      width: 48,
                                      height: 48,
                                      artworkFit: BoxFit.cover,
                                      nullArtworkWidget: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          Icons.music_note_rounded,
                                          color: cs.onSurfaceVariant,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          song.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          artistText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  trailing,
                                ],
                              ),
                            ),
                          ),
                        ),
                      );

                      return Dismissible(
                        key: ValueKey('playlist_${widget.playlistId}_${song.id}'),
                        direction: canDismiss
                            ? DismissDirection.endToStart
                            : DismissDirection.none,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          color: Colors.redAccent.withOpacity(0.85),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.white,
                          ),
                        ),
                        confirmDismiss: (_) async => canDismiss,
                        onDismissed: (_) => _removeSongsByIds([song.id]),
                        child: tile,
                      );
                    },
                    itemCount: songs.length,
                    onReorder: canReorder ? _reorderVisible : (a, b) {},
                  ),
                if (widget.embeddedInHome)
                  buildBottomBarsGutter(context)
                else
                  const SliverToBoxAdapter(child: SizedBox(height: 18)),
              ],
            ),
          ],
        );
      },
    );

    if (widget.embeddedInHome) return content;

    return Scaffold(
      bottomNavigationBar: StreamBuilder<int?>(
        stream: widget.player.currentIndexStream,
        builder: (context, snapshot) {
          return buildDetailBottomBars(
            context: context,
            player: widget.player,
            songs: widget.librarySongs,
            currentIndex: snapshot.data ?? widget.player.currentIndex,
            playlist: widget.playlist,
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

