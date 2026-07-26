
import 'dart:async';

import 'package:audiotags/audiotags.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart';
import 'file_ops.dart';


const Duration tagWriteTimeout = Duration(seconds: 12);
const Duration tagDetachTimeout = Duration(milliseconds: 2500);
const Duration tagRestoreTimeout = Duration(seconds: 4);
const Duration tagScanTimeout = Duration(milliseconds: 3500);

Future<void> writeTagsSafelyWithBackup(
  String path,
  Tag tag, {
  required Future<bool> Function() verify,
}) async {
  // This should be unreachable on web since tag editing is blocked.
  if (kIsWeb) {
    throw UnsupportedError('Tag editing is not supported on web builds.');
  }

  final backupPath = '$path.bak_${DateTime.now().millisecondsSinceEpoch}';
  await copyFile(path, backupPath);

  try {
    await AudioTags.write(path, tag);
    final ok = await verify();
    if (!ok) {
      throw Exception(
        'Write verification failed. The file may not be writable right now.',
      );
    }

    // Best-effort cleanup.
    try {
      await deleteFile(backupPath);
    } catch (_) {}
  } catch (_) {
    // Restore original if anything went wrong. If restore fails, still rethrow.
    try {
      await copyFile(backupPath, path);
    } catch (_) {}
    rethrow;
  }
}

Future<void> detachPlayerForTagWrite(AudioPlayer player) async {
  try {
    await player.pause();
  } catch (_) {}
  try {
    await player.stop();
  } catch (_) {}
  try {
    await player.setAudioSource(
      ConcatenatingAudioSource(children: []),
      preload: false,
    );
  } catch (_) {}

  // Give the platform a moment to release file handles.
  await Future<void>.delayed(const Duration(milliseconds: 150));
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

Future<bool> ensureTagWriteAccess(BuildContext context, String data) async {
  if (kIsWeb) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tag editing is not supported on web builds.'),
      ),
    );
    return false;
  }

  if (data.startsWith('content:')) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This track is provided via a content URI. Editing tags requires direct file access.',
        ),
      ),
    );
    return false;
  }

  if (defaultTargetPlatform != TargetPlatform.android) return true;

  // audiotags writes via file I/O. On Android 11+ this typically requires All Files Access.
  final manage = await Permission.manageExternalStorage.status;
  if (manage.isGranted) return true;

  final requested = await Permission.manageExternalStorage.request();
  if (requested.isGranted) return true;

  // Fallback for older devices.
  final storage = await Permission.storage.request();
  if (storage.isGranted) return true;

  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text(
        'Permission denied. Enable “All files access” to edit tags.',
      ),
      action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
    ),
  );
  return false;
}
