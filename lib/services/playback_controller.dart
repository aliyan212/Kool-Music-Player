import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/sort_mode.dart';
import 'app_local_store.dart';

/// Comprehensive audio playback controller.
///
/// Owns the [AudioPlayer] lifecycle, exposes reactive state via
/// [ValueNotifier]s, and provides all play/pause/seek/queue/sort
/// operations that the UI needs.
class PlaybackController {
  PlaybackController({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  // ── Core player ────────────────────────────────────────────────────
  final AudioPlayer _player;
  AudioPlayer get player => _player;

  // ── Streams ────────────────────────────────────────────────────────
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
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
  SequenceState? get sequenceState => _player.sequenceState;
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

  // ── Library & playlist state ───────────────────────────────────────
  List<SongModel> songs = [];
  Map<int, AlbumModel> albumMap = {};
  ConcatenatingAudioSource? libraryPlaylist;
  ConcatenatingAudioSource? currentPlaylist;
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
      final nowPlaying = state.playing;
      if (!_wasPlaying && nowPlaying) {
        final id = currentSongId ?? _currentSongIdFromPlayer();
        if (id != null) recordPlayForSongId(id);
      }
      _wasPlaying = nowPlaying;
      _hasStartedPlayback = _hasStartedPlayback || state.playing;
    });
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

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
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
    if (seq == null || seq.isEmpty) return null;
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
    if (seq == null || seq.isEmpty) return;
    if (playerIndex < 0 || playerIndex >= seq.length) return;

    final songId = songIdFromTag(seq[playerIndex].tag);
    if (songId == null) return;
    currentSongId = songId;

