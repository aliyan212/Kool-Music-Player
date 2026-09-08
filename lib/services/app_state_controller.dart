import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import '../dialogs/playlist_dialogs.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audio_service/audio_service.dart';

import '../android_notifications.dart';
import '../data/models/album_stat.dart';
import '../data/models/isolate_data.dart';
import '../data/models/sort_mode.dart';
import '../data/models/user_playlist.dart';
import '../dialogs/folder_management_dialog.dart';
import '../main.dart';
import '../platform_exit.dart';
import '../services/app_local_store.dart';
import '../services/local_audio_scanner.dart';
import '../services/playback_controller.dart';
import '../ui/shared/bottom_bars_gutter.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';
import '../utils/palette_compute.dart';
import '../utils/song_sort_utils.dart';
import '../utils/tag_write_access.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_options_sheet.dart';

import '../pages/about_page.dart';
import '../pages/album_page.dart';
import '../pages/artist_page.dart';
import '../pages/now_playing_page.dart';
import '../pages/playlist_page.dart';
import '../pages/tabs/album_artists_tab.dart';
import '../pages/tabs/albums_tab.dart';
import '../pages/tabs/library_tab.dart';
import '../pages/tabs/playlists_tab.dart';

const List<String> _defaultExcludedFolderFragments = [
  '/storage/emulated/0/Ringtones',
  '/storage/emulated/0/Android/media',
  '/storage/emulated/0/Recordings',
];




enum LibraryPermissionState { unknown, granted, denied, permanentlyDenied }

class AppStateController extends ChangeNotifier {
  final SearchController searchController = SearchController();
  static final AppStateController instance = AppStateController._();
  AppStateController._() {
    _controller.attachStreamListeners();
    _controller.onPlayHistoryUpdated = () {
      recomputePlayHistoryStats();
      notifyListeners();
    };
  }
  
  BuildContext get context => navigatorKey.currentContext!;

  final PlaybackController _controller = playbackController;
  final AppLocalStore _localStore = AppLocalStore.instance;
  final OnAudioQuery _audioQuery = OnAudioQuery();


  late int selectedTabIndex;

  void selectTab(int index) {
    if (isSelectionMode) exitSelectionMode();
    if (inlineDetailContent != null) {
      inlineDetailContent = null;
    }
    selectedTabIndex = index;
    notifyListeners();
  }

  bool nowPlayingRouteActive = false;
  DateTime? _lastNowPlayingClosedAt;

  List<SongModel> songs = [];
  bool isLoading = true;
  LibraryPermissionState permissionState = LibraryPermissionState.unknown;
  AlbumArtistsSort albumArtistsSort = AlbumArtistsSort.nameAsc;
  AlbumsSort albumsSort = AlbumsSort.titleAsc;
  List<String> allFolders = [];
  Set<String> includedFolders = {};
  Set<String> excludedFolders = {};

  static const String _includedFoldersKey = "included_folders";
  static const String _excludedFoldersKey = "excluded_folders";

  static const String _userPlaylistsKey = 'user_playlists_v1';

  bool isSelectionMode = false;
  final Set<int> selectedSongIds = <int>{};

  List<UserPlaylist> userPlaylists = <UserPlaylist>[];
  List<AlbumArtistStat> cachedAlbumArtists = <AlbumArtistStat>[];
  List<AlbumTabStat> cachedAlbums = <AlbumTabStat>[];
  List<SongModel> cachedMostPlayed = <SongModel>[];
  List<SongModel> cachedRecentlyPlayed = <SongModel>[];
  List<SongModel> cachedRecentlyAdded = <SongModel>[];
  Map<String, int> cachedUserPlaylistTrackCounts = <String, int>{};

  bool hideBottomBars = false;
  DateTime? _lastBottomBarsToggleAt;
  Widget? inlineDetailContent;

  static final RegExp _yearRegex = RegExp(r'\b(19\d{2}|20\d{2})\b');

  

  

  String _displayAlbumTitle(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Album' : v;
  }

  String _displayArtistName(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Artist' : v;
  }

  int _yearValueForCompare(int y) => y == 0 ? 99999 : y;

  void recomputeAllData() {
    recomputeLibraryStructure();
    recomputePlayHistoryStats();
  }

