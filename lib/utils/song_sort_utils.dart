import 'package:on_audio_query/on_audio_query.dart';
import '../services/playback_controller.dart';
import 'format_utils.dart';

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
  final v = s.getMap["year"];
  if (v == null) return 0;
  if (v is int) return v;
  final raw = v.toString();
  final direct = int.tryParse(raw);
  if (direct != null) return direct;
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
  final raw = s.getMap["album_artist"]?.toString();
  final fromSong = normalizeSortText(raw ?? '');
  if (fromSong.isNotEmpty) return fromSong;
  final fromAlbum = normalizeSortText(playbackController.albumMap[s.albumId]?.artist ?? '');
  if (fromAlbum.isNotEmpty) return fromAlbum;
  return normalizeSortText(s.artist ?? '');
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

