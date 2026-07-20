import 'dart:collection';
import 'dart:typed_data';

class CachingService {
  static final CachingService _instance = CachingService._internal();
  factory CachingService() => _instance;
  CachingService._internal();

  final LinkedHashMap<String, Uint8List?> thumbnailCache = LinkedHashMap<String, Uint8List?>();
  final LinkedHashMap<String, Uint8List?> highResCache = LinkedHashMap<String, Uint8List?>();

  void clearOldThumbnails(int max) {
    while (thumbnailCache.length > max) {
      thumbnailCache.remove(thumbnailCache.keys.first);
    }
  }

  void clearOldHighRes(int max) {
    while (highResCache.length > max) {
      highResCache.remove(highResCache.keys.first);
    }
  }
}