  void recomputeLibraryStructure() {
    final songs = this.songs;
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
        switch (albumArtistsSort) {
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
              final artist = _displayArtistName(albumArtistFor(song));
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
            switch (albumsSort) {
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
    for (final playlist in userPlaylists) {
      var count = 0;
      for (final id in playlist.songIds) {
        if (byId.containsKey(id)) count++;
      }
      userPlaylistTrackCounts[playlist.id] = count;
    }

    cachedAlbumArtists = artists;
    cachedAlbums = albums;
    cachedRecentlyAdded = recentlyAdded;
    cachedUserPlaylistTrackCounts = userPlaylistTrackCounts;
  }

  void recomputePlayHistoryStats() {
    final songs = this.songs;
    final playCounts = _controller.playCountBySongId;
    final lastPlayed = _controller.lastPlayedMsBySongId;

    final mostPlayed =
        songs.where((s) => (playCounts[s.id] ?? 0) > 0).toList(growable: false)
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
        songs.where((s) => (lastPlayed[s.id] ?? 0) > 0).toList(growable: false)
          ..sort((a, b) {
            final at = lastPlayed[a.id] ?? 0;
            final bt = lastPlayed[b.id] ?? 0;
            final comp = bt.compareTo(at);
            if (comp != 0) return comp;
            return a.id.compareTo(b.id);
          });

    cachedMostPlayed = mostPlayed;
    cachedRecentlyPlayed = recentlyPlayed;
  }

  

  void showInlineDetail(Widget detailContent) {
    
    inlineDetailContent = detailContent;
      hideBottomBars = false;
    notifyListeners();
  }

  void closeInlineDetail() {
    
    if (inlineDetailContent == null) return;
    inlineDetailContent = null;
    notifyListeners();
  }

  void enterSelectionMode({int? initialSongId}) {
    if (searchController.isOpen) {
      searchController.closeView(searchController.text);
      FocusManager.instance.primaryFocus?.unfocus();
    }
    isSelectionMode = true;
      selectedSongIds.clear();
      if (initialSongId != null) selectedSongIds.add(initialSongId);
    notifyListeners();
  }

  void exitSelectionMode() {
    if (!isSelectionMode) return;
    isSelectionMode = false;
      selectedSongIds.clear();
    notifyListeners();
  }

  void toggleSelectedSongId(int songId) {
    if (selectedSongIds.contains(songId)) {
        selectedSongIds.remove(songId);
        if (selectedSongIds.isEmpty) isSelectionMode = false;
      } else {
        selectedSongIds.add(songId);
        isSelectionMode = true;
      }
    notifyListeners();
  }

  Future<void> loadUserPlaylists() async {
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
        userPlaylists = <UserPlaylist>[];
        recomputeAllData();
        if (true) 
    notifyListeners();
        return;
      }

      final list = <UserPlaylist>[];
      for (final item in decoded) {
        final pl = UserPlaylist.fromJson(item);
        if (pl == null) continue;
        list.add(pl);
      }
      userPlaylists = list;
      recomputeAllData();
      if (true) 
    notifyListeners();
    } catch (_) {
      userPlaylists = <UserPlaylist>[];
      recomputeAllData();
      if (true) 
    notifyListeners();
    }
  }

  Future<void> _saveUserPlaylists() async {
    try {
      await _localStore.writeUserPlaylists(
        userPlaylists.map((p) => p.toJson()).toList(growable: false),
      );
    } catch (_) {
      // Best-effort; do not crash UI.
    }
  }

  Future<UserPlaylist?> createNewPlaylist(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final playlist = UserPlaylist(
      id: _newPlaylistId(),
      name: name,
      songIds: const <int>[],
      createdAtMs: now,
      updatedAtMs: now,
    );
    userPlaylists = <UserPlaylist>[playlist, ...userPlaylists];
    cachedUserPlaylistTrackCounts[playlist.id] = 0;
    recomputeAllData();
    notifyListeners();
    await _saveUserPlaylists();
    return playlist;
  }

  Future<void> renamePlaylist(UserPlaylist playlist, String newName) async {
    final idx = userPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx == -1) return;
    userPlaylists[idx] = playlist.copyWith(
      name: newName,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    recomputeAllData();
    notifyListeners();
    await _saveUserPlaylists();
  }

