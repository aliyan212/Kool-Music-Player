import 'data/models/album_stat.dart';
import 'data/models/sort_mode.dart';
import 'data/models/isolate_data.dart';
import 'data/models/user_playlist.dart';
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
import 'package:palette_generator/palette_generator.dart';
import 'dart:typed_data';
import 'package:audiotags/audiotags.dart';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/rendering.dart';
import 'core/theme/app_theme.dart';
import 'app_audio_handler.dart';
import 'android_notifications.dart';
import 'platform_exit.dart';
import 'services/app_local_store.dart';
import 'services/playback_controller.dart';
import 'data/services/caching_service.dart';
import 'utils/file_ops.dart';
import 'utils/palette_compute.dart';
import 'ui/shared/frosted_card.dart';
import 'ui/shared/squiggly_seek_bar.dart';
import 'widgets/now_playing_transport.dart';

import 'dialogs/lyrics_editor_dialog.dart';
import 'dialogs/tag_editor_dialog.dart';
import 'pages/queue_page.dart';
import 'utils/lyrics.dart';
import 'utils/tag_write_access.dart';
import 'widgets/mini_player.dart';
import 'widgets/song_search_delegate.dart';

AppAudioHandler? audioHandler;
Future<AudioHandler>? _audioHandlerInitFuture;

final ValueNotifier<bool> appIsForeground = ValueNotifier<bool>(true);
int _autoExitSuppressCount = 0;
bool get suppressAutoExit => _autoExitSuppressCount > 0;
void pushAutoExitSuppress() => _autoExitSuppressCount++;
void popAutoExitSuppress() {
  if (_autoExitSuppressCount > 0) _autoExitSuppressCount--;
}

final GlobalKey<DynamicColorBuilderState> dynamicColorBuilderKey =
    GlobalKey<DynamicColorBuilderState>();
final GoRouter appRouter = GoRouter(
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) {
        final tabRaw = state.uri.queryParameters['tab'];
        final tab = int.tryParse(tabRaw ?? '0') ?? 0;
        return MyHomePage(initialTabIndex: tab);
      },
    ),
    GoRoute(
      path: '/about',
      name: 'about',
      builder: (context, state) => const AboutPage(),
    ),
  ],
);

Future<bool> ensureNotificationPermissionIfNeeded() async {
  if (kIsWeb) return true;
  if (defaultTargetPlatform != TargetPlatform.android) return true;

  const audioChannelId = 'com.example.music_player.channel.audio';

  final status = await Permission.notification.status;
  if (status.isGranted || status.isLimited) return true;
  if (status.isPermanentlyDenied) return false;

  final result = await Permission.notification.request();
  final granted = result.isGranted || result.isLimited;
  if (!granted) return false;

  // Even with runtime permission granted, Android can still block notifications
  // at the app or channel level (importance=NONE). That looks like "no
  // permission issue" but the media notification won't appear.
  final appEnabled = await AndroidNotifications.areNotificationsEnabled();
  if (appEnabled == false) return false;

  final importance = await AndroidNotifications.getChannelImportance(
    audioChannelId,
  );
  if (importance == 0) return false;

  return true;
}

class _AppLifecycleObserver with WidgetsBindingObserver {
  DateTime? _lastDynamicRefresh;
  int? _lastDynamicSignature;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Treat only resumed as foreground to aggressively stop periodic streams.
    appIsForeground.value = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Refresh Material You / dynamic colors without recreating the app.
      final now = DateTime.now();
      final last = _lastDynamicRefresh;
      if (last == null || now.difference(last) > const Duration(seconds: 2)) {
        _lastDynamicRefresh = now;
        _maybeRefreshDynamicColor();
      }
    }
  }

  Future<void> _maybeRefreshDynamicColor() async {
    // Only Android supports dynamic colors via platform palette.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final core = await DynamicColorPlugin.getCorePalette();
      final accent = await DynamicColorPlugin.getAccentColor();

      int? signature;
      if (core != null) {
        // Sample a stable set of tones as a signature.
        signature = Object.hashAll([
          core.primary.get(40),
          core.primary.get(80),
          core.secondary.get(40),
          core.tertiary.get(40),
          core.neutral.get(10),
          core.neutral.get(90),
          core.neutralVariant.get(30),
          core.error.get(40),
          accent?.toARGB32(),
        ]);
      } else {
        signature = accent?.toARGB32();
      }

      if (signature == null) return;
      if (_lastDynamicSignature == signature) return;
      _lastDynamicSignature = signature;

      dynamicColorBuilderKey.currentState?.initPlatformState();
    } catch (_) {
      // Ignore: dynamic color not available.
    }
  }
}

final _appLifecycleObserver = _AppLifecycleObserver();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addObserver(_appLifecycleObserver);
  runApp(const _BootApp());
}

class _BootApp extends StatefulWidget {
  const _BootApp();

  @override
  State<_BootApp> createState() => _BootAppState();
}

class _BootAppState extends State<_BootApp> {
  Object? _error;
  bool _ready = false;
  StreamSubscription<dynamic>? _handlerEventSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // Always allow the first frame to render; do not await long-running
      // platform/plugin initialization in main().
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await AppLocalStore.instance.init();

      // Ensure audio_service initialization is only attempted once. If an init
      // attempt hangs or fails, retry should await the same future rather than
      // calling AudioService.init again (which triggers _cacheManager asserts).
      if (audioHandler == null) {
        if (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          audioHandler = AppAudioHandler(playbackController.player);
        } else {
          _audioHandlerInitFuture ??= () async {
            return await AudioService.init(
              builder: () => AppAudioHandler(playbackController.player),
              config: const AudioServiceConfig(
                androidNotificationChannelId:
                    'com.example.music_player.channel.audio',
                androidNotificationChannelName: 'Music playback',
                androidNotificationOngoing: true,
                androidStopForegroundOnPause: true,
              ),
            );
          }();

          audioHandler = await _audioHandlerInitFuture! as AppAudioHandler;
        }
      }

      _handlerEventSub ??= audioHandler?.customEvent.listen((event) async {
        if (event is Map && event['type'] == 'exit') {
          await PlatformExit.quit();
        }
      });

      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    _handlerEventSub?.cancel();
    _handlerEventSub = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    if (_ready) return const MyApp();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  _error == null ? 'Starting…' : 'Startup failed',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error.toString(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _init, child: const Text('Retry')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const List<String> _defaultExcludedFolderFragments = [
  // Default Android non-music folders.
  '/storage/emulated/0/Ringtones',
  '/storage/emulated/0/Android/media',
  '/storage/emulated/0/Recordings',
];

String _normalizeMetadataText(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return '';
  final lower = text.toLowerCase();
  if (lower == 'unknown' ||
      lower == 'unknown artist' ||
      lower == 'unknown album' ||
      lower == 'unknown title') {
    return '';
  }
  return text;
}

String _basenameFromPath(String path) {
  var p = path.trim();
  if (p.startsWith('file://')) {
    try {
      p = Uri.parse(p).toFilePath();
    } catch (_) {}
  }
  final q = p.indexOf('?');
  if (q != -1) p = p.substring(0, q);
  final h = p.indexOf('#');
  if (h != -1) p = p.substring(0, h);

  p = p.replaceAll('\\', '/');
  final idx = p.lastIndexOf('/');
  if (idx == -1) return p;
  return p.substring(idx + 1);
}

String _stripFileExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return filename;
  return filename.substring(0, dot);
}

Map<dynamic, dynamic> repairSongMetadataMap(
  Map<dynamic, dynamic> map, {
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  int? year,
  int? track,
}) {
  final fixed = Map<dynamic, dynamic>.from(map);
  final dataPath = (fixed['data'] ?? '').toString();
  final filename = _stripFileExtension(_basenameFromPath(dataPath));
  final mediaDisplayName = _normalizeMetadataText(fixed['_display_name']);
  final mediaDisplayNameWoExt = _normalizeMetadataText(
    fixed['_display_name_wo_ext'],
  );

  final titleValue = _normalizeMetadataText(fixed['title']);
  if (titleValue.isEmpty) {
    final richTitle = _normalizeMetadataText(title);
    final fallbackTitle =
        mediaDisplayNameWoExt.isNotEmpty
            ? mediaDisplayNameWoExt
            : mediaDisplayName.isNotEmpty
            ? mediaDisplayName
            : filename;
    fixed['title'] = richTitle.isNotEmpty ? richTitle : fallbackTitle;
  }

  final artistValue = _normalizeMetadataText(fixed['artist']);
  if (artistValue.isEmpty) {
    final richArtist = _normalizeMetadataText(artist);
    fixed['artist'] = richArtist.isNotEmpty ? richArtist : 'Unknown Artist';
  }

  final albumValue = _normalizeMetadataText(fixed['album']);
  if (albumValue.isEmpty) {
    final richAlbum = _normalizeMetadataText(album);
    fixed['album'] = richAlbum.isNotEmpty ? richAlbum : 'Unknown Album';
  }

  final albumArtistValue = _normalizeMetadataText(fixed['album_artist']);
  if (albumArtistValue.isEmpty) {
    final richAlbumArtist = _normalizeMetadataText(albumArtist);
    if (richAlbumArtist.isNotEmpty) {
      fixed['album_artist'] = richAlbumArtist;
    } else {
      final fallbackArtist = _normalizeMetadataText(fixed['artist']);
      fixed['album_artist'] = fallbackArtist.isNotEmpty
          ? fallbackArtist
          : 'Unknown Artist';
    }
  }

  final rawYear = fixed['year'];
  if (rawYear == null ||
      (rawYear is int && rawYear <= 0) ||
      (rawYear is String && _normalizeMetadataText(rawYear).isEmpty)) {
    if (year != null && year > 0) {
      fixed['year'] = year;
    }
  }

  final rawTrack = fixed['track'];
  if (rawTrack == null ||
      (rawTrack is int && rawTrack <= 0) ||
      (rawTrack is String && _normalizeMetadataText(rawTrack).isEmpty)) {
    if (track != null && track > 0) {
      fixed['track'] = track;
    }
  }

  return fixed;
}

Future<List<SongModel>> repairSongMetadataList(
  List<SongModel> songs, {
  String? tagTitle,
  String? tagArtist,
  String? tagAlbum,
  String? tagAlbumArtist,
  int? tagYear,
  int? tagTrack,
}) async {
  final repaired = <SongModel>[];
  for (final song in songs) {
    final map = Map<dynamic, dynamic>.from(song.getMap);
    final filePath = song.data.trim();

    String? tagTitleValue = tagTitle;
    String? tagArtistValue = tagArtist;
    String? tagAlbumValue = tagAlbum;
    String? tagAlbumArtistValue = tagAlbumArtist;
    int? tagYearValue = tagYear;
    int? tagTrackValue = tagTrack;

    if (filePath.isNotEmpty) {
      try {
        final tag = await AudioTags.read(filePath);
        if (tag != null) {
          tagTitleValue ??= tag.title;
          tagArtistValue ??= tag.trackArtist;
          tagAlbumValue ??= tag.album;
          tagAlbumArtistValue ??= tag.albumArtist;
          tagYearValue ??= tag.year;
          tagTrackValue ??= tag.trackNumber;
        }
      } catch (_) {}
    }

    repaired.add(
      SongModel(
        repairSongMetadataMap(
          map,
          title: tagTitleValue,
          artist: tagArtistValue,
          album: tagAlbumValue,
          albumArtist: tagAlbumArtistValue,
          year: tagYearValue,
          track: tagTrackValue,
        ),
      ),
    );
  }

  return repaired;
}

String formatTime(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) return "0:00";
  int totalSeconds = (milliseconds / 1000).truncate();
  int minutes = (totalSeconds / 60).truncate();
  int seconds = totalSeconds % 60;
  return "$minutes:${seconds.toString().padLeft(2, '0')}";
}
const int _thumbnailCacheMax = 300;
const int _highResCacheMax = 10;

String _getArtworkKey(int id, ArtworkType type, int size) =>
  '${type.name}_${id}_$size';

LinkedHashMap<String, Uint8List?> _artworkCacheForSize(int size) {
  return size > 400 ? CachingService().highResCache : CachingService().thumbnailCache;
}

Uint8List? _peekCachedArtworkBytesByKey(String key, int size) {
  final cache = _artworkCacheForSize(size);
  if (!cache.containsKey(key)) return null;
  final cached = cache.remove(key);
  cache[key] = cached;
  return cached;
}

void _storeCachedArtworkBytesByKey(String key, int size, Uint8List? bytes) {
  final cache = _artworkCacheForSize(size);
  final maxEntries = size > 400 ? _highResCacheMax : _thumbnailCacheMax;
  cache.remove(key);
  cache[key] = bytes;
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

bool hasCachedArtworkBytes(
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
}) {
  return _artworkCacheForSize(size).containsKey(_getArtworkKey(id, type, size));
}

Uint8List? peekCachedArtworkBytes(
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
}) {
  return _peekCachedArtworkBytesByKey(_getArtworkKey(id, type, size), size);
}

Future<Uint8List?> queryArtworkBytesCached(
  int id,
  {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
  int quality = 80,
  }) async {
  final key = _getArtworkKey(id, type, size);
  if (_artworkCacheForSize(size).containsKey(key)) {
    return _peekCachedArtworkBytesByKey(key, size);
  }
  final bytes = await OnAudioQuery().queryArtwork(
    id,
    type,
    size: size,
    quality: quality,
  );
  _storeCachedArtworkBytesByKey(key, size, bytes);
  return bytes;
}

class FastArtworkWidget extends StatefulWidget {
  final int id;
  final ArtworkType type;
  final double width;
  final double height;
  final Widget nullArtworkWidget;
  final int size;
  final int quality;

  const FastArtworkWidget({
    super.key,
    required this.id,
    required this.type,
    required this.width,
    required this.height,
    required this.nullArtworkWidget,
    this.size = 200,
    this.quality = 80,
  });

  @override
  State<FastArtworkWidget> createState() => _FastArtworkWidgetState();
}

class _FastArtworkWidgetState extends State<FastArtworkWidget> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _fetchArtwork();
  }

  @override
  void didUpdateWidget(covariant FastArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.type != widget.type) {
      _fetchArtwork();
    }
  }

  void _fetchArtwork() {
    final key = _getArtworkKey(widget.id, widget.type, widget.size);
    if (hasCachedArtworkBytes(widget.id, type: widget.type, size: widget.size)) {
      _bytes = peekCachedArtworkBytes(widget.id, type: widget.type, size: widget.size);
      return;
    }

    queryArtworkBytesCached(
      widget.id,
      type: widget.type,
      size: widget.size,
      quality: widget.quality,
    ).then((bytes) {
      if (!mounted) return;
      if (_getArtworkKey(widget.id, widget.type, widget.size) != key) return;
      setState(() {
        _bytes = bytes;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: widget.nullArtworkWidget,
    );
  }
}

Color _boostVibrance(
  Color color, {
  double extraSaturation = 0.2,
  double extraLightness = 0.0,
}) {
  final hsl = HSLColor.fromColor(color);
  final sat = (hsl.saturation + extraSaturation).clamp(0.0, 1.0);
  final light = (hsl.lightness + extraLightness).clamp(0.0, 1.0);
  return hsl.withSaturation(sat).withLightness(light).toColor();
}

Color _harmonizeBackgroundAccent(
  Color color,
  Color surface, {
  required bool isDark,
}) {
  final blended = Color.lerp(color, surface, isDark ? 0.42 : 0.52) ?? color;
  final hsl = HSLColor.fromColor(blended);
  final sat = hsl.saturation.clamp(0.08, isDark ? 0.42 : 0.38);
  final light = hsl.lightness.clamp(
    isDark ? 0.20 : 0.66,
    isDark ? 0.44 : 0.90,
  );
  return hsl.withSaturation(sat).withLightness(light).toColor();
}

Widget buildDetailBottomBars({
  required BuildContext context,
  required AudioPlayer player,
  required List<SongModel> songs,
  required int? currentIndex,
  required ConcatenatingAudioSource? playlist,
  required Function(List<SongModel>) onQueueChanged,
  required Function(SongModel) onOpenNowPlaying,
  required int selectedTabIndex,
  required ValueChanged<int> onNavigateTab,
}) {
  return SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MiniPlayer(
          controller: playbackController,
          songs: songs,
          currentIndex: currentIndex,
          playlist: playlist,
          onQueueChanged: onQueueChanged,
          onTap: onOpenNowPlaying,
        ),
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.transparent,
              ),
              child: NavigationBar(
                selectedIndex: selectedTabIndex,
                onDestinationSelected: (index) {
                  if (index == selectedTabIndex) return;
                  HapticFeedback.selectionClick();
                  onNavigateTab(index);
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.people_outline_rounded),
                    selectedIcon: Icon(Icons.people_rounded),
                    label: 'Album Artists',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.album_outlined),
                    selectedIcon: Icon(Icons.album_rounded),
                    label: 'Albums',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.queue_music_outlined),
                    selectedIcon: Icon(Icons.queue_music_rounded),
                    label: 'Playlists',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _frostedBarBackground(BuildContext ctx, {double? opacity}) {
  final cs = Theme.of(ctx).colorScheme;
  final isDark = Theme.of(ctx).brightness == Brightness.dark;
  final op = opacity ?? (isDark ? 0.68 : 0.82);
  return ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface.withOpacity(op),
          border: Border(
            bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.04)),
          ),
        ),
      ),
    ),
  );
}



