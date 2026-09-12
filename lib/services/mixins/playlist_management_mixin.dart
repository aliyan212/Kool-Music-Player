import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/user_playlist.dart';
import '../../dialogs/playlist_dialogs.dart';
import '../../main.dart';
import '../../pages/playlist_page.dart';
import '../app_local_store.dart';
import '../playback_controller.dart';

/// Mixin handling user playlists, creation, deletion, renaming,
/// M3U importing, track additions, and playlist page routing.
mixin PlaylistManagementMixin on ChangeNotifier {
  // Dependencies satisfied by AppStateController or NavigationStateMixin:
  List<SongModel> get songs;
  void recomputeAllData();
  void showSnackBar(SnackBar snackBar, {BuildContext? context});
  void showInlineDetail(Widget detailContent);
  void closeInlineDetail();
  int get selectedTabIndex;
  void selectTab(int index);
  bool get nowPlayingRouteActive;
  Future<void> openNowPlaying(SongModel song);

  static const String _userPlaylistsKey = 'user_playlists_v1';
  final AppLocalStore _localStore = AppLocalStore.instance;

  List<UserPlaylist> userPlaylists = <UserPlaylist>[];
  Map<String, int> cachedUserPlaylistTrackCounts = <String, int>{};

  BuildContext get context => navigatorKey.currentContext!;

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
      notifyListeners();
    } catch (_) {
      userPlaylists = <UserPlaylist>[];
      recomputeAllData();
      notifyListeners();
    }
  }

  Future<void> saveUserPlaylists() async {
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
    await saveUserPlaylists();
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
    await saveUserPlaylists();
  }

  Future<void> deletePlaylist(UserPlaylist playlist) async {
    userPlaylists.removeWhere((p) => p.id == playlist.id);
    cachedUserPlaylistTrackCounts.remove(playlist.id);
    recomputeAllData();
    notifyListeners();
    await saveUserPlaylists();
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

  String _newPlaylistId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(1 << 32);
    return '${now}_$rand';
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
        showSnackBar(
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
        showSnackBar(
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
        showSnackBar(
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
      await saveUserPlaylists();

      showSnackBar(
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
      showSnackBar(
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
        player: playbackController.player,
        playlistId: playlistId,
        playlistName: playlist.name,
        initialSongIds: playlist.songIds,
        librarySongs: songs,
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
          await playbackController.playFromQueue(songs, initialIndex: initialIndex);
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
          await saveUserPlaylists();
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
    unawaited(saveUserPlaylists());
  }

  Future<UserPlaylist?> pickPlaylistOrCreate({
    required List<int> songIdsToAdd,
  }) async {
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
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return null;
      return promptCreatePlaylist(
        ctx,
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
      showSnackBar(
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
    await saveUserPlaylists();

    showSnackBar(
      SnackBar(
        content: Text(
          'Added $addedCount song${addedCount == 1 ? '' : 's'} to "${newPlaylist.name}"',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return true;
  }
}
