
import 'dart:math' as math;

import 'package:audiotags/audiotags.dart';


class LyricLine {
  final Duration time;
  final String content;

  const LyricLine(this.time, this.content);
}

class LyricsHelper {
  static Future<String?> getEmbeddedLyrics(String path) async {
    try {
      final tag = await AudioTags.read(path);
      return tag?.lyrics;
    } catch (_) {
      return null;
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
