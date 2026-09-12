import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../data/models/user_playlist.dart';
import '../utils/song_sort_utils.dart';

/// Pure helper functions for computing and querying smart playlists
/// (Most Played, Recently Played, and Recently Added).
class SmartPlaylistHelper {
  SmartPlaylistHelper._();

  /// Filters and sorts songs by play count descending.
  static List<SongModel> computeMostPlayed({
    required List<SongModel> songs,
    required Map<int, int> playCounts,
  }) {
    return songs.where((s) => (playCounts[s.id] ?? 0) > 0).toList()
      ..sort((a, b) {
        final ac = playCounts[a.id] ?? 0;
        final bc = playCounts[b.id] ?? 0;
        final comp = bc.compareTo(ac);
        if (comp != 0) return comp;
        final t = compareSortStrings(a.title, b.title);
        if (t != 0) return t;
        return a.id.compareTo(b.id);
      });
  }

  /// Filters and sorts songs by last played timestamp descending.
  static List<SongModel> computeRecentlyPlayed({
    required List<SongModel> songs,
    required Map<int, int> lastPlayedTimestamps,
  }) {
    return songs.where((s) => (lastPlayedTimestamps[s.id] ?? 0) > 0).toList()
      ..sort((a, b) {
        final at = lastPlayedTimestamps[a.id] ?? 0;
        final bt = lastPlayedTimestamps[b.id] ?? 0;
        final comp = bt.compareTo(at);
        if (comp != 0) return comp;
        return a.id.compareTo(b.id);
      });
  }

  /// Returns user-facing metadata (title, description, icon) for a smart playlist kind.
  static ({String title, String description, IconData icon}) metadataForKind(
    SmartPlaylistKind kind,
  ) {
    return switch (kind) {
      SmartPlaylistKind.mostPlayed => (
          title: 'Most played',
          description: 'Your top tracks based on how often you play them',
          icon: Icons.local_fire_department_rounded,
        ),
      SmartPlaylistKind.recentlyPlayed => (
          title: 'Recently played',
          description: 'Tracks you listened to recently on this device',
          icon: Icons.history_rounded,
        ),
      SmartPlaylistKind.recentlyAdded => (
          title: 'Recently added',
          description: 'Tracks added in the last 30 days',
          icon: Icons.new_releases_rounded,
        ),
    };
  }
}

