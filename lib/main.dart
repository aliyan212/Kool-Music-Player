import 'pages/about_page.dart';
import 'pages/now_playing_page.dart';
import 'pages/playlist_page.dart';
import 'pages/album_page.dart';
import 'pages/artist_page.dart';
import 'data/models/album_stat.dart';
import 'data/models/sort_mode.dart';
import 'data/models/isolate_data.dart';
import 'data/models/user_playlist.dart';
import 'dart:async';
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
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:audiotags/audiotags.dart';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'core/theme/app_theme.dart';
import 'widgets/song_options_sheet.dart';import 'app_audio_handler.dart';
import 'android_notifications.dart';
import 'platform_exit.dart';
import 'services/app_local_store.dart';
import 'services/playback_controller.dart';
import 'services/local_audio_scanner.dart';
import 'utils/palette_compute.dart';
import "dialogs/folder_management_dialog.dart";
import "utils/song_sort_utils.dart";
import "utils/format_utils.dart";
import 'ui/shared/fast_artwork_widget.dart';
import 'ui/shared/squiggly_seek_bar.dart';

import 'dialogs/playlist_dialogs.dart';
import 'utils/tag_write_access.dart';
import 'widgets/mini_player.dart';

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
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        final setLocale = DynamicLibrary.process().lookupFunction<
            Int8 Function(Int32, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)>('setlocale');
        final localeC = "C".toNativeUtf8();
        setLocale(1, localeC);
        malloc.free(localeC);
      } catch (e) {
        debugPrint('Failed to set locale: $e');
      }
    }
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: true,
      macOS: true,
    );
  }
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
  final mediaDisplayName = normalizeMetadataText(fixed['_display_name']);
  final mediaDisplayNameWoExt = normalizeMetadataText(
    fixed['_display_name_wo_ext'],
  );

  final titleValue = normalizeMetadataText(fixed['title']);
  if (titleValue.isEmpty) {
    final richTitle = normalizeMetadataText(title);
    final fallbackTitle =
        mediaDisplayNameWoExt.isNotEmpty
            ? mediaDisplayNameWoExt
            : mediaDisplayName.isNotEmpty
            ? mediaDisplayName
            : filename;
    fixed['title'] = richTitle.isNotEmpty ? richTitle : fallbackTitle;
  }

  final artistValue = normalizeMetadataText(fixed['artist']);
  if (artistValue.isEmpty) {
    final richArtist = normalizeMetadataText(artist);
    fixed['artist'] = richArtist.isNotEmpty ? richArtist : 'Unknown Artist';
  }

  final albumValue = normalizeMetadataText(fixed['album']);
  if (albumValue.isEmpty) {
    final richAlbum = normalizeMetadataText(album);
    fixed['album'] = richAlbum.isNotEmpty ? richAlbum : 'Unknown Album';
  }

  final albumArtistValue = normalizeMetadataText(fixed['album_artist']);
  if (albumArtistValue.isEmpty) {
    final richAlbumArtist = normalizeMetadataText(albumArtist);
    if (richAlbumArtist.isNotEmpty) {
      fixed['album_artist'] = richAlbumArtist;
    } else {
      final fallbackArtist = normalizeMetadataText(fixed['artist']);
      fixed['album_artist'] = fallbackArtist.isNotEmpty
          ? fallbackArtist
          : 'Unknown Artist';
    }
  }

  final rawYear = fixed['year'];
  if (rawYear == null ||
      (rawYear is int && rawYear <= 0) ||
      (rawYear is String && normalizeMetadataText(rawYear).isEmpty)) {
    if (year != null && year > 0) {
      fixed['year'] = year;
    }
  }

  final rawTrack = fixed['track'];
  if (rawTrack == null ||
      (rawTrack is int && rawTrack <= 0) ||
      (rawTrack is String && normalizeMetadataText(rawTrack).isEmpty)) {
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
    final rawData = map['_data'] ?? map['data'] ?? '';
    final filePath = rawData.toString().trim();

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
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Column(
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
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: isDark ? 0.82 : 0.90),
              border: Border(
                top: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 6),
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
      ),
    ],
  );
}