  Future<void> deletePlaylist(UserPlaylist playlist) async {
    userPlaylists.removeWhere((p) => p.id == playlist.id);
    cachedUserPlaylistTrackCounts.remove(playlist.id);
    recomputeAllData();
    notifyListeners();
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
    final existing = userPlaylists
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

  Future<void> importM3uPlaylistFlow() async {
    
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
      for (final s in songs) {
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
      userPlaylists = <UserPlaylist>[playlist, ...userPlaylists];
        recomputeAllData();
    notifyListeners();
      await _saveUserPlaylists();

      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${songIds.length} track${songIds.length == 1 ? '' : 's'} to "$playlistName"',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );

      // Open the imported playlist.
      openUserPlaylistPage(playlist);
    } catch (_) {
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to import playlist'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void openUserPlaylistPage(UserPlaylist playlist) {
    final playlistId = playlist.id;
    showInlineDetail(
      UserPlaylistPage(
        player: _controller.player,
        playlistId: playlistId,
        playlistName: playlist.name,
        initialSongIds: playlist.songIds,
        librarySongs: songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: selectTab,
        embeddedInHome: true,
        onClose: closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          openNowPlaying(s);
        },
        playFromQueue: (songs, initialIndex) async {
          await _controller.playFromQueue(songs, initialIndex: initialIndex);
        },
        onUpdateSongIds: (id, newSongIds) async {
          final idx = userPlaylists.indexWhere((p) => p.id == id);
          if (idx == -1) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          final existing = userPlaylists[idx];
            userPlaylists = List<UserPlaylist>.from(
              userPlaylists,
            )..[idx] = existing.copyWith(songIds: newSongIds, updatedAtMs: now);
            recomputeAllData();
    notifyListeners();
          await _saveUserPlaylists();
        },
      ),
    );
  }

  void reorderUserPlaylists(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= userPlaylists.length) return;
    if (newIndex < 0 || newIndex > userPlaylists.length) return;

    final list = List<UserPlaylist>.from(userPlaylists);
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = list.removeAt(oldIndex);
      list.insert(newIndex, moved);
      userPlaylists = list;
      recomputeAllData();
    notifyListeners();
    unawaited(_saveUserPlaylists());
  }

