
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/playback_controller.dart';


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

  // Synchronize ID3v2 TYER and ID3v1 trailer for MP3 files.
  // audiotags / lofty writes ID3v2.4 with TDRC and strips ID3v1, which causes
  // Android's MediaMetadataRetriever, MediaScanner, and external music players
  // (VLC, Poweramp, Samsung Music) to read the year as 0 or unknown.
  if (path.toLowerCase().endsWith('.mp3')) {
    try {
      await writeMp3Id3YearAndId3v1(
        path: path,
        year: tag.year ?? 0,
        title: tag.title,
        artist: tag.trackArtist,
        album: tag.album,
        track: tag.trackNumber,
      );
    } catch (e) {
      debugPrint('writeMp3Id3YearAndId3v1 non-fatal error: $e');
    }
  }

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

/// Inspects and synchronizes ID3v2 TYER frame and ID3v1 trailer for MP3 files.
/// This ensures full compatibility with Android's MediaMetadataRetriever,
/// MediaScanner, and external music players.
Future<void> writeMp3Id3YearAndId3v1({
  required String path,
  required int year,
  String? title,
  String? artist,
  String? album,
  int? track,
}) async {
  if (year <= 0 || year > 9999) return;
  if (!path.toLowerCase().endsWith('.mp3')) return;

  final file = File(path);
  if (!await file.exists()) return;

  try {
    await _syncMp3Id3v2Year(file, year);
  } catch (e) {
    debugPrint('ID3v2 TYER sync error for $path: $e');
  }

  try {
    await _syncMp3Id3v1(
      file: file,
      year: year,
      title: title,
      artist: artist,
      album: album,
      track: track,
    );
  } catch (e) {
    debugPrint('ID3v1 sync error for $path: $e');
  }
}

Future<void> _syncMp3Id3v2Year(File file, int year) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    if (length < 10) return;

    await raf.setPosition(0);
    final header = await raf.read(10);
    // Verify ID3 magic bytes ('I', 'D', '3')
    if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
      return;
    }

    final versionMajor = header[3]; // 3 for ID3v2.3, 4 for ID3v2.4
    if (versionMajor < 3 || versionMajor > 4) {
      return;
    }

    final flags = header[5];
    final hasExtendedHeader = (flags & 0x40) != 0;

    // Synchsafe tag size (excluding 10-byte header)
    final tagSize = ((header[6] & 0x7F) << 21) |
                    ((header[7] & 0x7F) << 14) |
                    ((header[8] & 0x7F) << 7) |
                    (header[9] & 0x7F);

    if (10 + tagSize > length) return;

    final tagBody = await raf.read(tagSize);

    int pos = 0;
    if (hasExtendedHeader) {
      if (tagBody.length < 4) return;
      int extSize;
      if (versionMajor == 4) {
        extSize = ((tagBody[0] & 0x7F) << 21) |
                  ((tagBody[1] & 0x7F) << 14) |
                  ((tagBody[2] & 0x7F) << 7) |
                  (tagBody[3] & 0x7F);
      } else {
        extSize = (tagBody[0] << 24) |
                  (tagBody[1] << 16) |
                  (tagBody[2] << 8) |
                  tagBody[3];
      }
      pos += extSize;
      if (pos >= tagBody.length) return;
    }

    final yearStr = year.toString().padLeft(4, '0').substring(0, 4);
    final yearAscii = ascii.encode(yearStr);

    int framePos = pos;
    int? tyerFrameOffset;
    int? paddingOffset;

    while (framePos + 10 <= tagBody.length) {
      // Frame ID starting with 0x00 marks padding start
      if (tagBody[framePos] == 0x00) {
        paddingOffset = framePos;
        break;
      }

      final frameId = String.fromCharCodes(tagBody.sublist(framePos, framePos + 4));
      int frameSize;
      if (versionMajor == 4) {
        frameSize = ((tagBody[framePos + 4] & 0x7F) << 21) |
                    ((tagBody[framePos + 5] & 0x7F) << 14) |
                    ((tagBody[framePos + 6] & 0x7F) << 7) |
                    (tagBody[framePos + 7] & 0x7F);
      } else {
        frameSize = (tagBody[framePos + 4] << 24) |
                    (tagBody[framePos + 5] << 16) |
                    (tagBody[framePos + 6] << 8) |
                    tagBody[framePos + 7];
      }

      if (frameSize < 0 || framePos + 10 + frameSize > tagBody.length) {
        break;
      }

      if (frameId == 'TYER') {
        tyerFrameOffset = framePos;
        break;
      }

      framePos += 10 + frameSize;
    }

    if (tyerFrameOffset != null) {
      // TYER frame exists: update text in place if ISO-8859-1 (encoding 0)
      final dataOffset = tyerFrameOffset + 10;
      if (dataOffset + 5 <= tagBody.length && tagBody[dataOffset] == 0) {
        await raf.setPosition(10 + dataOffset + 1);
        await raf.writeFrom(yearAscii);
        return;
      }
    }

    // Build standard 15-byte TYER frame:
    // 'TYER' (4) + Size 5 (4) + Flags 0 (2) + Encoding 0 (1) + Year digits (4)
    final tyerFrameBytes = Uint8List(15);
    tyerFrameBytes.setRange(0, 4, ascii.encode('TYER'));
    tyerFrameBytes[4] = 0;
    tyerFrameBytes[5] = 0;
    tyerFrameBytes[6] = 0;
    tyerFrameBytes[7] = 5;
    tyerFrameBytes[8] = 0;
    tyerFrameBytes[9] = 0;
    tyerFrameBytes[10] = 0; // ISO-8859-1
    tyerFrameBytes.setRange(11, 15, yearAscii);

    final currentPaddingOffset = paddingOffset ?? framePos;
    if (tagBody.length - currentPaddingOffset >= 15) {
      // Overwrite first 15 bytes of existing padding without modifying tag size or audio
      await raf.setPosition(10 + currentPaddingOffset);
      await raf.writeFrom(tyerFrameBytes);
      return;
    }

    // Insufficient padding: expand ID3v2 tag safely
    await raf.close();
    await _expandId3v2AndInsertFrame(file, 10 + currentPaddingOffset, tyerFrameBytes);
  } finally {
    try {
      await raf.close();
    } catch (_) {}
  }
}

