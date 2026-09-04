
import 'dart:io';
import 'dart:math' as math;

import 'package:audiotags/audiotags.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class LyricLine {
  final Duration time;
  final String content;

  const LyricLine(this.time, this.content);
}

class LyricsHelper {
  /// Computes companion .lrc path matching the audio file name.
  static String getCompanionLrcPath(String audioPath) {
    final dir = p.dirname(audioPath);
    final baseName = p.basenameWithoutExtension(audioPath);
    return p.join(dir, '$baseName.lrc');
  }

  /// Fast retrieval: checks companion .lrc file first (<1ms), then falls back to embedded tag.
  static Future<String?> getLyrics(String path) async {
    // 1. Check companion .lrc file first.
    try {
      final lrcPath = getCompanionLrcPath(path);
      final lrcFile = File(lrcPath);
      if (await lrcFile.exists()) {
        final content = await lrcFile.readAsString();
        if (content.trim().isNotEmpty) {
          return content.trim();
        }
      }
    } catch (_) {}

    // 2. Fall back to reading embedded tag.
    return getEmbeddedLyrics(path);
  }

  static Future<String?> getEmbeddedLyrics(String path) async {
    try {
      final tag = await AudioTags.read(path);
      return tag?.lyrics;
    } catch (_) {
      return null;
    }
  }

  /// Saves lyrics to both the companion .lrc file (for all external players)
  /// and embedded in the audio file's tags.
  static Future<void> saveLyrics(String audioPath, String? lyrics) async {
    final trimmed = lyrics?.trim() ?? '';

    // 1. Write/update companion .lrc file.
    try {
      final lrcPath = getCompanionLrcPath(audioPath);
      final lrcFile = File(lrcPath);
      if (trimmed.isEmpty) {
        if (await lrcFile.exists()) {
          await lrcFile.delete();
        }
      } else {
        await lrcFile.writeAsString(trimmed);
      }
    } catch (e) {
      debugPrint('Companion .lrc write warning: $e');
    }

    // 2. Write embedded audio tags.
    try {
      final existingTag = await AudioTags.read(audioPath);
      final newTag = Tag(
        title: existingTag?.title,
        trackArtist: existingTag?.trackArtist,
        album: existingTag?.album,
        albumArtist: existingTag?.albumArtist,
        year: existingTag?.year,
        genre: existingTag?.genre,
        trackNumber: existingTag?.trackNumber,
        trackTotal: existingTag?.trackTotal,
        discNumber: existingTag?.discNumber,
        discTotal: existingTag?.discTotal,
        lyrics: trimmed.isEmpty ? null : trimmed,
        duration: existingTag?.duration,
        pictures: existingTag?.pictures ?? const <Picture>[],
        bpm: existingTag?.bpm,
      );
      await AudioTags.write(audioPath, newTag);
    } catch (e) {
      debugPrint('Embedded lyrics write warning: $e');
    }
  }

  static final RegExp _timestampRegex = RegExp(r"\[(\d{2}):(\d{2})\.(\d{2,3})\]");

  static bool isLRC(String lyrics) => _timestampRegex.hasMatch(lyrics);

  /// Shifts all LRC timestamps by [offsetMs]. Negative values shift earlier.
  /// Clamps timestamps to >= 0.
  static String shiftLrcTimings(String lrc, int offsetMs) {
    if (lrc.isEmpty || offsetMs == 0) return lrc;

    String shiftToken(Match match) {
      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fracRaw = match.group(3) ?? '000';
      final fracLen = fracRaw.length;
      final millis = int.tryParse(fracRaw.padRight(3, '0')) ?? 0;

      final baseMs = (minutes * 60 * 1000) + (seconds * 1000) + millis;
      final shiftedMs = math.max(0, baseMs + offsetMs);

      final outMin = shiftedMs ~/ 60000;
      final outSec = (shiftedMs % 60000) ~/ 1000;
      final outMs = shiftedMs % 1000;

      final fracOut = fracLen == 2
          ? (outMs ~/ 10).toString().padLeft(2, '0')
          : outMs.toString().padLeft(3, '0');

      return '[${outMin.toString().padLeft(2, '0')}:${outSec.toString().padLeft(2, '0')}.$fracOut]';
    }

    final lines = lrc.split('\n');
    final shiftedLines = lines.map((line) {
      if (!line.contains('[') || !line.contains(']')) return line;
      return line.replaceAllMapped(_timestampRegex, shiftToken);
    }).toList(growable: false);

    return shiftedLines.join('\n');
  }

  static List<LyricLine> parseLRC(String lrc) {
    if (lrc.trim().isEmpty) return const <LyricLine>[];

    final lineRegex = RegExp(r"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)");
    final parsed = <LyricLine>[];

    for (final rawLine in lrc.split('\n')) {
      final match = lineRegex.firstMatch(rawLine);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fraction = match.group(3) ?? '000';
      final millis = int.tryParse(fraction.padRight(3, '0')) ?? 0;
      final content = (match.group(4) ?? '').trim();

      parsed.add(
        LyricLine(
          Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis,
          ),
          content,
        ),
      );
    }

    parsed.sort((a, b) => a.time.compareTo(b.time));
    return parsed;
  }
}