  String _newPlaylistId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(1 << 32);
    return '${now}_$rand';
  }

  Future<UserPlaylist?> pickPlaylistOrCreate({
    required List<int> songIdsToAdd,
  }) async {
     null;
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
                if (userPlaylists.isEmpty)
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
                  ...userPlaylists.map(
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
      return promptCreatePlaylist(
        context,
        onPlaylistCreated: createNewPlaylist,
      );
    }
    for (final p in userPlaylists) {
      if (p.id == pickedId) return p;
    }
    return null;
  }

  Future<bool> addSongsToPlaylistFlow(List<int> songIds) async {
    if (songIds.isEmpty) return false;
    final playlist = await pickPlaylistOrCreate(songIdsToAdd: songIds);
    if (playlist == null) return false;

    final idx = userPlaylists.indexWhere((p) => p.id == playlist.id);
    if (idx == -1) return false;

    final existing = userPlaylists[idx];
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
    userPlaylists = List<UserPlaylist>.from(userPlaylists)
        ..[idx] = newPlaylist;
      recomputeAllData();
    notifyListeners();
    await _saveUserPlaylists();

    
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

  

  

  

  Future<void> ensureLibraryPermissionAndLoad({
    bool fromUserAction = false,
  }) async {
    if (kIsWeb) {
      permissionState = LibraryPermissionState.granted;
    notifyListeners();
      await loadIncludedFolders();
      await loadExcludedFolders();
      await _loadPlayHistory();
      await loadUserPlaylists();
      await loadMusic();
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      // Keep behavior simple for non-Android targets.
      permissionState = LibraryPermissionState.granted;
    notifyListeners();
      await loadIncludedFolders();
      await loadExcludedFolders();
      await _loadPlayHistory();
      await loadUserPlaylists();
      await loadMusic();
      return;
    }

    final audioStatus = await Permission.audio.status;
    final storageStatus = await Permission.storage.status;

    final hasAccess = audioStatus.isGranted || storageStatus.isGranted;
    if (hasAccess) {
      if (true) {
        permissionState = LibraryPermissionState.granted;
    notifyListeners();
      }
      await loadIncludedFolders();
      await loadExcludedFolders();
      await _loadPlayHistory();
      await loadUserPlaylists();
      await loadMusic();
      return;
    }

    if (!fromUserAction) {
      if (true) {
        permissionState = LibraryPermissionState.denied;
    notifyListeners();
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

    if (true) {
      final anyPermanent =
          (results[Permission.audio]?.isPermanentlyDenied ?? false) ||
          (results[Permission.storage]?.isPermanentlyDenied ?? false);
      permissionState = granted
          ? LibraryPermissionState.granted
          : (anyPermanent
                ? LibraryPermissionState.permanentlyDenied
                : LibraryPermissionState.denied);
      
    notifyListeners();
    }

    if (granted) {
      await loadIncludedFolders();
      await loadExcludedFolders();
      await _loadPlayHistory();
      await loadUserPlaylists();
      await loadMusic();
    }
  }

  Future<void> _loadPlayHistory() async {
    await _controller.loadPlayHistory();
    recomputeAllData();
    if (true) 
    notifyListeners();
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

  Future<void> checkNotificationPermission() async {
    final ok = await ensureNotificationPermissionIfNeeded();
    if (!ok) {
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
    isLoading = true;
    notifyListeners();
    clearArtworkCache();
    try {
      List<SongModel> rawSongs;
      List<AlbumModel> albums;

      if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
        final result = await LocalAudioScanner.instance.scanMusic(
          includedFolders: includedFolders,
          excludedFolders: excludedFolders,
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

      allFolders = _extractFolders(rawSongs);

      final processedSongs = await compute(
        _processSongsInBackground,
        IsolateData(
          rawSongs,
          albums,
          excludedFolders.toList(),
          includedFolders.toList(),
        ),
      );

      _controller.songs = processedSongs;
      _controller.libraryPlaylist = _controller.buildPlaylist(processedSongs);
      _controller.currentPlaylist = _controller.libraryPlaylist;

      songs = processedSongs;
        recomputeAllData();
        isLoading = false;
    notifyListeners();
    } catch (e) {
      debugPrint('Error in loadMusic: $e');
      isLoading = false;
    notifyListeners();
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
      if (album.isNotEmpty)
        return '${artist.toLowerCase()}\u0000${album.toLowerCase()}';
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

  void updateSongMetadataInPlace(SongModel updatedSong) {
    // 1. Update in songs list
    final idx = songs.indexWhere(
      (s) => s.id == updatedSong.id || s.data == updatedSong.data,
    );
    if (idx != -1) {
      final newSongs = List<SongModel>.from(songs);
      newSongs[idx] = updatedSong;
      songs = newSongs;
    }

    // 2. Update in _controller.songs
    final ctrlIdx = _controller.songs.indexWhere(
      (s) => s.id == updatedSong.id || s.data == updatedSong.data,
    );
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
    recomputeAllData();
    
    notifyListeners();
  }

  Future<void> runWithPlaybackSuspendedForTagWrite(
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
    final shouldSuspend =
        handler != null && handler.player == _controller.player;
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

  Future<void> loadIncludedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_includedFoldersKey) ?? [];
    final normalized = stored.map(_normalizeFolderPath).toSet();
    includedFolders = normalized;
    notifyListeners();
  }

  Future<void> saveIncludedFolders(Set<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_includedFoldersKey, folders.toList());
  }

  Future<void> loadExcludedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_excludedFoldersKey) ?? [];
    excludedFolders = stored.toSet();
    notifyListeners();
  }

  Future<void> saveExcludedFolders(Set<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludedFoldersKey, folders.toList());
  }

  void openAboutPage() {
    context.pushNamed('about');
  }

  Future<void> confirmQuit() async {
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

  void openManageFoldersDialog() {
    showManageFoldersDialog(
      context: context,
      initialIncluded: includedFolders,
      initialExcluded: excludedFolders,
      onSave: (included, excluded) async {
        includedFolders = included;
          excludedFolders = excluded;
    notifyListeners();
        await saveIncludedFolders(includedFolders);
        await saveExcludedFolders(excludedFolders);
        await loadMusic();
      },
    );
  }

  
  void applyAlbumArtistsSort(AlbumArtistsSort mode) {
    albumArtistsSort = mode;
    recomputeAllData();
    notifyListeners();
  }

  void applyAlbumsSort(AlbumsSort mode) {
    albumsSort = mode;
    recomputeAllData();
    notifyListeners();
  }

  Future<void> applySort(SortMode mode) async {
    await _controller.applySort(mode);
    songs = _controller.songs;
    recomputeAllData();
    if (true) 
    notifyListeners();
  }

  Future<void> playFromQueue(
    List<SongModel> queue, {
    required int initialIndex,
  }) async {
    if (queue.isEmpty) return;
    if (initialIndex < 0 || initialIndex >= queue.length) return;

    await checkNotificationPermission();

    final newPlaylist = _controller.buildPlaylist(queue);
    final songId = queue[initialIndex].id;

    _controller.currentPlaylist = newPlaylist;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);
    _controller.currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;
    _controller.currentSongId = songId;

    try {
      _controller.setSuppressIndexUpdates(true);
      await _controller.player.setAudioSource(
        newPlaylist,
        initialIndex: initialIndex,
      );
      await _controller.player.play();
      _controller.recordPlayForSongId(songId);
    } catch (e, st) {
      debugPrint('Failed to play custom queue initialIndex=$initialIndex: $e');
      debugPrintStack(stackTrace: st);
      if (true) {
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

  Future<void> playSong(int index) async {
    if (index < 0 || index >= songs.length) return;
    await checkNotificationPermission();
    await _controller.playSong(index);
  }

  



  void showSongOptions(SongModel song, int index) {
    showSongOptionsSheet(
      context: context,
      song: song,
      index: index,
      onEnterSelectionMode: (songId) =>
          enterSelectionMode(initialSongId: songId),
      onOpenNowPlaying: openNowPlaying,
      onOpenAlbum: openAlbumPageFromSong,
      onOpenArtist: openArtistPageFromSong,
      onSongUpdated: updateSongMetadataInPlace,
      runWithPlaybackSuspended: runWithPlaybackSuspendedForTagWrite,
      onPlaySong: () => _controller.playSong(index),
    );
  }

  Future<void> openNowPlaying(SongModel song) async {
    
    if (nowPlayingRouteActive) return;
    final lastClosed = _lastNowPlayingClosedAt;
    if (lastClosed != null &&
        DateTime.now().difference(lastClosed) <
            const Duration(milliseconds: 500)) {
      return;
    }

    nowPlayingRouteActive = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          barrierLabel: 'Now Playing',
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, __, ___) => NowPlayingPage(
            player: _controller.player,
            song: song,
            songs: songs,
            playlist: _controller.currentPlaylist,
            onQueueChanged: (_) {},
            onOpenAlbum: openAlbumPageFromSong,
            onOpenArtist: openArtistPageFromSong,
            onSongUpdated: updateSongMetadataInPlace,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curve = CurveTween(curve: Curves.easeOutCubic);
            final fade = Tween<double>(begin: 0.0, end: 1.0).chain(curve);

            // When returning to the miniplayer (reverse transition / pop),
            // fade out smoothly without sliding down so the gradient doesn't
            // slide down awkwardly while the Hero artwork flies back into place.
            if (animation.status == AnimationStatus.reverse) {
              return FadeTransition(
                opacity: animation.drive(fade),
                child: child,
              );
            }

            final slide = Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).chain(curve);

            return SlideTransition(
              position: animation.drive(slide),
              child: FadeTransition(
                opacity: animation.drive(fade),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      nowPlayingRouteActive = false;
      _lastNowPlayingClosedAt = DateTime.now();
    }
  }

  void openAlbumPageFromSong(SongModel song) {
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
    final albumSongs = songs
        .where((s) => albumIdentityKey(s) == targetKey)
        .toList();
    albumSongs.sort(compareDiscAndTrack);

    showInlineDetail(
      AlbumPage(
        player: _controller.player,
        albumId: albumId,
        albumTitle: albumTitle,
        albumArtist: albumArtist,
        songs: albumSongs,
        librarySongs: songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: selectTab,
        embeddedInHome: true,
        onClose: closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          openNowPlaying(s);
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

  void openArtistPageFromSong(SongModel song) {
    final name = (song.artist ?? '').trim().isEmpty
        ? 'Unknown Artist'
        : song.artist!.trim();
    openArtistPageByName(name);
  }

  void openArtistPageByName(String artistName) {
    final normalizedArtist = artistName.trim();
    if (normalizedArtist.isEmpty) return;

    String norm(String? v) => (v ?? '').trim().toLowerCase();
    final target = norm(normalizedArtist);

    final artistSongs = songs
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

    showInlineDetail(
      ArtistPage(
        player: _controller.player,
        artistName: normalizedArtist,
        albums: albums,
        librarySongs: songs,
        playlist: _controller.currentPlaylist,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: selectTab,
        embeddedInHome: true,
        onClose: closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          openNowPlaying(s);
        },
        onOpenAlbum: (s) => openAlbumPageFromSong(s),
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

