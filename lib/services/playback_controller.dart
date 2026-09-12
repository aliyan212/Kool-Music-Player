// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/sort_mode.dart';
import '../main.dart';
import '../utils/song_sort_utils.dart';
import 'app_local_store.dart';

/// Comprehensive audio playback controller.
///
/// Owns the [AudioPlayer] lifecycle, exposes reactive state via
/// [ValueNotifier]s, and provides all play/pause/seek/queue/sort
/// operations that the UI needs.
class PlaybackController {
  PlaybackController({AudioPlayer? player})
    : _player = player ?? AudioPlayer(handleInterruptions: false) {
    attachStreamListeners();
  }

  // ── Core player ────────────────────────────────────────────────────
  final AudioPlayer _player;
  AudioPlayer get player => _player;

  // ── Streams ────────────────────────────────────────────────────────
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  SequenceState? get sequenceState => _player.sequenceState;
  Stream<SequenceState?> get sequenceStateStream =>
      _player.sequenceStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<bool> get shuffleModeEnabledStream =>
      _player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  // ── Properties ─────────────────────────────────────────────────────
  bool get playing => _player.playing;
  ProcessingState get processingState => _player.processingState;
  int? get currentIndex => _player.currentIndex;
  List<IndexedAudioSource>? get sequence => _player.sequence;
  AudioSource? get audioSource => _player.audioSource;
  Duration? get position => _player.position;
  Duration? get duration => _player.duration;
  double get volume => _player.volume;
  bool get hasNext => _player.hasNext;
  bool get hasPrevious => _player.hasPrevious;
  bool get shuffleModeEnabled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;

  // ── Reactive state (ValueNotifiers for UI binding) ─────────────────
  final ValueNotifier<int?> currentSongIdNotifier =
      ValueNotifier<int?>(null);
  final ValueNotifier<int?> currentPlayIndexNotifier =
      ValueNotifier<int?>(null);

  int? get currentSongId => currentSongIdNotifier.value;
  set currentSongId(int? v) => currentSongIdNotifier.value = v;
  int? get currentPlayIndex => currentPlayIndexNotifier.value;
  set currentPlayIndex(int? v) => currentPlayIndexNotifier.value = v;

  SongModel? get currentSong {
    final idx = currentPlayIndex;
    if (idx != null && idx >= 0 && idx < songs.length) {
      return songs[idx];
    }
    final pIdx = _player.currentIndex;
    if (pIdx != null && pIdx >= 0 && pIdx < _currentQueue.length) {
      return _currentQueue[pIdx];
    }
    return null;
  }

  // ── Library & playlist state ───────────────────────────────────────
  List<SongModel> songs = [];
  List<SongModel> _currentQueue = [];
  List<SongModel> get currentQueue {
    if (_currentQueue.isNotEmpty) return _currentQueue;
    final seq = _player.sequence;
    if (seq.isNotEmpty) {
      final out = <SongModel>[];
      final songMap = {for (final s in songs) s.id: s};
      for (final src in seq) {
        final tag = src.tag;
        if (tag is SongModel) {
          out.add(tag);
        } else if (tag is MediaItem) {
          final id = int.tryParse(tag.id);
          if (id != null && songMap.containsKey(id)) {
            out.add(songMap[id]!);
          }
        }
      }
      if (out.isNotEmpty) {
        _currentQueue = out;
        return _currentQueue;
      }
    }
    return songs;
  }
  set currentQueue(List<SongModel> list) => _currentQueue = list;

  Map<int, AlbumModel> albumMap = {};
  List<AudioSource>? libraryPlaylist;
  List<AudioSource>? currentPlaylist;
  bool _isLibraryActive = false;
  bool get isLibraryActive => _isLibraryActive;
  SortMode sortMode = SortMode.albumArtistYear;
  bool isLoading = true;