final themeNotifier = ThemeNotifier();

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  SystemUiOverlayStyle _overlayForBrightness(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      // Used primarily by iOS; keep consistent.
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    );
  }

  

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      key: dynamicColorBuilderKey,
      builder: (lightDynamic, darkDynamic) {
        final fallbackLight = ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C2A8),
          brightness: Brightness.light,
        );
        final fallbackDark = ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C2A8),
          brightness: Brightness.dark,
        );

        final lightScheme = (lightDynamic?.harmonized() ?? fallbackLight);
        final darkScheme = (darkDynamic?.harmonized() ?? fallbackDark);

        return ValueListenableBuilder<ThemeMode>(
          valueListenable: themeNotifier,
          builder: (context, themeMode, _) {
            final platformBrightness = MediaQuery.platformBrightnessOf(context);
            final effectiveBrightness = switch (themeMode) {
              ThemeMode.light => Brightness.light,
              ThemeMode.dark => Brightness.dark,
              ThemeMode.system => platformBrightness,
            };

            SystemChrome.setSystemUIOverlayStyle(
              _overlayForBrightness(effectiveBrightness),
            );

            return MaterialApp.router(
              title: 'Expressive Music',
              themeMode: themeMode,
              debugShowCheckedModeBanner: false,
              routerConfig: appRouter,
              theme: buildTheme(lightScheme, Brightness.light),
              darkTheme: buildTheme(darkScheme, Brightness.dark),
            );
          },
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, this.initialTabIndex = 0});
  final int initialTabIndex;
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}









enum _PlaylistSort { manual, artist, albumArtist, year, albumArtistYear }

enum _PlaylistSongAction { remove }

enum _PlaylistShareAction { copyList, copyM3u, exportM3u }









enum _AppMenuAction {
  refresh,
  manageFolders,
  toggleTheme,
  about,
  quit,
}

enum _LibraryPermissionState { unknown, granted, denied, permanentlyDenied }

class _MyHomePageState extends State<MyHomePage> {
  final PlaybackController _controller = playbackController;
  final AppLocalStore _localStore = AppLocalStore.instance;
  final ScrollController _scrollController = ScrollController();
  final OnAudioQuery _audioQuery = OnAudioQuery();
  final SearchController _searchController = SearchController();

  bool _showSearchInAppBar = false;

  late int _selectedTabIndex;

  bool _nowPlayingRouteActive = false;
  DateTime? _lastNowPlayingClosedAt;

  List<SongModel> _songs = [];
  bool _isLoading = true;
  _LibraryPermissionState _permissionState = _LibraryPermissionState.unknown;
  AlbumArtistsSort _albumArtistsSort = AlbumArtistsSort.nameAsc;
  AlbumsSort _albumsSort = AlbumsSort.titleAsc;
  List<String> _allFolders = [];
  Set<String> _includedFolders = {};
  Set<String> _excludedFolders = {};

  static const String _includedFoldersKey = "included_folders";
  static const String _excludedFoldersKey = "excluded_folders";

  static const String _userPlaylistsKey = 'user_playlists_v1';

  bool _isSelectionMode = false;
  final Set<int> _selectedSongIds = <int>{};

  List<UserPlaylist> _userPlaylists = <UserPlaylist>[];
  List<AlbumArtistStat> _cachedAlbumArtists = <AlbumArtistStat>[];
  List<AlbumTabStat> _cachedAlbums = <AlbumTabStat>[];
  List<SongModel> _cachedMostPlayed = <SongModel>[];
  List<SongModel> _cachedRecentlyPlayed = <SongModel>[];
  List<SongModel> _cachedRecentlyAdded = <SongModel>[];
  Map<String, int> _cachedUserPlaylistTrackCounts = <String, int>{};

  bool _hideBottomBars = false;
  DateTime? _lastBottomBarsToggleAt;
  double _bottomBarScrollAccumulator = 0;
  double? _lastScrollPixels;
  Widget? _inlineDetailContent;

  static final RegExp _yearRegex = RegExp(r'(19|20)\\d{2}');

  void _setHideBottomBars(bool hide) {
    if (_hideBottomBars == hide) return;
    // Debounce rapid direction changes for smoother UX.
    final now = DateTime.now();
    final last = _lastBottomBarsToggleAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 90)) {
      return;
    }
    _lastBottomBarsToggleAt = now;
    setState(() => _hideBottomBars = hide);
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (!mounted) return false;
    if (n.metrics.axis != Axis.vertical) return false;

    // Always show controls when near the top.
    if (n.metrics.pixels <= (n.metrics.minScrollExtent + 16)) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(false);
      return false;
    }

    if (n is ScrollStartNotification) {
      _lastScrollPixels = n.metrics.pixels;
      _bottomBarScrollAccumulator = 0;
      return false;
    }

    if (n is ScrollEndNotification) {
      _bottomBarScrollAccumulator = 0;
      _lastScrollPixels = n.metrics.pixels;
      return false;
    }

    if (n is! ScrollUpdateNotification) return false;

    final delta = n.scrollDelta ??
        (_lastScrollPixels == null ? 0 : n.metrics.pixels - _lastScrollPixels!);
    _lastScrollPixels = n.metrics.pixels;

    if (delta.abs() < 0.5) return false;

    // Positive delta means user scrolls down content (hide bars).
    if (_bottomBarScrollAccumulator == 0 ||
        (_bottomBarScrollAccumulator > 0) != (delta > 0)) {
      _bottomBarScrollAccumulator = delta;
    } else {
      _bottomBarScrollAccumulator += delta;
    }

    const hideThreshold = 28.0;
    const showThreshold = 20.0;

    if (_bottomBarScrollAccumulator > hideThreshold) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(true);
    } else if (_bottomBarScrollAccumulator < -showThreshold) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(false);
    }

    return false;
  }

  String _displayAlbumTitle(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Album' : v;
  }

  String _displayArtistName(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Artist' : v;
  }

  int _yearValueForCompare(int y) => y == 0 ? 99999 : y;

