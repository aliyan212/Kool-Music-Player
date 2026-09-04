import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:audiotags/audiotags.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path/path.dart' as p;
import 'package:hive_flutter/hive_flutter.dart';
import '../data/services/caching_service.dart';

class LocalScanResult {
  final List<SongModel> songs;
  final List<AlbumModel> albums;

  LocalScanResult({required this.songs, required this.albums});
}

class LocalAudioScanner {
  LocalAudioScanner._();
  static final LocalAudioScanner instance = LocalAudioScanner._();

  static const Set<String> supportedExtensions = {
    '.mp3',
    '.flac',
    '.m4a',
    '.aac',
    '.ogg',
    '.oga',
    '.opus',
    '.wav',
    '.wma',
    '.aiff',
    '.alac',
  };

  static const List<String> coverFilenames = [
    'cover.jpg',
    'folder.jpg',
    'album.jpg',
    'front.jpg',
    'artwork.jpg',
    'cover.png',
    'folder.png',
    'album.png',
    'front.png',
    'artwork.png',
    'cover.jpeg',
    'folder.jpeg',
    'album.jpeg',
    'front.jpeg',
  ];

  static const String _metadataBoxName = 'desktop_song_meta_cache_v1';
  Box<dynamic>? _metaBox;
  bool _boxInitialized = false;

  final Map<int, String> _songPathById = {};
  final Map<int, String> _representativeSongByAlbumId = {};

  Future<void> _ensureBox() async {
    if (_boxInitialized) return;
    try {
      if (!Hive.isBoxOpen(_metadataBoxName)) {
        _metaBox = await Hive.openBox<dynamic>(_metadataBoxName);
      } else {
        _metaBox = Hive.box<dynamic>(_metadataBoxName);
      }
      _boxInitialized = true;
    } catch (e) {
      debugPrint('LocalAudioScanner Hive cache init error: $e');
    }
  }

  /// Updates or invalidates the cached metadata for a specific song path.
  Future<void> updateCachedSong({
    required String path,
    required SongModel song,
  }) async {
    await _ensureBox();
    try {
      final f = File(path);
      if (f.existsSync()) {
        final stat = f.statSync();
        await _metaBox?.put(path, {
          'modified': stat.modified.millisecondsSinceEpoch,
          'size': stat.size,
          'meta': song.getMap,
        });
      } else {
        await _metaBox?.delete(path);
      }
    } catch (_) {}
  }

  /// Returns default music directories on Linux / Desktop.
  static List<String> getDefaultMusicDirectories() {
    final List<String> dirs = [];

    // Check XDG_MUSIC_DIR
    final xdg = Platform.environment['XDG_MUSIC_DIR'];
    if (xdg != null && xdg.trim().isNotEmpty && Directory(xdg).existsSync()) {
      dirs.add(_normalizePath(xdg));
    }

    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final musicDir = Directory(p.join(home, 'Music'));
      if (musicDir.existsSync()) {
        final path = _normalizePath(musicDir.path);
        if (!dirs.contains(path)) dirs.add(path);
      }

      final downloadDir = Directory(p.join(home, 'Downloads'));
      if (downloadDir.existsSync()) {
        final path = _normalizePath(downloadDir.path);
        if (!dirs.contains(path)) dirs.add(path);
      }

      final docDir = Directory(p.join(home, 'Documents'));
      if (docDir.existsSync()) {
        final path = _normalizePath(docDir.path);
        if (!dirs.contains(path)) dirs.add(path);
      }
    }