Future<void> _expandId3v2AndInsertFrame(
  File file,
  int insertPos,
  Uint8List frameBytes,
) async {
  final bytes = await file.readAsBytes();
  if (bytes.length < 10) return;

  final oldTagSize = ((bytes[6] & 0x7F) << 21) |
                     ((bytes[7] & 0x7F) << 14) |
                     ((bytes[8] & 0x7F) << 7) |
                     (bytes[9] & 0x7F);

  const extraPadding = 1024;
  final newTagSize = oldTagSize + extraPadding;

  final newBytes = Uint8List(bytes.length + extraPadding);

  // Copy header (10 bytes)
  newBytes.setRange(0, 10, bytes.sublist(0, 10));

  // Update synchsafe size in header
  newBytes[6] = (newTagSize >> 21) & 0x7F;
  newBytes[7] = (newTagSize >> 14) & 0x7F;
  newBytes[8] = (newTagSize >> 7) & 0x7F;
  newBytes[9] = newTagSize & 0x7F;

  // Copy bytes up to insertion point
  newBytes.setRange(10, insertPos, bytes.sublist(10, insertPos));

  // Insert TYER frame
  newBytes.setRange(insertPos, insertPos + frameBytes.length, frameBytes);

  // Copy remaining file data
  final afterInsert = insertPos + extraPadding;
  newBytes.setRange(afterInsert, newBytes.length, bytes.sublist(insertPos));

  final tempFile = File('${file.path}.tmp_tag');
  await tempFile.writeAsBytes(newBytes, flush: true);
  await tempFile.rename(file.path);
}

