import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../main.dart';
import '../../utils/tag_write_access.dart';
import '../../widgets/song_options_sheet.dart';
import '../local_audio_scanner.dart';
import '../playback_controller.dart';

/// Mixin handling tag editing flows, in-place metadata updates,
/// audio playback suspension during file writes, and song options sheet.
mixin TagEditorStateMixin on ChangeNotifier {
  // Dependencies satisfied by AppStateController or NavigationStateMixin:
  BuildContext get context;
  List<SongModel> get songs;
  set songs(List<SongModel> value);
  void recomputeAllData();
  void enterSelectionMode({int? initialSongId});
  Future<void> openNowPlaying(SongModel song);
  void openAlbumPageFromSong(SongModel song);
  void openArtistPageFromSong(SongModel song);

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
      onPlaySong: () => playbackController.playSong(index),
    );
  }

  void updateSongMetadataInPlace(SongModel updatedSong) {
    updateSongsMetadataInPlace([updatedSong]);
  }

  void updateSongsMetadataInPlace(List<SongModel> updatedSongs) {
    if (updatedSongs.isEmpty) return;

    final updatedById = <int, SongModel>{
      for (final s in updatedSongs) s.id: s,
    };
    final updatedByPath = <String, SongModel>{
      for (final s in updatedSongs) s.data: s,
    };

    SongModel? findUpdated(SongModel s) =>
        updatedById[s.id] ?? updatedByPath[s.data];

    // 1. Update in songs list
    final newSongs = List<SongModel>.from(songs);
    bool changedSongs = false;
    for (int i = 0; i < newSongs.length; i++) {
      final u = findUpdated(newSongs[i]);
      if (u != null) {
        newSongs[i] = u;
        changedSongs = true;
      }
    }
    if (changedSongs) {
      songs = newSongs;
    }

    // 2. Update in playbackController.songs
    final newCtrlSongs = List<SongModel>.from(playbackController.songs);
    bool changedCtrl = false;
    for (int i = 0; i < newCtrlSongs.length; i++) {
      final u = findUpdated(newCtrlSongs[i]);
      if (u != null) {
        newCtrlSongs[i] = u;
        changedCtrl = true;
      }
    }
    if (changedCtrl) {
      playbackController.songs = newCtrlSongs;
    }

    // 3. Update in playbackController.currentQueue
    final newQueue = List<SongModel>.from(playbackController.currentQueue);
    bool changedQueue = false;
    for (int i = 0; i < newQueue.length; i++) {
      final u = findUpdated(newQueue[i]);
      if (u != null) {
        newQueue[i] = u;
        changedQueue = true;
      }
    }
    if (changedQueue) {
      playbackController.currentQueue = newQueue;
    }

    // 4. Update albumMap in playbackController
    for (final u in updatedSongs) {
      final aId = u.albumId;
      if (aId != null && playbackController.albumMap.containsKey(aId)) {
        final oldAlbum = playbackController.albumMap[aId]!;
        final m = Map<dynamic, dynamic>.from(oldAlbum.getMap);
        if (u.album != null && u.album!.isNotEmpty) m['album'] = u.album;
        final a = (u.getMap['album_artist'] ?? u.artist)?.toString();
        if (a != null && a.isNotEmpty) m['artist'] = a;
        playbackController.albumMap[aId] = AlbumModel(m);
      }
    }

    // 5. Update desktop scanner cache if running on desktop
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      for (final u in updatedSongs) {
        LocalAudioScanner.instance.updateCachedSong(
          path: u.data,
          song: u,
        );
      }
    }

    // 6. Recompute library structure, album/artist views, and refresh UI instantaneously
    recomputeAllData();

    notifyListeners();
  }

  Future<void> runWithPlaybackSuspendedForTagWrite(
    Future<void> Function() action, {
    String? targetFilePath,
  }) async {
    final currentPlayingPath = playbackController.currentSong?.data;
    // If targetFilePath is specified and is NOT the song currently loaded in player,
    // execute directly without interrupting playback!
    if (targetFilePath != null &&
        targetFilePath.isNotEmpty &&
        currentPlayingPath != null &&
        currentPlayingPath != targetFilePath) {
      await action();
      return;
    }

    await _executeWithSuspendedPlayback(action);
  }

  Future<void> runWithPlaybackSuspendedForBatchTagWrite(
    Future<void> Function() action, {
    Set<String>? targetFilePaths,
    int itemCount = 1,
  }) async {
    final currentPlayingPath = playbackController.currentSong?.data;
    if (targetFilePaths != null &&
        targetFilePaths.isNotEmpty &&
        currentPlayingPath != null &&
        !targetFilePaths.contains(currentPlayingPath)) {
      await action();
      return;
    }

    final dynamicTimeout = Duration(
      seconds: 120 + (itemCount * 10),
    );
    await _executeWithSuspendedPlayback(action, timeout: dynamicTimeout);
  }

  Future<void> _executeWithSuspendedPlayback(
    Future<void> Function() action, {
    Duration timeout = tagWriteTimeout,
  }) async {
    final handler = audioHandler;
    final shouldSuspend =
        handler != null && handler.player == playbackController.player;
    final restoreSource = playbackController.player.audioSource;
    final hasLoaded =
        playbackController.player.processingState != ProcessingState.idle &&
        restoreSource != null;
    if (!hasLoaded) {
      await action();
      return;
    }

    final wasPlaying = playbackController.player.playing;
    final index = playbackController.player.currentIndex;
    final pos = playbackController.player.position;

    playbackController.setSuppressIndexUpdates(true);
    try {
      pushAutoExitSuppress();
      if (shouldSuspend) handler.setStateBroadcastSuspended(true);
      await detachPlayerForTagWrite(playbackController.player).timeout(
        tagDetachTimeout,
        onTimeout: () {
          debugPrint('Timed out detaching player for tag write.');
        },
      );

      await action().timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('Tag write timed out. Please try again.');
        },
      );
    } finally {
      popAutoExitSuppress();
      if (shouldSuspend) handler.setStateBroadcastSuspended(false);
      try {
        await restorePlayerAfterTagWrite(
          playbackController.player,
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
        playbackController.setSuppressIndexUpdates(false);
      }
    }
  }
}

