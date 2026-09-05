import 'package:on_audio_query/on_audio_query.dart';


class ArtistAlbum {
  final int albumId;
  final String title;
  final int year;
  final int trackCount;
  final int totalDurationMs;
  final SongModel representativeSong;

  const ArtistAlbum({
    required this.albumId,
    required this.title,
    required this.year,
    required this.trackCount,
    required this.totalDurationMs,
    required this.representativeSong,
  });
}

class AlbumArtistStat {
  AlbumArtistStat({required this.name});

  final String name;
  final Set<int> albumIds = <int>{};
  int trackCount = 0;

  int get albumCount => albumIds.length;
}

class AlbumTabStat {
  const AlbumTabStat({
    required this.albumId,
    required this.representativeSong,
    required this.title,
    required this.artist,
    required this.trackCount,
    required this.year,
  });

  final int albumId;
  final SongModel representativeSong;
  final String title;
  final String artist;
  final int trackCount;
  final int year;
}

enum AlbumArtistsSort {
  nameAsc,
  nameDesc,
  mostAlbums,
  leastAlbums,
  mostTracks,
  leastTracks,
}

enum AlbumsSort {
  titleAsc,
  titleDesc,
  artistAsc,
  artistDesc,
  yearAsc,
  yearDesc,
  albumArtistYear,
  mostTracks,
  leastTracks,
}