import 'package:on_audio_query/on_audio_query.dart';

String formatTime(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) return "0:00";
  int totalSeconds = (milliseconds / 1000).truncate();
  int minutes = (totalSeconds / 60).truncate();
  int seconds = totalSeconds % 60;
  return "$minutes:${seconds.toString().padLeft(2, '0')}";
}

String formatPlaylistDuration(int totalMs) {
  if (totalMs <= 0) return '0m';
  final totalMinutes = (totalMs / 60000).floor();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours <= 0) return '${minutes}m';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

String normalizeMetadataText(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return '';
  final lower = text.toLowerCase();
  if (lower == 'unknown' ||
      lower == 'unknown artist' ||
      lower == 'unknown album' ||
      lower == 'unknown title') {
    return '';
  }
  return text;
}

