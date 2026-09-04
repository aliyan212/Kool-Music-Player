import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../data/services/caching_service.dart';
import '../../services/local_audio_scanner.dart';

const int _thumbnailCacheMax = 300;
const int _highResCacheMax = 10;

String getArtworkKey(int id, ArtworkType type, int size) =>
    '${type.name}_${id}_$size';

LinkedHashMap<String, Uint8List?> artworkCacheForSize(int size) {
  return size > 400
      ? CachingService().highResCache
      : CachingService().thumbnailCache;
}

Uint8List? peekCachedArtworkBytesByKey(String key, int size) {
  final cache = artworkCacheForSize(size);
  if (!cache.containsKey(key)) return null;
  final cached = cache.remove(key);
  cache[key] = cached;
  return cached;
}

void storeCachedArtworkBytesByKey(String key, int size, Uint8List? bytes) {
  final cache = artworkCacheForSize(size);
  final maxEntries = size > 400 ? _highResCacheMax : _thumbnailCacheMax;
  cache.remove(key);
  cache[key] = bytes;
  while (cache.length > maxEntries) {
    cache.remove(cache.keys.first);
  }
}

bool hasCachedArtworkBytes(
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
}) {
  return artworkCacheForSize(size).containsKey(getArtworkKey(id, type, size));
}

Uint8List? peekCachedArtworkBytes(
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
}) {
  return peekCachedArtworkBytesByKey(getArtworkKey(id, type, size), size);
}

final Map<String, Future<Uint8List?>> _inFlightArtwork = {};

Future<Uint8List?> queryArtworkBytesCached(
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  int size = 200,
  int quality = 80,
}) async {
  final key = getArtworkKey(id, type, size);
  if (artworkCacheForSize(size).containsKey(key)) {
    return peekCachedArtworkBytesByKey(key, size);
  }
  if (_inFlightArtwork.containsKey(key)) {
    return _inFlightArtwork[key];
  }

  final future = () async {
    Uint8List? bytes;

    // On non-Android or web/desktop, query from LocalAudioScanner
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      bytes = await LocalAudioScanner.instance.getArtworkBytes(id, type: type);
    } else {
      try {
        bytes = await OnAudioQuery().queryArtwork(
          id,
          type,
          size: size,
          quality: quality,
        );
      } catch (_) {}

      // If Android MediaStore had no artwork, attempt local file tag fallback
      if (bytes == null) {
        bytes = await LocalAudioScanner.instance.getArtworkBytes(id, type: type);
      }
    }

    storeCachedArtworkBytesByKey(key, size, bytes);
    _inFlightArtwork.remove(key);
    return bytes;
  }();
  
  _inFlightArtwork[key] = future;
  return future;
}

class FastArtworkWidget extends StatefulWidget {
  final int id;
  final ArtworkType type;
  final double width;
  final double height;
  final Widget nullArtworkWidget;
  final int size;
  final int quality;
  final BoxFit artworkFit;
  final bool keepOldArtwork;

  const FastArtworkWidget({
    super.key,
    required this.id,
    required this.type,
    required this.width,
    required this.height,
    required this.nullArtworkWidget,
    this.size = 200,
    this.quality = 80,
    this.artworkFit = BoxFit.cover,
    this.keepOldArtwork = true,
  });

  @override
  State<FastArtworkWidget> createState() => _FastArtworkWidgetState();
}

class _FastArtworkWidgetState extends State<FastArtworkWidget> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _fetchArtwork();
  }

  @override
  void didUpdateWidget(covariant FastArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.type != widget.type) {
      if (!widget.keepOldArtwork) {
        setState(() => _bytes = null);
      }
      _fetchArtwork();
    }
  }

  void _fetchArtwork() {
    final key = getArtworkKey(widget.id, widget.type, widget.size);
    if (hasCachedArtworkBytes(widget.id, type: widget.type, size: widget.size)) {
      _bytes = peekCachedArtworkBytes(widget.id, type: widget.type, size: widget.size);
      return;
    }

    queryArtworkBytesCached(
      widget.id,
      type: widget.type,
      size: widget.size,
      quality: widget.quality,
    ).then((bytes) {
      if (!mounted) return;
      if (getArtworkKey(widget.id, widget.type, widget.size) != key) return;
      setState(() {
        _bytes = bytes;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null && _bytes!.isNotEmpty) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      return Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        cacheWidth: (widget.width * dpr).round(),
        cacheHeight: (widget.height * dpr).round(),
        fit: widget.artworkFit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => widget.nullArtworkWidget,
      );
    }
    return widget.nullArtworkWidget;
  }
}