    return dirs;
  }

  static String _normalizePath(String path) {
    var norm = path.replaceAll('\\', '/');
    if (!norm.endsWith('/')) norm = '$norm/';
    return norm;
  }

  /// Scans local directories for audio files and builds [SongModel] and [AlbumModel] lists.
  Future<LocalScanResult> scanMusic({
    Set<String>? includedFolders,
    Set<String>? excludedFolders,
  }) async {
    await _ensureBox();

    final List<String> rootPaths;
    if (includedFolders != null && includedFolders.isNotEmpty) {
      rootPaths = includedFolders.toList();
    } else {
      final defaults = getDefaultMusicDirectories();
      // If we found default dirs, use them. If Music dir exists, prioritize it.
      if (defaults.isNotEmpty) {
        rootPaths = defaults;
      } else {
        rootPaths = ['/home'];
      }
    }

    final List<File> audioFiles = [];
    final Set<String> visitedPaths = {};

    for (final root in rootPaths) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      _collectAudioFiles(dir, audioFiles, visitedPaths, excludedFolders);
    }

    final List<SongModel> songs = [];
    final Map<int, List<SongModel>> albumSongsMap = {};
    final Map<int, AlbumModel> albumMap = {};

    // Process files in batches to prevent UI lag while maintaining high speed
    final rootToken = RootIsolateToken.instance!;
    const batchSize = 32;
    for (var i = 0; i < audioFiles.length; i += batchSize) {
      final end = (i + batchSize < audioFiles.length) ? i + batchSize : audioFiles.length;
      final batch = audioFiles.sublist(i, end);

      final uncached = <Map<String, dynamic>>[];

      for (final file in batch) {
         final filePath = file.path;
         final fileStat = file.statSync();
         final lastModified = fileStat.modified.millisecondsSinceEpoch;
         final fileSize = fileStat.size;

         final cacheKey = filePath;
         final cached = _metaBox?.get(cacheKey);
         if (cached is Map &&
             cached['modified'] == lastModified &&
             cached['size'] == fileSize) {
           final map = Map<dynamic, dynamic>.from(cached['meta'] as Map);
           final song = SongModel(map);
           _songPathById[song.id] = filePath;
           songs.add(song);
           
           final albumId = song.albumId ?? 0;
           albumSongsMap.putIfAbsent(albumId, () => []).add(song);
         } else {
           uncached.add({
             'path': filePath,
             'modified': lastModified,
             'size': fileSize,
             'dateAdded': fileStat.changed.millisecondsSinceEpoch,
           });
         }
      }

      if (uncached.isNotEmpty) {
        final parsedMaps = await Isolate.run(() async {
          BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
          final results = <Map<String, dynamic>>[];
          for (final req in uncached) {
            final filePath = req['path'] as String;
            Tag? tag;
            try {
              tag = await AudioTags.read(filePath);
            } catch (_) {}

            final baseName = p.basename(filePath);
            final baseNameNoExt = p.basenameWithoutExtension(filePath);
            final ext = p.extension(filePath).replaceAll('.', '').toLowerCase();

            final title = (tag?.title != null && tag!.title!.trim().isNotEmpty)
                ? tag.title!.trim()
                : baseNameNoExt;

            final artist = (tag?.trackArtist != null && tag!.trackArtist!.trim().isNotEmpty)
                ? tag.trackArtist!.trim()
                : 'Unknown Artist';

            final album = (tag?.album != null && tag!.album!.trim().isNotEmpty)
                ? tag.album!.trim()
                : 'Unknown Album';

            final albumArtist = (tag?.albumArtist != null && tag!.albumArtist!.trim().isNotEmpty)
                ? tag.albumArtist!.trim()
                : artist;

            final durationSeconds = tag?.duration ?? 0;
            final durationMs = durationSeconds > 0 ? durationSeconds * 1000 : 0;
            final trackNumber = tag?.trackNumber ?? 0;
            final trackTotal = tag?.trackTotal ?? 0;
            final discNumber = tag?.discNumber ?? 1;
            final discTotal = tag?.discTotal ?? 1;
            final year = tag?.year ?? 0;
            final genre = tag?.genre ?? '';

            final songId = filePath.hashCode.abs();
            final albumId = '${albumArtist.toLowerCase()}|${album.toLowerCase()}'.hashCode.abs();
            final artistId = artist.toLowerCase().hashCode.abs();
            final genreId = genre.toLowerCase().hashCode.abs();

            final songMap = <dynamic, dynamic>{
              '_id': songId,
              '_data': filePath,
              '_uri': Uri.file(filePath).toString(),
              '_display_name': baseName,
              '_display_name_wo_ext': baseNameNoExt,
              '_size': req['size'],
              'title': title,
              'artist': artist,
              'artist_id': artistId,
              'album': album,
              'album_id': albumId,
              'album_artist': albumArtist,
              'duration': durationMs,
              'track': trackNumber,
              'track_total': trackTotal,
              'disc_number': discNumber,
              'disc_total': discTotal,
              'year': year,
              'genre': genre,
              'genre_id': genreId,
              'file_extension': ext,
              'date_added': req['dateAdded'],
              'date_modified': req['modified'],
              'is_music': true,
              'is_alarm': false,
              'is_notification': false,
              'is_podcast': false,
              'is_ringtone': false,
            };
            results.add({
              'cacheKey': filePath,
              'modified': req['modified'],
              'size': req['size'],
              'meta': songMap,
            });
          }
          return results;
        });

        for (final res in parsedMaps) {
          _metaBox?.put(res['cacheKey'], {
            'modified': res['modified'],
            'size': res['size'],
            'meta': res['meta'],
          });
          final song = SongModel(res['meta']);
          _songPathById[song.id] = res['cacheKey'] as String;
          songs.add(song);
          
          final albumId = song.albumId ?? 0;
          albumSongsMap.putIfAbsent(albumId, () => []).add(song);
        }
      }
    }

    // Build AlbumModels
    for (final entry in albumSongsMap.entries) {
      final albumId = entry.key;
      final albumSongList = entry.value;
      if (albumSongList.isEmpty) continue;

      final firstSong = albumSongList.first;
      final albumName = firstSong.album ?? 'Unknown Album';
      final albumArtist = firstSong.getMap['album_artist']?.toString() ??
          firstSong.artist ??
          'Unknown Artist';
      final artistId = firstSong.artistId ?? 0;

      _representativeSongByAlbumId[albumId] = firstSong.data;

      int minYear = 9999;
      int maxYear = 0;
      for (final s in albumSongList) {
        final y = s.getMap['year'] is int ? s.getMap['year'] as int : 0;
        if (y > 0) {
          if (y < minYear) minYear = y;
          if (y > maxYear) maxYear = y;
        }
      }
      if (minYear == 9999) minYear = 0;

      final albumInfo = <dynamic, dynamic>{
        '_id': albumId,
        'album': albumName,
        'artist': albumArtist,
        'artist_id': artistId,
        'numsongs': albumSongList.length,
        'minyear': minYear,
        'maxyear': maxYear,
        'album_art': firstSong.data,
      };

      albumMap[albumId] = AlbumModel(albumInfo);
    }

    return LocalScanResult(
      songs: songs,
      albums: albumMap.values.toList(),
    );
  }

  void _collectAudioFiles(
    Directory dir,
    List<File> result,
    Set<String> visitedPaths,
    Set<String>? excludedFolders,
  ) {
    try {
      final entries = dir.listSync(followLinks: false);
      for (final entry in entries) {
        final normalized = entry.path.replaceAll('\\', '/');
        final baseName = p.basename(entry.path);

        // Skip hidden folders and files
        if (baseName.startsWith('.')) continue;

        if (entry is Directory) {
          if (excludedFolders != null &&
              excludedFolders.any((ex) => normalized.startsWith(ex))) {
            continue;
          }
          if (visitedPaths.add(normalized)) {
            _collectAudioFiles(entry, result, visitedPaths, excludedFolders);
          }
        } else if (entry is File) {
          final ext = p.extension(entry.path).toLowerCase();
          if (supportedExtensions.contains(ext)) {
            if (visitedPaths.add(normalized)) {
              result.add(entry);
            }
          }
        }
      }
    } catch (_) {
      // Ignore unreadable directories
    }
  }



  /// Resolves artwork bytes for a given song or album on Linux / Desktop.
  Future<Uint8List?> getArtworkBytes(int id, {ArtworkType type = ArtworkType.AUDIO}) async {
    // 1. Check CachingService memory cache
    final key = '${type.name}_$id';
    final cached = CachingService().thumbnailCache[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    String? filePath;
    if (type == ArtworkType.AUDIO) {
      filePath = _songPathById[id];
    } else if (type == ArtworkType.ALBUM) {
      filePath = _representativeSongByAlbumId[id] ?? _songPathById[id];
    }

    if (filePath == null || !File(filePath).existsSync()) {
      return null;
    }

    Uint8List? artworkBytes;

    // 2. Try embedded tag artwork
    try {
      final tag = await AudioTags.read(filePath);
      if (tag != null && tag.pictures.isNotEmpty) {
        // Find front cover or fallback to first picture
        final front = tag.pictures.firstWhere(
          (p) => p.pictureType == PictureType.coverFront,
          orElse: () => tag.pictures.first,
        );
        artworkBytes = front.bytes;
      }
    } catch (_) {}

    // 3. If no embedded artwork, check album folder for image files
    if (artworkBytes == null) {
      try {
        final parentDir = File(filePath).parent;
        for (final coverName in coverFilenames) {
          final coverFile = File(p.join(parentDir.path, coverName));
          if (coverFile.existsSync()) {
            artworkBytes = await coverFile.readAsBytes();
            break;
          }
        }
      } catch (_) {}
    }

    if (artworkBytes == null) {
      artworkBytes = Uint8List(0);
    }
    
    CachingService().thumbnailCache[key] = artworkBytes;
    CachingService().highResCache[key] = artworkBytes;

    return artworkBytes.isEmpty ? null : artworkBytes;
  }

  void registerSongPath(int id, String path) {
    _songPathById[id] = path;
  }

  void registerAlbumRepresentativePath(int albumId, String path) {
    _representativeSongByAlbumId[albumId] = path;
  }
}