    if (_suppressIndexUpdates) return;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);
    if (libraryIndex >= 0) currentPlayIndex = libraryIndex;
  }

  void _syncLibraryCurrentIndexFromSequenceState(SequenceState? state) {
    final songId = songIdFromTag(state?.currentSource?.tag);
    if (songId == null) return;
    currentSongId = songId;

    if (_suppressIndexUpdates) return;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);
    if (libraryIndex >= 0) currentPlayIndex = libraryIndex;
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

  ConcatenatingAudioSource buildPlaylist(List<SongModel> list) {
    return ConcatenatingAudioSource(
      children: list.map(sourceForSong).toList(),
    );
  }

  // ── Play song ──────────────────────────────────────────────────────

  Future<void> playSong(int index) async {
    if (index < 0 || index >= songs.length) return;
    currentSongId = songs[index].id;
    currentPlayIndex = index;

    try {
      _suppressIndexUpdates = true;
      final activeLibrary = libraryPlaylist;
      if (_player.audioSource != activeLibrary) {
        currentPlaylist = activeLibrary;
        await _player.setAudioSource(
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

    final newPlaylist = buildPlaylist(queue);
    final songId = queue[initialIndex].id;
    final libraryIndex = songs.indexWhere((s) => s.id == songId);

    currentPlaylist = newPlaylist;
    currentPlayIndex = libraryIndex >= 0 ? libraryIndex : null;
    currentSongId = songId;

    try {
      _suppressIndexUpdates = true;
      await _player.setAudioSource(
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
    if (currentPlaylist == null || _player.currentIndex == null) return;
    final insertAt = (_player.currentIndex! + 1).clamp(
      0,
      currentPlaylist!.length,
    );
    try {
      await currentPlaylist!.insert(insertAt, sourceForSong(song));
    } catch (_) {}
  }

  Future<void> addToQueueEnd(SongModel song) async {
    if (currentPlaylist == null) return;
    try {
      await currentPlaylist!.add(sourceForSong(song));
    } catch (_) {}
  }

  // ── Sort ───────────────────────────────────────────────────────────

  Future<void> applySort(SortMode mode) async {
    if (songs.isEmpty || currentPlaylist == null) return;
    final currentId =
        (currentPlayIndex != null &&
            currentPlayIndex! >= 0 &&
            currentPlayIndex! < songs.length)
        ? songs[currentPlayIndex!].id
        : null;
    final wasPlaying = _player.playing;
    final pos = _player.position;

    sortMode = mode;

    songs.sort((a, b) {
      switch (mode) {
        case SortMode.artist:
          final c = _cs(a.artist ?? '', b.artist ?? '');
          if (c != 0) return c;
          return _cs(a.title, b.title);
        case SortMode.albumArtist:
          final c = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (c != 0) return c;
          final ac = _cs(a.album ?? '', b.album ?? '');
          if (ac != 0) return ac;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
        case SortMode.year:
          final yc = _yearForCompare(a).compareTo(_yearForCompare(b));
          if (yc != 0) return yc;
          final ac = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (ac != 0) return ac;
          final alc = _cs(a.album ?? '', b.album ?? '');
          if (alc != 0) return alc;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
        case SortMode.albumArtistYear:
        default:
          final ac = _cs(_albumArtistFor(a), _albumArtistFor(b));
          if (ac != 0) return ac;
          final yc = _yearForCompare(a).compareTo(_yearForCompare(b));
          if (yc != 0) return yc;
          final alc = _cs(a.album ?? '', b.album ?? '');
          if (alc != 0) return alc;
          final tc = _compareDiscAndTrack(a, b);
          if (tc != 0) return tc;
          return _cs(a.title, b.title);
      }
    });

    currentPlaylist = buildPlaylist(songs);

    int? newIndex;
    if (currentId != null) {
      newIndex = songs.indexWhere((s) => s.id == currentId);
      if (newIndex < 0) newIndex = null;
    }

    if (newIndex != null) {
      await _player.setAudioSource(
        currentPlaylist!,
        initialIndex: newIndex,
      );
      await _player.seek(pos, index: newIndex);
      if (wasPlaying) await _player.play();
      currentPlayIndex = newIndex;
    } else {
      await _player.setAudioSource(currentPlaylist!);
      currentPlayIndex = null;
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
      decodedCounts = _decodeIntMap(jsonEncode(loaded['counts']));
      decodedLastPlayed =
          _decodeIntMap(jsonEncode(loaded['last_played']));
    } else {
      final prefs = await SharedPreferences.getInstance();
      final playCountsRaw = prefs.getString('play_counts_v1');
      final lastPlayedRaw = prefs.getString('last_played_ms_v1');
      decodedCounts = _decodeIntMap(playCountsRaw);
      decodedLastPlayed = _decodeIntMap(lastPlayedRaw);
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
  }

  Map<int, int> _decodeIntMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <int, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <int, int>{};
      final out = <int, int>{};
      for (final entry in decoded.entries) {
        final key = int.tryParse(entry.key.toString());
        if (key == null) continue;
        final value = entry.value;
        final v =
            value is int ? value : int.tryParse(value.toString());
        if (v == null) continue;
        out[key] = v;
      }
      return out;
    } catch (_) {
      return <int, int>{};
    }
  }

  // ── Suppress index updates ─────────────────────────────────────────

  void setSuppressIndexUpdates(bool v) => _suppressIndexUpdates = v;
  bool get suppressIndexUpdates => _suppressIndexUpdates;

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

  static final RegExp _yearRegex = RegExp(r'(19|20)\d{2}');

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
        lower == 'unknown album') return '';
    return t;
  }

  int _yearFromSong(SongModel s) {
    final v = s.getMap['year'];
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

  String _albumArtistFor(SongModel s) {
    final raw = s.getMap['album_artist']?.toString();
    final fromSong = _normalizeSortText(raw ?? '');
    if (fromSong.isNotEmpty) return fromSong;
    final fromAlbum =
        _normalizeSortText(albumMap[s.albumId]?.artist ?? '');
    if (fromAlbum.isNotEmpty) return fromAlbum;
    return _normalizeSortText(s.artist ?? '');
  }

  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final aDisc =
        a.getMap['disc_number'] is int
            ? a.getMap['disc_number'] as int
            : 0;
    final bDisc =
        b.getMap['disc_number'] is int
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
    return (an == 0 ? 99999 : an).compareTo(bn == 0 ? 99999 : bn);
  }
}

/// Singleton instance for the app.
final playbackController = PlaybackController();
