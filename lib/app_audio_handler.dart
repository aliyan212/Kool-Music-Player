import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Describes the current audio focus relationship with the OS.
enum AudioFocusState {
  /// We hold focus and can play normally.
  gained,

  /// Focus lost temporarily (notification ping, short call).
  /// Playback is paused; will auto-resume when focus returns.
  transientLoss,

  /// Focus lost permanently (another app started playing music).
  /// Playback is stopped; will NOT auto-resume.
  permanentLoss,

  /// Volume is lowered (ducked) but we're still playing.
  ducked,
}

/// Audio handler backing the media notification / lockscreen controls.
///
/// Keep this file minimal and reliable: it should never block app startup.
class AppAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  AppAudioHandler(this.player) {
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
  Timer? _permanentLossTimer;

  bool _suspendStateUpdates = false;

  AudioSession? _session;
  DateTime? _duckStartedAt;
  DateTime? _lastPlaybackProgressAt;
  Duration? _lastPlaybackPosition;
  DateTime? _lastPlaybackRecoveryAt;

  bool _ducked = false;
  double _preDuckVolume = 1.0;
  double _baselineVolume = 1.0;

  DateTime? _lastMuteRecoveryAt;

  // ── Audio focus state ──────────────────────────────────────────────

  final _audioFocusStateController =
      StreamController<AudioFocusState>.broadcast();
  Stream<AudioFocusState> get audioFocusState =>
      _audioFocusStateController.stream;
  AudioFocusState _focusState = AudioFocusState.gained;

  AudioFocusState get currentFocusState => _focusState;

  void _setFocusState(AudioFocusState newState) {
    if (_focusState == newState) return;
    _focusState = newState;
    _audioFocusStateController.add(newState);
  }

  /// Android maps focus events through [AudioInterruptionEvent].
  ///   AUDIOFOCUS_LOSS                    → pause begin (no end — permanent)
  ///   AUDIOFOCUS_LOSS_TRANSIENT          → pause begin then end (transient)
  ///   AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK → duck begin then end
  ///
  /// Since [audio_session] maps both LOSS and LOSS_TRANSIENT to
  /// [AudioInterruptionType.pause], we use a timer: if the "end" event
  /// doesn't arrive within [permanentLossTimeout], treat the loss as permanent.
  static const Duration permanentLossTimeout = Duration(seconds: 6);

  // ── Volume helpers ─────────────────────────────────────────────────

  Future<void> _setNormalVolume() async {
    final v = _baselineVolume.clamp(0.0, 1.0);
    if ((player.volume - v).abs() <= 0.001) return;
    await player.setVolume(v);
  }

