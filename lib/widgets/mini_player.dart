
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:palette_generator/palette_generator.dart';

import '../android_notifications.dart';
import '../main.dart';
import '../pages/queue_page.dart';


class MiniPlayer extends StatefulWidget {
  final AudioPlayer player;
  final List<SongModel> songs;
  final int? currentIndex;
  final void Function(SongModel) onTap;
  final ConcatenatingAudioSource? playlist;
  final void Function(List<SongModel>) onQueueChanged;

  const MiniPlayer({
    super.key,
    required this.player,
    required this.songs,
    this.currentIndex,
    required this.onTap,
    this.playlist,
    required this.onQueueChanged,
  });

  static int? _songIdFromTag(dynamic tag) {
    if (tag is SongModel) return tag.id;
    if (tag is MediaItem) return int.tryParse(tag.id);
    return null;
  }

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  int? _lastResolvedIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<SequenceState?>(
      stream: widget.player.sequenceStateStream,
      builder: (context, snap) {
        final state = snap.data ?? widget.player.sequenceState;
        final tag = state?.currentSource?.tag;
        final songId = MiniPlayer._songIdFromTag(tag);

        int? resolvedIndex;
        if (songId != null) {
          final idx = widget.songs.indexWhere((s) => s.id == songId);
          if (idx >= 0) resolvedIndex = idx;
        }

        resolvedIndex ??= widget.currentIndex;
        resolvedIndex ??= widget.player.currentIndex;

        if (resolvedIndex != null &&
            resolvedIndex >= 0 &&
            resolvedIndex < widget.songs.length) {
          _lastResolvedIndex = resolvedIndex;
        } else {
          resolvedIndex = _lastResolvedIndex;
        }

        final index = resolvedIndex;
        if (index == null || index < 0 || index >= widget.songs.length) {
          return const SizedBox.shrink();
        }

        final song = widget.songs[index];
        return MiniPlayerTile(
          player: widget.player,
          song: song,
          songs: widget.songs,
          currentIndex: index,
          onTap: () => widget.onTap(song),
          onDismiss: () => widget.player.stop(),
          playlist: widget.playlist,
          onQueueChanged: widget.onQueueChanged,
        );
      },
    );
  }
}

class MiniPlayerTile extends StatefulWidget {
  final AudioPlayer player;
  final SongModel song;
  final List<SongModel> songs;
  final int currentIndex;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final ConcatenatingAudioSource? playlist;
  final void Function(List<SongModel>) onQueueChanged;

  const MiniPlayerTile({
    super.key,
    required this.player,
    required this.song,
    required this.songs,
    required this.currentIndex,
    required this.onTap,
    required this.onDismiss,
    this.playlist,
    required this.onQueueChanged,
  });

  @override
  State<MiniPlayerTile> createState() => _MiniPlayerTileState();
}

class _MiniPlayerTileState extends State<MiniPlayerTile> {
  static final LinkedHashMap<int, Color> _bgColorCache = LinkedHashMap<int, Color>();
  static const int _bgColorCacheMax = 40;

  Color? _bgColor;
  Uint8List? _artworkBytes;
  Timer? _colorDebounceTimer;
  Timer? _artworkDebounceTimer;
  int _colorToken = 0;
  int _artworkToken = 0;

  @override
  void initState() {
    super.initState();
    final cachedColor = _bgColorCache[widget.song.id];
    if (cachedColor != null) {
      _bgColor = cachedColor;
    }
    if (hasCachedArtworkBytes(widget.song.id)) {
      _artworkBytes = peekCachedArtworkBytes(widget.song.id);
    }
    _scheduleUpdateColor();
    _scheduleUpdateArtwork(delay: Duration.zero);
  }

