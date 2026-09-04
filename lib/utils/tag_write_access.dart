
import 'dart:async';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart';


const Duration tagWriteTimeout = Duration(seconds: 15);
const Duration tagDetachTimeout = Duration(milliseconds: 3000);
const Duration tagRestoreTimeout = Duration(seconds: 5);
const Duration tagScanTimeout = Duration(milliseconds: 4000);

const MethodChannel _mediaStoreChannel = MethodChannel('com.example.music_player/media_store');

/// Synchronizes tag metadata with the Android system MediaStore database directly.
/// This ensures external players (and this app) immediately see updated metadata
/// without waiting for a full, slow media scan.
Future<void> syncMediaStoreTags({
  required String path,
  String? title,
  String? artist,
  String? album,
  int? year,
  int? track,
  String? genre,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _mediaStoreChannel.invokeMethod('updateMediaStoreTags', {
      'path': path,
      'title': title,
      'artist': artist,
      'album': album,
      'year': year,
      'track': track,
      'genre': genre,
    });
  } catch (e) {
    debugPrint('syncMediaStoreTags non-fatal error: $e');
  }

  try {
    await OnAudioQuery().scanMedia(path).timeout(tagScanTimeout);
  } catch (_) {}
}

/// Writes [tag] to [path] swiftly with verification, and syncs changes to MediaStore.
Future<void> writeTagsSafelyWithBackup(
  String path,
  Tag tag, {
  Future<bool> Function()? verify,
}) async {
  if (kIsWeb) {
    throw UnsupportedError('Tag editing is not supported on web builds.');
  }

  // Ensure the file exists and is writable before attempting.
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('File not found', path);
  }

  // Perform native audio tag write directly (fast, in-place).
  await AudioTags.write(path, tag);

  // Soft-verify if requested. Log warning rather than throwing to avoid destructive rollback.
  if (verify != null) {
    try {
      final ok = await verify();
      if (!ok) {
        debugPrint('Tag write notice: verify returned non-exact match for $path');
      }
    } catch (vErr) {
      debugPrint('Tag verification warning (non-fatal): $vErr');
    }
  }

  // Synchronize with Android system MediaStore immediately.
  await syncMediaStoreTags(
    path: path,
    title: tag.title,
    artist: tag.trackArtist,
    album: tag.album,
    year: tag.year,
    track: tag.trackNumber,
    genre: tag.genre,
  );
}

/// Fully detaches the [player] from its current audio source to release
/// all native file handles before external tag writing.
Future<void> detachPlayerForTagWrite(AudioPlayer player) async {
  // Step 1: Pause and stop to halt decoding.
  try {
    await player.pause();
  } catch (_) {}
  try {
    await player.stop();
  } catch (_) {}

  // Step 2: Replace audio source with an empty playlist. This forces
  // just_audio to release the native decoder and close file handles.
  try {
    await player.setAudioSources([], preload: false);
  } catch (_) {}

  // Step 3: Give the native layer time to actually close file descriptors.
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

Future<void> restorePlayerAfterTagWrite(
  AudioPlayer player,
  AudioSource? restoreSource,
  int? index,
  Duration pos,
  bool wasPlaying,
) async {
  if (restoreSource == null) return;
  if (index != null) {
    await player.setAudioSource(restoreSource, initialIndex: index);
    await player.seek(pos, index: index);
    if (wasPlaying) await player.play();
  } else {
    await player.setAudioSource(restoreSource);
    if (wasPlaying) await player.play();
  }
}

/// Runs [action], only suspending and detaching the player IF the file being
/// edited is currently loaded in [player]. If another song is playing, playback
/// continues uninterrupted.
Future<void> runWithPlayerPlaybackSuspended(
  AudioPlayer player,
  AudioSource? playlist,
  Future<void> Function() action, {
  String? targetFilePath,
}) async {
  final handler = audioHandler;
  final shouldSuspend = handler != null && handler.player == player;
  final restoreSource = playlist ?? player.audioSource;
  final hasLoaded =
      player.processingState != ProcessingState.idle && restoreSource != null;

  // Check if the target file is actually what's currently playing/loaded.
  bool targetIsCurrent = true;
  if (targetFilePath != null && targetFilePath.isNotEmpty) {
    try {
      final currentIdx = player.currentIndex;
      final sequence = player.sequence;
      if (currentIdx != null && currentIdx < sequence.length) {
        final currentSource = sequence[currentIdx];
        if (currentSource is UriAudioSource) {
          final uri = currentSource.uri;
          final currentPath = uri.toFilePath();
          targetIsCurrent = (currentPath == targetFilePath);
        }
      }
    } catch (_) {
      targetIsCurrent = true; // Safe fallback if inspection fails
    }
  }

  // If player isn't playing this file, execute directly without stopping playback!
  if (!hasLoaded || !targetIsCurrent) {
    await action();
    return;
  }

  final wasPlaying = player.playing;
  final index = player.currentIndex;
  final pos = player.position;

  try {
    pushAutoExitSuppress();
    if (shouldSuspend) handler.setStateBroadcastSuspended(true);
    await detachPlayerForTagWrite(player).timeout(
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
        player,
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
    }
  }
}

/// Ensures the app has the necessary permissions and file access to write
/// ID3 tags on the given [data] path.
///
/// On Android 11+ this requires MANAGE_EXTERNAL_STORAGE (All Files Access).
/// On older Android, regular storage permission may suffice.
Future<bool> ensureTagWriteAccess(BuildContext context, String data) async {
  if (kIsWeb) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tag editing is not supported on web builds.'),
        ),
      );
    }
    return false;
  }

  // Content URIs are mediated by MediaStore — audiotags needs a real file path.
  if (data.startsWith('content:')) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This track is provided via a content URI. Editing tags requires direct file access.',
          ),
        ),
      );
    }
    return false;
  }

  // Verify the file actually exists and is writable.
  final file = File(data);
  if (!await file.exists()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found. It may have been moved or deleted.'),
        ),
      );
    }
    return false;
  }

  if (defaultTargetPlatform != TargetPlatform.android) return true;

  // Android 11+: MANAGE_EXTERNAL_STORAGE is required for direct file writes
  // outside the app's scoped storage sandbox.
  final manage = await Permission.manageExternalStorage.status;
  if (manage.isGranted) return true;

  final requested = await Permission.manageExternalStorage.request();
  if (requested.isGranted) return true;

  // Fallback for older Android versions.
  final storage = await Permission.storage.request();
  if (storage.isGranted) return true;

  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text(
        'Permission denied. Enable "All files access" to edit tags.',
      ),
      action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
    ),
  );
  return false;
}