/// Reserves scrollable space at the bottom of list pages so the last item can
/// be scrolled fully above the mini-player and the navigation bar, which are
/// overlaid on top of the body via `extendBody: true`.
///
/// The gutter grows when a song is loaded (mini-player visible) so the last
/// row is never hidden behind the player.
Widget buildBottomBarsGutter(
  BuildContext context, {
  bool includeMiniPlayer = true,
}) {
  // 72px themed NavigationBar + breathing room and bottom insets.
  const double navBarReserve = 80;
  // 80px mini-player + 6px bottom margin.
  const double miniPlayerReserve = 86;
  final double bottomInset = MediaQuery.of(context).padding.bottom;
  return SliverToBoxAdapter(
    child: ValueListenableBuilder<int?>(
      valueListenable: playbackController.currentSongIdNotifier,
      builder: (context, songId, _) {
        final double gutter = bottomInset +
            navBarReserve +
            (includeMiniPlayer && songId != null ? miniPlayerReserve : 0);
        return SizedBox(height: gutter);
      },
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
          color: cs.surface.withValues(alpha: op),
          border: Border(
            bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.04)),
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

  final ValueNotifier<bool> _showSearchInAppBar = ValueNotifier<bool>(false);

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

  static final RegExp _yearRegex = RegExp(r'\b(19\d{2}|20\d{2})\b');

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
    final representativeByAlbumKey = <String, SongModel>{};
    final trackCountByAlbumKey = <String, int>{};
    final minYearByAlbumKey = <String, int>{};

    for (final s in songs) {
      final artistName = _displayArtistName(albumArtistFor(s));
      final artistKey = artistName.toLowerCase();
      final artistStat = artistStatByKey.putIfAbsent(
        artistKey,
        () => AlbumArtistStat(name: artistName),
      );
      artistStat.trackCount++;

      final albumKey = albumIdentityKey(s);
      artistStat.albumIds.add(albumKey.hashCode);

      final existingRep = representativeByAlbumKey[albumKey];
      if (existingRep == null ||
          ((existingRep.albumId ?? 0) <= 0 && (s.albumId ?? 0) > 0)) {
        representativeByAlbumKey[albumKey] = s;
      }
      trackCountByAlbumKey.update(albumKey, (v) => v + 1, ifAbsent: () => 1);
      final y = yearFromSong(s);
      if (y > 0) {
        final existing = minYearByAlbumKey[albumKey];
        if (existing == null || y < existing) minYearByAlbumKey[albumKey] = y;
      }
    }

    final artists = artistStatByKey.values.toList(growable: false)
      ..sort((a, b) {
        int comp;
        switch (_albumArtistsSort) {
          case AlbumArtistsSort.nameAsc:
            comp = compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.nameDesc:
            comp = compareSortStrings(b.name, a.name);
            break;
          case AlbumArtistsSort.mostAlbums:
            comp = b.albumCount.compareTo(a.albumCount);
            if (comp != 0) break;
            comp = b.trackCount.compareTo(a.trackCount);
            if (comp != 0) break;
            comp = compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.leastAlbums:
            comp = a.albumCount.compareTo(b.albumCount);
            if (comp != 0) break;
            comp = a.trackCount.compareTo(b.trackCount);
            if (comp != 0) break;
            comp = compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.mostTracks:
            comp = b.trackCount.compareTo(a.trackCount);
            if (comp != 0) break;
            comp = b.albumCount.compareTo(a.albumCount);
            if (comp != 0) break;
            comp = compareSortStrings(a.name, b.name);
            break;
          case AlbumArtistsSort.leastTracks:
            comp = a.trackCount.compareTo(b.trackCount);
            if (comp != 0) break;
            comp = a.albumCount.compareTo(b.albumCount);
            if (comp != 0) break;
            comp = compareSortStrings(a.name, b.name);
            break;
        }
        if (comp != 0) return comp;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final albums =
        representativeByAlbumKey.keys
            .map((albumKey) {
              final song = representativeByAlbumKey[albumKey]!;
              final album = _controller.albumMap[song.albumId];
              final title = _displayAlbumTitle(song.album ?? album?.album);
              final artist = _displayArtistName(
                albumArtistFor(song),
              );
              final albumId = (song.albumId != null && song.albumId! > 0)
                  ? song.albumId!
                  : song.id;
              return AlbumTabStat(
                albumId: albumId,
                representativeSong: song,
                title: title,
                artist: artist,
                trackCount: trackCountByAlbumKey[albumKey] ?? 0,
                year: minYearByAlbumKey[albumKey] ?? 0,
              );
            })
            .toList(growable: false)
          ..sort((a, b) {
            int comp;
            switch (_albumsSort) {
              case AlbumsSort.titleAsc:
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.titleDesc:
                comp = compareSortStrings(b.title, a.title);
                break;
              case AlbumsSort.artistAsc:
                comp = compareSortStrings(a.artist, b.artist);
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.artistDesc:
                comp = compareSortStrings(b.artist, a.artist);
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.yearAsc:
                comp = _yearValueForCompare(
                  a.year,
                ).compareTo(_yearValueForCompare(b.year));
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.yearDesc:
                comp = _yearValueForCompare(
                  b.year,
                ).compareTo(_yearValueForCompare(a.year));
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.albumArtistYear:
                comp = compareSortStrings(a.artist, b.artist);
                if (comp != 0) break;
                comp = _yearValueForCompare(
                  a.year,
                ).compareTo(_yearValueForCompare(b.year));
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.mostTracks:
                comp = b.trackCount.compareTo(a.trackCount);
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
              case AlbumsSort.leastTracks:
                comp = a.trackCount.compareTo(b.trackCount);
                if (comp != 0) break;
                comp = compareSortStrings(a.title, b.title);
                break;
            }
            if (comp != 0) return comp;
            comp = compareSortStrings(a.artist, b.artist);
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
            final t = compareSortStrings(a.title, b.title);
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
              onQueueChanged: (_) {},
              onTap: (song) => _openNowPlaying(song),
            ),
          ),
          Builder(builder: (ctx) {
            final cs = Theme.of(ctx).colorScheme;
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: isDark ? 0.82 : 0.90),
                    border: Border(
                      top: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.18),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: 6),
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
              ),
            );
          }),
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

  Future<UserPlaylist?> _createNewPlaylist(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = UserPlaylist(
      id: _newPlaylistId(),
      name: name,
      songIds: const <int>[],
      createdAtMs: now,
      updatedAtMs: now,
    );
    setState(() {
      _userPlaylists.insert(0, playlist);
      _cachedUserPlaylistTrackCounts[playlist.id] = 0;
    });
    await _saveUserPlaylists();
    return playlist;
  }

  Future<void> _renamePlaylist(UserPlaylist playlist, String newName) async {
    final idx = _userPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx == -1) return;
    setState(() {
      _userPlaylists[idx] = playlist.copyWith(
        name: newName,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    await _saveUserPlaylists();
  }

  Future<void> _deletePlaylist(UserPlaylist playlist) async {
    setState(() {
      _userPlaylists.removeWhere((p) => p.id == playlist.id);
      _cachedUserPlaylistTrackCounts.remove(playlist.id);
    });
    await _saveUserPlaylists();
  }

  String _normalizeFolderPath(String path) {
    return path.trim().replaceAll(RegExp(r'/+$'), '');
  }

  int _compareStrings(String a, String b) {
    return a.compareTo(b);
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
          if (candidates != null && candidates.isNotEmpty) {
            id = candidates.first;
          }
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


  void _openUserPlaylistPage(UserPlaylist playlist) {
    final playlistId = playlist.id;
    _showInlineDetail(
      UserPlaylistPage(
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




  String _newPlaylistId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(1 << 32);
    return '${now}_$rand';
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
                    color: cs.outlineVariant.withValues(alpha: 0.55),
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
      return promptCreatePlaylist(context, onPlaylistCreated: _createNewPlaylist);
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
    if (shouldShow != _showSearchInAppBar.value) {
      _showSearchInAppBar.value = shouldShow;
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
    _showSearchInAppBar.dispose();
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
      if (mounted) {
        setState(() => _permissionState = _LibraryPermissionState.granted);
      }
      await _loadIncludedFolders();
      await _loadExcludedFolders();
      await _loadPlayHistory();
      await _loadUserPlaylists();
      await loadMusic();
      return;
    }

    if (!fromUserAction) {
      if (mounted) {
        setState(() => _permissionState = _LibraryPermissionState.denied);
      }
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
    clearArtworkCache();
    try {
      List<SongModel> rawSongs;
      List<AlbumModel> albums;

      if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
        final result = await LocalAudioScanner.instance.scanMusic(
          includedFolders: _includedFolders,
          excludedFolders: _excludedFolders,
        );
        rawSongs = result.songs;
        albums = result.albums;
      } else {
        rawSongs = await _audioQuery.querySongs(
          uriType: UriType.EXTERNAL,
          ignoreCase: true,
        );
        albums = await _audioQuery.queryAlbums();
      }

      for (final song in rawSongs) {
        LocalAudioScanner.instance.registerSongPath(song.id, song.data);
        final aId = song.albumId;
        if (aId != null && aId > 0) {
          LocalAudioScanner.instance.registerAlbumRepresentativePath(
            aId,
            song.data,
          );
        }
      }
      for (final album in albums) {
        final art = album.getMap['album_art']?.toString();
        if (art != null && art.isNotEmpty) {
          LocalAudioScanner.instance.registerAlbumRepresentativePath(
            album.id,
            art,
          );
        }
      }

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
      debugPrint('Error in loadMusic: $e');
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
      if (excludedPrefixes.any((prefix) => normalized.startsWith(prefix))) {
        return true;
      }
      return false;
    }

    songs = songs
        .where((song) => isIncluded(song.data) && !isExcluded(song.data))
        .toList();

    // Sort: Album Artist → Album Identity → Year (album release) → Album name → Disc/Track
    // Keep comparisons deterministic (Dart's sort is not stable).
    final yearRegex = RegExp(r'\b(19\d{2}|20\d{2})\b');

    String normalize(String v) {
      final t = v.trim();
      if (t.isEmpty) return '';
      final lower = t.toLowerCase();
      // Treat "unknown" values as empty to avoid them dominating sorts.
      if (lower == 'unknown' ||
          lower == 'unknown artist' ||
          lower == 'unknown album') {
        return '';
      }
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

    String albumArtistFor(SongModel s, AlbumModel? album) {
      final raw = s.getMap["album_artist"]?.toString();
      final fromSong = normalize(raw ?? '');
      if (fromSong.isNotEmpty) return fromSong;
      final fromAlbum = normalize(album?.artist ?? '');
      if (fromAlbum.isNotEmpty) return fromAlbum;
      return normalize(s.artist ?? '');
    }

    String albumFor(SongModel s, AlbumModel? album) =>
        album?.album ?? s.album ?? "";

    String albumKeyFor(SongModel s) {
      final artist = albumArtistFor(s, albumMap[s.albumId]);
      final album = normalize(albumFor(s, albumMap[s.albumId]));
      if (album.isNotEmpty) return '${artist.toLowerCase()}\u0000${album.toLowerCase()}';
      final aid = s.albumId;
      if (aid != null && aid > 0) return 'id_$aid';
      return 'song_${s.id}';
    }

    int discFromSongLocal(SongModel s) {
      final v = s.getMap['disc_number'];
      if (v is int && v > 0) return v;
      if (v != null) {
        final str = v.toString().trim();
        final slash = str.indexOf('/');
        final discStr = slash != -1 ? str.substring(0, slash).trim() : str;
        final parsed = int.tryParse(discStr);
        if (parsed != null && parsed > 0) return parsed;
      }
      final track = s.track ?? 0;
      if (track >= 1000) return track ~/ 1000;
      return 1;
    }

    int trackFromSongLocal(SongModel s) {
      int t = s.track ?? 0;
      if (t == 0) {
        final v = s.getMap['track'];
        if (v is int && v > 0) {
          t = v;
        } else if (v != null) {
          final str = v.toString().trim();
          final slash = str.indexOf('/');
          final trackStr = slash != -1 ? str.substring(0, slash).trim() : str;
          t = int.tryParse(trackStr) ?? 0;
        }
      }
      if (t >= 1000) t = t % 1000;
      return t;
    }

    int compareDiscAndTrackLocal(SongModel a, SongModel b) {
      final ad = discFromSongLocal(a);
      final bd = discFromSongLocal(b);
      if (ad != bd) return ad.compareTo(bd);

      final at = trackFromSongLocal(a);
      final bt = trackFromSongLocal(b);
      final finalAt = at == 0 ? 99999 : at;
      final finalBt = bt == 0 ? 99999 : bt;
      final tc = finalAt.compareTo(finalBt);
      if (tc != 0) return tc;

      final titleComp = compareSortStrings(a.title, b.title);
      if (titleComp != 0) return titleComp;
      return a.id.compareTo(b.id);
    }

    final albumYearMap = <String, int>{};
    for (final s in songs) {
      final key = albumKeyFor(s);
      final y = yearFromSong(s);
      if (y > 0) {
        final cur = albumYearMap[key];
        if (cur == null || y < cur) albumYearMap[key] = y;
      }
    }

    songs.sort((a, b) {
      AlbumModel? albumA = albumMap[a.albumId];
      AlbumModel? albumB = albumMap[b.albumId];

      String albumArtistA = albumArtistFor(a, albumA);
      String albumArtistB = albumArtistFor(b, albumB);
      int artistComp = compareSortStrings(albumArtistA, albumArtistB);
      if (artistComp != 0) return artistComp;

      final keyA = albumKeyFor(a);
      final keyB = albumKeyFor(b);
      if (keyA == keyB) {
        final trackComp = compareDiscAndTrackLocal(a, b);
        if (trackComp != 0) return trackComp;
        final titleComp = compareSortStrings(a.title, b.title);
        if (titleComp != 0) return titleComp;
        return a.id.compareTo(b.id);
      }

      int yearA = albumYearMap[keyA] ?? 99999;
      int yearB = albumYearMap[keyB] ?? 99999;
      if (yearA != yearB) return yearA.compareTo(yearB);

      String albumNameA = albumFor(a, albumA);
      String albumNameB = albumFor(b, albumB);
      int albumCompare = compareSortStrings(albumNameA, albumNameB);
      if (albumCompare != 0) return albumCompare;

      final trackComp = compareDiscAndTrackLocal(a, b);
      if (trackComp != 0) return trackComp;

      final titleComp = compareSortStrings(a.title, b.title);
      if (titleComp != 0) return titleComp;
      return a.id.compareTo(b.id);
    });

    return songs;
  }























  void _updateSongMetadataInPlace(SongModel updatedSong) {
    // 1. Update in _songs list
    final idx = _songs.indexWhere((s) => s.id == updatedSong.id || s.data == updatedSong.data);
    if (idx != -1) {
      final newSongs = List<SongModel>.from(_songs);
      newSongs[idx] = updatedSong;
      _songs = newSongs;
    }

    // 2. Update in _controller.songs
    final ctrlIdx = _controller.songs.indexWhere((s) => s.id == updatedSong.id || s.data == updatedSong.data);
    if (ctrlIdx != -1) {
      final newCtrlSongs = List<SongModel>.from(_controller.songs);
      newCtrlSongs[ctrlIdx] = updatedSong;
      _controller.songs = newCtrlSongs;
    }

    // 3. Update desktop scanner cache if running on desktop
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      LocalAudioScanner.instance.updateCachedSong(
        path: updatedSong.data,
        song: updatedSong,
      );
    }

    // 5. Recompute library structure, album/artist views, and refresh UI instantaneously
    _recomputeAllData();
    setState(() {});
  }

  Future<void> _runWithPlaybackSuspendedForTagWrite(
    Future<void> Function() action, {
    String? targetFilePath,
  }) async {
    final currentPlayingPath = _controller.currentSong?.data;
    // If targetFilePath is specified and is NOT the song currently loaded in player,
    // execute directly without interrupting playback!
    if (targetFilePath != null &&
        targetFilePath.isNotEmpty &&
        currentPlayingPath != null &&
        currentPlayingPath != targetFilePath) {
      await action();
      return;
    }

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




  void _showManageFoldersDialog() {
    showManageFoldersDialog(
      context: context,
      initialIncluded: _includedFolders,
      initialExcluded: _excludedFolders,
      onSave: (included, excluded) async {
        setState(() {
          _includedFolders = included;
          _excludedFolders = excluded;
        });
        await _saveIncludedFolders(_includedFolders);
        await _saveExcludedFolders(_excludedFolders);
        await loadMusic();
      },
    );
  }



  Future<void> _applySort(SortMode mode) async {
    await _controller.applySort(mode);
    _songs = _controller.songs;
    _recomputeAllData();
    if (mounted) setState(() {});
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
                    ?_inlineDetailContent,
                  ],
                ),
        ),
      ),
    );
  }

  Widget _wrapWithAuroraBackground({required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rawPrimary = boostVibrance(
      cs.primaryContainer,
      extraSaturation: 0.08,
      extraLightness: isDark ? -0.04 : 0.04,
    );
    final rawSecondary = boostVibrance(
      cs.tertiaryContainer,
      extraSaturation: 0.10,
      extraLightness: isDark ? -0.03 : 0.03,
    );
    final rawAccent = boostVibrance(
      cs.secondaryContainer,
      extraSaturation: 0.10,
      extraLightness: isDark ? -0.03 : 0.03,
    );

    final primary = harmonizeBackgroundAccent(
      rawPrimary,
      cs.surface,
      isDark: isDark,
    );
    final secondary = harmonizeBackgroundAccent(
      rawSecondary,
      cs.surface,
      isDark: isDark,
    );
    final accent = harmonizeBackgroundAccent(
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
                color.withValues(alpha: opacity),
                color.withValues(alpha: 0.0),
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
                  primary.withValues(alpha: overlayOpacity),
                  cs.surface,
                ),
                Color.alphaBlend(
                  secondary.withValues(alpha: overlayOpacity * 0.9),
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
            expandedHeight: 166,
            collapsedHeight: 86,
            toolbarHeight: 86,
            backgroundColor: cs.surface.withValues(alpha: 0.90),
            surfaceTintColor: Colors.transparent,
            centerTitle: false,
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
                  dividerColor: cs.outlineVariant.withValues(alpha: 0.28),
                  builder: (context, controller) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: _showSearchInAppBar,
                      builder: (context, showSearch, _) {
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: showSearch
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
                              if (exact(s.artist)) {
                                exactMatches.add(s);
                              } else if (starts(s.artist)) startMatches.add(s);
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
                              if (exact(s.album)) {
                                exactMatches.add(s);
                              } else if (starts(s.album)) startMatches.add(s);
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
                              if (exact(s.title)) {
                                exactMatches.add(s);
                              } else if (starts(s.title)) startMatches.add(s);
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
                                color: cs.outlineVariant.withValues(alpha: 0.35),
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
            SliverList(
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
                                  cs.primaryContainer.withValues(alpha: 
                                    Theme.of(context).brightness == Brightness.dark
                                        ? 0.28
                                        : 0.55,
                                  ),
                                  cs.surface,
                                )
                              : isCurrent
                              ? Color.alphaBlend(
                                  cs.secondaryContainer.withValues(alpha: 
                                    Theme.of(context).brightness == Brightness.dark
                                        ? 0.35
                                        : 0.55,
                                  ),
                                  cs.surface,
                                )
                              : cs.surfaceContainerLow;

                          final borderColor = (_isSelectionMode && isSelected)
                              ? cs.primary.withValues(alpha: 
                                  Theme.of(context).brightness == Brightness.dark
                                      ? 0.35
                                      : 0.30,
                                )
                              : isCurrent
                              ? cs.secondary.withValues(alpha: 
                                  Theme.of(context).brightness == Brightness.dark
                                      ? 0.30
                                      : 0.22,
                                )
                              : cs.outlineVariant.withValues(alpha: 
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
                                    color: Colors.black.withValues(alpha: 
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
                                    color: cs.primary.withValues(alpha: 
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
                                        showSongOptionsSheet(
                                          context: context,
                                          song: song,
                                          index: index,
                                          onEnterSelectionMode: (songId) => _enterSelectionMode(initialSongId: songId),
                                          onOpenNowPlaying: (s) => _openNowPlaying(s),
                                          onOpenAlbum: (s) => _openAlbumPageFromSong(s),
                                          onOpenArtist: (s) => _openArtistPageFromSong(s),
                                          onSongUpdated: _updateSongMetadataInPlace,
                                          runWithPlaybackSuspended: _runWithPlaybackSuspendedForTagWrite,
                                          onPlaySong: () => _controller.playSong(index),
                                        );
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
                                                        cs.surface.withValues(alpha: 
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
                                                            .withValues(alpha: 0.35),
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
                                                        cs.surface.withValues(alpha: 
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
                                                            .withValues(alpha: 0.35),
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
                                                          .withValues(alpha: 0.85),
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
                                                                  .withValues(alpha: 0.75),
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
                                                                  .withValues(alpha: 
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
          buildBottomBarsGutter(context),
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
          buildBottomBarsGutter(context),
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
                          _openAlbumPageFromSong(song);
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
          buildBottomBarsGutter(context),
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
        SmartPlaylistPage(
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
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
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
                    showCreateOrImportPlaylistSheet(
                      context,
                      onNewPlaylist: () async {
                        final pl = await promptCreatePlaylist(
                          context,
                          onPlaylistCreated: _createNewPlaylist,
                        );
                        if (pl != null) _openUserPlaylistPage(pl);
                      },
                      onImportPlaylist: _importM3uPlaylistFlow,
                    );
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
                              color: cs.primary.withValues(alpha: 0.35 * animValue),
                              blurRadius: 24 * animValue,
                              spreadRadius: 2 * animValue,
                              offset: Offset(0, 8 * animValue),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2 * animValue),
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
                        showUserPlaylistActionsSheet(
                          context,
                          _userPlaylists[i],
                          onRenameClicked: () => promptRenamePlaylist(
                            context,
                            _userPlaylists[i],
                            onPlaylistRenamed: (name) => _renamePlaylist(_userPlaylists[i], name),
                          ),
                          onDeleteClicked: () => confirmAndDeletePlaylist(
                            context,
                            _userPlaylists[i],
                            onPlaylistDeleted: () => _deletePlaylist(_userPlaylists[i]),
                          ),
                        );
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
          buildBottomBarsGutter(context),
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
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 350),
          pageBuilder: (_, __, ___) => NowPlayingPage(
            player: _controller.player,
            song: song,
            songs: _songs,
            playlist: _controller.currentPlaylist,
            onQueueChanged: (_) {},
            onOpenAlbum: _openAlbumPageFromSong,
            onOpenArtist: _openArtistPageFromSong,
            onSongUpdated: _updateSongMetadataInPlace,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final slide = Tween(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic));
            return SlideTransition(
              position: animation.drive(slide),
              child: child,
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

    // Use album identity key to group tracks with the same album artist + album
    // name, even if MediaStore assigned different album IDs (e.g. guest features).
    final targetKey = albumIdentityKey(song);
    final albumSongs = _songs.where((s) => albumIdentityKey(s) == targetKey).toList();
    albumSongs.sort(compareDiscAndTrack);

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
        onShuffle: () async {
          if (albumSongs.isEmpty) return;
          final shuffled = List<SongModel>.from(albumSongs)..shuffle();
          await _controller.playFromQueue(shuffled, initialIndex: 0);
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
          final aa = norm(albumArtistFor(s));
          return a == target || aa == target;
        })
        .toList(growable: false);

    if (artistSongs.isEmpty) return;

    // Group into albums by identity key (albumArtist + albumName) instead of
    // raw MediaStore albumId to prevent fragmentation from guest features.
    final Map<String, List<SongModel>> songsByAlbumKey = {};
    for (final s in artistSongs) {
      final key = albumIdentityKey(s);
      (songsByAlbumKey[key] ??= <SongModel>[]).add(s);
    }

    final albums = <ArtistAlbum>[];
    for (final entry in songsByAlbumKey.entries) {
      final songs = entry.value;
      songs.sort(compareDiscAndTrack);

      final title = (songs.first.album ?? '').trim().isEmpty
          ? 'Unknown Album'
          : songs.first.album!.trim();
      int year = 0;
      for (final s in songs) {
        final y = yearFromSong(s);
        if (y > 0 && (year == 0 || y < year)) year = y;
      }

      int totalMs = 0;
      for (final s in songs) {
        totalMs += (s.duration ?? 0);
      }

      // Use the first song's albumId as the representative for artwork lookups.
      final repAlbumId = songs.first.albumId ?? 0;

      albums.add(
        ArtistAlbum(
          albumId: repAlbumId,
          title: title,
          year: year,
          trackCount: songs.length,
          totalDurationMs: totalMs,
          representativeSong: songs.first,
        ),
      );
    }

    // Sort artist's albums chronologically by release year.
    albums.sort((a, b) {
      final ay = a.year == 0 ? 9999 : a.year;
      final by = b.year == 0 ? 9999 : b.year;
      final yc = ay.compareTo(by);
      if (yc != 0) return yc;
      final tc = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (tc != 0) return tc;
      return a.albumId.compareTo(b.albumId);
    });

    // Build album songs lookup by identity key for Play All.
    final albumKeyForAlbum = <int, String>{};
    for (final entry in songsByAlbumKey.entries) {
      final repId = entry.value.first.albumId ?? 0;
      albumKeyForAlbum[repId] = entry.key;
    }

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
                  final key = albumKeyForAlbum[a.albumId] ?? '';
                  final list = songsByAlbumKey[key] ?? const <SongModel>[];
                  final sorted = List<SongModel>.from(list);
                  sorted.sort(compareDiscAndTrack);
                  queue.addAll(sorted);
                }
                if (queue.isEmpty) return;
                await _controller.playFromQueue(queue, initialIndex: 0);
              },
      ),
    );
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
                    color: cs.secondaryContainer.withValues(alpha: 
                      Theme.of(context).brightness == Brightness.dark
                          ? 0.25
                          : 0.6,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.35),
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





enum _LyricTileMode { normal, near, active }