  // ── Internal stream subs ───────────────────────────────────────────
  StreamSubscription<int?>? _currentIndexSub;
  StreamSubscription<SequenceState?>? _sequenceStateSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  bool _suppressIndexUpdates = false;
  bool _hasStartedPlayback = false;
  bool _wasPlaying = false;

  // ── Play history ───────────────────────────────────────────────────
  final Map<int, int> _playCountBySongId = <int, int>{};
  final Map<int, int> _lastPlayedMsBySongId = <int, int>{};
  VoidCallback? onPlayHistoryUpdated;
  final Map<int, int> _lastRecordedPlayMsBySongId = <int, int>{};
  Timer? _playHistorySaveDebounce;
  static const int _minPlayRecordIntervalMs = 15000;

  Map<int, int> get playCountBySongId =>
      Map.unmodifiable(_playCountBySongId);
  Map<int, int> get lastPlayedMsBySongId =>
      Map.unmodifiable(_lastPlayedMsBySongId);

  // ── Initialization ─────────────────────────────────────────────────

  /// Attach stream listeners that keep [currentSongIdNotifier] /
  /// [currentPlayIndexNotifier] in sync with the player.
  void attachStreamListeners() {
    _currentIndexSub?.cancel();
    _sequenceStateSub?.cancel();
    _playerStateSub?.cancel();

    _currentIndexSub = _player.currentIndexStream.listen((index) {
      _syncLibraryCurrentIndexFromPlayer(index);
    });
    _sequenceStateSub =
        _player.sequenceStateStream.listen((state) {
      _syncLibraryCurrentIndexFromSequenceState(state);
    });
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        unawaited(_handlePlaybackCompleted());
        return;
      }
      final nowPlaying = state.playing;
      if (!_wasPlaying && nowPlaying) {
        final id = currentSongId ?? _currentSongIdFromPlayer();
        if (id != null) recordPlayForSongId(id);
      }
      _wasPlaying = nowPlaying;
      _hasStartedPlayback = _hasStartedPlayback || state.playing;
    });
  }

  bool _isHandlingCompletion = false;

  Future<void> _handlePlaybackCompleted() async {
    if (_isHandlingCompletion) return;
    _isHandlingCompletion = true;
    _wasPlaying = false;
    try {
      await _player.pause();
      await _player.seek(Duration.zero);
    } catch (_) {
    } finally {
      _isHandlingCompletion = false;
    }
  }

  void detachStreamListeners() {
    _currentIndexSub?.cancel();
    _currentIndexSub = null;
    _sequenceStateSub?.cancel();
    _sequenceStateSub = null;
    _playerStateSub?.cancel();
    _playerStateSub = null;
  }

  // ── Play / pause / seek ────────────────────────────────────────────

  bool get isActuallyPlaying =>
      _player.playing && _player.processingState != ProcessingState.completed;

  Future<void> play() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    return _player.play();
  }
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();

  Future<void> togglePlayPause() async {
    if (isActuallyPlaying) {
      await _player.pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration? position, {int? index}) =>
      _player.seek(position, index: index);

  Future<void> seekToNext() => _player.seekToNext();
  Future<void> seekToPrevious() => _player.seekToPrevious();

  Future<Duration?> setAudioSource(
    AudioSource source, {
    int? initialIndex,
    Duration? initialPosition,
    bool preload = true,
  }) {
    return _player.setAudioSource(
      source,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      preload: preload,
    );
  }

  Future<void> setVolume(double volume) => _player.setVolume(volume);
  Future<void> setShuffleModeEnabled(bool enabled) =>
      _player.setShuffleModeEnabled(enabled);
  Future<void> shuffle() => _player.shuffle();
  Future<void> setLoopMode(LoopMode mode) =>
      _player.setLoopMode(mode);

  // ── Index sync helpers ─────────────────────────────────────────────

  int? songIdFromTag(dynamic tag) {
    if (tag is SongModel) return tag.id;
    if (tag is MediaItem) return int.tryParse(tag.id);
    return null;
  }

  int? _currentSongIdFromPlayer() {
    final idx = _player.currentIndex;
    if (idx == null) return null;
    final seq = _player.sequence;
    if (seq.isEmpty) return null;
    if (idx < 0 || idx >= seq.length) return null;
    return songIdFromTag(seq[idx].tag);
  }

  void _syncLibraryCurrentIndexFromPlayer(int? playerIndex) {
    if (playerIndex == null) {
      currentPlayIndex = null;
      currentSongId = null;
      return;
    }
    final seq = _player.sequence;
    if (seq.isEmpty) return;
    if (playerIndex < 0 || playerIndex >= seq.length) return;

    final songId = songIdFromTag(seq[playerIndex].tag);
    if (songId == null) return;
    final idChanged = currentSongId != songId;
    currentSongId = songId;

    if (_suppressIndexUpdates) return;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);
    currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;

    if (idChanged && _player.playing) {
      recordPlayForSongId(songId);
    }
  }

  void _syncLibraryCurrentIndexFromSequenceState(SequenceState? state) {
    final songId = songIdFromTag(state?.currentSource?.tag);
    if (songId == null) return;
    final idChanged = currentSongId != songId;
    currentSongId = songId;

    if (_suppressIndexUpdates) return;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);
    currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;

    if (idChanged && _player.playing) {
      recordPlayForSongId(songId);
    }
  }

  // ── URI / media-item helpers ───────────────────────────────────────

  Uri songUri(SongModel song) {
    final primary = song.uri;
    if (primary != null && primary.isNotEmpty) {
      if (primary.startsWith('content:') || primary.startsWith('file:')) {
        return Uri.parse(primary);
      }
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return Uri.parse('content://media/external/audio/media/${song.id}');
    }
    final data = song.data;
    if (data.startsWith('content:') || data.startsWith('file:')) {
      return Uri.parse(data);
    }
    return Uri.file(data);
  }

  MediaItem toMediaItem(SongModel song) {
    final durationMs = song.duration;
    final artUri =
        (song.albumId != null && song.albumId! > 0)
            ? Uri.parse(
              'content://media/external/audio/albumart/${song.albumId}',
            )
            : null;
    return MediaItem(
      id: song.id.toString(),
      title: song.title,
      artist: song.artist ?? 'Unknown',
      album: song.album,
      duration:
          durationMs != null ? Duration(milliseconds: durationMs) : null,
      artUri: artUri,
    );
  }

  AudioSource sourceForSong(SongModel s) {
    final useBackground =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final uri = songUri(s);
    final tag = useBackground ? toMediaItem(s) : s;
    return AudioSource.uri(uri, tag: tag);
  }

  bool get useBackgroundTag =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // ── Playlist building ──────────────────────────────────────────────

  List<AudioSource> buildPlaylist(List<SongModel> list) {
    return list.map(sourceForSong).toList();
  }

  // ── Play song ──────────────────────────────────────────────────────

  Future<void> playSong(int index) async {
    if (index < 0 || index >= songs.length) return;
    currentSongId = songs[index].id;
    currentPlayIndex = index;
    _currentQueue = List<SongModel>.from(songs);

    try {
      _suppressIndexUpdates = true;
      final activeLibrary = libraryPlaylist;
      final isFullLibraryLoaded =
          _isLibraryActive && _player.audioSources.length == songs.length;
      if (!isFullLibraryLoaded && activeLibrary != null) {
        currentPlaylist = activeLibrary;
        _isLibraryActive = true;
        await _player.setAudioSources(
          currentPlaylist!,
          initialIndex: index,
        );
      } else {
        await _player.seek(Duration.zero, index: index);
      }
      await _player.play();
      recordPlayForSongId(songs[index].id);
    } catch (e, st) {
      debugPrint('Failed to play song index=$index: $e');
      debugPrintStack(stackTrace: st);
      currentPlayIndex = null;
    } finally {
      _suppressIndexUpdates = false;
      _syncLibraryCurrentIndexFromPlayer(_player.currentIndex);
    }
  }

  // ── Play from queue ────────────────────────────────────────────────

  Future<void> playFromQueue(
    List<SongModel> queue, {
    required int initialIndex,
  }) async {
    if (queue.isEmpty) return;
    if (initialIndex < 0 || initialIndex >= queue.length) return;

    _currentQueue = List<SongModel>.from(queue);
    final newPlaylist = buildPlaylist(queue);
    final songId = queue[initialIndex].id;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);

    _isLibraryActive = false;
    currentPlaylist = newPlaylist;
    currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;
    currentSongId = songId;

    try {
      _suppressIndexUpdates = true;
      await _player.setAudioSources(
        newPlaylist,
        initialIndex: initialIndex,
      );
      await _player.play();
      recordPlayForSongId(songId);
    } catch (e, st) {
      debugPrint(
        'Failed to play custom queue initialIndex=$initialIndex: $e',
      );
      debugPrintStack(stackTrace: st);
      currentPlayIndex = null;
    } finally {
      _suppressIndexUpdates = false;
      _syncLibraryCurrentIndexFromPlayer(_player.currentIndex);
    }
  }

  // ── Queue operations ───────────────────────────────────────────────

  Future<void> insertInQueue(SongModel song) async {
    if (_player.currentIndex == null) return;
    final insertAt = (_player.currentIndex! + 1).clamp(
      0,
      _player.audioSources.length,
    );
    if (_currentQueue.isNotEmpty && insertAt <= _currentQueue.length) {
      _currentQueue.insert(insertAt, song);
    }
    try {
      await _player.insertAudioSource(insertAt, sourceForSong(song));
    } catch (_) {}
  }

  Future<void> addToQueueEnd(SongModel song) async {
    if (_currentQueue.isNotEmpty) {
      _currentQueue.add(song);
    }
    try {
      await _player.addAudioSource(sourceForSong(song));
    } catch (_) {}
  }

  // ── Sort ───────────────────────────────────────────────────────────

  Future<void> applySort(SortMode mode) async {
    sortMode = mode;
    if (songs.isEmpty || currentPlaylist == null) return;
    final currentId =
        (currentPlayIndex != null &&
            currentPlayIndex! >= 0 &&
            currentPlayIndex! < songs.length)
        ? songs[currentPlayIndex!].id
        : null;
    final wasPlaying = _player.playing;
    final pos = _player.position;

    final albumYearMap = computeAlbumYearMap(songs);

    songs.sort((a, b) {
      switch (mode) {
        case SortMode.artist:
          final c = _cs(a.artist ?? '', b.artist ?? '');
          if (c != 0) return c;
          return _cs(a.title, b.title);
        case SortMode.albumArtist:
          final ac = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (ac != 0) return ac;

          final keyA = albumIdentityKey(a);
          final keyB = albumIdentityKey(b);
          if (keyA == keyB) {
            final tc = _compareDiscAndTrack(a, b);
            if (tc != 0) return tc;
            final tComp = _cs(a.title, b.title);
            if (tComp != 0) return tComp;
            return a.id.compareTo(b.id);
          }

          final alc = _cs(a.album ?? '', b.album ?? '');
          if (alc != 0) return alc;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
        case SortMode.year:
          final keyA = albumIdentityKey(a);
          final keyB = albumIdentityKey(b);
          if (keyA == keyB) {
            final tc = _compareDiscAndTrack(a, b);
            if (tc != 0) return tc;
            final tComp = _cs(a.title, b.title);
            if (tComp != 0) return tComp;
            return a.id.compareTo(b.id);
          }
          final ya = albumYearMap[keyA] ?? 99999;
          final yb = albumYearMap[keyB] ?? 99999;
          final yaVal = ya == 0 ? 99999 : ya;
          final ybVal = yb == 0 ? 99999 : yb;
          if (yaVal != ybVal) return yaVal.compareTo(ybVal);

          final ac = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (ac != 0) return ac;
          final alc = _cs(a.album ?? '', b.album ?? '');
          if (alc != 0) return alc;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
        case SortMode.albumArtistYear:
          final ac = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (ac != 0) return ac;

          final keyA = albumIdentityKey(a);
          final keyB = albumIdentityKey(b);
          if (keyA == keyB) {
            final tc = _compareDiscAndTrack(a, b);
            if (tc != 0) return tc;
            final tComp = _cs(a.title, b.title);
            if (tComp != 0) return tComp;
            return a.id.compareTo(b.id);
          }

          final ya = albumYearMap[keyA] ?? 99999;
          final yb = albumYearMap[keyB] ?? 99999;
          final yaVal = ya == 0 ? 99999 : ya;
          final ybVal = yb == 0 ? 99999 : yb;
          if (yaVal != ybVal) return yaVal.compareTo(ybVal);

          final alc = _cs(a.album ?? '', b.album ?? '');
          if (alc != 0) return alc;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
      }
    });

    currentPlaylist = buildPlaylist(songs);
    _isLibraryActive = true;
    _currentQueue = List<SongModel>.from(songs);

    int? newIndex;
    if (currentId != null) {
      newIndex = songs.indexWhere((s) => s.id == currentId);
      if (newIndex < 0) newIndex = null;
    }

    if (newIndex != null) {
      await _player.setAudioSources(
        currentPlaylist!,
        initialIndex: newIndex,
      );
      await _player.seek(pos, index: newIndex);
      if (wasPlaying) await _player.play();
      currentPlayIndex = newIndex;
    } else {
      currentPlayIndex = null;
      currentSongId = null;
      if (wasPlaying) {
        await _player.stop();
      }
    }
  }

  // ── Play count recording ───────────────────────────────────────────

  void recordPlayForSongId(int songId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastRecordedPlayMsBySongId[songId] ?? 0;
    if (now - last < _minPlayRecordIntervalMs) return;
    _lastRecordedPlayMsBySongId[songId] = now;
    _playCountBySongId[songId] =
        (_playCountBySongId[songId] ?? 0) + 1;
    _lastPlayedMsBySongId[songId] = now;
    _scheduleSavePlayHistory();
    onPlayHistoryUpdated?.call();
  }

  void _scheduleSavePlayHistory() {
    _playHistorySaveDebounce?.cancel();
    _playHistorySaveDebounce = Timer(
      const Duration(milliseconds: 700),
      _savePlayHistory,
    );
  }

  Future<void> _savePlayHistory() async {
    try {
      await AppLocalStore.instance.writePlayHistory(
        counts:
            _playCountBySongId.map((k, v) => MapEntry(k.toString(), v)),
        lastPlayed: _lastPlayedMsBySongId.map(
          (k, v) => MapEntry(k.toString(), v),
        ),
      );
    } catch (_) {}
  }

  Future<void> loadPlayHistory() async {
    final loaded = await AppLocalStore.instance.readPlayHistory();
    Map<int, int> decodedCounts = <int, int>{};
    Map<int, int> decodedLastPlayed = <int, int>{};

    if (loaded != null) {
      decodedCounts = _extractIntMap(loaded['counts']);
      decodedLastPlayed = _extractIntMap(loaded['last_played']);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final playCountsRaw = prefs.getString('play_counts_v1');
      final lastPlayedRaw = prefs.getString('last_played_ms_v1');
      decodedCounts = _extractIntMap(playCountsRaw);
      decodedLastPlayed = _extractIntMap(lastPlayedRaw);
      await AppLocalStore.instance.writePlayHistory(
        counts:
            decodedCounts.map((k, v) => MapEntry(k.toString(), v)),
        lastPlayed: decodedLastPlayed.map(
          (k, v) => MapEntry(k.toString(), v),
        ),
      );
      await AppLocalStore.instance.markPlayHistoryMigrated();
    }

    _playCountBySongId
      ..clear()
      ..addAll(decodedCounts);
    _lastPlayedMsBySongId
      ..clear()
      ..addAll(decodedLastPlayed);
    onPlayHistoryUpdated?.call();
  }

  Map<int, int> _extractIntMap(dynamic raw) {
    if (raw == null) return <int, int>{};
    Map<dynamic, dynamic> map;
    if (raw is Map) {
      map = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          map = decoded;
        } else {
          return <int, int>{};
        }
      } catch (_) {
        return <int, int>{};
      }
    } else {
      return <int, int>{};
    }

    final out = <int, int>{};
    for (final entry in map.entries) {
      final key = int.tryParse(entry.key.toString());
      if (key == null) continue;
      final val = entry.value;
      int? v;
      if (val is num) {
        v = val.toInt();
      } else if (val != null) {
        v = int.tryParse(val.toString()) ?? (double.tryParse(val.toString())?.toInt());
      }
      if (v == null) continue;
      out[key] = v;
    }
    return out;
  }

  // ── Suppress index updates ─────────────────────────────────────────

  void setSuppressIndexUpdates(bool v) => _suppressIndexUpdates = v;
  bool get suppressIndexUpdates => _suppressIndexUpdates;

  // ── Tag write playback suspension ─────────────────────────────────

  /// Safely suspends playback, releases native decoder file locks, runs [action],
  /// and seamlessly reconstructs fresh [AudioSource] instances to restore playback
  /// at the exact same track, position, and queue state.
  Future<void> runWithPlaybackSuspendedForTagWrite(
    Future<void> Function() action, {
    String? targetFilePath,
  }) async {
    final activeSong = currentSong;
    String? currentPlayingPath = activeSong?.data;
    if (currentPlayingPath == null && _player.currentIndex != null) {
      final pIdx = _player.currentIndex!;
      if (pIdx >= 0 && pIdx < _currentQueue.length) {
        currentPlayingPath = _currentQueue[pIdx].data;
      }
    }

    // If targetFilePath is specified and is NOT the song currently loaded in player,
    // execute directly without interrupting playback!
    if (targetFilePath != null &&
        targetFilePath.isNotEmpty &&
        currentPlayingPath != null &&
        currentPlayingPath != targetFilePath) {
      await action();
      return;
    }

    final hasLoaded = _player.processingState != ProcessingState.idle &&
        _player.audioSource != null &&
        _player.sequence.isNotEmpty;
    if (!hasLoaded) {
      await action();
      return;
    }

    final wasPlaying = _player.playing;
    final index = _player.currentIndex ?? 0;
    final pos = _player.position;
    final currentId = currentSongId;
    final activeQueue = List<SongModel>.from(currentQueue);

    setSuppressIndexUpdates(true);
    final handler = audioHandler;
    final shouldSuspendBroadcast =
        handler != null && handler.player == _player;

    try {
      pushAutoExitSuppress();
      if (shouldSuspendBroadcast) {
        handler.setStateBroadcastSuspended(true);
      }

      // Step 1: Pause and detach native decoder file lock
      try {
        await _player.pause();
      } catch (_) {}
      try {
        await _player.stop();
      } catch (_) {}
      try {
        await _player.setAudioSources([], preload: false);
      } catch (_) {}

      // Wait 200ms to allow native Android ExoPlayer / OS threads to close file descriptors.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Step 2: Perform tag/lyrics write action
      await action();
      // Step 2: Perform tag/lyrics write action with timeout guard
      await action().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          debugPrint('Tag write action timed out after 8s');
        },
      );
    } finally {
      popAutoExitSuppress();
      try {
        // Step 3: Rebuild FRESH playlist from activeQueue
        final queueToUse = activeQueue.isNotEmpty ? activeQueue : songs;
        final freshPlaylist = buildPlaylist(queueToUse);
        currentPlaylist = freshPlaylist;
        if (_isLibraryActive) {
          libraryPlaylist = freshPlaylist;
        }

        int targetIndex = index;
        if (currentId != null) {
          final foundIndex = queueToUse.indexWhere((s) => s.id == currentId);
          if (foundIndex != -1) targetIndex = foundIndex;
        }
        if (targetIndex >= freshPlaylist.length) {
          targetIndex = freshPlaylist.length - 1;
        }
        if (targetIndex < 0) targetIndex = 0;

        if (freshPlaylist.isNotEmpty) {
          await _player.setAudioSources(
            freshPlaylist,
            initialIndex: targetIndex,
            initialPosition: pos,
          );
          await _player
              .setAudioSources(
                freshPlaylist,
                initialIndex: targetIndex,
                initialPosition: pos,
              )
              .timeout(
                const Duration(seconds: 3),
                onTimeout: () {
                  debugPrint(
                    'Timed out restoring audio sources after tag write',
                  );
                  return null;
                },
              );
          if (wasPlaying) {
            await _player.play();
            unawaited(_player.play());
          }
        }
      } catch (e, st) {
        debugPrint('Failed to restore playback after tag write: $e');
        debugPrintStack(stackTrace: st);
      } finally {
        if (shouldSuspendBroadcast) {
          handler.setStateBroadcastSuspended(false);
        }
        setSuppressIndexUpdates(false);
        _syncLibraryCurrentIndexFromPlayer(_player.currentIndex);
      }
    }
  }

  // ── Dispose ────────────────────────────────────────────────────────

  Future<void> disposeController() async {
    _playHistorySaveDebounce?.cancel();
    detachStreamListeners();
    currentSongIdNotifier.dispose();
    currentPlayIndexNotifier.dispose();
    await _player.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  // Sort helpers (static / instance)
  // ═══════════════════════════════════════════════════════════════════

  static int _cs(String a, String b) => _compareSortStrings(a, b);

  static int _compareSortStrings(String a, String b) {
    final an = _normalizeSortText(a);
    final bn = _normalizeSortText(b);
    final ae = an.isEmpty;
    final be = bn.isEmpty;
    if (ae != be) return ae ? 1 : -1;
    final comp = an.toLowerCase().compareTo(bn.toLowerCase());
    return comp != 0 ? comp : an.compareTo(bn);
  }

  static String _normalizeSortText(String v) {
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

  String _albumArtistFor(SongModel s) {
    final raw =
        (s.getMap['album_artist'] ?? s.getMap['albumArtist'])?.toString();
    final fromSong = _normalizeSortText(raw ?? '');
    if (fromSong.isNotEmpty) return fromSong;
    final fromSongArtist = _normalizeSortText(s.artist ?? '');
    if (fromSongArtist.isNotEmpty) return fromSongArtist;
    final fromAlbum =
        _normalizeSortText(albumMap[s.albumId]?.artist ?? '');
    if (fromAlbum.isNotEmpty) return fromAlbum;
    return '';
  }

  int _discFromSong(SongModel s) {
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

  int _trackFromSong(SongModel s) {
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

  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final ad = _discFromSong(a);
    final bd = _discFromSong(b);
    if (ad != bd) return ad.compareTo(bd);

    final at = _trackFromSong(a);
    final bt = _trackFromSong(b);
    final fat = at == 0 ? 99999 : at;
    final fbt = bt == 0 ? 99999 : bt;
    if (fat != fbt) return fat.compareTo(fbt);

    final titleComp = _cs(a.title, b.title);
    if (titleComp != 0) return titleComp;
    return a.id.compareTo(b.id);
  }
}

/// Singleton instance for the app.
final playbackController = PlaybackController();
