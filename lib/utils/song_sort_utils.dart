import 'package:on_audio_query/on_audio_query.dart';
import '../services/playback_controller.dart';

final _yearRegex = RegExp(r'\b(19|20)\d{2}\b');

String normalizeSortText(String v) {
  final t = v.trim();
  if (t.isEmpty) return '';
  final lower = t.toLowerCase();
  if (lower == 'unknown' ||
      lower == 'unknown artist' ||
      lower == 'unknown album') {
    return '';
  }
  return t;
}

int compareSortStrings(String a, String b) {
  final aNorm = normalizeSortText(a);
  final bNorm = normalizeSortText(b);
  final aEmpty = aNorm.isEmpty;
  final bEmpty = bNorm.isEmpty;
  if (aEmpty != bEmpty) return aEmpty ? 1 : -1;

  final aLower = aNorm.toLowerCase();
  final bLower = bNorm.toLowerCase();
  final comp = aLower.compareTo(bLower);
  if (comp != 0) return comp;
  return aNorm.compareTo(bNorm);
}

int compareStrings(String a, String b) {
  final aTrim = a.trim();
  final bTrim = b.trim();
  final aLower = aTrim.toLowerCase();
  final bLower = bTrim.toLowerCase();
  final comp = aLower.compareTo(bLower);
  if (comp != 0) return comp;
  return aTrim.compareTo(bTrim);
}

int yearFromSong(SongModel s) {
  final map = s.getMap;
  dynamic v = map["year"];
  if (v == null || v == 0 || v == '0') {
    v = map["date"] ?? map["recording_time"];
  }
  if (v == null) return 0;
  if (v is int && v > 0) return v;
  final raw = v.toString();
  final direct = int.tryParse(raw);
  if (direct != null && direct > 0) return direct;
  final match = _yearRegex.firstMatch(raw);
  if (match == null) return 0;
  return int.tryParse(match.group(0)!) ?? 0;
}

int discFromSong(SongModel s) {
  final v = s.getMap['disc_number'];
  if (v is int && v > 0) return v;
  if (v != null) {
    final str = v.toString().trim();
    final slash = str.indexOf('/');
    final discStr = slash != -1 ? str.substring(0, slash).trim() : str;
    final parsed = int.tryParse(discStr);
    if (parsed != null && parsed > 0) return parsed;
  }
  // Fallback: Check if track has disc encoded (e.g. 1001 for disc 1, track 1)
  final t = s.track ?? 0;
  if (t >= 1000) return t ~/ 1000;
  return 0;
}

int trackFromSong(SongModel s) {
  int t = s.track ?? 0;
  if (t == 0) {
    final v = s.getMap['track'];
    if (v is int && v > 0) {
      t = v;
    } else if (v != null) {
      final str = v.toString().trim();
      final slash = str.indexOf('/');
      final trackStr = slash != -1 ? str.substring(0, slash).trim() : str;
      t = int.tryParse(trackStr) ?? 0;
    }
  }
  if (t >= 1000) return t % 1000;
  return t;
}

int compareDiscAndTrack(SongModel a, SongModel b) {
  var ad = discFromSong(a);
  var bd = discFromSong(b);
  if (ad == 0) ad = 1;
  if (bd == 0) bd = 1;
  if (ad != bd) return ad.compareTo(bd);

  final at = trackFromSong(a);
  final bt = trackFromSong(b);
  final finalAt = at == 0 ? 99999 : at;
  final finalBt = bt == 0 ? 99999 : bt;
  final tc = finalAt.compareTo(finalBt);
  if (tc != 0) return tc;

  final titleComp = compareSortStrings(a.title, b.title);
  if (titleComp != 0) return titleComp;
  return a.id.compareTo(b.id);
}

String albumArtistFor(SongModel s) {
  final raw = (s.getMap["album_artist"] ?? s.getMap["albumArtist"])?.toString();
  final fromSong = normalizeSortText(raw ?? '');
  if (fromSong.isNotEmpty) return fromSong;
  final fromSongArtist = normalizeSortText(s.artist ?? '');
  if (fromSongArtist.isNotEmpty) return fromSongArtist;
  final fromAlbum = normalizeSortText(playbackController.albumMap[s.albumId]?.artist ?? '');
  if (fromAlbum.isNotEmpty) return fromAlbum;
  return '';
}

String albumIdentityKey(SongModel s) {
  final artist = albumArtistFor(s).toLowerCase();
  final album = normalizeSortText(s.album ?? playbackController.albumMap[s.albumId]?.album ?? '').toLowerCase();
  if (album.isNotEmpty) {
    return '$artist\u0000$album';
  }
  final aid = s.albumId;
  if (aid != null && aid > 0) return 'album_id_$aid';
  return 'song_id_${s.id}';
}

/// Computes the representative release year for an album from the years of its songs.
///
/// The year assigned is the one associated with the most songs in the album.
/// If all tracks have different years (or if there is a tie between most frequent years),
/// the latest (highest) year is chosen. Returns 0 if no track has a valid year (> 0).
int computeAlbumYearFromYears(Iterable<int> songYears) {
  final valid = songYears.where((y) => y > 0).toList(growable: false);
  if (valid.isEmpty) return 0;

  final counts = <int, int>{};
  for (final y in valid) {
    counts[y] = (counts[y] ?? 0) + 1;
  }

  int maxCount = 0;
  for (final c in counts.values) {
    if (c > maxCount) maxCount = c;
  }

  int latestYear = 0;
  for (final entry in counts.entries) {
    if (entry.value == maxCount) {
      if (entry.key > latestYear) latestYear = entry.key;
    }
  }

  return latestYear;
}

/// Precomputes the representative album release year for every album among [songs],
/// keyed by [albumIdentityKey].
Map<String, int> computeAlbumYearMap(Iterable<SongModel> songs) {
  final yearsByAlbumKey = <String, List<int>>{};
  for (final s in songs) {
    final key = albumIdentityKey(s);
    final y = yearFromSong(s);
    if (y > 0) {
      (yearsByAlbumKey[key] ??= []).add(y);
    }
  }

  final out = <String, int>{};
  for (final entry in yearsByAlbumKey.entries) {
    out[entry.key] = computeAlbumYearFromYears(entry.value);
  }
  return out;
}

