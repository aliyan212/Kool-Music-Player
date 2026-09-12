import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../android_notifications.dart';
import '../data/models/album_stat.dart';
import '../data/models/isolate_data.dart';
import '../data/models/sort_mode.dart';
import '../dialogs/folder_management_dialog.dart';
import '../main.dart';
import '../services/local_audio_scanner.dart';
import '../services/playback_controller.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/song_sort_utils.dart';
import 'mixins/navigation_state_mixin.dart';
import 'mixins/playlist_management_mixin.dart';
import 'mixins/tag_editor_state_mixin.dart';

export 'mixins/navigation_state_mixin.dart';
export 'mixins/playlist_management_mixin.dart';
export 'mixins/tag_editor_state_mixin.dart';

const List<String> _defaultExcludedFolderFragments = [
  '/storage/emulated/0/Ringtones',
  '/storage/emulated/0/Android/media',
  '/storage/emulated/0/Recordings',
];

enum LibraryPermissionState { unknown, granted, denied, permanentlyDenied }

class AppStateController extends ChangeNotifier
    with NavigationStateMixin, PlaylistManagementMixin, TagEditorStateMixin {
  static final AppStateController instance = AppStateController._();
  AppStateController._() {
    _controller.attachStreamListeners();
    _controller.onPlayHistoryUpdated = () {
      recomputePlayHistoryStats();
      notifyListeners();
    };
    unawaited(loadSavedSortPreferences());
  }

  @override
  BuildContext get context => navigatorKey.currentContext!;

  @override
  void showSnackBar(SnackBar snackBar, {BuildContext? context}) {
    final ctx = context ?? navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(snackBar);
    }
  }

  final PlaybackController _controller = playbackController;
  final OnAudioQuery _audioQuery = OnAudioQuery();

  @override
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
  static const String _librarySortKey = "library_sort_mode_v1";
  static const String _albumsSortKey = "albums_sort_mode_v1";
  static const String _albumArtistsSortKey = "album_artists_sort_mode_v1";

  List<AlbumArtistStat> cachedAlbumArtists = <AlbumArtistStat>[];
  List<AlbumTabStat> cachedAlbums = <AlbumTabStat>[];
  List<SongModel> cachedMostPlayed = <SongModel>[];
  List<SongModel> cachedRecentlyPlayed = <SongModel>[];
  List<SongModel> cachedRecentlyAdded = <SongModel>[];


  

  

  String _displayAlbumTitle(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Album' : v;
  }

  String _displayArtistName(String? raw) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? 'Unknown Artist' : v;
  }

  int _yearValueForCompare(int y) => y == 0 ? 99999 : y;

  @override
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
    final albumYearByKey = computeAlbumYearMap(songs);

    for (final s in songs) {
      final artistName = _displayArtistName(albumArtistFor(s));
      final artistKey = artistName.toLowerCase();
      final artistStat = artistStatByKey.putIfAbsent(
        artistKey,
        () => AlbumArtistStat(name: artistName, representativeSong: s),
      );
      artistStat.trackCount++;
      if (artistStat.representativeSong == null ||
          ((artistStat.representativeSong!.albumId ?? 0) <= 0 && (s.albumId ?? 0) > 0)) {
        artistStat.representativeSong = s;
      }

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
                year: albumYearByKey[albumKey] ?? 0,
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

  String _normalizeFolderPath(String path) {
    return path.trim().replaceAll(RegExp(r'/+$'), '');
  }

  int _compareStrings(String a, String b) {
    return a.compareTo(b);
  }

  Future<void> ensureLibraryPermissionAndLoad({
    bool fromUserAction = false,
  }) async {
    if (kIsWeb) {
      permissionState = LibraryPermissionState.granted;
    notifyListeners();
      await loadSavedSortPreferences();
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
      await loadSavedSortPreferences();
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
      await loadSavedSortPreferences();
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
      showSnackBar(
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
      await _controller.applySort(_controller.sortMode);

      songs = _controller.songs;
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
      final raw =
          (s.getMap["album_artist"] ?? s.getMap["albumArtist"])?.toString();
      final fromSong = normalize(raw ?? '');
      if (fromSong.isNotEmpty) return fromSong;
      final fromSongArtist = normalize(s.artist ?? '');
      if (fromSongArtist.isNotEmpty) return fromSongArtist;
      final fromAlbum = normalize(album?.artist ?? '');
      if (fromAlbum.isNotEmpty) return fromAlbum;
      return '';
    }

    String albumFor(SongModel s, AlbumModel? album) =>
        album?.album ?? s.album ?? "";

    String albumKeyFor(SongModel s) {
      final artist = albumArtistFor(s, albumMap[s.albumId]);
      final album = normalize(albumFor(s, albumMap[s.albumId]));
      if (album.isNotEmpty) {
        return '${artist.toLowerCase()}\u0000${album.toLowerCase()}';
      }
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

  Future<void> loadSavedSortPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final libSortName = prefs.getString(_librarySortKey);
      if (libSortName != null) {
        for (final m in SortMode.values) {
          if (m.name == libSortName) {
            _controller.sortMode = m;
            break;
          }
        }
      }

      final albumsSortName = prefs.getString(_albumsSortKey);
      if (albumsSortName != null) {
        for (final m in AlbumsSort.values) {
          if (m.name == albumsSortName) {
            albumsSort = m;
            break;
          }
        }
      }

      final albumArtistsSortName = prefs.getString(_albumArtistsSortKey);
      if (albumArtistsSortName != null) {
        for (final m in AlbumArtistsSort.values) {
          if (m.name == albumArtistsSortName) {
            albumArtistsSort = m;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading saved sort preferences: $e');
    }
  }

  Future<void> saveLibrarySortPreference(SortMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_librarySortKey, mode.name);
    } catch (e) {
      debugPrint('Error saving library sort preference: $e');
    }
  }

  Future<void> saveAlbumsSortPreference(AlbumsSort mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_albumsSortKey, mode.name);
    } catch (e) {
      debugPrint('Error saving albums sort preference: $e');
    }
  }

  Future<void> saveAlbumArtistsSortPreference(AlbumArtistsSort mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_albumArtistsSortKey, mode.name);
    } catch (e) {
      debugPrint('Error saving album artists sort preference: $e');
    }
  }

  Future<void> applyAlbumArtistsSort(AlbumArtistsSort mode) async {
    albumArtistsSort = mode;
    await saveAlbumArtistsSortPreference(mode);
    recomputeAllData();
    notifyListeners();
  }

  Future<void> applyAlbumsSort(AlbumsSort mode) async {
    albumsSort = mode;
    await saveAlbumsSortPreference(mode);
    recomputeAllData();
    notifyListeners();
  }

  Future<void> applySort(SortMode mode) async {
    await saveLibrarySortPreference(mode);
    await _controller.applySort(mode);
    songs = _controller.songs;
    recomputeAllData();
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
      await _controller.player.setAudioSources(
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
        showSnackBar(
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
}

