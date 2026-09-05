import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';






class QueuePage extends StatefulWidget {
  final AudioPlayer player;
  final List<SongModel> songs;
  final int currentIndex;
  final void Function(int) onPlayIndex;
  final ConcatenatingAudioSource? playlist;
  final void Function(List<SongModel>) onQueueChanged;

  const QueuePage({
    super.key,
    required this.player,
    required this.songs,
    required this.currentIndex,
    required this.onPlayIndex,
    this.playlist,
    required this.onQueueChanged,
  });

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  late List<SongModel> _queue;
  late int _currentIndex;
  late final Map<int, SongModel> _songById;
  StreamSubscription<SequenceState?>? _sequenceSub;
  bool _isReordering = false;
  bool _ignoreSequenceUpdates = false;

  bool _sameQueueById(List<SongModel> a, List<SongModel> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  List<SongModel> _queueFromSequence(List<IndexedAudioSource> sequence) {
    final out = <SongModel>[];
    for (final src in sequence) {
      final tag = src.tag;
      if (tag is SongModel) {
        out.add(tag);
        continue;
      }
      if (tag is MediaItem) {
        final songId = int.tryParse(tag.id);
        if (songId != null) {
          final song = _songById[songId];
          if (song != null) out.add(song);
        }
      }
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _songById = {for (final s in widget.songs) s.id: s};

    final initialSequence = widget.player.sequence;
    if (initialSequence.isNotEmpty) {
      _queue = _queueFromSequence(initialSequence);
    } else {
      _queue = List.from(widget.songs);
    }

    if (initialSequence.isNotEmpty) {
      final sameLength = widget.songs.length == _queue.length;
      if (sameLength && !_sameQueueById(widget.songs, _queue) && _queue.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onQueueChanged(_queue);
        });
      }
    }

    _currentIndex = widget.player.currentIndex ?? widget.currentIndex;
    if (_currentIndex < 0) _currentIndex = 0;
    if (_queue.isNotEmpty && _currentIndex >= _queue.length) {
      _currentIndex = _queue.length - 1;
    }

    _sequenceSub = widget.player.sequenceStateStream.listen((state) {
      if (!mounted) return;
      if (_isReordering || _ignoreSequenceUpdates) return;

      final seq = state.sequence;
      if (seq.isEmpty) return;

      final mappedQueue = _queueFromSequence(seq);
      final nextQueue = mappedQueue.isNotEmpty ? mappedQueue : _queue;
      final nextIndex = widget.player.currentIndex ?? _currentIndex;

      final orderChanged = !_sameQueueById(_queue, nextQueue);
      final indexChanged = nextIndex != _currentIndex;
      if (!orderChanged && !indexChanged) return;

      setState(() {
        if (orderChanged) _queue = nextQueue;
        _currentIndex = nextIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
      });
      if (orderChanged) widget.onQueueChanged(_queue);
    });
  }

  @override
  void dispose() {
    _sequenceSub?.cancel();
    super.dispose();
  }

  Future<void> _moveItem(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex >= _queue.length || newIndex >= _queue.length) return;

    final prevQueue = List<SongModel>.from(_queue);
    final prevCurrentIndex = _currentIndex;