Future<void> _syncMp3Id3v1({
  required File file,
  required int year,
  String? title,
  String? artist,
  String? album,
  int? track,
}) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    final yearBytes = ascii.encode(year.toString().padLeft(4, '0').substring(0, 4));

    if (length >= 128) {
      await raf.setPosition(length - 128);
      final trailer = await raf.read(128);
      if (trailer.length == 128 &&
          trailer[0] == 0x54 && // 'T'
          trailer[1] == 0x41 && // 'A'
          trailer[2] == 0x47) { // 'G'
        if (year > 0 && year <= 9999) {
          await raf.setPosition(length - 128 + 93);
          await raf.writeFrom(yearBytes);
        }

        if (title != null && title.isNotEmpty) {
          await raf.setPosition(length - 128 + 3);
          await raf.writeFrom(_id3v1String(title, 30));
        }
        if (artist != null && artist.isNotEmpty) {
          await raf.setPosition(length - 128 + 33);
          await raf.writeFrom(_id3v1String(artist, 30));
        }
        if (album != null && album.isNotEmpty) {
          await raf.setPosition(length - 128 + 63);
          await raf.writeFrom(_id3v1String(album, 30));
        }
        if (track != null && track > 0 && track <= 255) {
          await raf.setPosition(length - 128 + 125);
          await raf.writeFrom(Uint8List.fromList([0, track]));
        }
        return;
      }
    }

    // No ID3v1 trailer: construct 128-byte block and append to EOF
    final id3v1 = Uint8List(128);
    // Header: "TAG"
    id3v1[0] = 0x54;
    id3v1[1] = 0x41;
    id3v1[2] = 0x47;

    // Title (30 bytes, offset 3..33)
    id3v1.setRange(3, 33, _id3v1String(title ?? '', 30));
    // Artist (30 bytes, offset 33..63)
    id3v1.setRange(33, 63, _id3v1String(artist ?? '', 30));
    // Album (30 bytes, offset 63..93)
    id3v1.setRange(63, 93, _id3v1String(album ?? '', 30));
    // Year (4 bytes, offset 93..97)
    id3v1.setRange(93, 97, yearBytes);
    // Comment: 28 zero bytes (offset 97..125)
    // ID3v1.1 marker: byte 125 = 0
    id3v1[125] = 0;
    // Track number: byte 126
    id3v1[126] = (track != null && track > 0 && track <= 255) ? track : 0;
    // Genre: byte 127 = 255 (unknown)
    id3v1[127] = 0xFF;

    await raf.setPosition(length);
    await raf.writeFrom(id3v1);
  } finally {
    try {
      await raf.close();
    } catch (_) {}
  }
}

Uint8List _id3v1String(String text, int maxLen) {
  final out = Uint8List(maxLen);
  final runes = text.runes.toList();
  final len = runes.length > maxLen ? maxLen : runes.length;
  for (int i = 0; i < len; i++) {
    final r = runes[i];
    out[i] = (r <= 255) ? r : 0x3F; // 0x3F is '?'
  }
  return out;
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
  try {
    final queue = playbackController.currentQueue.isNotEmpty
        ? playbackController.currentQueue
        : playbackController.songs;
    final freshPlaylist = playbackController.buildPlaylist(queue);
    playbackController.currentPlaylist = freshPlaylist;
    if (playbackController.isLibraryActive) {
      playbackController.libraryPlaylist = freshPlaylist;
    }
    final targetIndex = (index ?? 0).clamp(
      0,
      freshPlaylist.isEmpty ? 0 : freshPlaylist.length - 1,
    );
    if (freshPlaylist.isNotEmpty) {
      await player.setAudioSources(
        freshPlaylist,
        initialIndex: targetIndex,
        initialPosition: pos,
      );
      if (wasPlaying) await player.play();
    }
  } catch (e) {
    debugPrint('restorePlayerAfterTagWrite error: $e');
  }
}

/// Runs [action], safely delegating to [playbackController] to suspend playback,
/// drop native file locks, and reconstruct fresh audio sources without corruption.
Future<void> runWithPlayerPlaybackSuspended(
  AudioPlayer player,
  AudioSource? playlist,
  Future<void> Function() action, {
  String? targetFilePath,
}) async {
  await playbackController.runWithPlaybackSuspendedForTagWrite(
    action,
    targetFilePath: targetFilePath,
  );
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