void _recomputeAllData() {
    _recomputeLibraryStructure();
    _recomputePlayHistoryStats();
  }

  void _recomputeLibraryStructure() {
    final songs = _songs;
    final byId = <int, SongModel>{for (final s in songs) s.id: s};

    final artistStatByKey = <String, AlbumArtistStat>{};
    final representativeByAlbumId = <int, SongModel>{};
    final trackCountByAlbumId = <int, int>{};
    final minYearByAlbumId = <int, int>{};

    for (final s in songs) {
      final artistName = _displayArtistName(_albumArtistFor(s));
      final artistKey = artistName.toLowerCase();
      final artistStat = artistStatByKey.putIfAbsent(
        artistKey,
        () => AlbumArtistStat(name: artistName),
      );
      artistStat.trackCount++;
      final artistAlbumId = s.albumId;
      if (artistAlbumId != null && artistAlbumId > 0) {
        artistStat.albumIds.add(artistAlbumId);
      }

      final albumId = s.albumId;
      if (albumId == null || albumId <= 0) continue;
      representativeByAlbumId.putIfAbsent(albumId, () => s);
      trackCountByAlbumId.update(albumId, (v) => v + 1, ifAbsent: () => 1);
      final y = _yearFromSong(s);
      if (y > 0) {
        final existing = minYearByAlbumId[albumId];
        if (existing == null || y < existing) minYearByAlbumId[albumId] = y;
      }
    }

    final artists = artistStatByKey.values.toList(growable: false)
      ..sort((a, b) {
        int comp;
        switch (_albumArtistsSort) {
          case AlbumArtistsSort.nameAsc:
            comp = _compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.nameDesc:
            comp = _compareSortStrings(b.name, a.name);
            break;
          case AlbumArtistsSort.mostAlbums:
            comp = b.albumCount.compareTo(a.albumCount);
            if (comp != 0) break;
            comp = b.trackCount.compareTo(a.trackCount);
            if (comp != 0) break;
            comp = _compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.leastAlbums:
            comp = a.albumCount.compareTo(b.albumCount);
            if (comp != 0) break;
            comp = a.trackCount.compareTo(b.trackCount);
            if (comp != 0) break;
            comp = _compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.mostTracks:
            comp = b.trackCount.compareTo(a.trackCount);
            if (comp != 0) break;
            comp = b.albumCount.compareTo(a.albumCount);
            if (comp != 0) break;
            comp = _compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.leastTracks:
            comp = a.trackCount.compareTo(b.trackCount);
            if (comp != 0) break;
            comp = a.albumCount.compareTo(b.albumCount);
            if (comp != 0) break;
            comp = _compareSortStrings(a.name, b.name);
            break;
        }
        if (comp != 0) return comp;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final albums =
        representativeByAlbumId.keys
            .map((albumId) {
              final song = representativeByAlbumId[albumId]!;
              final album = _controller.albumMap[albumId];
              final title = _displayAlbumTitle(album?.album ?? song.album);
              final artist = _displayArtistName(
                album?.artist ?? _albumArtistFor(song),
              );
              return AlbumTabStat(
                albumId: albumId,
                representativeSong: song,
                title: title,
                artist: artist,
                trackCount: trackCountByAlbumId[albumId] ?? 0,
                year: minYearByAlbumId[albumId] ?? 0,
              );
            })
            .toList(growable: false)
          ..sort((a, b) {
            int comp;
            switch (_albumsSort) {
              case AlbumsSort.titleAsc:
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.titleDesc:
                comp = _compareSortStrings(b.title, a.title);
                break;
              case AlbumsSort.artistAsc:
                comp = _compareSortStrings(a.artist, b.artist);
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.artistDesc:
                comp = _compareSortStrings(b.artist, a.artist);
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.yearAsc:
                comp = _yearValueForCompare(
                  a.year,
                ).compareTo(_yearValueForCompare(b.year));
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.yearDesc:
                comp = _yearValueForCompare(
                  b.year,
                ).compareTo(_yearValueForCompare(a.year));
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.albumArtistYear:
                comp = _compareSortStrings(a.artist, b.artist);
                if (comp != 0) break;
                comp = _yearValueForCompare(
                  a.year,
                ).compareTo(_yearValueForCompare(b.year));
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.mostTracks:
                comp = b.trackCount.compareTo(a.trackCount);
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.leastTracks:
                comp = a.trackCount.compareTo(b.trackCount);
                if (comp != 0) break;
                comp = _compareSortStrings(a.title, b.title);
                break;
            }
            if (comp != 0) return comp;
            comp = _compareSortStrings(a.artist, b.artist);
            if (comp != 0) return comp;
            return a.albumId.compareTo(b.albumId);
          });

    final cutoff = DateTime.now()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final recentlyAdded =
        songs
            .where((s) {
              final ms = _dateAddedFromSong(s);
              return ms != 0 && ms >= cutoff;
            })
            .toList(growable: false)
          ..sort((a, b) {
            final ad = _dateAddedFromSong(a);
            final bd = _dateAddedFromSong(b);
            final comp = bd.compareTo(ad);
            if (comp != 0) return comp;
            return a.id.compareTo(b.id);
          });

    final userPlaylistTrackCounts = <String, int>{};
    for (final playlist in _userPlaylists) {
      var count = 0;
      for (final id in playlist.songIds) {
        if (byId.containsKey(id)) count++;
      }
      userPlaylistTrackCounts[playlist.id] = count;
    }

    _cachedAlbumArtists = artists;
    _cachedAlbums = albums;
    _cachedRecentlyAdded = recentlyAdded;
    _cachedUserPlaylistTrackCounts = userPlaylistTrackCounts;
  }

  void _recomputePlayHistoryStats() {
    final songs = _songs;
    final playCounts = _controller.playCountBySongId;
    final lastPlayed = _controller.lastPlayedMsBySongId;

    final mostPlayed =
        songs
            .where((s) => (playCounts[s.id] ?? 0) > 0)
            .toList(growable: false)
          ..sort((a, b) {
            final ac = playCounts[a.id] ?? 0;
            final bc = playCounts[b.id] ?? 0;
            final comp = bc.compareTo(ac);
            if (comp != 0) return comp;
            final t = _compareSortStrings(a.title, b.title);
            if (t != 0) return t;
            return a.id.compareTo(b.id);
          });

    final recentlyPlayed =
        songs
            .where((s) => (lastPlayed[s.id] ?? 0) > 0)
            .toList(growable: false)
          ..sort((a, b) {
            final at = lastPlayed[a.id] ?? 0;
            final bt = lastPlayed[b.id] ?? 0;
            final comp = bt.compareTo(at);
            if (comp != 0) return comp;
            return a.id.compareTo(b.id);
          });

    _cachedMostPlayed = mostPlayed;
    _cachedRecentlyPlayed = recentlyPlayed;
  }

  Widget _animatedBottomBars() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<int?>(
          valueListenable: _controller.currentPlayIndexNotifier,
          builder: (context, currentIndex, _) => MiniPlayer(
            controller: _controller,
            songs: _songs,
            currentIndex: currentIndex,
            playlist: _controller.currentPlaylist,
            // Queue changes must not mutate the Library list.
            onQueueChanged: (_) {},
            onTap: (song) => _openNowPlaying(song),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 1, end: _hideBottomBars ? 0 : 1),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) {
            final hidden = t < 0.02;
            final dy = (1 - t) * 84;
            return IgnorePointer(
              ignoring: hidden,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: t,
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: Opacity(opacity: t, child: child),
                  ),
                ),
              ),
            );
          },
          child: Builder(builder: (ctx) {
            final cs = Theme.of(ctx).colorScheme;
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                  ),
                  child: NavigationBar(
                    selectedIndex: _selectedTabIndex,
                    onDestinationSelected: (index) {
                      if (index == _selectedTabIndex) return;
                      HapticFeedback.selectionClick();
                      if (_isSelectionMode) _exitSelectionMode();
                      setState(() {
                        _selectedTabIndex = index;
                        _inlineDetailContent = null;
                      });
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.people_outline_rounded),
                        selectedIcon: Icon(Icons.people_rounded),
                        label: 'Album Artists',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.album_outlined),
                        selectedIcon: Icon(Icons.album_rounded),
                        label: 'Albums',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.queue_music_outlined),
                        selectedIcon: Icon(Icons.queue_music_rounded),
                        label: 'Playlists',
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  void _showInlineDetail(Widget detailContent) {
    if (!mounted) return;
    setState(() {
      _inlineDetailContent = detailContent;
      _hideBottomBars = false;
    });
  }

  void _closeInlineDetail() {
    if (!mounted) return;
    if (_inlineDetailContent == null) return;
    setState(() => _inlineDetailContent = null);
  }

  void _enterSelectionMode({int? initialSongId}) {
    if (_searchController.isOpen) {
      _searchController.closeView(_searchController.text);
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() {
      _isSelectionMode = true;
      _selectedSongIds.clear();
      if (initialSongId != null) _selectedSongIds.add(initialSongId);
    });
  }

  void _exitSelectionMode() {
    if (!_isSelectionMode) return;
    setState(() {
      _isSelectionMode = false;
      _selectedSongIds.clear();
    });
  }

  void _toggleSelectedSongId(int songId) {
    setState(() {
      if (_selectedSongIds.contains(songId)) {
        _selectedSongIds.remove(songId);
        if (_selectedSongIds.isEmpty) _isSelectionMode = false;
      } else {
        _selectedSongIds.add(songId);
        _isSelectionMode = true;
      }
    });
  }

  Future<void> _loadUserPlaylists() async {
    try {
      List<dynamic>? decoded = await _localStore.readUserPlaylists();
      if (decoded == null) {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_userPlaylistsKey);
        if (raw != null && raw.trim().isNotEmpty) {
          final parsed = jsonDecode(raw);
          if (parsed is List) {
            decoded = parsed;
            await _localStore.writeUserPlaylists(
              parsed
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(growable: false),
            );
            await _localStore.markUserPlaylistsMigrated();
          }
        }
      }

      if (decoded == null) {
        _userPlaylists = <UserPlaylist>[];
        _recomputeAllData();
        if (mounted) setState(() {});
        return;
      }

      final list = <UserPlaylist>[];
      for (final item in decoded) {
        final pl = UserPlaylist.fromJson(item);
        if (pl == null) continue;
        list.add(pl);
      }
      _userPlaylists = list;
      _recomputeAllData();
      if (mounted) setState(() {});
    } catch (_) {
      _userPlaylists = <UserPlaylist>[];
      _recomputeAllData();
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveUserPlaylists() async {
    try {
      await _localStore.writeUserPlaylists(
        _userPlaylists.map((p) => p.toJson()).toList(growable: false),
      );
    } catch (_) {
      // Best-effort; do not crash UI.
    }
  }

  String _basename(String path) {
    var p = path.trim();
    if (p.startsWith('file://')) {
      try {
        p = Uri.parse(p).toFilePath();
      } catch (_) {
        // fall through
      }
    }
    // Strip any query/fragment if a URI-like string sneaks in.
    final q = p.indexOf('?');
    if (q != -1) p = p.substring(0, q);
    final h = p.indexOf('#');
    if (h != -1) p = p.substring(0, h);

    p = p.replaceAll('\\', '/');
    final idx = p.lastIndexOf('/');
    if (idx == -1) return p;
    return p.substring(idx + 1);
  }

  String _stripExtension(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0) return filename;
    return filename.substring(0, dot);
  }

  String _uniquePlaylistName(String base) {
    final existing = _userPlaylists
        .map((p) => p.name.trim().toLowerCase())
        .toSet();
    var candidate = base.trim();
    if (candidate.isEmpty) candidate = 'Playlist';
    if (!existing.contains(candidate.toLowerCase())) return candidate;

    for (var i = 2; i < 1000; i++) {
      final next = '$candidate ($i)';
      if (!existing.contains(next.toLowerCase())) return next;
    }
    // Fallback: append timestamp.
    return '$candidate (${DateTime.now().millisecondsSinceEpoch})';
  }

  Future<void> _importM3uPlaylistFlow() async {
    if (!mounted) return;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8'],
        withData: true,
        allowMultiple: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.single;
      final bytes = f.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not read playlist file'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      final entries = <String>[];
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#')) continue;
        entries.add(line);
      }

      if (entries.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No tracks found in .m3u'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final byData = <String, int>{};
      final byUri = <String, int>{};
      final byBase = <String, List<int>>{};
      for (final s in _songs) {
        final data = s.data.trim();
        if (data.isNotEmpty) byData[data.toLowerCase()] = s.id;
        final uri = (s.uri ?? '').trim();
        if (uri.isNotEmpty) byUri[uri.toLowerCase()] = s.id;
        final base = _basename(data).toLowerCase();
        if (base.isNotEmpty) {
          (byBase[base] ??= <int>[]).add(s.id);
        }
      }

      final songIds = <int>[];
      final seen = <int>{};
      for (final e in entries) {
        var entry = e.trim();
        if ((entry.startsWith('"') && entry.endsWith('"')) ||
            (entry.startsWith("'") && entry.endsWith("'"))) {
          entry = entry.substring(1, entry.length - 1).trim();
        }

        String normalized = entry;
        if (normalized.startsWith('file://')) {
          try {
            normalized = Uri.parse(normalized).toFilePath();
          } catch (_) {
            // keep as-is
          }
        }
        normalized = normalized.replaceAll('\\', '/');

        int? id;
        id ??= byData[normalized.toLowerCase()];
        id ??= byUri[entry.toLowerCase()];
        if (id == null) {
          final base = _basename(normalized).toLowerCase();
          final candidates = byBase[base];
          if (candidates != null && candidates.isNotEmpty)
            id = candidates.first;
        }

        if (id == null) continue;
        if (seen.add(id)) songIds.add(id);
      }

      if (songIds.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not match any tracks from the .m3u to your library',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final filename = (f.name).trim();
      final baseName = _stripExtension(filename);
      final playlistName = _uniquePlaylistName(
        baseName.isEmpty ? 'Imported playlist' : baseName,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final playlist = UserPlaylist(
        id: _newPlaylistId(),
        name: playlistName,
        songIds: songIds,
        createdAtMs: now,
        updatedAtMs: now,
      );
      setState(() {
        _userPlaylists = <UserPlaylist>[playlist, ..._userPlaylists];
        _recomputeAllData();
      });
      await _saveUserPlaylists();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${songIds.length} track${songIds.length == 1 ? '' : 's'} to "$playlistName"',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );

      // Open the imported playlist.
      _openUserPlaylistPage(playlist);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to import playlist'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showCreateOrImportPlaylistSheet() async {
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('New playlist'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              ListTile(
                leading: const Icon(Icons.file_open_rounded),
                title: const Text('Import .m3u playlist'),
                onTap: () => Navigator.pop(ctx, 'import'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    if (picked == 'new') {
      final pl = await _promptCreatePlaylist();
      if (pl != null) _openUserPlaylistPage(pl);
      return;
    }
    if (picked == 'import') {
      await _importM3uPlaylistFlow();
      return;
    }
  }

  void _openUserPlaylistPage(UserPlaylist playlist) {
    final playlistId = playlist.id;
    _showInlineDetail(
      _UserPlaylistPage(
        player: _controller.player,
        playlistId: playlistId,
        playlistName: playlist.name,
        initialSongIds: playlist.songIds,
        librarySongs: _songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: _selectedTabIndex,
        onNavigateTab: (index) {
          if (!mounted) return;
          if (_isSelectionMode) _exitSelectionMode();
          setState(() => _selectedTabIndex = index);
        },
        embeddedInHome: true,
        onClose: _closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (_nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          _openNowPlaying(s);
        },
        playFromQueue: (songs, initialIndex) async {
          await _controller.playFromQueue(songs, initialIndex: initialIndex);
        },
        onUpdateSongIds: (id, newSongIds) async {
          final idx = _userPlaylists.indexWhere((p) => p.id == id);
          if (idx == -1) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          setState(() {
            final existing = _userPlaylists[idx];
            _userPlaylists = List<UserPlaylist>.from(_userPlaylists)
              ..[idx] = existing.copyWith(
                songIds: newSongIds,
                updatedAtMs: now,
              );
            _recomputeAllData();
          });
          await _saveUserPlaylists();
        },
      ),
    );
  }

  void _reorderUserPlaylists(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _userPlaylists.length) return;
    if (newIndex < 0 || newIndex > _userPlaylists.length) return;

    setState(() {
      final list = List<UserPlaylist>.from(_userPlaylists);
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = list.removeAt(oldIndex);
      list.insert(newIndex, moved);
      _userPlaylists = list;
      _recomputeAllData();
    });
    unawaited(_saveUserPlaylists());
  }

  Future<void> _promptRenamePlaylist(UserPlaylist playlist) async {
    if (!mounted) return;
    final controller = TextEditingController(text: playlist.name);
    final newNameRaw = await showDialog<String>(
      context: context,
      builder: (dctx) {
        return AlertDialog(
          title: const Text('Rename playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Playlist name'),
            onSubmitted: (v) => Navigator.pop(dctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    final newName = (newNameRaw ?? '').trim();
    if (newName.isEmpty) return;

    final idx = _userPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx == -1) return;

    final existing = _userPlaylists[idx];
    if (existing.name == newName) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _userPlaylists = List<UserPlaylist>.from(_userPlaylists)
        ..[idx] = existing.copyWith(name: newName, updatedAtMs: now);
      _recomputeAllData();
    });
    await _saveUserPlaylists();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Renamed to "$newName"'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmAndDeletePlaylist(UserPlaylist playlist) async {
    if (!mounted) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dctx) {
            return AlertDialog(
              title: const Text('Delete playlist?'),
              content: Text(
                '"${playlist.name}" will be removed from your playlists.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dctx, true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    setState(() {
      _userPlaylists = List<UserPlaylist>.from(_userPlaylists)
        ..removeWhere((p) => p.id == playlist.id);
      _recomputeAllData();
    });
    await _saveUserPlaylists();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted "${playlist.name}"'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showUserPlaylistActionsSheet(UserPlaylist playlist) async {
    if (!mounted) return;
    final picked = await showModalBottomSheet<UserPlaylistAction>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(ctx, UserPlaylistAction.rename),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete'),
                onTap: () => Navigator.pop(ctx, UserPlaylistAction.delete),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (picked == null) return;
    switch (picked) {
      case UserPlaylistAction.rename:
        await _promptRenamePlaylist(playlist);
        return;
      case UserPlaylistAction.delete:
        await _confirmAndDeletePlaylist(playlist);
        return;
    }
  }

  String _newPlaylistId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(1 << 32);
    return '${now}_$rand';
  }

  Future<UserPlaylist?> _promptCreatePlaylist() async {
    if (!mounted) return null;
    final controller = TextEditingController();
    final createdName = await showDialog<String>(
      context: context,
      builder: (dctx) {
        return AlertDialog(
          title: const Text('New playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Playlist name',
              hintText: 'e.g. Roadtrip',
            ),
            onSubmitted: (v) => Navigator.pop(dctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, controller.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    final name = (createdName ?? '').trim();
    if (name.isEmpty) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = UserPlaylist(
      id: _newPlaylistId(),
      name: name,
      songIds: const <int>[],
      createdAtMs: now,
      updatedAtMs: now,
    );
    setState(() {
      _userPlaylists = <UserPlaylist>[playlist, ..._userPlaylists];
      _recomputeAllData();
    });
    await _saveUserPlaylists();
    return playlist;
  }

  Future<UserPlaylist?> _pickPlaylistOrCreate({
    required List<int> songIdsToAdd,
  }) async {
    if (!mounted) return null;
    final pickedId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Text(
                    'Add to playlist',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(
                    height: 1,
                    color: cs.outlineVariant.withOpacity(0.55),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('New playlist'),
                  onTap: () => Navigator.pop(ctx, '__new__'),
                ),
                if (_userPlaylists.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: Text(
                      'No playlists yet',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ..._userPlaylists.map(
                    (p) => ListTile(
                      leading: const Icon(Icons.playlist_play_rounded),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${p.songIds.length} tracks'),
                      onTap: () => Navigator.pop(ctx, p.id),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (pickedId == null) return null;
    if (pickedId == '__new__') {
      return _promptCreatePlaylist();
    }
    for (final p in _userPlaylists) {
      if (p.id == pickedId) return p;
    }
    return null;
  }

  Future<bool> _addSongsToPlaylistFlow(List<int> songIds) async {
    if (songIds.isEmpty) return false;
    final playlist = await _pickPlaylistOrCreate(songIdsToAdd: songIds);
    if (playlist == null) return false;

    final idx = _userPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx == -1) return false;

    final existing = _userPlaylists[idx];
    final existingSet = existing.songIds.toSet();
    final updated = List<int>.from(existing.songIds);
    var addedCount = 0;
    for (final id in songIds) {
      if (existingSet.add(id)) {
        updated.add(id);
        addedCount++;
      }
    }

    if (addedCount == 0) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('All selected songs are already in "${existing.name}"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final newPlaylist = existing.copyWith(songIds: updated, updatedAtMs: now);
    setState(() {
      _userPlaylists = List<UserPlaylist>.from(_userPlaylists)
        ..[idx] = newPlaylist;
      _recomputeAllData();
    });
    await _saveUserPlaylists();

    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added $addedCount song${addedCount == 1 ? '' : 's'} to "${newPlaylist.name}"',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return true;
  }

  // Thin wrappers — delegates to PlaybackController.
  Uri _songUri(SongModel song) => _controller.songUri(song);
  MediaItem _toMediaItem(SongModel song) => _controller.toMediaItem(song);
  int? _songIdFromTag(dynamic tag) => _controller.songIdFromTag(tag);

  @override
  void initState() {
    super.initState();
    _selectedTabIndex = widget.initialTabIndex.clamp(0, 3);
    _scrollController.addListener(_handleScroll);
    _controller.attachStreamListeners();
    _ensureLibraryPermissionAndLoad();
  }

  void _handleScroll() {
    // When the large header collapses, show a search icon in the app bar.
    // Keep the threshold low so it feels responsive.
    final shouldShow =
        _scrollController.hasClients && _scrollController.offset > 80;
    if (shouldShow != _showSearchInAppBar) {
      setState(() => _showSearchInAppBar = shouldShow);
    }
    // Defensive: if the search overlay is open, scrolling should close it.
    if (_searchController.isOpen) {
      _searchController.closeView(_searchController.text);
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _ensureLibraryPermissionAndLoad({
    bool fromUserAction = false,
  }) async {
    if (kIsWeb) {
      setState(() => _permissionState = _LibraryPermissionState.granted);
      await _loadIncludedFolders();
      await _loadExcludedFolders();
      await _loadPlayHistory();
      await _loadUserPlaylists();
      await loadMusic();
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      // Keep behavior simple for non-Android targets.
      setState(() => _permissionState = _LibraryPermissionState.granted);
      await _loadIncludedFolders();
      await _loadExcludedFolders();
      await _loadPlayHistory();
      await _loadUserPlaylists();
      await loadMusic();
      return;
    }

    final audioStatus = await Permission.audio.status;
    final storageStatus = await Permission.storage.status;

    final hasAccess = audioStatus.isGranted || storageStatus.isGranted;
    if (hasAccess) {
      if (mounted)
        setState(() => _permissionState = _LibraryPermissionState.granted);
      await _loadIncludedFolders();
      await _loadExcludedFolders();
      await _loadPlayHistory();
      await _loadUserPlaylists();
      await loadMusic();
      return;
    }

    if (!fromUserAction) {
      if (mounted)
        setState(() => _permissionState = _LibraryPermissionState.denied);
      return;
    }

    // Ask only for the minimum necessary permissions.
    final results = await <Permission>[
      Permission.audio,
      Permission.storage,
    ].request();
    final audioGranted = results[Permission.audio]?.isGranted ?? false;
    final storageGranted = results[Permission.storage]?.isGranted ?? false;
    final granted = audioGranted || storageGranted;

    if (mounted) {
      final anyPermanent =
          (results[Permission.audio]?.isPermanentlyDenied ?? false) ||
          (results[Permission.storage]?.isPermanentlyDenied ?? false);
      _permissionState = granted
          ? _LibraryPermissionState.granted
          : (anyPermanent
                ? _LibraryPermissionState.permanentlyDenied
                : _LibraryPermissionState.denied);
      setState(() {});
    }

    if (granted) {
      await _loadIncludedFolders();
      await _loadExcludedFolders();
      await _loadPlayHistory();
      await _loadUserPlaylists();
      await loadMusic();
    }
  }

  Future<void> _loadPlayHistory() async {
    await _controller.loadPlayHistory();
    _recomputeAllData();
    if (mounted) setState(() {});
  }

  int _dateAddedFromSong(SongModel s) {
    final v =
        s.getMap['date_added'] ??
        s.getMap['dateAdded'] ??
        s.getMap['date_added_ms'];
    if (v == null) return 0;
    final parsed = v is int ? v : int.tryParse(v.toString());
    if (parsed == null) return 0;

    // Heuristic: MediaStore date_added is usually seconds since epoch.
    // If it looks like seconds, convert to ms.
    if (parsed > 0 && parsed < 1000000000000) {
      // < ~2001-09-09 in ms; likely seconds.
      if (parsed > 1000000000) return parsed * 1000;
    }
    return parsed;
  }

  Future<void> _ensureNotificationPermissionIfNeeded() async {
    final ok = await ensureNotificationPermissionIfNeeded();
    if (!ok && mounted) {
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
  }

  Future<void> loadMusic() async {
    setState(() => _isLoading = true);
    try {
      List<SongModel> rawSongs = await _audioQuery.querySongs(
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );

      List<AlbumModel> albums = await _audioQuery.queryAlbums();

      _controller.albumMap = {for (final a in albums) a.id: a};

      _allFolders = _extractFolders(rawSongs);

      final processedSongs = await compute(
        _processSongsInBackground,
        IsolateData(
          rawSongs,
          albums,
          _excludedFolders.toList(),
          _includedFolders.toList(),
        ),
      );

      _controller.songs = processedSongs;
      _controller.libraryPlaylist = _controller.buildPlaylist(processedSongs);
      _controller.currentPlaylist = _controller.libraryPlaylist;

      setState(() {
        _songs = processedSongs;
        _recomputeAllData();
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  static List<SongModel> _processSongsInBackground(IsolateData data) {
    List<SongModel> songs = data.songs;
    final Map<int, AlbumModel> albumMap = {for (var a in data.albums) a.id: a};

    final List<String> excludedFragments = _defaultExcludedFolderFragments;
    final List<String> excludedPrefixes = data.excludedFolders;
    final List<String> includedPrefixes = data.includedFolders;
    final bool hasInclude = includedPrefixes.isNotEmpty;

    bool isIncluded(String path) {
      if (!hasInclude) return true;
      final normalized = path.replaceAll('\\', '/');
      return includedPrefixes.any((prefix) => normalized.startsWith(prefix));
    }

    bool isExcluded(String path) {
      final normalized = path.replaceAll('\\', '/');
      if (!hasInclude &&
          excludedFragments.any((fragment) => normalized.contains(fragment))) {
        return true;
      }
      if (excludedPrefixes.any((prefix) => normalized.startsWith(prefix)))
        return true;
      return false;
    }

    songs = songs
        .where((song) => isIncluded(song.data) && !isExcluded(song.data))
        .toList();

    // Sort: Album Artist → Year (album release) → Album name → Track number
    // Keep comparisons deterministic (Dart's sort is not stable).
    final yearRegex = RegExp(r'(19|20)\\d{2}');

    String normalize(String v) {
      final t = v.trim();
      if (t.isEmpty) return '';
      final lower = t.toLowerCase();
      // Treat "unknown" values as empty to avoid them dominating sorts.
      if (lower == 'unknown' ||
          lower == 'unknown artist' ||
          lower == 'unknown album')
        return '';
      return t;
    }

    int compareSortStrings(String a, String b) {
      final aNorm = normalize(a);
      final bNorm = normalize(b);
      final aEmpty = aNorm.isEmpty;
      final bEmpty = bNorm.isEmpty;
      if (aEmpty != bEmpty) return aEmpty ? 1 : -1;

      final aLower = aNorm.toLowerCase();
      final bLower = bNorm.toLowerCase();
      final comp = aLower.compareTo(bLower);
      if (comp != 0) return comp;
      return aNorm.compareTo(bNorm);
    }

    int yearFromSong(SongModel s) {
      final v = s.getMap["year"];
      if (v == null) return 0;
      if (v is int) return v;
      final raw = v.toString();
      final direct = int.tryParse(raw);
      if (direct != null) return direct;
      final match = yearRegex.firstMatch(raw);
      if (match == null) return 0;
      return int.tryParse(match.group(0)!) ?? 0;
    }

    int yearForCompare(SongModel s) {
      final y = yearFromSong(s);
      return y == 0 ? 99999 : y;
    }

    int _compareDiscAndTrackLocal(SongModel a, SongModel b) {
      final aDisc = a.getMap['disc_number'] is int
          ? a.getMap['disc_number'] as int
          : 0;
      final bDisc = b.getMap['disc_number'] is int
          ? b.getMap['disc_number'] as int
          : 0;
      final at = a.track ?? 0;
      final bt = b.track ?? 0;

      var ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
      var bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);

      if (ad == 0) ad = 1;
      if (bd == 0) bd = 1;
      if (ad != bd) return ad.compareTo(bd);

      final an = at >= 1000 ? (at % 1000) : at;
      final bn = bt >= 1000 ? (bt % 1000) : bt;

      final finalAt = an == 0 ? 99999 : an;
      final finalBt = bn == 0 ? 99999 : bn;
      return finalAt.compareTo(finalBt);
    }

    String albumArtistFor(SongModel s, AlbumModel? album) {
      // Prefer explicit album_artist tag; fall back to album model or track artist.
      final raw = s.getMap["album_artist"]?.toString();
      final fromSong = normalize(raw ?? '');
      if (fromSong.isNotEmpty) return fromSong;
      final fromAlbum = normalize(album?.artist ?? '');
      if (fromAlbum.isNotEmpty) return fromAlbum;
      return normalize(s.artist ?? '');
    }

    String albumFor(SongModel s, AlbumModel? album) =>
        album?.album ?? s.album ?? "";

    songs.sort((a, b) {
      AlbumModel? albumA = albumMap[a.albumId];
      AlbumModel? albumB = albumMap[b.albumId];

      String albumArtistA = albumArtistFor(a, albumA);
      String albumArtistB = albumArtistFor(b, albumB);
      int artistComp = compareSortStrings(albumArtistA, albumArtistB);
      if (artistComp != 0) return artistComp;

      int yearA = yearForCompare(a);
      int yearB = yearForCompare(b);
      if (yearA != yearB) return yearA.compareTo(yearB);

      String albumNameA = albumFor(a, albumA);
      String albumNameB = albumFor(b, albumB);
      int albumCompare = compareSortStrings(albumNameA, albumNameB);
      if (albumCompare != 0) return albumCompare;

      final trackComp = _compareDiscAndTrackLocal(a, b);
      if (trackComp != 0) return trackComp;

      final titleComp = compareSortStrings(a.title, b.title);
      if (titleComp != 0) return titleComp;
      return a.id.compareTo(b.id);
    });

    return songs;
  }

  int _compareStrings(String a, String b) {
    final aTrim = a.trim();
    final bTrim = b.trim();
    final aLower = aTrim.toLowerCase();
    final bLower = bTrim.toLowerCase();
    final comp = aLower.compareTo(bLower);
    if (comp != 0) return comp;
    return aTrim.compareTo(bTrim);
  }

  String _normalizeSortText(String v) {
    final t = v.trim();
    if (t.isEmpty) return '';
    final lower = t.toLowerCase();
    if (lower == 'unknown' ||
        lower == 'unknown artist' ||
        lower == 'unknown album')
      return '';
    return t;
  }

  int _compareSortStrings(String a, String b) {
    final aNorm = _normalizeSortText(a);
    final bNorm = _normalizeSortText(b);
    final aEmpty = aNorm.isEmpty;
    final bEmpty = bNorm.isEmpty;
    if (aEmpty != bEmpty) return aEmpty ? 1 : -1;

    final aLower = aNorm.toLowerCase();
    final bLower = bNorm.toLowerCase();
    final comp = aLower.compareTo(bLower);
    if (comp != 0) return comp;
    return aNorm.compareTo(bNorm);
  }

  int _yearFromSong(SongModel s) {
    final v = s.getMap["year"];
    if (v == null) return 0;
    if (v is int) return v;
    final raw = v.toString();
    final direct = int.tryParse(raw);
    if (direct != null) return direct;
    final match = _yearRegex.firstMatch(raw);
    if (match == null) return 0;
    return int.tryParse(match.group(0)!) ?? 0;
  }

  int _yearForCompare(SongModel s) {
    final y = _yearFromSong(s);
    return y == 0 ? 99999 : y;
  }

  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final aDisc = a.getMap['disc_number'] is int
        ? a.getMap['disc_number'] as int
        : 0;
    final bDisc = b.getMap['disc_number'] is int
        ? b.getMap['disc_number'] as int
        : 0;
    final at = a.track ?? 0;
    final bt = b.track ?? 0;

    var ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
    var bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);

    // Treat missing/0 disc as Disc 1 to align with explicit Disc 1 tags
    if (ad == 0) ad = 1;
    if (bd == 0) bd = 1;

    if (ad != bd) return ad.compareTo(bd);

    final an = at >= 1000 ? (at % 1000) : at;
    final bn = bt >= 1000 ? (bt % 1000) : bt;

    // 0 is usually unknown track, push to end
    final finalAt = an == 0 ? 99999 : an;
    final finalBt = bn == 0 ? 99999 : bn;
    return finalAt.compareTo(finalBt);
  }

  int _trackForCompare(SongModel s) {
    final t = s.track ?? 0;
    return t == 0 ? 99999 : t;
  }

  String _albumArtistFor(SongModel s) {
    final raw = s.getMap["album_artist"]?.toString();
    final fromSong = _normalizeSortText(raw ?? '');
    if (fromSong.isNotEmpty) return fromSong;
    final fromAlbum = _normalizeSortText(_controller.albumMap[s.albumId]?.artist ?? '');
    if (fromAlbum.isNotEmpty) return fromAlbum;
    return _normalizeSortText(s.artist ?? '');
  }

  Future<void> _runWithPlaybackSuspendedForTagWrite(
    Future<void> Function() action,
  ) async {
    final handler = audioHandler;
    final shouldSuspend = handler != null && handler.player == _controller.player;
    final playlist = _controller.currentPlaylist;
    final restoreSource = playlist ?? _controller.player.audioSource;
    final hasLoaded =
        _controller.player.processingState != ProcessingState.idle &&
        restoreSource != null;
    if (!hasLoaded) {
      await action();
      return;
    }

    final wasPlaying = _controller.player.playing;
    final index = _controller.player.currentIndex;
    final pos = _controller.player.position;

    _controller.setSuppressIndexUpdates(true);
    try {
      pushAutoExitSuppress();
      if (shouldSuspend) handler.setStateBroadcastSuspended(true);
      await detachPlayerForTagWrite(_controller.player).timeout(
        tagDetachTimeout,
        onTimeout: () {
          debugPrint('Timed out detaching player for tag write.');
        },
      );

      await action().timeout(
        tagWriteTimeout,
        onTimeout: () {
          throw TimeoutException('Tag write timed out. Please try again.');
        },
      );
    } finally {
      popAutoExitSuppress();
      if (shouldSuspend) handler.setStateBroadcastSuspended(false);
      try {
        await restorePlayerAfterTagWrite(
          _controller.player,
          restoreSource,
          index,
          pos,
          wasPlaying,
        ).timeout(
          tagRestoreTimeout,
          onTimeout: () {
            debugPrint('Timed out restoring playback after tag write.');
          },
        );
      } catch (e, st) {
        debugPrint('Failed to restore playback after tag write: $e');
        debugPrintStack(stackTrace: st);
      } finally {
        _controller.setSuppressIndexUpdates(false);
      }
    }
  }

  String _normalizeFolderPath(String path) {
    var normalized = path.replaceAll('\\', '/');
    if (!normalized.endsWith('/')) normalized = '$normalized/';
    return normalized;
  }

  List<String> _extractFolders(List<SongModel> songs) {
    final Set<String> folders = {};
    for (final song in songs) {
      final path = song.data.replaceAll('\\', '/');
      final lastSlash = path.lastIndexOf('/');
      if (lastSlash <= 0) continue;
      final dir = path.substring(0, lastSlash + 1);
      folders.add(_normalizeFolderPath(dir));
    }
    final list = folders.toList();
    list.sort(_compareStrings);
    return list;
  }

  String _folderDisplayName(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return trimmed;
    return parts.last;
  }

  Future<void> _loadIncludedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_includedFoldersKey) ?? [];
    final normalized = stored.map(_normalizeFolderPath).toSet();
    setState(() => _includedFolders = normalized);
  }

  Future<void> _saveIncludedFolders(Set<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_includedFoldersKey, folders.toList());
  }

  Future<void> _loadExcludedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_excludedFoldersKey) ?? [];
    setState(() => _excludedFolders = stored.toSet());
  }

  Future<void> _saveExcludedFolders(Set<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludedFoldersKey, folders.toList());
  }

  void _openAboutPage() {
    context.pushNamed('about');
  }

  Future<void> _confirmQuit() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    final shouldQuit = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Quit app?'),
          content: const Text('This will completely close the app.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? cs.errorContainer : cs.error,
                foregroundColor: isDark ? cs.onErrorContainer : cs.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Quit'),
            ),
          ],
        );
      },
    );

    if (shouldQuit == true) {
      await PlatformExit.quit();
    }
  }

  static const List<String> _commonFolders = [
    '/storage/emulated/0/Music/',
    '/storage/emulated/0/Download/',
    '/storage/emulated/0/Podcasts/',
    '/storage/emulated/0/Ringtones/',
    '/storage/emulated/0/Alarms/',
    '/storage/emulated/0/Notifications/',
    '/storage/emulated/0/Recordings/',
    '/storage/emulated/0/DCIM/',
    '/storage/emulated/0/Movies/',
    '/storage/emulated/0/Pictures/',
  ];

  String _commonFolderDisplayName(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return trimmed;
    return parts.last;
  }

  void _showManageFoldersDialog() {
    final included = Set<String>.from(_includedFolders);
    final excluded = Set<String>.from(_excludedFolders);
    int _activeTab = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setModalState) {
              final cs = Theme.of(ctx).colorScheme;
              return SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.8,
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      TabBar(
                        onTap: (i) => _activeTab = i,
                        labelColor: cs.primary,
                        unselectedLabelColor: cs.onSurfaceVariant,
                        tabs: const [
                          Tab(icon: Icon(Icons.folder_open_rounded), text: 'Included'),
                          Tab(icon: Icon(Icons.folder_off_rounded), text: 'Excluded'),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          'Quick-add common folders:',
                          style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: _commonFolders.map((folder) {
                            return ActionChip(
                              avatar: const Icon(Icons.folder, size: 18),
                              label: Text(
                                _commonFolderDisplayName(folder),
                                style: const TextStyle(fontSize: 12),
                              ),
                              onPressed: () {
                                setModalState(() {
                                  if (_activeTab == 0) {
                                    included.add(folder);
                                  } else {
                                    excluded.add(folder);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text("Browse folder…"),
                                onPressed: () async {
                                  final folder = await FilePicker.platform.getDirectoryPath();
                                  if (folder == null) return;
                                  final normalized = _normalizeFolderPath(folder);
                                  setModalState(() {
                                    if (_activeTab == 0) {
                                      included.add(normalized);
                                    } else {
                                      excluded.add(normalized);
                                    }
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            // ── Included tab ──
                            _buildFolderTab(
                              ctx,
                              setModalState,
                              folders: included,
                              otherFolders: excluded,
                              title: 'Included folders',
                              emptyLabel: 'No folders included — all songs are shown.',
                              description:
                                  'Only songs inside these folders (and subfolders) are shown.',
                              isIncluded: true,
                              onClear: () => setModalState(() => included.clear()),
                            ),
                            // ── Excluded tab ──
                            _buildFolderTab(
                              ctx,
                              setModalState,
                              folders: excluded,
                              otherFolders: included,
                              title: 'Excluded folders',
                              emptyLabel: 'No folders excluded.',
                              description:
                                  'Songs inside these folders are hidden from the library.',
                              isIncluded: false,
                              onClear: () => setModalState(() => excluded.clear()),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text("Cancel"),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                setState(() {
                                  _includedFolders = included;
                                  _excludedFolders = excluded;
                                });
                                await _saveIncludedFolders(_includedFolders);
                                await _saveExcludedFolders(_excludedFolders);
                                await loadMusic();
                              },
                              child: const Text("Save"),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildFolderTab(
    BuildContext ctx,
    StateSetter setModalState, {
    required Set<String> folders,
    required Set<String> otherFolders,
    required String title,
    required String emptyLabel,
    required String description,
    required bool isIncluded,
    required VoidCallback onClear,
  }) {
    final cs = Theme.of(ctx).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const Spacer(),
              Text('${folders.length}', style: Theme.of(ctx).textTheme.labelLarge),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            description,
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: folders.isEmpty ? null : onClear,
              child: const Text("Clear all"),
            ),
          ),
        ),
        Expanded(
          child: folders.isEmpty
              ? Center(child: Text(emptyLabel))
              : ListView.builder(
                  itemCount: folders.length,
                  itemBuilder: (context, index) {
                    final folder = folders.elementAt(index);
                    final isAlsoInOther = otherFolders.contains(folder);
                    return ListTile(
                      leading: Icon(
                        isAlsoInOther ? Icons.folder_shared_rounded : Icons.folder_rounded,
                        color: isAlsoInOther ? cs.tertiary : null,
                      ),
                      title: Text(_folderDisplayName(folder)),
                      subtitle: Text(
                        folder.endsWith('/') ? folder.substring(0, folder.length - 1) : folder,
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isAlsoInOther)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                isIncluded ? Icons.block : Icons.check_circle_outline,
                                size: 18,
                                color: cs.tertiary,
                              ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => setModalState(() => folders.remove(folder)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _applySort(SortMode mode) async {
    await _controller.applySort(mode);
    _songs = _controller.songs;
    _recomputeAllData();
    if (mounted) setState(() {});
  }

  Future<void> _showSongOptionsSheet(SongModel song, int index) async {
    if (!mounted) return;
    final hasAlbum = (song.albumId ?? 0) > 0;
    final artistName = (song.artist ?? '').trim();
    final hasArtist =
        artistName.isNotEmpty && artistName.toLowerCase() != 'unknown artist';

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = cs.surface;
    final sectionLabelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.18,
    );

    Widget sectionLabel(String text) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text(text, style: sectionLabelStyle),
      );
    }

    AudioSource _sourceForSong(SongModel s) {
      final useBackground =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      final uri = _songUri(s);
      final tag = useBackground ? _toMediaItem(s) : s;
      return AudioSource.uri(uri, tag: tag);
    }

    Future<void> playNext() async {
      if (_controller.currentPlaylist == null || _controller.player.currentIndex == null) {
        await _controller.playSong(index);
        return;
      }
      final insertAt = (_controller.player.currentIndex! + 1).clamp(
        0,
        _controller.currentPlaylist!.length,
      );
      try {
        await _controller.currentPlaylist!.insert(insertAt, _sourceForSong(song));
        HapticFeedback.selectionClick();
      } catch (_) {
        await _controller.playSong(index);
      }
    }

    Future<void> addToQueue() async {
      if (_controller.currentPlaylist == null) {
        await _controller.playSong(index);
        return;
      }
      try {
        await _controller.currentPlaylist!.add(_sourceForSong(song));
        HapticFeedback.selectionClick();
      } catch (_) {
        await _controller.playSong(index);
      }
    }

    Future<void> openNowPlaying() async {
      final songToOpen = song;
      // If this song is currently in the player sequence, open that exact item.
      await _openNowPlaying(songToOpen);
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.78,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Row(
                    children: [
                      ClipOval(
                        child: FastArtworkWidget(
                          id: song.id,
                          type: ArtworkType.AUDIO,
                          width: 52,
                          height: 52,
                          nullArtworkWidget: Container(
                            width: 52,
                            height: 52,
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.12,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist ?? 'Unknown Artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(
                    height: 1,
                    color: cs.outlineVariant.withOpacity(isDark ? 0.35 : 0.55),
                  ),
                ),

                sectionLabel('Selection'),
                ListTile(
                  leading: const Icon(Icons.checklist_rounded),
                  title: const Text('Select'),
                  subtitle: const Text(
                    'Select multiple songs to add to a playlist',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    HapticFeedback.selectionClick();
                    _enterSelectionMode(initialSongId: song.id);
                  },
                ),

                sectionLabel('Playback'),
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('Play'),
                  subtitle: const Text('Start playing this track'),
                  onTap: () {
                    Navigator.pop(ctx);
                    HapticFeedback.selectionClick();
                    _controller.playSong(index);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_full_rounded),
                  title: const Text('Open Now Playing'),
                  subtitle: const Text('Jump to the player screen'),
                  onTap: () {
                    Navigator.pop(ctx);
                    openNowPlaying();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded),
                  title: const Text('Play next'),
                  subtitle: const Text('Insert after the current track'),
                  onTap: () {
                    Navigator.pop(ctx);
                    playNext();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: const Text('Add to queue'),
                  subtitle: const Text('Append to the end of the queue'),
                  onTap: () {
                    Navigator.pop(ctx);
                    addToQueue();
                  },
                ),

                if (hasAlbum || hasArtist) ...[
                  sectionLabel('Library'),
                  if (hasAlbum)
                    ListTile(
                      leading: const Icon(Icons.album_rounded),
                      title: const Text('Open album'),
                      subtitle: const Text('View all tracks in this album'),
                      onTap: () {
                        Navigator.pop(ctx);
                        HapticFeedback.selectionClick();
                        _openAlbumPageFromSong(song);
                      },
                    ),
                  if (hasArtist)
                    ListTile(
                      leading: const Icon(Icons.person_rounded),
                      title: const Text('Open artist'),
                      subtitle: const Text('View albums by this artist'),
                      onTap: () {
                        Navigator.pop(ctx);
                        HapticFeedback.selectionClick();
                        _openArtistPageFromSong(song);
                      },
                    ),
                ],

                sectionLabel('Edit'),
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('Edit tags'),
                  subtitle: const Text('Title, artist, album, cover art'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    HapticFeedback.selectionClick();
                    await showDialog<bool>(
                      context: context,
                      builder: (dctx) => TagEditorDialog(
                        song: song,
                        onSaved: loadMusic,
                        runWithPlaybackSuspended:
                            _runWithPlaybackSuspendedForTagWrite,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lyrics_rounded),
                  title: const Text('Edit lyrics'),
                  subtitle: const Text('Paste lyrics or synced LRC'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    HapticFeedback.selectionClick();
                    await showDialog<bool>(
                      context: context,
                      builder: (dctx) => LyricsEditorDialog(
                        song: song,
                        currentLyrics: null,
                        onSaved: () {},
                        runWithPlaybackSuspended:
                            _runWithPlaybackSuspendedForTagWrite,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _playFromQueue(
    List<SongModel> queue, {
    required int initialIndex,
  }) async {
    if (queue.isEmpty) return;
    if (initialIndex < 0 || initialIndex >= queue.length) return;

    await _ensureNotificationPermissionIfNeeded();

    final newPlaylist = _controller.buildPlaylist(queue);
    final songId = queue[initialIndex].id;

    _controller.currentPlaylist = newPlaylist;
    final libraryIndex = _songs.indexWhere((s) => s.id == songId);
    _controller.currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;
    _controller.currentSongId = songId;

    try {
      _controller.setSuppressIndexUpdates(true);
      await _controller.player.setAudioSource(newPlaylist, initialIndex: initialIndex);
      await _controller.player.play();
      _controller.recordPlayForSongId(songId);
    } catch (e, st) {
      debugPrint('Failed to play custom queue initialIndex=$initialIndex: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        _controller.currentPlayIndex = null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playback failed: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _controller.setSuppressIndexUpdates(false);
    }
  }

  Future<void> _playSong(int index) async {
    if (index < 0 || index >= _songs.length) return;
    await _ensureNotificationPermissionIfNeeded();
    await _controller.playSong(index);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSelectionMode && _inlineDetailContent == null,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_isSelectionMode) {
          HapticFeedback.selectionClick();
          _exitSelectionMode();
          return;
        }
        if (_inlineDetailContent != null) {
          HapticFeedback.selectionClick();
          _closeInlineDetail();
        }
      },
      child: Scaffold(
        extendBody: true,
        bottomNavigationBar: _animatedBottomBars(),
        body: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: _permissionState != _LibraryPermissionState.granted
              ? (_permissionState == _LibraryPermissionState.unknown
                    ? const Center(child: CircularProgressIndicator())
                    : _LibraryPermissionGate(
                        state: _permissionState,
                        onGrant: () => _ensureLibraryPermissionAndLoad(
                          fromUserAction: true,
                        ),
                        onOpenSettings: openAppSettings,
                      ))
              : _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    // Offstage hides the tabs visually but keeps them fully loaded in memory!
                    Offstage(
                      offstage: _inlineDetailContent != null,
                      child: IndexedStack(
                        index: _selectedTabIndex,
                        children: [
                          KeyedSubtree(
                            key: const PageStorageKey<String>('tab_library'),
                            child: _buildLibraryTab(
                              context,
                              isVisible: _inlineDetailContent == null,
                            ),
                          ),
                          KeyedSubtree(
                            key: const PageStorageKey<String>('tab_album_artists'),
                            child: _buildAlbumArtistsTab(context),
                          ),
                          KeyedSubtree(
                            key: const PageStorageKey<String>('tab_albums'),
                            child: _buildAlbumsTab(context),
                          ),
                          KeyedSubtree(
                            key: const PageStorageKey<String>('tab_playlists'),
                            child: _buildPlaylistsTab(context),
                          ),
                        ],
                      ),
                    ),
                    // Show the detail page on top of the hidden tabs
                    if (_inlineDetailContent != null)
                      _inlineDetailContent!,
                  ],
                ),
        ),
      ),
    );
  }

  Widget _wrapWithAuroraBackground({required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rawPrimary = _boostVibrance(
      cs.primaryContainer,
      extraSaturation: 0.08,
      extraLightness: isDark ? -0.04 : 0.04,
    );
    final rawSecondary = _boostVibrance(
      cs.tertiaryContainer,
      extraSaturation: 0.10,
      extraLightness: isDark ? -0.03 : 0.03,
    );
    final rawAccent = _boostVibrance(
      cs.secondaryContainer,
      extraSaturation: 0.10,
      extraLightness: isDark ? -0.03 : 0.03,
    );

    final primary = _harmonizeBackgroundAccent(
      rawPrimary,
      cs.surface,
      isDark: isDark,
    );
    final secondary = _harmonizeBackgroundAccent(
      rawSecondary,
      cs.surface,
      isDark: isDark,
    );
    final accent = _harmonizeBackgroundAccent(
      rawAccent,
      cs.surface,
      isDark: isDark,
    );
    final overlayOpacity = isDark ? 0.12 : 0.18;

    Widget blob(
      Color color,
      double size,
      Alignment alignment, {
      double opacity = 0.28,
    }) {
      return Align(
        alignment: alignment,
        // Using a RadialGradient is mathematically pre-calculated by the rendering
        // engine and costs 99% less GPU overhead than an ImageFilter.blur.
        child: Container(
          width: size * 1.6, // Slightly larger to mimic the blur spread
          height: size * 1.6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withOpacity(opacity),
                color.withOpacity(0.0),
              ],
              stops: const [0.2, 1.0],
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  primary.withOpacity(overlayOpacity),
                  cs.surface,
                ),
                Color.alphaBlend(
                  secondary.withOpacity(overlayOpacity * 0.9),
                  cs.surface,
                ),
                cs.surface,
              ],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              blob(
                primary,
                240,
                Alignment.topLeft,
                opacity: isDark ? 0.08 : 0.14,
              ),
              blob(
                secondary,
                260,
                Alignment.topRight,
                opacity: isDark ? 0.07 : 0.12,
              ),
              blob(
                accent,
                200,
                Alignment.bottomLeft,
                opacity: isDark ? 0.06 : 0.10,
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildLibraryTab(
    BuildContext context, {
    required bool isVisible,
  }) {
    final cs = Theme.of(context).colorScheme;

    Widget menuLabel(IconData icon, String label) {
      return Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label),
        ],
      );
    }

    return _wrapWithAuroraBackground(
      child: Scrollbar(
        controller: _scrollController,
        interactive: true,
        child: CustomScrollView(
        // Helps avoid transient blanking while scrubbing the scrollbar quickly
        // by keeping more children alive and prefetched.
        cacheExtent: 1200,
        controller: _scrollController,
        slivers: [
          SliverAppBar.large(
            title: _isSelectionMode
                ? Text('${_selectedSongIds.length} selected')
                : const Text('Library'),
            expandedHeight: 112,
            collapsedHeight: 86,
            toolbarHeight: 86,
            centerTitle: false,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            forceMaterialTransparency: true,
            foregroundColor: cs.onSurface,
            titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
            ),
            actions: [
              if (_isSelectionMode) ...[
                IconButton(
                  tooltip: 'Cancel',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _exitSelectionMode();
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
                IconButton(
                  tooltip: 'Add to playlist',
                  onPressed: _selectedSongIds.isEmpty
                      ? null
                      : () async {
                          HapticFeedback.selectionClick();
                          final ids = _selectedSongIds.toList(growable: false);
                          final didAdd = await _addSongsToPlaylistFlow(ids);
                          if (didAdd) _exitSelectionMode();
                        },
                  icon: const Icon(Icons.playlist_add_rounded),
                ),
              ] else ...[
                // Search "collapses" into this button when scrolled.
                SearchAnchor(
                  searchController: _searchController,
                  viewBackgroundColor: cs.surface,
                  viewSurfaceTintColor: Colors.transparent,
                  dividerColor: cs.outlineVariant.withOpacity(0.28),
                  builder: (context, controller) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _showSearchInAppBar
                          ? IconButton(
                              key: const ValueKey('search_on'),
                              icon: const Icon(Icons.search_rounded),
                              tooltip: 'Search',
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                controller.openView();
                              },
                            )
                          : const SizedBox.shrink(key: ValueKey('search_off')),
                    );
                  },
                  suggestionsBuilder: (context, controller) {
                    final cs = Theme.of(context).colorScheme;
                    final q = controller.text.trim().toLowerCase();

                    String norm(String? v) => (v ?? '').trim().toLowerCase();
                    bool starts(String? v) => norm(v).startsWith(q);
                    bool contains(String? v) => norm(v).contains(q);
                    bool exact(String? v) => q.isNotEmpty && norm(v) == q;

                    // Artist hits (unique by artist name)
                    final Map<String, SongModel> firstSongByArtist = {};
                    for (final s in _songs) {
                      final name = (s.artist ?? '').trim();
                      if (name.isEmpty) continue;
                      firstSongByArtist.putIfAbsent(name.toLowerCase(), () => s);
                    }

                    final artistHits = q.isEmpty
                        ? firstSongByArtist.values.take(6).toList(growable: false)
                        : () {
                            final exactMatches = <SongModel>[];
                            final startMatches = <SongModel>[];
                            final containMatches = <SongModel>[];
                            for (final s in firstSongByArtist.values) {
                              if (exact(s.artist)) exactMatches.add(s);
                              else if (starts(s.artist)) startMatches.add(s);
                              else if (contains(s.artist)) containMatches.add(s);
                            }
                            return [...exactMatches, ...startMatches, ...containMatches].take(10).toList(growable: false);
                          }();

                    // Album hits (unique by albumId)
                    final Map<int, SongModel> firstSongByAlbumId = {};
                    for (final s in _songs) {
                      final albumId = s.albumId;
                      if (albumId == null || albumId <= 0) continue;
                      firstSongByAlbumId.putIfAbsent(albumId, () => s);
                    }

                    final albumHits = q.isEmpty
                        ? firstSongByAlbumId.values.take(6).toList(growable: false)
                        : () {
                            final exactMatches = <SongModel>[];
                            final startMatches = <SongModel>[];
                            final containMatches = <SongModel>[];
                            for (final s in firstSongByAlbumId.values) {
                              if (exact(s.album)) exactMatches.add(s);
                              else if (starts(s.album)) startMatches.add(s);
                              else if (contains(s.album)) containMatches.add(s);
                            }
                            return [...exactMatches, ...startMatches, ...containMatches].take(10).toList(growable: false);
                          }();

                    // Track hits (The biggest performance gain)
                    final trackHits = q.isEmpty
                        ? _songs.take(12).toList(growable: false)
                        : () {
                            final exactMatches = <SongModel>[];
                            final startMatches = <SongModel>[];
                            final containMatches = <SongModel>[];
                            for (final s in _songs) {
                              if (exact(s.title)) exactMatches.add(s);
                              else if (starts(s.title)) startMatches.add(s);
                              else if (contains(s.title)) containMatches.add(s);
                            }
                            return [...exactMatches, ...startMatches, ...containMatches].take(20).toList(growable: false);
                          }();

                    Widget header(String text) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Text(
                          text,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                        ),
                      );
                    }

                    Widget searchResultTile({
                      required Widget leading,
                      required Widget title,
                      Widget? subtitle,
                      Widget? trailing,
                      required VoidCallback onTap,
                    }) {
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
                              onTap: onTap,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    leading,
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          DefaultTextStyle(
                                            style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      letterSpacing: -0.1,
                                                    ) ??
                                                const TextStyle(),
                                            child: title,
                                          ),
                                          if (subtitle != null) ...[
                                            const SizedBox(height: 2),
                                            DefaultTextStyle(
                                              style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color:
                                                            cs.onSurfaceVariant,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ) ??
                                                  const TextStyle(),
                                              child: subtitle,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (trailing != null) ...[
                                      const SizedBox(width: 10),
                                      trailing,
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    final widgets = <Widget>[];

                    final hasExactTrack =
                        q.isNotEmpty && _songs.any((s) => exact(s.title));
                    final hasExactAlbum =
                        q.isNotEmpty &&
                        firstSongByAlbumId.values.any((s) => exact(s.album));
                    final hasExactArtist =
                        q.isNotEmpty &&
                        firstSongByArtist.values.any((s) => exact(s.artist));

                    void addTracks() {
                      if (trackHits.isEmpty) return;
                      widgets.add(header('Tracks'));
                      for (final song in trackHits) {
                        final idx = _songs.indexWhere((s) => s.id == song.id);
                        final artist = (song.artist ?? '').trim().isEmpty
                            ? 'Unknown Artist'
                            : song.artist!.trim();
                        final album = (song.album ?? '').trim().isEmpty
                            ? 'Unknown Album'
                            : song.album!.trim();
                        final duration = song.duration == null
                            ? null
                            : formatTime(song.duration);
                        final subtitle = duration == null
                            ? '$artist • $album'
                            : '$artist • $album • $duration';
                        widgets.add(
                          searchResultTile(
                            leading: ClipOval(
                              child: FastArtworkWidget(
                                id: song.id,
                                type: ArtworkType.AUDIO,
                                width: 52,
                                height: 52,
                                nullArtworkWidget: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    color: cs.onSurfaceVariant,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton.filledTonal(
                              icon: const Icon(Icons.play_arrow_rounded),
                              tooltip: 'Play',
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                controller.closeView(song.title);
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (idx != -1) _controller.playSong(idx);
                              },
                            ),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              controller.closeView(song.title);
                              FocusManager.instance.primaryFocus?.unfocus();
                              if (idx != -1) _controller.playSong(idx);
                            },
                          ),
                        );
                      }
                    }

                    void addAlbums() {
                      if (albumHits.isEmpty) return;
                      widgets.add(header('Albums'));
                      for (final song in albumHits) {
                        final albumId = song.albumId ?? 0;
                        final albumTitle = song.album ?? 'Unknown Album';
                        widgets.add(
                          searchResultTile(
                            leading: ClipOval(
                              child: FastArtworkWidget(
                                id: albumId,
                                type: ArtworkType.ALBUM,
                                width: 52,
                                height: 52,
                                nullArtworkWidget: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.album_rounded,
                                    color: cs.onSurfaceVariant,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              albumTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.artist ?? 'Unknown',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              controller.closeView(albumTitle);
                              FocusManager.instance.primaryFocus?.unfocus();
                              _openAlbumPageFromSong(song);
                            },
                          ),
                        );
                      }
                    }

                    void addArtists() {
                      if (artistHits.isEmpty) return;
                      widgets.add(header('Artists'));
                      for (final song in artistHits) {
                        final name = (song.artist ?? '').trim();
                        if (name.isEmpty) continue;
                        widgets.add(
                          searchResultTile(
                            leading: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.person_rounded,
                                color: cs.onSurfaceVariant,
                                size: 22,
                              ),
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: const Text(
                              'Artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              controller.closeView(name);
                              FocusManager.instance.primaryFocus?.unfocus();
                              _openArtistPageByName(name);
                            },
                          ),
                        );
                      }
                    }

                    // Section ordering:
                    // - Prefer exact matches: if exact album -> albums first; if exact artist -> artists first.
                    // - If all three have exact matches: Tracks -> Albums -> Artists.
                    // - Otherwise default: Tracks -> Albums -> Artists.
                    if (q.isEmpty) {
                      addTracks();
                      addAlbums();
                      addArtists();
                    } else if (hasExactTrack &&
                        hasExactAlbum &&
                        hasExactArtist) {
                      addTracks();
                      addAlbums();
                      addArtists();
                    } else if (hasExactAlbum && !hasExactTrack) {
                      addAlbums();
                      addTracks();
                      addArtists();
                    } else if (hasExactArtist &&
                        !hasExactTrack &&
                        !hasExactAlbum) {
                      addArtists();
                      addTracks();
                      addAlbums();
                    } else {
                      addTracks();
                      addAlbums();
                      addArtists();
                    }

                    if (widgets.isEmpty) {
                      widgets.add(
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            q.isEmpty
                                ? 'Start typing to search.'
                                : 'No results for "$q".',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                      );
                    }

                    return widgets;
                  },
                ),
                PopupMenuButton<SortMode>(
                  icon: const Icon(Icons.sort_rounded),
                  initialValue: _controller.sortMode,
                  tooltip: 'Sort library',
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    _applySort(mode);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: SortMode.artist,
                      child: menuLabel(
                        Icons.person_rounded,
                        'Sort by Artist',
                      ),
                    ),
                    PopupMenuItem(
                      value: SortMode.albumArtist,
                      child: menuLabel(
                        Icons.person_outline_rounded,
                        'Sort by Album Artist',
                      ),
                    ),
                    PopupMenuItem(
                      value: SortMode.year,
                      child: menuLabel(Icons.event_rounded, 'Sort by Year'),
                    ),
                    PopupMenuItem(
                      value: SortMode.albumArtistYear,
                      child: menuLabel(
                        Icons.calendar_view_month_rounded,
                        'Sort by Album Artist/Year',
                      ),
                    ),
                  ],
                ),
                PopupMenuButton<_AppMenuAction>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    HapticFeedback.selectionClick();
                    switch (action) {
                      case _AppMenuAction.refresh:
                        loadMusic();
                        break;
                      case _AppMenuAction.manageFolders:
                        _showManageFoldersDialog();
                        break;
                      case _AppMenuAction.toggleTheme:
                        themeNotifier.toggle();
                        break;
                      case _AppMenuAction.about:
                        _openAboutPage();
                        break;
                      case _AppMenuAction.quit:
                        _confirmQuit();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _AppMenuAction.refresh,
                      child: menuLabel(
                        Icons.refresh_rounded,
                        'Scan/Refresh Library',
                      ),
                    ),
                    PopupMenuItem(
                      value: _AppMenuAction.manageFolders,
                      child: menuLabel(
                        Icons.folder_copy_rounded,
                        'Manage Folders',
                      ),
                    ),
                    PopupMenuItem(
                      value: _AppMenuAction.toggleTheme,
                      child: menuLabel(
                        Icons.palette_rounded,
                        themeNotifier.themeMenuLabel,
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _AppMenuAction.about,
                      child: menuLabel(Icons.info_outline_rounded, 'About'),
                    ),
                    PopupMenuItem(
                      value: _AppMenuAction.quit,
                      child: Row(
                        children: [
                          Icon(
                            Icons.power_settings_new_rounded,
                            size: 18,
                            color: cs.error,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Quit',
                            style: TextStyle(color: cs.error),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          if (!_isSelectionMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SearchBar(
                  controller: _searchController,
                  hintText: 'Search songs',
                  leading: const Icon(Icons.search_rounded),
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () =>
                            setState(() => _searchController.clear()),
                      ),
                  ],
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _searchController.openView();
                  },
                  onTapOutside: (_) {
                    if (_searchController.isOpen) {
                      _searchController.closeView(_searchController.text);
                    }
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                ),
              ),
            ),
            SliverPrototypeExtentList(
            prototypeItem: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10.0),
                child: const SizedBox(height: 68, width: double.infinity),
              ),
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final song = _songs[index];
              final isSelected = _selectedSongIds.contains(song.id);
              final cs = Theme.of(context).colorScheme;

              // 1. Push the listeners DOWN to the individual item level
              return ValueListenableBuilder<int?>(
                valueListenable: _controller.currentSongIdNotifier,
                builder: (context, currentSongId, _) {
                  return ValueListenableBuilder<int?>(
                    valueListenable: _controller.currentPlayIndexNotifier,
                    builder: (context, currentPlayIndex, __) {
                      final isCurrent = currentSongId != null
                          ? currentSongId == song.id
                          : currentPlayIndex == index;

                      // 2. ONLY listen to the player state stream if THIS song is the active one!
                      // This avoids dozens of inactive tiles needlessly rebuilding on Play/Pause.
                      return StreamBuilder<PlayerState>(
                        stream: (isCurrent && isVisible)
                            ? _controller.player.playerStateStream
                            : null,
                        builder: (context, snap) {
                          final playing = isCurrent ? (snap.data?.playing ?? _controller.player.playing) : false;
                          final showPause = isCurrent && playing;
                          final icon = showPause
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded;

                          final tileColor = (_isSelectionMode && isSelected)
                              ? Color.alphaBlend(
                                  cs.primaryContainer.withOpacity(
                                    Theme.of(context).brightness == Brightness.dark
                                        ? 0.28
                                        : 0.55,
                                  ),
                                  cs.surface,
                                )
                              : isCurrent
                              ? Color.alphaBlend(
                                  cs.secondaryContainer.withOpacity(
                                    Theme.of(context).brightness == Brightness.dark
                                        ? 0.35
                                        : 0.55,
                                  ),
                                  cs.surface,
                                )
                              : cs.surfaceContainerLow;

                          final borderColor = (_isSelectionMode && isSelected)
                              ? cs.primary.withOpacity(
                                  Theme.of(context).brightness == Brightness.dark
                                      ? 0.35
                                      : 0.30,
                                )
                              : isCurrent
                              ? cs.secondary.withOpacity(
                                  Theme.of(context).brightness == Brightness.dark
                                      ? 0.30
                                      : 0.22,
                                )
                              : cs.outlineVariant.withOpacity(
                                  Theme.of(context).brightness == Brightness.dark
                                      ? 0.28
                                      : 0.35,
                                );

                          final artistText = (song.artist ?? '').trim().isEmpty
                              ? 'Unknown Artist'
                              : song.artist!.trim();
                          final albumText = (song.album ?? '').trim().isEmpty
                              ? 'Unknown Album'
                              : song.album!.trim();
                          final durationText = song.duration == null
                              ? null
                              : formatTime(song.duration);
                          final metaText = albumText;

                          final baseShadows = Theme.of(context).brightness == Brightness.dark
                              ? const <BoxShadow>[]
                              : [
                                  BoxShadow(
                                    blurRadius: 10,
                                    spreadRadius: -6,
                                    offset: const Offset(0, 6),
                                    color: Colors.black.withOpacity(
                                      isCurrent ? 0.12 : 0.08,
                                    ),
                                  ),
                                ];
                          final highlightShadows = isCurrent
                              ? [
                                  BoxShadow(
                                    blurRadius: 18,
                                    spreadRadius: -8,
                                    offset: const Offset(0, 10),
                                    color: cs.primary.withOpacity(
                                      Theme.of(context).brightness == Brightness.dark
                                          ? 0.28
                                          : 0.18,
                                    ),
                                  ),
                                ]
                              : const <BoxShadow>[];

                          return RepaintBoundary(
                            key: ValueKey(song.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                decoration: ShapeDecoration(
                                  color: tileColor,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    side: BorderSide(
                                      color: borderColor,
                                      width: 1,
                                    ),
                                  ),
                                  shadows: <BoxShadow>[
                                    ...baseShadows,
                                    ...highlightShadows,
                                  ],
                                ),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(20),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      if (_isSelectionMode) {
                                        _toggleSelectedSongId(song.id);
                                      } else {
                                        _controller.playSong(index);
                                      }
                                    },
                                    onLongPress: () {
                                      HapticFeedback.mediumImpact();
                                      if (_isSelectionMode) {
                                        _toggleSelectedSongId(song.id);
                                      } else {
                                        _showSongOptionsSheet(song, index);
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 14,
                                      ),
                                      child: Row(
                                        children: [
                                          Stack(
                                            children: [
                                              AnimatedScale(
                                                scale: isCurrent ? 1.03 : 1.0,
                                                duration: const Duration(
                                                  milliseconds: 220,
                                                ),
                                                curve: Curves.easeOutCubic,
                                                child: ClipOval(
                                                  child: FastArtworkWidget(
                                                    id: song.id,
                                                    type: ArtworkType.AUDIO,
                                                    width: 56,
                                                    height: 56,
                                                    nullArtworkWidget:
                                                        Container(
                                                      width: 56,
                                                      height: 56,
                                                    decoration: BoxDecoration(
                                                    color: cs
                                                      .surfaceContainerHighest,
                                                    shape:
                                                      BoxShape.circle,
                                                    ),
                                                      child: Icon(
                                                        Icons
                                                            .music_note_rounded,
                                                        color: cs
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              if (_isSelectionMode)
                                                Positioned(
                                                  left: 4,
                                                  top: 4,
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Color.alphaBlend(
                                                        cs.surface.withOpacity(
                                                          0.75,
                                                        ),
                                                        cs.surfaceContainerHigh,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        999,
                                                      ),
                                                      border: Border.all(
                                                        color: cs.outlineVariant
                                                            .withOpacity(0.35),
                                                      ),
                                                    ),
                                                    child: Icon(
                                                      isSelected
                                                          ? Icons
                                                              .check_circle_rounded
                                                          : Icons
                                                              .radio_button_unchecked_rounded,
                                                      size: 14,
                                                      color: isSelected
                                                          ? cs.primary
                                                          : cs.onSurfaceVariant,
                                                    ),
                                                  ),
                                                ),
                                              if (isCurrent)
                                                Positioned(
                                                  right: 4,
                                                  bottom: 4,
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Color.alphaBlend(
                                                        cs.surface.withOpacity(
                                                          0.75,
                                                        ),
                                                        cs.surfaceContainerHigh,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        999,
                                                      ),
                                                      border: Border.all(
                                                        color: cs.outlineVariant
                                                            .withOpacity(0.35),
                                                      ),
                                                    ),
                                                    child: Icon(
                                                      playing
                                                          ? Icons
                                                              .graphic_eq_rounded
                                                          : Icons
                                                              .pause_circle_filled_rounded,
                                                      size: 14,
                                                      color: cs.onSurface
                                                          .withOpacity(0.85),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  song.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w500,
                                                    letterSpacing: -0.05,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  artistText,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color:
                                                            cs.onSurfaceVariant,
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                ),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        metaText,
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow.ellipsis,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: cs
                                                                  .onSurfaceVariant
                                                                  .withOpacity(0.75),
                                                            ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    SizedBox(
                                                      width: 48,
                                                      child: Text(
                                                        durationText ?? '--:--',
                                                        maxLines: 1,
                                                        textAlign:
                                                            TextAlign.right,
                                                        overflow:
                                                            TextOverflow.visible,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .labelMedium
                                                            ?.copyWith(
                                                              color: cs
                                                                  .onSurfaceVariant
                                                                  .withOpacity(
                                                                    durationText ==
                                                                            null
                                                                        ? 0.45
                                                                        : 0.8,
                                                                  ),
                                                              fontFeatures: const [
                                                                FontFeature.tabularFigures(),
                                                              ],
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _isSelectionMode
                                              ? IconButton.filledTonal(
                                                  icon: Icon(
                                                    isSelected
                                                        ? Icons
                                                            .check_circle_rounded
                                                        : Icons
                                                            .radio_button_unchecked_rounded,
                                                  ),
                                                  tooltip: isSelected
                                                      ? 'Deselect'
                                                      : 'Select',
                                                  onPressed: () {
                                                    HapticFeedback.selectionClick();
                                                    _toggleSelectedSongId(
                                                      song.id,
                                                    );
                                                  },
                                                )
                                              : IconButton.filledTonal(
                                                  icon: AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 220,
                                                    ),
                                                    transitionBuilder:
                                                        (child, animation) {
                                                      return ScaleTransition(
                                                        scale: CurvedAnimation(
                                                          parent: animation,
                                                          curve: Curves
                                                              .easeOutBack,
                                                        ),
                                                        child: FadeTransition(
                                                          opacity: animation,
                                                          child: child,
                                                        ),
                                                      );
                                                    },
                                                    child: Icon(
                                                      icon,
                                                      key: ValueKey(icon),
                                                    ),
                                                  ),
                                                  tooltip: showPause
                                                      ? 'Pause'
                                                      : 'Play',
                                                  onPressed: () async {
                                                    HapticFeedback.selectionClick();
                                                    if (isCurrent) {
                                                      if (playing) {
                                                        await _controller.player.pause();
                                                      } else {
                                                        await _ensureNotificationPermissionIfNeeded();
                                                        await _controller.player.play();
                                                      }
                                                      return;
                                                    }
                                                    _controller.playSong(index);
                                                  },
                                                ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            }, childCount: _songs.length),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
        ),
      ),
    );
  }

  Widget _buildAlbumArtistsTab(BuildContext context) {
    final artists = _cachedAlbumArtists;

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

    return _wrapWithAuroraBackground(
      child: Scrollbar(
        child: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Album Artists'),
            expandedHeight: 112,
            collapsedHeight: 86,
            toolbarHeight: 86,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            forceMaterialTransparency: true,
            foregroundColor: cs.onSurface,
            titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
            ),
            actions: [
              PopupMenuButton<AlbumArtistsSort>(
                icon: const Icon(Icons.sort_rounded),
                tooltip: 'Sort',
                initialValue: _albumArtistsSort,
                onSelected: (mode) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _albumArtistsSort = mode;
                    _recomputeAllData();
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
                '${artists.length} artists • Sort: ${sortLabel(_albumArtistsSort)}',
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
                          _openArtistPageByName(stat.name);
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
        ),
      ),
    );
  }

  Widget _buildAlbumsTab(BuildContext context) {
    final albums = _cachedAlbums;

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

    return _wrapWithAuroraBackground(
      child: Scrollbar(
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: const Text('Albums'),
              expandedHeight: 112,
              collapsedHeight: 86,
              toolbarHeight: 86,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              forceMaterialTransparency: true,
              foregroundColor: cs.onSurface,
              titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
              actions: [
                PopupMenuButton<AlbumsSort>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sort',
                  initialValue: _albumsSort,
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _albumsSort = mode;
                      _recomputeAllData();
                    });
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
                '${albums.length} albums • Sort: ${sortLabel(_albumsSort)}',
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
              child: Center(child: Text('No albums found')),
            )
          else
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
                          _openAlbumPageFromSong(song);
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
                                  id: albumId,
                                  type: ArtworkType.ALBUM,
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
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistsTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final mostPlayedList = _cachedMostPlayed;
    final recentlyPlayedList = _cachedRecentlyPlayed;
    final recentlyAddedList = _cachedRecentlyAdded;

    void open(SmartPlaylistKind kind) {
      final (title, description, icon, list) = switch (kind) {
        SmartPlaylistKind.mostPlayed => (
          'Most played',
          'Your top tracks based on how often you play them',
          Icons.local_fire_department_rounded,
          mostPlayedList,
        ),
        SmartPlaylistKind.recentlyPlayed => (
          'Recently played',
          'Tracks you listened to recently on this device',
          Icons.history_rounded,
          recentlyPlayedList,
        ),
        SmartPlaylistKind.recentlyAdded => (
          'Recently added',
          'Tracks added in the last 30 days',
          Icons.new_releases_rounded,
          recentlyAddedList,
        ),
      };

      _showInlineDetail(
        _SmartPlaylistPage(
          player: _controller.player,
          title: title,
          description: description,
          icon: icon,
          songs: list,
          librarySongs: _songs,
          playlist: _controller.currentPlaylist,
          onQueueChanged: (_) {},
          selectedTabIndex: _selectedTabIndex,
          onNavigateTab: (index) {
            if (!mounted) return;
            if (_isSelectionMode) _exitSelectionMode();
            setState(() => _selectedTabIndex = index);
          },
          embeddedInHome: true,
          onClose: _closeInlineDetail,
          onOpenNowPlaying: (s) {
            if (_nowPlayingRouteActive) {
              Navigator.of(context).pop();
              return;
            }
            _openNowPlaying(s);
          },
          onPlayAll: list.isEmpty
              ? null
              : () async {
                  await _controller.playFromQueue(list, initialIndex: 0);
                },
          onPlaySong: (song) async {
            final idx = list.indexWhere((s) => s.id == song.id);
            if (idx == -1) return;
            await _controller.playFromQueue(list, initialIndex: idx);
          },
        ),
      );
    }

    Widget playlistCard({
      required String title,
      required String subtitle,
      required IconData icon,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
      Widget? trailing,
    }) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: cs.outlineVariant.withOpacity(0.35)),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, color: cs.onSurfaceVariant),
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.08,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    trailing ??
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
    }

    final mostPlayedCount = mostPlayedList.length;
    final recentlyPlayedCount = recentlyPlayedList.length;
    final recentlyAddedCount = recentlyAddedList.length;

    return _wrapWithAuroraBackground(
      child: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Playlists'),
            expandedHeight: 112,
            collapsedHeight: 86,
            toolbarHeight: 86,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            forceMaterialTransparency: true,
            foregroundColor: cs.onSurface,
            titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Text(
              'Smart playlists',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              playlistCard(
                title: 'Most played',
                subtitle: mostPlayedCount == 0
                    ? 'No play history yet — start listening to build this'
                    : '$mostPlayedCount tracks',
                icon: Icons.local_fire_department_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  open(SmartPlaylistKind.mostPlayed);
                },
              ),
              playlistCard(
                title: 'Recently played',
                subtitle: recentlyPlayedCount == 0
                    ? 'Nothing yet'
                    : '$recentlyPlayedCount tracks',
                icon: Icons.history_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  open(SmartPlaylistKind.recentlyPlayed);
                },
              ),
              playlistCard(
                title: 'Recently added',
                subtitle: recentlyAddedCount == 0
                    ? 'No songs added in the last 30 days'
                    : '$recentlyAddedCount tracks',
                icon: Icons.new_releases_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  open(SmartPlaylistKind.recentlyAdded);
                },
              ),
            ],
          ),
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Your playlists',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Create or import',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _showCreateOrImportPlaylistSheet();
                  },
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
        ),
        if (_userPlaylists.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Long-press a song → Select to create a playlist.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          )
        else
          SliverToBoxAdapter(
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: (Widget child, int index, Animation<double> animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (BuildContext context, Widget? child) {
                    final double animValue = Curves.easeOutBack.transform(animation.value);
                    final double scale = lerpDouble(1.0, 1.04, animValue)!;
                    final cs = Theme.of(context).colorScheme;

                    return Transform.scale(
                      scale: scale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withOpacity(0.35 * animValue),
                              blurRadius: 24 * animValue,
                              spreadRadius: 2 * animValue,
                              offset: Offset(0, 8 * animValue),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2 * animValue),
                              blurRadius: 12 * animValue,
                              offset: Offset(0, 4 * animValue),
                            ),
                          ],
                        ),
                        child: Opacity(
                          opacity: lerpDouble(1.0, 0.95, animValue)!,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: child,
                );
              },
              onReorder: _reorderUserPlaylists,
              children: [
                for (var i = 0; i < _userPlaylists.length; i++)
                  KeyedSubtree(
                    key: ValueKey(_userPlaylists[i].id),
                    child: playlistCard(
                      title: _userPlaylists[i].name,
                      subtitle:
                          '${_cachedUserPlaylistTrackCounts[_userPlaylists[i].id] ?? 0} tracks',
                      icon: Icons.playlist_play_rounded,
                      onLongPress: () {
                        HapticFeedback.selectionClick();
                        _showUserPlaylistActionsSheet(_userPlaylists[i]);
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 4,
                              ),
                              child: Icon(
                                Icons.drag_handle_rounded,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _openUserPlaylistPage(_userPlaylists[i]);
                      },
                    ),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height:
                  MediaQuery.of(context).padding.bottom + 160,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openNowPlaying(SongModel song) async {
    if (!mounted) return;
    if (_nowPlayingRouteActive) return;
    final lastClosed = _lastNowPlayingClosedAt;
    if (lastClosed != null &&
        DateTime.now().difference(lastClosed) <
            const Duration(milliseconds: 500)) {
      return;
    }

    _nowPlayingRouteActive = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          barrierLabel: 'Now Playing',
          pageBuilder: (_, __, ___) => NowPlayingPage(
            player: _controller.player,
            song: song,
            songs: _songs,
            playlist: _controller.currentPlaylist,
            onQueueChanged: (_) {},
            onOpenAlbum: _openAlbumPageFromSong,
            onOpenArtist: _openArtistPageFromSong,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final fade = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            );
            final slide = Tween(
              begin: const Offset(0.0, 0.08),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic));
            final scale = Tween<double>(
              begin: 0.985,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOutCubic));
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: animation.drive(slide),
                child: ScaleTransition(
                  scale: animation.drive(scale),
                  child: child,
                ),
              ),
            );
          },
        ),
      );
    } finally {
      _nowPlayingRouteActive = false;
      _lastNowPlayingClosedAt = DateTime.now();
    }
  }

  void _openAlbumPageFromSong(SongModel song) {
    final albumId = song.albumId;
    if (albumId == null || albumId <= 0) return;

    final albumTitle = (song.album ?? '').trim().isEmpty
        ? 'Unknown Album'
        : song.album!.trim();
    final albumArtist =
        (song.getMap["album_artist"]?.toString().trim().isNotEmpty ?? false)
        ? song.getMap["album_artist"].toString().trim()
        : ((song.artist ?? '').trim().isEmpty
              ? 'Unknown Artist'
              : song.artist!.trim());

    final albumSongs = _songs.where((s) => s.albumId == albumId).toList();
    albumSongs.sort((a, b) {
      final t = _compareDiscAndTrack(a, b);
      if (t != 0) return t;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    _showInlineDetail(
      AlbumPage(
        player: _controller.player,
        albumId: albumId,
        albumTitle: albumTitle,
        albumArtist: albumArtist,
        songs: albumSongs,
        librarySongs: _songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: _selectedTabIndex,
        onNavigateTab: (index) {
          if (!mounted) return;
          if (_isSelectionMode) _exitSelectionMode();
          setState(() => _selectedTabIndex = index);
        },
        embeddedInHome: true,
        onClose: _closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (_nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          _openNowPlaying(s);
        },
        onPlaySong: (s) async {
          final albumIndex = albumSongs.indexWhere((x) => x.id == s.id);
          if (albumIndex == -1) return;
          await _controller.playFromQueue(albumSongs, initialIndex: albumIndex);
        },
      ),
    );
  }

  void _openArtistPageFromSong(SongModel song) {
    final name = (song.artist ?? '').trim().isEmpty
        ? 'Unknown Artist'
        : song.artist!.trim();
    _openArtistPageByName(name);
  }

  void _openArtistPageByName(String artistName) {
    final normalizedArtist = artistName.trim();
    if (normalizedArtist.isEmpty) return;

    String norm(String? v) => (v ?? '').trim().toLowerCase();
    final target = norm(normalizedArtist);

    final artistSongs = _songs
        .where((s) {
          final a = norm(s.artist);
          final aa = norm(_albumArtistFor(s));
          return a == target || aa == target;
        })
        .toList(growable: false);

    if (artistSongs.isEmpty) return;

    // Group into albums.
    final Map<int, List<SongModel>> songsByAlbumId = {};
    for (final s in artistSongs) {
      final albumId = s.albumId;
      if (albumId == null || albumId <= 0) continue;
      (songsByAlbumId[albumId] ??= <SongModel>[]).add(s);
    }

    final albums = <ArtistAlbum>[];
    for (final entry in songsByAlbumId.entries) {
      final albumId = entry.key;
      final songs = entry.value;
      songs.sort((a, b) {
        final t = _compareDiscAndTrack(a, b);
        if (t != 0) return t;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

      final title = (songs.first.album ?? '').trim().isEmpty
          ? 'Unknown Album'
          : songs.first.album!.trim();
      int year = 0;
      for (final s in songs) {
        final y = _yearFromSong(s);
        if (y > 0 && (year == 0 || y < year)) year = y;
      }

      int totalMs = 0;
      for (final s in songs) {
        totalMs += (s.duration ?? 0);
      }

      albums.add(
        ArtistAlbum(
          albumId: albumId,
          title: title,
          year: year,
          trackCount: songs.length,
          totalDurationMs: totalMs,
          representativeSong: songs.first,
        ),
      );
    }

    albums.sort((a, b) {
      final ay = a.year == 0 ? 9999 : a.year;
      final by = b.year == 0 ? 9999 : b.year;
      final yc = ay.compareTo(by);
      if (yc != 0) return yc;
      final tc = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (tc != 0) return tc;
      return a.albumId.compareTo(b.albumId);
    });

    final albumSongsById = {
      for (final e in songsByAlbumId.entries)
        e.key: List<SongModel>.unmodifiable(e.value),
    };

    _showInlineDetail(
      ArtistPage(
        player: _controller.player,
        artistName: normalizedArtist,
        albums: albums,
        librarySongs: _songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: _selectedTabIndex,
        onNavigateTab: (index) {
          if (!mounted) return;
          if (_isSelectionMode) _exitSelectionMode();
          setState(() => _selectedTabIndex = index);
        },
        embeddedInHome: true,
        onClose: _closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (_nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          _openNowPlaying(s);
        },
        onOpenAlbum: (s) => _openAlbumPageFromSong(s),
        onPlayAll: albums.isEmpty
            ? null
            : () async {
                final queue = <SongModel>[];
                for (final a in albums) {
                  final list = albumSongsById[a.albumId] ?? const <SongModel>[];
                  final sorted = List<SongModel>.from(list);
                  sorted.sort((x, y) {
                    final t = (x.track ?? 0).compareTo(y.track ?? 0);
                    if (t != 0) return t;
                    return x.title.toLowerCase().compareTo(
                      y.title.toLowerCase(),
                    );
                  });
                  queue.addAll(sorted);
                }
                if (queue.isEmpty) return;
                await _controller.playFromQueue(queue, initialIndex: 0);
              },
      ),
    );
  }
}



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
          SliverAppBar.large(
            title: const SizedBox.shrink(),
            expandedHeight: 96,
            collapsedHeight: 80,
            toolbarHeight: 80,
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
            actions: [
              IconButton(
                tooltip: 'Play',
                onPressed: onPlayAll == null ? null : () => onPlayAll!(),
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
                                color: cs.secondaryContainer.withOpacity(0.52),
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
                leading: ClipOval(
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
                        shape: BoxShape.circle,
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

      final bytes = await OnAudioQuery().queryArtwork(
        albumId,
        ArtworkType.ALBUM,
        size: 320,
      );
      if (bytes == null) return null;

      final result = await computePaletteFromBytes(bytes);
      final primaryColorInt = result['primary'] ?? 0xFF303030;
      final secondaryColorInt = result['secondary'] ?? primaryColorInt;
      final tertiaryColorInt = result['tertiary'] ?? secondaryColorInt;

      final primary = _boostVibrance(
        Color(primaryColorInt),
        extraSaturation: 0.5,
        extraLightness: 0.08,
      );
      final secondary = _boostVibrance(
        Color(secondaryColorInt),
        extraSaturation: 0.42,
        extraLightness: -0.02,
      );
      final tertiary = _boostVibrance(
        Color(tertiaryColorInt),
        extraSaturation: 0.46,
        extraLightness: 0.03,
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
              : cs.primaryContainer;
          final mid = bgB != null
              ? Color.alphaBlend(
                  bgB.withOpacity(isDark ? 0.16 : 0.08),
                  cs.surface,
                )
              : cs.surfaceContainerLow;
          final accent = bgC != null
              ? Color.alphaBlend(
                  bgC.withOpacity(isDark ? 0.14 : 0.07),
                  cs.surface,
                )
              : cs.tertiaryContainer;
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
                  SliverAppBar.large(
                    title: const SizedBox.shrink(),
                    expandedHeight: 96,
                    collapsedHeight: 80,
                    toolbarHeight: 80,
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
                    actions: [
                      IconButton(
                        tooltip: 'Play',
                        onPressed: songs.isEmpty
                            ? null
                            : () => onPlaySong(songs.first),
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipOval(
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
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.album_rounded,
                                  color: cs.onSurfaceVariant,
                                  size: 42,
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
                                  albumTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.4,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  albumArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 6),
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
                                      color: cs.outlineVariant.withOpacity(
                                        0.35,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    subtitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
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

class _SmartPlaylistPage extends StatelessWidget {
  const _SmartPlaylistPage({
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
            expandedHeight: 112,
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

class _UserPlaylistPage extends StatefulWidget {
  const _UserPlaylistPage({
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
  State<_UserPlaylistPage> createState() => _UserPlaylistPageState();
}

class _UserPlaylistPageState extends State<_UserPlaylistPage> {
  late List<int> _songIds;
  late List<int> _manualSongIds;
  _PlaylistSort _playlistSort = _PlaylistSort.manual;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _selectionMode = false;
  final Set<int> _selectedSongIds = <int>{};

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

  String _formatPlaylistDuration(int totalMs) {
    if (totalMs <= 0) return '0m';
    final totalMinutes = (totalMs / 60000).floor();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
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

    if (_playlistSort == _PlaylistSort.manual) {
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

  String _playlistSortLabel(_PlaylistSort mode) {
    switch (mode) {
      case _PlaylistSort.manual:
        return 'Manual';
      case _PlaylistSort.artist:
        return 'Artist';
      case _PlaylistSort.albumArtist:
        return 'Album Artist';
      case _PlaylistSort.year:
        return 'Year';
      case _PlaylistSort.albumArtistYear:
        return 'Album Artist/Year';
    }
  }

  static final RegExp _playlistYearRegex = RegExp(r'(19|20)\d{2}');

  String _normalizeSortText(String v) {
    final t = v.trim();
    if (t.isEmpty) return '';
    final lower = t.toLowerCase();
    if (lower == 'unknown' ||
        lower == 'unknown artist' ||
        lower == 'unknown album') {
      return '';
    }
    return t;
  }

  int _compareSortStrings(String a, String b) {
    final aNorm = _normalizeSortText(a);
    final bNorm = _normalizeSortText(b);
    final aEmpty = aNorm.isEmpty;
    final bEmpty = bNorm.isEmpty;
    if (aEmpty != bEmpty) return aEmpty ? 1 : -1;

    final aLower = aNorm.toLowerCase();
    final bLower = bNorm.toLowerCase();
    final comp = aLower.compareTo(bLower);
    if (comp != 0) return comp;
    return aNorm.compareTo(bNorm);
  }

  int _yearFromSong(SongModel s) {
    final v = s.getMap["year"];
    if (v == null) return 0;
    if (v is int) return v;
    final raw = v.toString();
    final direct = int.tryParse(raw);
    if (direct != null) return direct;
    final match = _playlistYearRegex.firstMatch(raw);
    if (match == null) return 0;
    return int.tryParse(match.group(0)!) ?? 0;
  }

  int _yearForCompare(SongModel s) {
    final y = _yearFromSong(s);
    return y == 0 ? 99999 : y;
  }

  String _albumArtistForSort(SongModel s) {
    final raw = s.getMap["album_artist"]?.toString();
    final fromSong = _normalizeSortText(raw ?? '');
    if (fromSong.isNotEmpty) return fromSong;
    return _normalizeSortText(s.artist ?? '');
  }

  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final aDisc = a.getMap['disc_number'] is int
        ? a.getMap['disc_number'] as int
        : 0;
    final bDisc = b.getMap['disc_number'] is int
        ? b.getMap['disc_number'] as int
        : 0;
    final at = a.track ?? 0;
    final bt = b.track ?? 0;

    var ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
    var bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);

    if (ad == 0) ad = 1;
    if (bd == 0) bd = 1;

    if (ad != bd) return ad.compareTo(bd);

    final an = at >= 1000 ? (at % 1000) : at;
    final bn = bt >= 1000 ? (bt % 1000) : bt;

    final finalAt = an == 0 ? 99999 : an;
    final finalBt = bn == 0 ? 99999 : bn;
    return finalAt.compareTo(finalBt);
  }

  Future<void> _applyPlaylistSort(_PlaylistSort mode) async {
    if (!mounted) return;
    final map = _idToSong();

    if (mode == _PlaylistSort.manual) {
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
    final sorted = List<SongModel>.from(visible);
    sorted.sort((a, b) {
      switch (mode) {
        case _PlaylistSort.artist:
          final artistComp = _compareSortStrings(
            a.artist ?? "",
            b.artist ?? "",
          );
          if (artistComp != 0) return artistComp;
          final titleComp = _compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case _PlaylistSort.albumArtist:
          final artistComp = _compareSortStrings(
            _albumArtistForSort(a),
            _albumArtistForSort(b),
          );
          if (artistComp != 0) return artistComp;
          final albumComp = _compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = _compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = _compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case _PlaylistSort.year:
          final yearComp = _yearForCompare(a).compareTo(_yearForCompare(b));
          if (yearComp != 0) return yearComp;
          final artistComp = _compareSortStrings(
            _albumArtistForSort(a),
            _albumArtistForSort(b),
          );
          if (artistComp != 0) return artistComp;
          final albumComp = _compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = _compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = _compareSortStrings(a.title, b.title);
          if (titleComp != 0) return titleComp;
          return a.id.compareTo(b.id);
        case _PlaylistSort.albumArtistYear:
        default:
          final artistComp = _compareSortStrings(
            _albumArtistForSort(a),
            _albumArtistForSort(b),
          );
          if (artistComp != 0) return artistComp;
          final yearComp = _yearForCompare(a).compareTo(_yearForCompare(b));
          if (yearComp != 0) return yearComp;
          final albumComp = _compareSortStrings(a.album ?? "", b.album ?? "");
          if (albumComp != 0) return albumComp;
          final trackComp = _compareDiscAndTrack(a, b);
          if (trackComp != 0) return trackComp;
          final titleComp = _compareSortStrings(a.title, b.title);
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
      _playlistSort = _PlaylistSort.manual;
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
    if (_playlistSort == _PlaylistSort.manual) {
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
        '${allSongs.length} tracks • ${_formatPlaylistDuration(totalMs)}';
    final canReorder =
        _playlistSort == _PlaylistSort.manual &&
        query.isEmpty &&
        !_selectionMode;

    final content = CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: _selectionMode
                ? Text('${_selectedSongIds.length} selected')
                : Text(
                    widget.playlistName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            expandedHeight: 112,
            collapsedHeight: 86,
            toolbarHeight: 86,
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
                : null,
            titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
            ),
            actions: [
              if (_selectionMode) ...[
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
                  tooltip: 'Add songs',
                  onPressed: _addSongs,
                  icon: const Icon(Icons.add_rounded),
                ),
                IconButton(
                  tooltip: 'Shuffle play',
                  onPressed: allSongs.isEmpty
                      ? null
                      : () async => _playShuffledQueue(allSongs),
                  icon: const Icon(Icons.shuffle_rounded),
                ),
                PopupMenuButton<_PlaylistSort>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sort',
                  initialValue: _playlistSort,
                  onSelected: (mode) {
                    HapticFeedback.selectionClick();
                    _applyPlaylistSort(mode);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _PlaylistSort.manual,
                      child: Text('Manual (drag order)'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: _PlaylistSort.artist,
                      child: Text('Sort by Artist'),
                    ),
                    PopupMenuItem(
                      value: _PlaylistSort.albumArtist,
                      child: Text('Sort by Album Artist'),
                    ),
                    PopupMenuItem(
                      value: _PlaylistSort.year,
                      child: Text('Sort by Year'),
                    ),
                    PopupMenuItem(
                      value: _PlaylistSort.albumArtistYear,
                      child: Text('Sort by Album Artist/Year'),
                    ),
                  ],
                ),
                PopupMenuButton<_PlaylistShareAction>(
                  icon: const Icon(Icons.share_rounded),
                  tooltip: 'Share',
                  onSelected: (action) {
                    HapticFeedback.selectionClick();
                    switch (action) {
                      case _PlaylistShareAction.copyList:
                        _copyPlaylistText(allSongs);
                        break;
                      case _PlaylistShareAction.copyM3u:
                        _copyPlaylistM3u(allSongs);
                        break;
                      case _PlaylistShareAction.exportM3u:
                        _exportPlaylistM3u(allSongs);
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _PlaylistShareAction.copyList,
                      child: Text('Copy track list'),
                    ),
                    PopupMenuItem(
                      value: _PlaylistShareAction.copyM3u,
                      child: Text('Copy M3U'),
                    ),
                    PopupMenuItem(
                      value: _PlaylistShareAction.exportM3u,
                      child: Text('Export M3U file'),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Play',
                  onPressed: songs.isEmpty
                      ? null
                      : () async => widget.playFromQueue(songs, 0),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ],
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
                      ClipOval(
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: allSongs.isEmpty
                              ? Container(
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.playlist_play_rounded,
                                    color: cs.onSurfaceVariant,
                                    size: 30,
                                  ),
                                )
                                : FastArtworkWidget(
                                    id: allSongs.first.id,
                                    type: ArtworkType.AUDIO,
                                    width: 64,
                                    height: 64,
                                    nullArtworkWidget: Container(
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.playlist_play_rounded,
                                        color: cs.onSurfaceVariant,
                                        size: 30,
                                      ),
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
                              widget.playlistName,
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
                              _playlistSort == _PlaylistSort.manual
                                  ? 'Drag songs to rearrange'
                                  : 'Sort: ${_playlistSortLabel(_playlistSort)}',
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
            SliverReorderableList(
              proxyDecorator: (Widget child, int index, Animation<double> animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (BuildContext context, Widget? child) {
                    final double animValue = Curves.easeOutBack.transform(animation.value);
                    final double scale = lerpDouble(1.0, 1.04, animValue)!;
                    final cs = Theme.of(context).colorScheme;

                    return Transform.scale(
                      scale: scale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withOpacity(0.35 * animValue),
                              blurRadius: 24 * animValue,
                              spreadRadius: 2 * animValue,
                              offset: Offset(0, 8 * animValue),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2 * animValue),
                              blurRadius: 12 * animValue,
                              offset: Offset(0, 4 * animValue),
                            ),
                          ],
                        ),
                        child: Opacity(
                          opacity: lerpDouble(1.0, 0.95, animValue)!,
                          child: child,
                        ),
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
                final albumText = (song.album ?? '').trim().isEmpty
                    ? 'Unknown Album'
                    : song.album!.trim();
                final isSelected = _selectedSongIds.contains(song.id);
                final canDismiss = !_selectionMode;
                final tileColor = isSelected
                    ? cs.secondaryContainer.withOpacity(isDark ? 0.22 : 0.55)
                    : cs.surfaceContainerLow;

                final tile = Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: tileColor,
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
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              if (canReorder)
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              else if (_selectionMode)
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (_) => _toggleSelection(song.id),
                                )
                              else
                                const SizedBox(width: 8),
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
                              if (!_selectionMode)
                                IconButton.filledTonal(
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  tooltip: 'Play',
                                  onPressed: () {
                                    HapticFeedback.selectionClick();
                                    widget.playFromQueue(songs, index);
                                  },
                                ),
                            ],
                          ),
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
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
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



class _LibraryPermissionGate extends StatelessWidget {
  final _LibraryPermissionState state;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  const _LibraryPermissionGate({
    required this.state,
    required this.onGrant,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = switch (state) {
      _LibraryPermissionState.permanentlyDenied => 'Music access blocked',
      _LibraryPermissionState.denied => 'Allow access to your music',
      _LibraryPermissionState.unknown => 'Preparing your library',
      _LibraryPermissionState.granted => 'Ready',
    };

    final body = switch (state) {
      _LibraryPermissionState.permanentlyDenied =>
        'Permission was denied permanently. Open Settings and enable Music/Audio access to scan your library.',
      _LibraryPermissionState.denied =>
        'To show your on-device songs, the app needs permission to read your audio library. Nothing is uploaded.',
      _LibraryPermissionState.unknown =>
        'We’ll ask for access only when you’re ready.',
      _LibraryPermissionState.granted => '',
    };

    final primaryLabel = state == _LibraryPermissionState.permanentlyDenied
        ? 'Open Settings'
        : 'Grant access';
    final primaryAction = state == _LibraryPermissionState.permanentlyDenied
        ? onOpenSettings
        : onGrant;

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withOpacity(
                      Theme.of(context).brightness == Brightness.dark
                          ? 0.25
                          : 0.6,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(0.35),
                    ),
                  ),
                  child: Icon(
                    Icons.library_music_rounded,
                    size: 42,
                    color: cs.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                if (state == _LibraryPermissionState.unknown) ...[
                  const CircularProgressIndicator(),
                ] else ...[
                  FilledButton.icon(
                    onPressed: primaryAction,
                    icon: Icon(
                      state == _LibraryPermissionState.permanentlyDenied
                          ? Icons.settings_rounded
                          : Icons.lock_open_rounded,
                    ),
                    label: Text(primaryLabel),
                  ),
                  if (state != _LibraryPermissionState.permanentlyDenied) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: onOpenSettings,
                      child: const Text('Settings'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback? onTap;
  const _AboutPill({required this.text, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withOpacity(
          Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.55,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white12
              : Colors.black12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: cs.onSecondaryContainer.withOpacity(0.85),
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSecondaryContainer.withOpacity(0.92),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return pill;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bg;

  static const List<String> _taglines = [
    'You found the About page. Nice.',
    'Yes, these lines are here on purpose.',
    'Tap the note. I promise it’s not a trap.',
    'This app is listening… to your taps.',
    'Fourth wall? Consider it gently removed.',
    'Built with love, caffeine, and suspiciously many gradients.',
    'If something breaks, it’s not a bug. It’s a feature audition.',
  ];

  int _taglineIndex = 0;

  int _vibeIndex = 0;
  static const List<
    ({String name, Duration duration, double intensity, double midOpacity})
  >
  _vibes = [
    (
      name: 'Chill',
      duration: Duration(seconds: 14),
      intensity: 0.9,
      midOpacity: 0.10,
    ),
    (
      name: 'Vibe',
      duration: Duration(seconds: 10),
      intensity: 1.0,
      midOpacity: 0.12,
    ),
    (
      name: 'Chaos',
      duration: Duration(seconds: 7),
      intensity: 1.25,
      midOpacity: 0.16,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _bg = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _bg.dispose();
    super.dispose();
  }

  void _shuffleTagline() {
    HapticFeedback.selectionClick();
    setState(() => _taglineIndex = (_taglineIndex + 1) % _taglines.length);
  }

  void _cycleVibe() {
    HapticFeedback.mediumImpact();
    setState(() => _vibeIndex = (_vibeIndex + 1) % _vibes.length);

    final v = _vibes[_vibeIndex];
    final pos = _bg.value;
    _bg
      ..stop()
      ..duration = v.duration
      ..value = pos
      ..repeat();

    _capsuleTap(
      title: 'About page vibe: ${v.name}',
      description: v.name == 'Chill'
          ? 'Slow gradients, gentle bubbles. Good for pretending you have your life together.'
          : v.name == 'Vibe'
          ? 'The default. Smooth motion, just enough drama.'
          : 'Faster motion, louder colors. For demo day energy.',
    );
  }

  void _capsuleTap({required String title, required String description}) {
    HapticFeedback.lightImpact();
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2200),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: cs.onInverseSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onInverseSurface.withOpacity(0.92),
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _copyCredits() async {
    await Clipboard.setData(
      const ClipboardData(
        text:
            'Made by Muhammad Aliyan\nTester: Affan Iqbal\nSpecial thanks: you (For using ;))',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Credits copied. Yes, I watched you do it.'),
        duration: Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white70 : Colors.black54;

    final vibe = _vibes[_vibeIndex];

    return Scaffold(
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: _bg,
            builder: (context, _) {
              final t = _bg.value;
              final a1 =
                  Alignment.lerp(
                    Alignment.topLeft,
                    Alignment.topRight,
                    (math.sin(t * math.pi * 2) + 1) / 2,
                  ) ??
                  Alignment.topLeft;
              final a2 =
                  Alignment.lerp(
                    Alignment.bottomRight,
                    Alignment.bottomLeft,
                    (math.cos(t * math.pi * 2) + 1) / 2,
                  ) ??
                  Alignment.bottomRight;
              final top = isDark
                  ? const Color(0xFF121016)
                  : const Color(0xFFF7F3FF);
              final mid = cs.primary.withOpacity(
                isDark ? 0.26 : vibe.midOpacity,
              );
              final bottom = isDark
                  ? const Color(0xFF0B0A0E)
                  : const Color(0xFFFFFFFF);
              return Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: a1,
                    end: a2,
                    colors: [top, mid, bottom],
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: -40,
            left: -30,
            child: _Bubble(
              color: cs.primary.withOpacity(isDark ? 0.18 : 0.12),
              size: 180,
              animation: _bg,
              phase: 0.15,
              intensity: vibe.intensity,
            ),
          ),
          Positioned(
            bottom: -50,
            right: -40,
            child: _Bubble(
              color: cs.secondary.withOpacity(isDark ? 0.18 : 0.10),
              size: 220,
              animation: _bg,
              phase: 0.55,
              intensity: vibe.intensity,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.arrow_back_rounded, color: subColor),
                      ),
                          Expanded(
                        child: Text(
                          'About',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Licenses',
                        onPressed: () {
                          showLicensePage(
                            context: context,
                            applicationName: 'Expressive Music',
                          );
                        },
                        icon: Icon(Icons.description_rounded, color: subColor),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Material(
                              color: cs.primaryContainer.withOpacity(
                                isDark ? 0.25 : 0.80,
                              ),
                              borderRadius: BorderRadius.circular(22),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(22),
                                onTap: _shuffleTagline,
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    color: cs.onPrimaryContainer,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Expressive Music',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _taglines[_taglineIndex],
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: subColor),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Tip: tap the music note to change this line. You’re literally doing UI testing right now.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: subColor.withOpacity(0.9),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FrostedCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Credits',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: textColor,
                                    ),
                              ),
                              const SizedBox(height: 10),
                              RichText(
                                text: TextSpan(
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(color: textColor),
                                  children: [
                                    TextSpan(
                                      text: 'Made by: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'Muhammad Aliyan',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                    const TextSpan(text: '\n'),
                                    TextSpan(
                                      text: 'Tester: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'Affan Iqbal',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                    const TextSpan(text: '\n'),
                                    TextSpan(
                                      text: 'Special thanks: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'You ( For using ;) )',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _AboutPill(
                                    text: 'Vibe: ${vibe.name}',
                                    icon: Icons.graphic_eq_rounded,
                                    onTap: _cycleVibe,
                                  ),
                                  _AboutPill(
                                    text: 'Drag & reorder queue',
                                    icon: Icons.drag_handle_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Queue reordering',
                                      description:
                                          'Long-press and drag songs to change the play order. The queue updates live, so your next track is always what you see.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Synced lyrics editor',
                                    icon: Icons.lyrics_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Synced lyrics',
                                      description:
                                          'Lyrics can follow the song in real-time. Toggle lyrics on Now Playing and the view jumps to the current line automatically.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Edit tags & cover',
                                    icon: Icons.edit_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Tag editing',
                                      description:
                                          'Update metadata like title/artist and embed cover art into the file. It’s basically a tiny music “makeover” studio.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Palette vibes',
                                    icon: Icons.auto_awesome_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Dynamic colors',
                                      description:
                                          'The UI picks colors from the current artwork to paint the background. It’s cached and throttled to keep it smooth and battery-friendly.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Swipe, tap, repeat',
                                    icon: Icons.swipe_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Gestures',
                                      description:
                                          'Swipe down to dismiss Now Playing, tap controls for play/pause/skip, and use the mini player for quick navigation.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Plays in background',
                                    icon: Icons.notifications_active_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Background playback',
                                      description:
                                          'Keep listening while you do other things. Playback stays controllable via system media controls and notifications.',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _copyCredits,
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Copy credits'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: _shuffleTagline,
                                      icon: const Icon(
                                        Icons.casino_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Shuffle'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        FrostedCard(
                          child: Row(
                            children: [
                              Icon(
                                Icons.waving_hand_rounded,
                                color: cs.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Thanks for trying the app. If you’re reading this, the About page is doing its job.',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: subColor),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



class _Bubble extends StatelessWidget {
  final Color color;
  final double size;
  final Animation<double> animation;
  final double phase;
  final double intensity;
  const _Bubble({
    required this.color,
    required this.size,
    required this.animation,
    required this.phase,
    this.intensity = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = (animation.value + phase) % 1.0;
        final y = math.sin(t * math.pi * 2) * 10 * intensity;
        final x = math.cos(t * math.pi * 2) * 8 * intensity;
        return Transform.translate(
          offset: Offset(x, y),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [color, Colors.transparent],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}



class _SquigglySeekBarState extends State<SquigglySeekBar>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late AnimationController _seekBackController;
  double? _dragProgress;
  double _smoothProgress = 0.0;
  double _seekBackFrom = 0.0;
  double _seekBackTo = 0.0;

  static const Duration _animateBackMinDelta = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      // Full cycle = 2 seconds, so crest to trough = 1 second
      duration: const Duration(seconds: 2),
    );
    _seekBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _seekBackController.addListener(() {
      if (!mounted) return;
      if (_dragProgress != null) return;
      final t = Curves.easeOutCubic.transform(_seekBackController.value);
      final v = lerpDouble(_seekBackFrom, _seekBackTo, t) ?? _seekBackTo;
      setState(() => _smoothProgress = v);
    });
    if (widget.isPlaying) _animController.repeat();

    final denom = widget.duration.inMilliseconds == 0
        ? 1
        : widget.duration.inMilliseconds;
    _smoothProgress = (widget.position.inMilliseconds / denom).clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant SquigglySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_animController.isAnimating) {
      _animController.repeat();
    } else if (!widget.isPlaying && _animController.isAnimating) {
      _animController.stop();
    }

    if (_dragProgress != null) return;

    final denom = widget.duration.inMilliseconds == 0
        ? 1
        : widget.duration.inMilliseconds;
    final newActual = (widget.position.inMilliseconds / denom).clamp(0.0, 1.0);

    final isBackwards = widget.position < oldWidget.position;
    final backDelta = oldWidget.position - widget.position;
    final shouldAnimateBack = isBackwards && backDelta >= _animateBackMinDelta;

    if (!shouldAnimateBack) {
      _seekBackController.stop();
      _smoothProgress = newActual;
      return;
    }

    _seekBackController.stop();
    _seekBackFrom = _smoothProgress;
    _seekBackTo = newActual;
    _seekBackController.forward(from: 0.0);
  }

  @override
  void dispose() {
    _animController.dispose();
    _seekBackController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _dragProgress ?? _smoothProgress;
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            _seekBackController.stop();
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            final newProgress = (localPos.dx / box.size.width).clamp(0.0, 1.0);
            setState(() => _dragProgress = newProgress);
          },
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            final newProgress = (localPos.dx / box.size.width).clamp(0.0, 1.0);
            setState(() => _dragProgress = newProgress);
          },
          onHorizontalDragEnd: (details) {
            if (_dragProgress != null) {
              widget.onChanged(
                Duration(
                  milliseconds:
                      (_dragProgress! * widget.duration.inMilliseconds).toInt(),
                ),
              );
            }
            setState(() => _dragProgress = null);
          },
          onHorizontalDragCancel: () {
            setState(() => _dragProgress = null);
          },
          onTapDown: (details) {
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            widget.onChanged(
              Duration(
                milliseconds:
                    ((localPos.dx / box.size.width).clamp(0.0, 1.0) *
                            widget.duration.inMilliseconds)
                        .toInt(),
              ),
            );
          },
          child: SizedBox(
            height: 48,
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                final color = widget.isDark ? Colors.white : Colors.black87;
                final baseColor = widget.isDark
                    ? Colors.white24
                    : Colors.black12;
                return CustomPaint(
                  painter: SquigglePainter(
                    progress: progress,
                    phase: _animController.value * 2 * math.pi,
                    color: color,
                    baseColor: baseColor,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}



class NowPlayingPage extends StatefulWidget {
  final AudioPlayer player;
  final SongModel song;
  final List<SongModel> songs;
  final ConcatenatingAudioSource? playlist;
  final Function(List<SongModel>)? onQueueChanged;
  final void Function(SongModel song) onOpenAlbum;
  final void Function(SongModel song) onOpenArtist;
  const NowPlayingPage({
    super.key,
    required this.player,
    required this.song,
    required this.songs,
    this.playlist,
    this.onQueueChanged,
    required this.onOpenAlbum,
    required this.onOpenArtist,
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
  StreamSubscription<PlayerState>? _nowPlayingPlayerStateSub;
  StreamSubscription<Duration>? _positionSub;

  bool _disableMotion = false;
  bool _fullscreenLandscape = false;
  bool _fullscreenControlsVisible = false;

  @override
  void initState() {
    super.initState();
    _displayedSong = widget.song;
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
      if (sequence == null || index >= sequence.length) return;

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
    String? lyrics = await LyricsHelper.getEmbeddedLyrics(_displayedSong.data);
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
        final primary = _boostVibrance(
          Color(primaryColorInt),
          extraSaturation: 0.5,
          extraLightness: 0.08,
        );
        final secondary = _boostVibrance(
          Color(secondaryColorInt),
          extraSaturation: 0.42,
          extraLightness: -0.02,
        );
        final tertiary = _boostVibrance(
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
        Theme.of(context).colorScheme.primary.withOpacity(isDark ? 0.10 : 0.06),
        Theme.of(context).colorScheme.surface.withOpacity(isDark ? 0.14 : 0.10),
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
                                          .withOpacity(0.5),
                                      blurRadius: 40,
                                      spreadRadius: 10,
                                      offset: const Offset(0, 15),
                                    ),
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.3),
                                      blurRadius: 20,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: Hero(
                                  tag: 'mini_artwork_${_displayedSong.id}',
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(28),
                                    child: _buildNowPlayingArtwork(side: side),
                                  ),
                                ),
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
                                                      .withOpacity(
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
                                                                    .withOpacity(
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
                                                                    .withOpacity(
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
                                                                    .withOpacity(
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
                              color: textColor.withOpacity(0.82),
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
        // Darker colors for dark mode
        return hsl
            .withLightness((hsl.lightness * 0.7).clamp(0.1, 0.4))
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
        : Colors.black.withOpacity(0.08);
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
                        // Same animation style as AboutPage, but vertical motion.
                        final t = _bgGradientController.value;
                        final begin =
                            Alignment.lerp(
                              Alignment.topLeft,
                              Alignment.bottomLeft,
                              (math.sin(t * math.pi * 2) + 1) / 2,
                            ) ??
                            Alignment.topLeft;
                        final end =
                            Alignment.lerp(
                              Alignment.bottomRight,
                              Alignment.topRight,
                              (math.cos(t * math.pi * 2) + 1) / 2,
                            ) ??
                            Alignment.bottomRight;

                        final bgGradient = LinearGradient(
                          begin: begin,
                          end: end,
                          colors: [c1, c2, c3, bottomColor],
                          stops: const [0.0, 0.34, 0.68, 1.0],
                        );

                        final enableBlur = appIsForeground.value && !_disableMotion;
                        // Reduce blur while the gradient animation is running to avoid heavy ImageFilter costs.
                        final double blurSigma = enableBlur
                            ? (_bgGradientController.isAnimating ? 2.0 : 8.0)
                            : 0.0;

                        final gradientLayer = blurSigma > 0.5
                            ? ImageFiltered(
                                imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(gradient: bgGradient),
                                ),
                              )
                            : DecoratedBox(
                                decoration: BoxDecoration(gradient: bgGradient),
                              );

                        final vignette = DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment.topCenter,
                              radius: 1.1,
                              colors: [
                                Colors.transparent,
                                (isDark ? Colors.black : Colors.white).withOpacity(
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
                                    runWithPlaybackSuspended: (action) =>
                                        runWithPlayerPlaybackSuspended(
                                          widget.player,
                                          widget.playlist,
                                          action,
                                        ),
                                  ),
                                );
                                if (result == true) {
                                  // Refresh will happen on next app restart or library reload
                                }
                              } else if (value == 'edit_lyrics') {
                                final result = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => LyricsEditorDialog(
                                    song: _displayedSong,
                                    currentLyrics: _rawLyrics,
                                    onSaved: () => _loadLyrics(),
                                    runWithPlaybackSuspended: (action) =>
                                        runWithPlayerPlaybackSuspended(
                                          widget.player,
                                          widget.playlist,
                                          action,
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
                                            color: textColor.withOpacity(0.8),
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
                      color: (_primaryColor ?? Colors.black).withOpacity(0.5),
                      blurRadius: 40,
                      spreadRadius: 10,
                      offset: const Offset(0, 15),
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Hero(
                  tag: 'mini_artwork_${_displayedSong.id}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: _buildNowPlayingArtwork(side: side),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLyricsView() {
    if (_rawLyrics == null)
      return Container(
        alignment: Alignment.center,
        child: const Text(
          "No Lyrics Found",
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
      );

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

enum _LyricTileMode { normal, near, active }

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
    if ((widget.index - active).abs() <= _nearWindow)
      return _LyricTileMode.near;
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
              color: Colors.white.withOpacity(0.28),
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