    setState(() {
      final item = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, item);

      if (oldIndex == _currentIndex) {
        _currentIndex = newIndex;
      } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
        _currentIndex--;
      } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
        _currentIndex++;
      }
    });
    widget.onQueueChanged(_queue);

    if (widget.playlist == null) return;

    _ignoreSequenceUpdates = true;
    try {
      await widget.playlist!.move(oldIndex, newIndex);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _queue = prevQueue;
        _currentIndex = prevCurrentIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
      });
      widget.onQueueChanged(_queue);
    } finally {
      _ignoreSequenceUpdates = false;
    }
  }

  Future<void> _removeItem(int index, {int? songId}) async {
    final resolvedIndex = songId == null ? index : _queue.indexWhere((s) => s.id == songId);
    if (resolvedIndex < 0 || resolvedIndex >= _queue.length) return;

    if (resolvedIndex == _currentIndex) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot remove currently playing song'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final prevQueue = List<SongModel>.from(_queue);
    final prevCurrentIndex = _currentIndex;

    _ignoreSequenceUpdates = true;
    try {
      if (widget.playlist != null) {
        await widget.playlist!.removeAt(resolvedIndex);
      }

      if (!mounted) return;
      setState(() {
        if (resolvedIndex >= 0 && resolvedIndex < _queue.length) {
          _queue.removeAt(resolvedIndex);
          if (resolvedIndex < _currentIndex) {
            _currentIndex--;
          }
        }

        final nextIndex = widget.player.currentIndex ?? _currentIndex;
        _currentIndex = nextIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
      });

      widget.onQueueChanged(_queue);
      HapticFeedback.lightImpact();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _queue = prevQueue;
        _currentIndex = prevCurrentIndex.clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
      });
      widget.onQueueChanged(_queue);
    } finally {
      _ignoreSequenceUpdates = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bgColor = cs.surface;
    final textColor = cs.onSurface;
    final textColorSecondary = cs.onSurfaceVariant;
    final textColorTertiary = cs.onSurfaceVariant.withValues(alpha: 0.78);
    final dividerColor = cs.outlineVariant.withValues(alpha: 0.45);
    final surfaceColor = Color.alphaBlend(cs.primary.withValues(alpha: 0.04), cs.surface);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton.filledTonal(
          icon: Icon(Icons.close_rounded, color: cs.onSecondaryContainer),
          style: IconButton.styleFrom(
            backgroundColor: cs.secondaryContainer,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Play Queue',
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${_queue.length} songs',
                style: TextStyle(
                  color: cs.onTertiaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              'Now Playing',
              style: TextStyle(
                color: textColorSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          if (_currentIndex >= 0 && _currentIndex < _queue.length)
            _buildCurrentSongTile(_queue[_currentIndex]),
          Divider(color: dividerColor, height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Up Next',
              style: TextStyle(
                color: textColorSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: Builder(
              builder: (context) {
                final upNextCount = (_queue.length - _currentIndex - 1).clamp(0, _queue.length);
                if (upNextCount == 0) {
                  return Center(
                    child: Text(
                      'Nothing up next',
                      style: TextStyle(color: textColorTertiary, fontSize: 14),
                    ),
                  );
                }

                return ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: upNextCount,
                  buildDefaultDragHandles: false,
                  onReorderStart: (_) => setState(() => _isReordering = true),
                  onReorderEnd: (_) => setState(() => _isReordering = false),
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, child) {
                        final elevation = lerpDouble(2, 10, animation.value) ?? 6;
                        final scale = lerpDouble(1.0, 1.02, animation.value) ?? 1.0;
                        return Transform.scale(
                          scale: scale,
                          alignment: Alignment.centerLeft,
                          child: Material(
                            elevation: elevation,
                            color: surfaceColor,
                            shadowColor: Colors.black54,
                            borderRadius: BorderRadius.circular(14),
                            clipBehavior: Clip.antiAlias,
                            child: child,
                          ),
                        );
                      },
                      child: child,
                    );
                  },
                  onReorder: (oldIndex, newIndex) {
                    if (oldIndex == newIndex) return;
                    final actualOld = oldIndex + _currentIndex + 1;
                    var actualNew = newIndex + _currentIndex + 1;
                    if (newIndex > oldIndex) actualNew--;
                    actualNew = actualNew.clamp(_currentIndex + 1, _queue.length - 1);
                    _moveItem(actualOld, actualNew);
                  },
                  itemBuilder: (context, index) {
                    final actualIndex = index + _currentIndex + 1;
                    final song = _queue[actualIndex];
                    return _buildQueueTile(song, actualIndex, index);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentSongTile(SongModel song) {
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface;
    final textColorSecondary = cs.onSurfaceVariant;
    final nullArtworkBg = cs.secondaryContainer.withValues(alpha: 0.55);
    final nullArtworkIcon = cs.onSecondaryContainer.withValues(alpha: 0.7);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color.alphaBlend(cs.primary.withValues(alpha: 0.14), cs.primaryContainer),
            Color.alphaBlend(cs.secondary.withValues(alpha: 0.1), cs.secondaryContainer),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: FastArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              width: 56,
              height: 56,
              keepOldArtwork: true,
              nullArtworkWidget: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: nullArtworkBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.music_note, color: nullArtworkIcon),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist ?? 'Unknown Artist',
                  style: TextStyle(color: textColorSecondary, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.tertiaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.equalizer_rounded,
              color: cs.onTertiaryContainer,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueTile(SongModel song, int queueIndex, int displayIndex) {
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface;
    final textColorTertiary = cs.onSurfaceVariant;
    final nullArtworkBg = cs.secondaryContainer.withValues(alpha: 0.5);
    final nullArtworkIcon = cs.onSecondaryContainer.withValues(alpha: 0.72);
    final dragHandleColor = cs.onSurfaceVariant.withValues(alpha: 0.8);
    final tileBg = Color.alphaBlend(cs.primary.withValues(alpha: 0.03), cs.surface);
    final tileBorder = cs.outlineVariant.withValues(alpha: 0.38);
    final deleteBg = cs.errorContainer;
    final deleteFg = cs.onErrorContainer;

    return Dismissible(
      key: ValueKey('queue_song_${song.id}'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.35},
      movementDuration: const Duration(milliseconds: 220),
      resizeDuration: const Duration(milliseconds: 180),
      confirmDismiss: (_) async {
        if (queueIndex == _currentIndex) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot remove currently playing song'),
              backgroundColor: Colors.orange,
            ),
          );
          return false;
        }
        return true;
      },
      onDismissed: (_) => _removeItem(queueIndex, songId: song.id),
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: deleteBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tileBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_rounded, color: deleteFg),
            const SizedBox(width: 10),
            Text(
              'Remove',
              style: TextStyle(color: deleteFg, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      child: RepaintBoundary(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: tileBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tileBorder),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                widget.onPlayIndex(queueIndex);
                setState(() => _currentIndex = queueIndex);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                child: Row(
                  children: [
                    ReorderableDelayedDragStartListener(
                      index: displayIndex,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: cs.secondaryContainer.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                '${displayIndex + 1}',
                                style: TextStyle(
                                  color: dragHandleColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Icon(
                              Icons.drag_handle_rounded,
                              color: dragHandleColor,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: FastArtworkWidget(
                        id: song.id,
                        type: ArtworkType.AUDIO,
                        width: 50,
                        height: 50,
                        keepOldArtwork: true,
                        nullArtworkWidget: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: nullArtworkBg,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.music_note,
                            color: nullArtworkIcon,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist ?? 'Unknown Artist',
                            style: TextStyle(color: textColorTertiary, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatTime(song.duration),
                      style: TextStyle(color: textColorTertiary, fontSize: 12),
                    ),
                    IconButton.filledTonal(
                      icon: Icon(
                        Icons.close_rounded,
                        color: cs.onErrorContainer,
                        size: 20,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.errorContainer,
                      ),
                      onPressed: () => _removeItem(queueIndex, songId: song.id),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
