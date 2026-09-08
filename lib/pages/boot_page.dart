import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import '../app_audio_handler.dart';
import '../main.dart';
import '../platform_exit.dart';
import '../services/app_local_store.dart';
import '../services/playback_controller.dart';

class BootApp extends StatefulWidget {
  const BootApp({super.key});

  @override
  State<BootApp> createState() => _BootAppState();
}

class _BootAppState extends State<BootApp> {
  Object? _error;
  bool _ready = false;
  StreamSubscription<dynamic>? _handlerEventSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // Always allow the first frame to render; do not await long-running
      // platform/plugin initialization in main().
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await AppLocalStore.instance.init();

      // Ensure audio_service initialization is only attempted once.
      if (audioHandler == null) {
        if (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          audioHandler = AppAudioHandler(playbackController.player);
        } else {
          audioHandlerInitFuture ??= () async {
            return await AudioService.init(
              builder: () => AppAudioHandler(playbackController.player),
              config: const AudioServiceConfig(
                androidNotificationChannelId:
                    'com.example.music_player.channel.audio.v2',
                androidNotificationChannelName: 'Music playback',
                androidNotificationOngoing: true,
                androidStopForegroundOnPause: true,
              ),
            );
          }();

          audioHandler = await audioHandlerInitFuture! as AppAudioHandler;
        }
      }

      _handlerEventSub ??= audioHandler?.customEvent.listen((event) async {
        if (event is Map && event['type'] == 'exit') {
          await PlatformExit.quit();
        }
      });

      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    _handlerEventSub?.cancel();
    _handlerEventSub = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const MyApp();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  _error == null ? 'Starting…' : 'Startup failed',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error.toString(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _init, child: const Text('Retry')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