  @override
  void didUpdateWidget(covariant MiniPlayerTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      final cachedColor = _bgColorCache[widget.song.id];
      if (cachedColor != null) {
        _bgColor = cachedColor;
      }
      if (hasCachedArtworkBytes(widget.song.id)) {
        _artworkBytes = peekCachedArtworkBytes(widget.song.id);
      }
      _scheduleUpdateColor();
      _scheduleUpdateArtwork();
    }
  }

  @override
  void dispose() {
    _colorDebounceTimer?.cancel();
    _colorDebounceTimer = null;
    _artworkDebounceTimer?.cancel();
    _artworkDebounceTimer = null;
    super.dispose();
  }

  Future<void> _playWithNotificationPermission() async {
    final ok = await ensureNotificationPermissionIfNeeded();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "Notifications are blocked, so the player notification can't be shown.",
          ),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Settings',
            onPressed: AndroidNotifications.openAppNotificationSettings,
          ),
        ),
      );
    }
    await widget.player.play();
  }

  void _scheduleUpdateColor() {
    _colorDebounceTimer?.cancel();

    // Mini player can change tracks quickly (skips). Debounce the palette work.
    final token = ++_colorToken;
    _colorDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      _updateColor(widget.song.id, token);
    });
  }

  void _scheduleUpdateArtwork({Duration delay = const Duration(milliseconds: 60)}) {
    _artworkDebounceTimer?.cancel();
    final token = ++_artworkToken;
    _artworkDebounceTimer = Timer(delay, () {
      _updateArtwork(widget.song.id, token);
    });
  }

  Future<void> _updateArtwork(int songId, int token) async {
    try {
      final bytes = await queryArtworkBytesCached(songId, size: 300);
      if (!mounted) return;
      if (token != _artworkToken) return;
      if (songId != widget.song.id) return;
      if (identical(_artworkBytes, bytes)) return;
      setState(() => _artworkBytes = bytes);
    } catch (_) {
      // Keep existing artwork bytes if retrieval fails.
    }
  }

  Future<void> _updateColor(int songId, int token) async {
    try {
      final cached = _bgColorCache.remove(songId);
      if (cached != null) {
        // LRU: re-insert as most recently used.
        _bgColorCache[songId] = cached;

        if (!mounted) return;
        if (token != _colorToken) return;
        if (songId != widget.song.id) return;

        setState(() => _bgColor = cached);
        return;
      }

      final bytes = await queryArtworkBytesCached(songId, size: 220);

      if (!mounted) return;
      if (token != _colorToken) return;
      if (songId != widget.song.id) return;

      if (bytes == null) {
        setState(() => _bgColor = null);
        return;
      }

      final palette = await PaletteGenerator.fromImageProvider(
        MemoryImage(bytes),
        maximumColorCount: 16,
      );

      if (!mounted) return;
      if (token != _colorToken) return;
      if (songId != widget.song.id) return;

      final baseColor = palette.darkVibrantColor?.color ??
          palette.vibrantColor?.color ??
          palette.darkMutedColor?.color ??
          palette.dominantColor?.color ??
          Colors.grey;

      _bgColorCache.remove(songId);
      _bgColorCache[songId] = baseColor;
      while (_bgColorCache.length > _bgColorCacheMax) {
        _bgColorCache.remove(_bgColorCache.keys.first);
      }

      setState(() => _bgColor = baseColor);
    } catch (_) {}
  }

  void _openQueue() {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => QueuePage(
          player: widget.player,
          songs: widget.songs,
          currentIndex: widget.player.currentIndex ?? 0,
          onPlayIndex: (index) {
            widget.player.seek(Duration.zero, index: index);
          },
          playlist: widget.playlist,
          onQueueChanged: widget.onQueueChanged,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Keep the mini player above system gesture/navigation areas.
    final mq = MediaQuery.of(context);
    final bottomInset = math.max(mq.padding.bottom, mq.systemGestureInsets.bottom);
    // Keep just a small buffer above the system inset so the area under the
    // mini-player stays visually open.
    final extraBottom = (bottomInset * 0.2).clamp(0.0, 8.0);

    Color adjustedBgColor;
    if (_bgColor != null) {
      final hsl = HSLColor.fromColor(_bgColor!);
      if (isDark) {
        adjustedBgColor = hsl
            .withSaturation((hsl.saturation * 0.85).clamp(0.0, 1.0))
            .withLightness((hsl.lightness * 0.45).clamp(0.15, 0.35))
            .toColor();
      } else {
        adjustedBgColor = hsl
            .withSaturation((hsl.saturation * 0.6).clamp(0.0, 1.0))
            .withLightness((hsl.lightness * 0.3 + 0.6).clamp(0.7, 0.9))
            .toColor();
      }
    } else {
      adjustedBgColor = isDark
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.primaryContainer;
    }

    final bgColor = adjustedBgColor;
    final luminance = bgColor.computeLuminance();
    final textColor = luminance > 0.5 ? Colors.black87 : Colors.white;
    final subTextColor = luminance > 0.5 ? Colors.black54 : Colors.white70;
    final borderColor = Colors.transparent;

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.velocity.pixelsPerSecond.dy < -300) {
          // Swipe up - open now playing
          widget.onTap();
        } else if (details.velocity.pixelsPerSecond.dy > 300) {
          // Swipe down - dismiss/stop
          widget.onDismiss();
        }
      },
      onHorizontalDragEnd: (details) {
        if (details.velocity.pixelsPerSecond.dx < -300) {
          // Swipe left - next track
          if (widget.player.hasNext) {
            HapticFeedback.selectionClick();
            widget.player.seekToNext();
          }
        } else if (details.velocity.pixelsPerSecond.dx > 300) {
          // Swipe right - previous track
          HapticFeedback.selectionClick();
          final pos = widget.player.position;
          if (pos > const Duration(seconds: 10)) {
            widget.player.seek(Duration.zero);
          } else if (widget.player.hasPrevious) {
            widget.player.seekToPrevious();
          } else {
            widget.player.seek(Duration.zero);
          }
        }
      },
      onLongPress: _openQueue,
      child: Container(
        height: 80,
        margin: EdgeInsets.fromLTRB(12, 0, 12, 6 + extraBottom),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.10 : 0.06),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    bgColor.withOpacity(0.40),
                    bgColor.withOpacity(0.28),
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: appIsForeground,
                      builder: (context, isFg, _) {
                        Widget progressBar(Duration pos) {
                          final progress =
                              ((pos.inMilliseconds) / (widget.player.duration?.inMilliseconds ?? 1))
                                  .clamp(0.0, 1.0);
                          return Container(
                            height: 3,
                            decoration: const BoxDecoration(
                              borderRadius: BorderRadius.only(
                                bottomLeft: Radius.circular(24),
                                bottomRight: Radius.circular(24),
                              ),
                            ),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(end: progress),
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, _) {
                                return LinearProgressIndicator(
                                  value: value,
                                  minHeight: 3,
                                  color: textColor.withOpacity(0.9),
                                  backgroundColor: Colors.transparent,
                                );
                              },
                            ),
                          );
                        }

                        if (!isFg) {
                          return progressBar(widget.player.position);
                        }

                        return StreamBuilder<Duration>(
                          stream: widget.player.positionStream,
                          builder: (context, snap) =>
                              progressBar(snap.data ?? widget.player.position),
                        );
                      },
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              widget.onTap();
                            },
                            borderRadius: BorderRadius.circular(24),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Row(
                                children: [
                                  Hero(
                                    tag: 'mini_artwork_${widget.song.id}',
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.3),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: _artworkBytes != null
                                            ? Image.memory(
                                                _artworkBytes!,
                                                width: 52,
                                                height: 52,
                                                fit: BoxFit.cover,
                                                gaplessPlayback: true,
                                                filterQuality: FilterQuality.low,
                                              )
                                            : Container(
                                                width: 52,
                                                height: 52,
                                                decoration: BoxDecoration(
                                                  color: Colors.black12,
                                                  borderRadius: BorderRadius.circular(14),
                                                ),
                                                child: Icon(
                                                  Icons.music_note,
                                                  color: textColor,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 240,
                                          ),
                                          transitionBuilder:
                                              (child, animation) {
                                            return SlideTransition(
                                              position: Tween<Offset>(
                                                begin: const Offset(0.0, 0.2),
                                                end: Offset.zero,
                                              ).animate(
                                                CurvedAnimation(
                                                  parent: animation,
                                                  curve: Curves.easeOutCubic,
                                                ),
                                              ),
                                              child: FadeTransition(
                                                opacity: animation,
                                                child: child,
                                              ),
                                            );
                                          },
                                          child: Text(
                                            widget.song.title,
                                            key: ValueKey(
                                              'mini_title_${widget.song.id}',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: textColor,
                                              fontSize: 14,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 240,
                                          ),
                                          transitionBuilder:
                                              (child, animation) {
                                            return SlideTransition(
                                              position: Tween<Offset>(
                                                begin: const Offset(0.0, 0.2),
                                                end: Offset.zero,
                                              ).animate(
                                                CurvedAnimation(
                                                  parent: animation,
                                                  curve: Curves.easeOutCubic,
                                                ),
                                              ),
                                              child: FadeTransition(
                                                opacity: animation,
                                                child: child,
                                              ),
                                            );
                                          },
                                          child: Text(
                                            widget.song.artist ?? 'Unknown',
                                            key: ValueKey(
                                              'mini_artist_${widget.song.id}',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: subTextColor,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      _buildControlButton(
                        Icons.skip_previous_rounded,
                        textColor,
                        () {
                          final pos = widget.player.position;
                          if (pos > const Duration(seconds: 10)) {
                            widget.player.seek(Duration.zero);
                          } else if (widget.player.hasPrevious) {
                            widget.player.seekToPrevious();
                          } else {
                            widget.player.seek(Duration.zero);
                          }
                        },
                      ),
                      StreamBuilder<PlayerState>(
                        stream: widget.player.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? false;
                          return _buildControlButton(
                            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            textColor,
                            playing ? widget.player.pause : _playWithNotificationPermission,
                            size: 32,
                          );
                        },
                      ),
                      _buildControlButton(
                        Icons.skip_next_rounded,
                        textColor,
                        () => widget.player.hasNext ? widget.player.seekToNext() : null,
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton(
    IconData icon,
    Color color,
    VoidCallback? onPressed, {
    double size = 24,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onPressed();
              },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) {
              return ScaleTransition(
                scale: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                ),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: Icon(
              icon,
              key: ValueKey(icon),
              color: color,
              size: size,
            ),
          ),
        ),
      ),
    );
  }
}