  Future<void> _recoverFromStuckMuteIfNeeded() async {
    final now = DateTime.now();
    final last = _lastMuteRecoveryAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastMuteRecoveryAt = now;

    try {
      await _setNormalVolume();
      if (player.playing && player.volume <= 0.001) {
        await player.pause();
        await player.play();
      }
    } catch (_) {}
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
    } catch (_) {}
  }

  // ── Audio session / focus ──────────────────────────────────────────

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _session = session;
      await session.configure(const AudioSessionConfiguration.music());

      _baselineVolume = player.volume.clamp(0.0, 1.0);

      // Headphones unplugged / BT disconnect → pause.
      _becomingNoisySub ??= session.becomingNoisyEventStream.listen((_) {
        player.pause();
      });

      _interruptionSub ??= session.interruptionEventStream.listen(
        _handleInterruption,
      );
    } catch (_) {
      // Ignore: audio session not available on some platforms.
    }
  }

  void _handleInterruption(AudioInterruptionEvent event) async {
    // ── Interruption begins ──────────────────────────────────────────
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          if (!_ducked) {
            _duckStartedAt = DateTime.now();
            _baselineVolume = player.volume.clamp(0.0, 1.0);
            if (_baselineVolume <= 0.001) _baselineVolume = 1.0;

            _preDuckVolume = _baselineVolume;
            _ducked = true;
            _setFocusState(AudioFocusState.ducked);

            var duckVol = (_preDuckVolume * 0.2);
            if (duckVol < 0.08) duckVol = 0.08;
            if (duckVol > 1.0) duckVol = 1.0;
            await player.setVolume(duckVol);

            _duckFailsafeTimer?.cancel();
            _duckFailsafeTimer = Timer(
              const Duration(seconds: 20),
              () async {
                if (!_ducked) return;
                _ducked = false;
                _setFocusState(AudioFocusState.gained);
                try {
                  await _setNormalVolume();
                } catch (_) {}
              },
            );
          }
          break;

        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // Pause the player and start a timer. If the "end" event
          // doesn't arrive within permanentLossTimeout, treat this as
          // AUDIOFOCUS_LOSS (permanent) rather than LOSS_TRANSIENT.
          if (player.playing) {
            await player.pause();
          }
          _setFocusState(AudioFocusState.transientLoss);

          // Start permanent-loss detection timer.
          _permanentLossTimer?.cancel();
          _permanentLossTimer = Timer(permanentLossTimeout, () {
            // No "end" event arrived — this is permanent focus loss.
            _setFocusState(AudioFocusState.permanentLoss);
            debugPrint(
              'Audio focus: permanent loss detected (no end event within '
              '${permanentLossTimeout.inSeconds}s). Stopping player.',
            );
            // Abandon audio focus entirely.
            try {
              _session?.setActive(false);
            } catch (_) {}
          });
          break;
      }
      return;
    }

    // ── Interruption ends ────────────────────────────────────────────
    switch (event.type) {
      case AudioInterruptionType.duck:
        if (_ducked) {
          _ducked = false;
          _duckStartedAt = null;
          _duckFailsafeTimer?.cancel();
          _duckFailsafeTimer = null;
          _setFocusState(AudioFocusState.gained);
          await _setNormalVolume();
        }
        break;

      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        _permanentLossTimer?.cancel();
        _permanentLossTimer = null;

        // Only resume if this was a transient loss (not permanent).
        if (_focusState == AudioFocusState.transientLoss) {
          try {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await _session?.setActive(true);
          } catch (_) {}
          try {
            await _setNormalVolume();
          } catch (_) {}
          await player.play();
          _lastPlaybackProgressAt = DateTime.now();
          _lastPlaybackPosition = player.position;
        }
        _setFocusState(AudioFocusState.gained);
        break;
    }
  }

  // ── Playback lifecycle ─────────────────────────────────────────────

  Future<void> disposePlayer() async {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _duckFailsafeTimer?.cancel();
    _duckFailsafeTimer = null;
    _permanentLossTimer?.cancel();
    _permanentLossTimer = null;
    await _playerStateSub?.cancel();
    await _currentIndexSub?.cancel();
    await _sequenceStateSub?.cancel();
    await _shuffleSub?.cancel();
    await _loopSub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    await _audioFocusStateController.close();
    await player.dispose();
  }

  void _syncPositionTimer() {
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

  // ── Notification / broadcast ───────────────────────────────────────

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

    playbackState.add(
      playbackState.value.copyWith(
        controls: _notificationControls(),
        androidCompactActionIndices: const [0, 2, 4],
        systemActions: const {MediaAction.seek},
        processingState: _mapProcessingState(player.processingState),
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: player.currentIndex,
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

  // ── Transport controls ─────────────────────────────────────────────

  @override
  Future<void> play() async {
    // If we lost focus permanently, re-acquire it before playing.
    if (_focusState == AudioFocusState.permanentLoss) {
      try {
        final regained = await _session?.setActive(true);
        if (regained == true || regained == null) {
          _setFocusState(AudioFocusState.gained);
        }
      } catch (_) {}
    } else {
      try {
        await _session?.setActive(true);
      } catch (_) {}
    }
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
    _setFocusState(AudioFocusState.permanentLoss);
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() => player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
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
        customEvent.add(<String, dynamic>{'type': 'exit'});
        await stop();
        break;
    }
    return super.customAction(name, extras);
  }
}

