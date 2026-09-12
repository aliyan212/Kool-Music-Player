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
    // 1. Update in songs list
    final idx = songs.indexWhere(
      (s) => s.id == updatedSong.id || s.data == updatedSong.data,
    );
    if (idx != -1) {
      final newSongs = List<SongModel>.from(songs);
      newSongs[idx] = updatedSong;
      songs = newSongs;
    }

    // 2. Update in playbackController.songs
    final ctrlIdx = playbackController.songs.indexWhere(
      (s) => s.id == updatedSong.id || s.data == updatedSong.data,
    );
    if (ctrlIdx != -1) {
      final newCtrlSongs = List<SongModel>.from(playbackController.songs);
      newCtrlSongs[ctrlIdx] = updatedSong;
      playbackController.songs = newCtrlSongs;
    }

    // 3. Update desktop scanner cache if running on desktop
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      LocalAudioScanner.instance.updateCachedSong(
        path: updatedSong.data,
        song: updatedSong,
      );
    }

    // 4. Recompute library structure, album/artist views, and refresh UI instantaneously
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
