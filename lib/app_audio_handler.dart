import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Audio handler backing the media notification / lockscreen controls.
///
/// Keep this file minimal and reliable: it should never block app startup.
class AppAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  AppAudioHandler(this.player) {
    // Best-effort: configure audio focus/interruptions.
    // Do not block app startup on this.
    unawaited(_initAudioSession());

    _playerStateSub = player.playerStateStream.listen((_) {
      _syncPositionTimer();
      _broadcastState();

      // Some devices occasionally end up with "playing" state but a muted
      // output (often after focus/route changes). If our volume has ended up
      // near-zero while playing, try a minimal recovery.
      if (player.playing && !_ducked && player.volume <= 0.001) {
        unawaited(_recoverFromStuckMuteIfNeeded());
      }
    });
    _currentIndexSub = player.currentIndexStream.listen((_) {
      _broadcastState();
    });
    _sequenceStateSub = player.sequenceStateStream.listen(_handleSequenceState);
    _shuffleSub = player.shuffleModeEnabledStream.listen(
      (_) => _broadcastState(),
    );
    _loopSub = player.loopModeStream.listen((_) => _broadcastState());

    _broadcastState();
  }

  final AudioPlayer player;

  static const Duration _restartTrackThreshold = Duration(seconds: 10);

  static const String _actionToggleShuffle = 'toggleShuffle';
  static const String _actionToggleRepeat = 'toggleRepeat';
  static const String _actionCloseApp = 'closeApp';

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<int?>? _currentIndexSub;
  StreamSubscription<SequenceState?>? _sequenceStateSub;
  StreamSubscription<bool>? _shuffleSub;
  StreamSubscription<LoopMode>? _loopSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  Timer? _positionUpdateTimer;
  Timer? _duckFailsafeTimer;

  bool _suspendStateUpdates = false;

  AudioSession? _session;
  DateTime? _duckStartedAt;
  DateTime? _lastPlaybackProgressAt;
  Duration? _lastPlaybackPosition;
  DateTime? _lastPlaybackRecoveryAt;

  bool _resumeAfterInterruption = false;
  bool _ducked = false;
  double _preDuckVolume = 1.0;
  double _baselineVolume = 1.0;

  DateTime? _lastMuteRecoveryAt;

  Future<void> _setNormalVolume() async {
    final v = _baselineVolume.clamp(0.0, 1.0);
    if ((player.volume - v).abs() <= 0.001) return;
    await player.setVolume(v);
  }

  Future<void> _recoverFromStuckMuteIfNeeded() async {
    // Guard: don't spam recovery.
    final now = DateTime.now();
    final last = _lastMuteRecoveryAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5))
      return;
    _lastMuteRecoveryAt = now;

    try {
      // Restore baseline volume first.
      await _setNormalVolume();

      // If still muted, do a quick pause→play (mirrors the user's workaround).
      if (player.playing && player.volume <= 0.001) {
        await player.pause();
        await player.play();
      }
    } catch (_) {
      // Ignore.
    }
  }

  void _recordPlaybackProgress() {
    if (!player.playing) return;
    final currentPosition = player.position;
    if (_lastPlaybackPosition != currentPosition) {
      _lastPlaybackPosition = currentPosition;
      _lastPlaybackProgressAt = DateTime.now();
    }
  }

  Future<void> _recoverFromStuckPlaybackIfNeeded() async {
    if (!player.playing) return;

    final lastProgressAt = _lastPlaybackProgressAt;
    if (lastProgressAt == null) return;

    final now = DateTime.now();
    if (now.difference(lastProgressAt) < const Duration(seconds: 6)) return;

    final lastRecoveryAt = _lastPlaybackRecoveryAt;
    if (lastRecoveryAt != null &&
        now.difference(lastRecoveryAt) < const Duration(seconds: 10)) {
      return;
    }

    _lastPlaybackRecoveryAt = now;

    try {
      await _session?.setActive(true);
    } catch (_) {}

    try {
      await _setNormalVolume();
    } catch (_) {}

    try {
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await player.play();
      _lastPlaybackProgressAt = DateTime.now();
      _lastPlaybackPosition = player.position;
    } catch (_) {
      // Ignore.
    }
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _session = session;
      await session.configure(const AudioSessionConfiguration.music());

      // Establish a baseline volume to restore to after ducking.
      _baselineVolume = player.volume.clamp(0.0, 1.0);

      // Headphones unplugged / BT disconnect → pause.
      _becomingNoisySub ??= session.becomingNoisyEventStream.listen((_) {
        player.pause();
      });

      _interruptionSub ??= session.interruptionEventStream.listen((
        event,
      ) async {
        // Interruption begins.
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              if (!_ducked) {
                _duckStartedAt = DateTime.now();
                // Record a baseline (normal) volume only when not ducked.
                _baselineVolume = player.volume.clamp(0.0, 1.0);
                if (_baselineVolume <= 0.001) _baselineVolume = 1.0;

                _preDuckVolume = _baselineVolume;
                _ducked = true;
                // Conservative duck volume.
                // Some devices fail to send the matching "end" event. Add a
                // failsafe so we don't get stuck in a ducked (near-muted) state.
                var duckVol = (_preDuckVolume * 0.2);
                if (duckVol < 0.08) duckVol = 0.08;
                if (duckVol > 1.0) duckVol = 1.0;
                await player.setVolume(duckVol);

                _duckFailsafeTimer?.cancel();
                _duckFailsafeTimer = Timer(
                  const Duration(seconds: 20),
                  () async {
                    if (!_ducked) return;
                    // If we're still ducked after a long time, assume the end
                    // event was missed.
                    _ducked = false;
                    try {
                      await _setNormalVolume();
                    } catch (_) {}
                  },
                );
              }
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              _resumeAfterInterruption = player.playing;
              await player.pause();
              break;
          }
          return;
        }

        // Interruption ends.
        switch (event.type) {
          case AudioInterruptionType.duck:
            if (_ducked) {
              _ducked = false;
              _duckStartedAt = null;
              _duckFailsafeTimer?.cancel();
              _duckFailsafeTimer = null;
              await _setNormalVolume();
            }
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            if (_resumeAfterInterruption) {
              _resumeAfterInterruption = false;
              try {
                await Future<void>.delayed(const Duration(milliseconds: 250));
                await _session?.setActive(true);
              } catch (_) {}
              // Ensure volume is restored before resuming.
              try {
                await _setNormalVolume();
              } catch (_) {}
              await player.play();
              _lastPlaybackProgressAt = DateTime.now();
              _lastPlaybackPosition = player.position;
            }
            break;
        }
      });
    } catch (_) {
      // Ignore: audio session not available on some platforms.
    }
  }

  Future<void> disposePlayer() async {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _duckFailsafeTimer?.cancel();
    _duckFailsafeTimer = null;
    await _playerStateSub?.cancel();
    await _currentIndexSub?.cancel();
    await _sequenceStateSub?.cancel();
    await _shuffleSub?.cancel();
    await _loopSub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    await player.dispose();
  }

  void _syncPositionTimer() {
    // Battery optimization: update occasionally while playing.
    if (player.playing) {
      _positionUpdateTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
        _recordPlaybackProgress();
        unawaited(_recoverFromStuckPlaybackIfNeeded());
        _broadcastState();
      });
    } else {
      _positionUpdateTimer?.cancel();
      _positionUpdateTimer = null;
    }
  }

  void _handleSequenceState(SequenceState? state) {
    if (_suspendStateUpdates) return;
    final seq = state?.sequence ?? const <IndexedAudioSource>[];
    final items = seq
        .map(_mediaItemFromSource)
        .whereType<MediaItem>()
        .toList(growable: false);

    queue.add(items);

    final idx = state?.currentIndex;
    if (idx != null && idx >= 0 && idx < items.length) {
      mediaItem.add(items[idx]);
    }
  }

  MediaItem? _mediaItemFromSource(IndexedAudioSource source) {
    final tag = source.tag;
    if (tag is MediaItem) return tag;
    return null;
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  AudioServiceRepeatMode _repeatModeFromLoop(LoopMode mode) {
    switch (mode) {
      case LoopMode.off:
        return AudioServiceRepeatMode.none;
      case LoopMode.one:
        return AudioServiceRepeatMode.one;
      case LoopMode.all:
        return AudioServiceRepeatMode.all;
    }
  }

  List<MediaControl> _notificationControls() {
    final shuffleEnabled = player.shuffleModeEnabled;
    final loopMode = player.loopMode;

    // Requirement: loop button converts to an X only when paused.
    final rightButton = !player.playing
        ? MediaControl.custom(
            androidIcon: 'drawable/ic_close',
            label: 'Close',
            name: _actionCloseApp,
          )
        : MediaControl.custom(
            androidIcon: switch (loopMode) {
              LoopMode.off => 'drawable/ic_repeat_off',
              LoopMode.all => 'drawable/ic_repeat',
              LoopMode.one => 'drawable/ic_repeat_one',
            },
            label: switch (loopMode) {
              LoopMode.off => 'Repeat off',
              LoopMode.all => 'Repeat all',
              LoopMode.one => 'Repeat one',
            },
            name: _actionToggleRepeat,
          );

    return [
      MediaControl.custom(
        // Make shuffle state obvious at a glance.
        androidIcon: shuffleEnabled
            ? 'drawable/ic_shuffle_on'
            : 'drawable/ic_shuffle_off',
        label: shuffleEnabled ? 'Shuffle ON' : 'Shuffle OFF',
        name: _actionToggleShuffle,
      ),
      MediaControl.skipToPrevious,
      player.playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      rightButton,
    ];
  }

  void _broadcastState() {
    if (_suspendStateUpdates) return;
    final event = player.playbackEvent;

    playbackState.add(
      playbackState.value.copyWith(
        controls: _notificationControls(),
        // Compact view shows status controls: shuffle + play/pause + loop-or-close.
        androidCompactActionIndices: const [0, 2, 4],
        systemActions: const {MediaAction.seek},
        processingState: _mapProcessingState(player.processingState),
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: event.currentIndex,
        repeatMode: _repeatModeFromLoop(player.loopMode),
        shuffleMode: player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  void setStateBroadcastSuspended(bool suspended) {
    if (_suspendStateUpdates == suspended) return;
    _suspendStateUpdates = suspended;
    if (!suspended) {
      _handleSequenceState(player.sequenceState);
      _broadcastState();
    }
  }

  @override
  Future<void> play() async {
    try {
      await _session?.setActive(true);
    } catch (_) {}
    return player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    try {
      await _session?.setActive(false);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await playbackState.firstWhere(
      (s) => s.processingState == AudioProcessingState.idle,
    );
    try {
      await _session?.setActive(false);
    } catch (_) {}
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() => player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
    // UX: If the user is more than N seconds into a track, "previous" restarts
    // the current track. Otherwise it moves to the previous track.
    final pos = player.position;
    if (pos > _restartTrackThreshold) {
      await player.seek(Duration.zero);
      return;
    }

    if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      await player.seek(Duration.zero);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) =>
      player.seek(Duration.zero, index: index);

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    switch (name) {
      case _actionToggleShuffle:
        final enable = !player.shuffleModeEnabled;
        await player.setShuffleModeEnabled(enable);
        if (enable) {
          await player.shuffle();
        }
        _broadcastState();
        break;
      case _actionToggleRepeat:
        final next = switch (player.loopMode) {
          LoopMode.off => LoopMode.all,
          LoopMode.all => LoopMode.one,
          LoopMode.one => LoopMode.off,
        };
        await player.setLoopMode(next);
        _broadcastState();
        break;
      case _actionCloseApp:
        // Ask the UI isolate to exit (best-effort) and stop the service.
        customEvent.add(<String, dynamic>{'type': 'exit'});
        await stop();
        break;
    }
    return super.customAction(name, extras);
  }
}
