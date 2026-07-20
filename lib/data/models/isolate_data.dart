import 'package:flutter/foundation.dart';


class IsolateData {
  final List<SongModel> songs;
  final List<AlbumModel> albums;
  final List<String> excludedFolders;
  final List<String> includedFolders;
  IsolateData(
    this.songs,
    this.albums,
    this.excludedFolders,
    this.includedFolders,
  );
}