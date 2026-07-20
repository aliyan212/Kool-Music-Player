import 'package:hive_flutter/hive_flutter.dart';

class AppLocalStore {
  AppLocalStore._();

  static final AppLocalStore instance = AppLocalStore._();

  static const String _metaBoxName = 'app_meta';
  static const String _playHistoryBoxName = 'play_history';
  static const String _playlistsBoxName = 'playlists';
  static const String _kMigratedPlayHistory = 'migrated_play_history_v1';
  static const String _kMigratedUserPlaylists = 'migrated_user_playlists_v1';

  Box<dynamic>? _metaBox;
  Box<dynamic>? _playHistoryBox;
  Box<dynamic>? _playlistsBox;

  Future<void> init() async {
    if (_metaBox != null && _playHistoryBox != null && _playlistsBox != null) return;
    await Hive.initFlutter();
    _metaBox = await Hive.openBox<dynamic>(_metaBoxName);
    _playHistoryBox = await Hive.openBox<dynamic>(_playHistoryBoxName);
    _playlistsBox = await Hive.openBox<dynamic>(_playlistsBoxName);
  }

  bool get isReady => _metaBox != null && _playHistoryBox != null && _playlistsBox != null;

  Future<Map<String, dynamic>?> readPlayHistory() async {
    final box = _playHistoryBox;
    if (box == null) return null;
    final counts = box.get('counts');
    final lastPlayed = box.get('last_played');
    if (counts is Map || lastPlayed is Map) {
      return <String, dynamic>{
        'counts': counts is Map ? Map<String, dynamic>.from(counts) : <String, dynamic>{},
        'last_played': lastPlayed is Map ? Map<String, dynamic>.from(lastPlayed) : <String, dynamic>{},
      };
    }
    return null;
  }

  Future<void> writePlayHistory({
    required Map<String, int> counts,
    required Map<String, int> lastPlayed,
  }) async {
    final box = _playHistoryBox;
    if (box == null) return;
    await box.put('counts', counts);
    await box.put('last_played', lastPlayed);
  }

  Future<List<dynamic>?> readUserPlaylists() async {
    final box = _playlistsBox;
    if (box == null) return null;
    final raw = box.get('items');
    if (raw is List) return List<dynamic>.from(raw);
    return null;
  }

  Future<void> writeUserPlaylists(List<Map<String, dynamic>> items) async {
    final box = _playlistsBox;
    if (box == null) return;
    await box.put('items', items);
  }

  bool get didMigratePlayHistory => _metaBox?.get(_kMigratedPlayHistory) == true;
  bool get didMigrateUserPlaylists => _metaBox?.get(_kMigratedUserPlaylists) == true;

  Future<void> markPlayHistoryMigrated() async {
    await _metaBox?.put(_kMigratedPlayHistory, true);
  }

  Future<void> markUserPlaylistsMigrated() async {
    await _metaBox?.put(_kMigratedUserPlaylists, true);
  }
}
