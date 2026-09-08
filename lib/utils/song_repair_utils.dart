import 'package:audiotags/audiotags.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'format_utils.dart';

String _basenameFromPath(String path) {
  var p = path.trim();
  if (p.startsWith('file://')) {
    try {
      p = Uri.parse(p).toFilePath();
    } catch (_) {}
  }
  final q = p.indexOf('?');
  if (q != -1) p = p.substring(0, q);
  final h = p.indexOf('#');
  if (h != -1) p = p.substring(0, h);

  p = p.replaceAll('\\', '/');
  final idx = p.lastIndexOf('/');
  if (idx == -1) return p;
  return p.substring(idx + 1);
}

String _stripFileExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return filename;
  return filename.substring(0, dot);
}

Map<dynamic, dynamic> repairSongMetadataMap(
  Map<dynamic, dynamic> map, {
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  int? year,
  int? track,
}) {
  final fixed = Map<dynamic, dynamic>.from(map);
  final dataPath = (fixed['data'] ?? '').toString();
  final filename = _stripFileExtension(_basenameFromPath(dataPath));
  final mediaDisplayName = normalizeMetadataText(fixed['_display_name']);
  final mediaDisplayNameWoExt = normalizeMetadataText(
    fixed['_display_name_wo_ext'],
  );

  final titleValue = normalizeMetadataText(fixed['title']);
  if (titleValue.isEmpty) {
    final richTitle = normalizeMetadataText(title);
    final fallbackTitle = mediaDisplayNameWoExt.isNotEmpty
        ? mediaDisplayNameWoExt
        : mediaDisplayName.isNotEmpty
        ? mediaDisplayName
        : filename;
    fixed['title'] = richTitle.isNotEmpty ? richTitle : fallbackTitle;
  }

  final artistValue = normalizeMetadataText(fixed['artist']);
  if (artistValue.isEmpty) {
    final richArtist = normalizeMetadataText(artist);
    fixed['artist'] = richArtist.isNotEmpty ? richArtist : 'Unknown Artist';
  }

  final albumValue = normalizeMetadataText(fixed['album']);
  if (albumValue.isEmpty) {
    final richAlbum = normalizeMetadataText(album);
    fixed['album'] = richAlbum.isNotEmpty ? richAlbum : 'Unknown Album';
  }

  final albumArtistValue = normalizeMetadataText(fixed['album_artist']);
  if (albumArtistValue.isEmpty) {
    final richAlbumArtist = normalizeMetadataText(albumArtist);
    if (richAlbumArtist.isNotEmpty) {
      fixed['album_artist'] = richAlbumArtist;
    } else {
      final fallbackArtist = normalizeMetadataText(fixed['artist']);
      fixed['album_artist'] = fallbackArtist.isNotEmpty
          ? fallbackArtist
          : 'Unknown Artist';
    }
  }

  final rawYear = fixed['year'];
  if (rawYear == null ||
      (rawYear is int && rawYear <= 0) ||
      (rawYear is String && normalizeMetadataText(rawYear).isEmpty)) {
    if (year != null && year > 0) {
      fixed['year'] = year;
    }
  }

  final rawTrack = fixed['track'];
  if (rawTrack == null ||
      (rawTrack is int && rawTrack <= 0) ||
      (rawTrack is String && normalizeMetadataText(rawTrack).isEmpty)) {
    if (track != null && track > 0) {
      fixed['track'] = track;
    }
  }

  return fixed;
}

Future<List<SongModel>> repairSongMetadataList(
  List<SongModel> songs, {
  String? tagTitle,
  String? tagArtist,
  String? tagAlbum,
  String? tagAlbumArtist,
  int? tagYear,
  int? tagTrack,
}) async {
  final repaired = <SongModel>[];
  for (final song in songs) {
    final map = Map<dynamic, dynamic>.from(song.getMap);
    final rawData = map['_data'] ?? map['data'] ?? '';
    final filePath = rawData.toString().trim();

    String? tagTitleValue = tagTitle;
    String? tagArtistValue = tagArtist;
    String? tagAlbumValue = tagAlbum;
    String? tagAlbumArtistValue = tagAlbumArtist;
    int? tagYearValue = tagYear;
    int? tagTrackValue = tagTrack;

    if (filePath.isNotEmpty) {
      try {
        final tag = await AudioTags.read(filePath);
        if (tag != null) {
          tagTitleValue ??= tag.title;
          tagArtistValue ??= tag.trackArtist;
          tagAlbumValue ??= tag.album;
          tagAlbumArtistValue ??= tag.albumArtist;
          tagYearValue ??= tag.year;
          tagTrackValue ??= tag.trackNumber;
        }
      } catch (_) {}
    }

    repaired.add(
      SongModel(
        repairSongMetadataMap(
          map,
          title: tagTitleValue,
          artist: tagArtistValue,
          album: tagAlbumValue,
          albumArtist: tagAlbumArtistValue,
          year: tagYearValue,
          track: tagTrackValue,
        ),
      ),
    );
  }

  return repaired;
}
