
import 'dart:async';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart';
import 'file_ops.dart';


const Duration tagWriteTimeout = Duration(seconds: 15);
const Duration tagDetachTimeout = Duration(milliseconds: 3000);
const Duration tagRestoreTimeout = Duration(seconds: 5);
const Duration tagScanTimeout = Duration(milliseconds: 4000);

/// Writes [tag] to [path] with a timestamped backup, verification, and
/// automatic rollback on failure. Also triggers an Android MediaStore scan
/// so that Scoped Storage doesn't silently revert the change.
Future<void> writeTagsSafelyWithBackup(
  String path,
  Tag tag, {
  required Future<bool> Function() verify,
}) async {
  if (kIsWeb) {
    throw UnsupportedError('Tag editing is not supported on web builds.');
  }

  // Ensure the file exists and is writable before attempting.
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('File not found', path);
  }

  final backupPath = '$path.bak_${DateTime.now().millisecondsSinceEpoch}';
  await copyFile(path, backupPath);

  try {
    await AudioTags.write(path, tag);

    // Verify the write persisted.
    final ok = await verify();
    if (!ok) {
      throw Exception(
        'Write verification failed. The file may be locked or read-only.',
      );
    }

    // Trigger MediaStore re-scan so Android Scoped Storage picks up changes.
    await _scanMediaAfterWrite(path);

    // Best-effort cleanup of backup.
    try {
      await deleteFile(backupPath);
    } catch (_) {}
  } catch (e) {
    // Restore original on any failure.
    try {
      await copyFile(backupPath, path);
    } catch (restoreErr) {
      debugPrint('CRITICAL: Failed to restore backup for $path: $restoreErr');
    }
    rethrow;
  }
}

/// Scans the file into Android MediaStore so Scoped Storage recognizes
/// metadata changes and doesn't revert them.
Future<void> _scanMediaAfterWrite(String path) async {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    // First scan the specific file.
    await OnAudioQuery().scanMedia(path);
    // Also scan the parent directory to ensure the MediaStore database
    // re-indexes the file completely.
    final parent = File(path).parent.path;
    await OnAudioQuery().scanMedia(parent);
  } catch (e) {
    debugPrint('MediaStore scan warning (non-fatal): $e');
  }
}

/// Fully detaches the [player] from its current audio source to release
/// all native file handles before external tag writing.
///
/// This is more aggressive than just pausing — it stops playback, clears
/// the audio source entirely, and gives the platform time to close file
/// descriptors. On Android, this is essential because ExoPlayer holds
/// file handles even when paused/stopped with a loaded source.
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
    await player.setAudioSource(
      ConcatenatingAudioSource(children: []),
      preload: false,
    );
  } catch (_) {}

  // Step 3: Give the native layer time to actually close file descriptors.
  // 300ms is a safe minimum; on slow devices this may need more time.
  await Future<void>.delayed(const Duration(milliseconds: 300));
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

Future<void> runWithPlayerPlaybackSuspended(
  AudioPlayer player,
  AudioSource? playlist,
  Future<void> Function() action,
) async {
  final handler = audioHandler;
  final shouldSuspend = handler != null && handler.player == player;
  final restoreSource = playlist ?? player.audioSource;
  final hasLoaded =
      player.processingState != ProcessingState.idle && restoreSource != null;
  if (!hasLoaded) {
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
