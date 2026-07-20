import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class NowPlayingTransport extends StatelessWidget {
  final AudioPlayer player;
  final bool isDark;
  final Color iconFgColor;
  final Color? accentColor;
  final Future<void> Function() onPlayPressed;

  const NowPlayingTransport({
    super.key,
    required this.player,
    required this.isDark,
    required this.iconFgColor,
    this.accentColor,
    required this.onPlayPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sideButtonBg = isDark ? Colors.white10 : Colors.black.withOpacity(0.08);
    final accent = accentColor ?? scheme.primary;
    final activeSideBg = Color.alphaBlend(
      accent.withOpacity(isDark ? 0.38 : 0.24),
      sideButtonBg,
    );
    final activeSideFg = isDark ? Colors.white : scheme.onPrimary;
    final mainButtonBg = Color.alphaBlend(
      (isDark ? Colors.white : Colors.black).withOpacity(isDark ? 0.2 : 0.06),
      accent,
    );
    final sideShadow = (isDark ? Colors.black : scheme.primary).withOpacity(0.2);
    final mainShadow = accent.withOpacity(isDark ? 0.42 : 0.28);

    Widget sideButton({
      required VoidCallback? onPressed,
      required IconData icon,
      required String tooltip,
      bool isActive = false,
    }) {
      final bg = isActive ? activeSideBg : sideButtonBg;
      final fg = isActive ? activeSideFg : iconFgColor;
      return Tooltip(
        message: tooltip,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          elevation: onPressed == null ? 0 : 3,
          shadowColor: isActive ? mainShadow : sideShadow,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    icon,
                    size: 28,
                    color: fg.withOpacity(onPressed == null ? 0.4 : 1),
                  ),
                  if (isActive)
                    Positioned(
                      right: 13,
                      bottom: 13,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white : scheme.onPrimary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StreamBuilder<bool>(
          stream: player.shuffleModeEnabledStream,
          initialData: player.shuffleModeEnabled,
          builder: (context, snapshot) {
            final enabled = snapshot.data ?? false;
            return sideButton(
              tooltip: enabled ? 'Shuffle on' : 'Shuffle off',
              isActive: enabled,
              onPressed: () async {
                final next = !player.shuffleModeEnabled;
                await player.setShuffleModeEnabled(next);
                if (next) {
                  await player.shuffle();
                }
              },
              icon: Icons.shuffle_rounded,
            );
          },
        ),
        const SizedBox(width: 12),
        sideButton(
          tooltip: 'Previous',
          onPressed: player.hasPrevious ? () => player.seekToPrevious() : null,
          icon: Icons.skip_previous_rounded,
        ),
        const SizedBox(width: 16),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return Tooltip(
              message: playing ? 'Pause' : 'Play',
              child: Material(
                color: mainButtonBg,
                shape: const CircleBorder(),
                elevation: 8,
                shadowColor: mainShadow,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () async {
                    if (playing) {
                      await player.pause();
                    } else {
                      await onPlayPressed();
                    }
                  },
                  child: SizedBox(
                    width: 74,
                    height: 74,
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 38,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 16),
        sideButton(
          tooltip: 'Next',
          onPressed: player.hasNext ? () => player.seekToNext() : null,
          icon: Icons.skip_next_rounded,
        ),
        const SizedBox(width: 12),
        StreamBuilder<LoopMode>(
          stream: player.loopModeStream,
          initialData: player.loopMode,
          builder: (context, snapshot) {
            final loopMode = snapshot.data ?? LoopMode.off;
            final icon = switch (loopMode) {
              LoopMode.off => Icons.repeat_rounded,
              LoopMode.all => Icons.repeat_rounded,
              LoopMode.one => Icons.repeat_one_rounded,
            };
            return sideButton(
              tooltip: switch (loopMode) {
                LoopMode.off => 'Repeat off',
                LoopMode.all => 'Repeat all',
                LoopMode.one => 'Repeat one',
              },
              isActive: loopMode != LoopMode.off,
              onPressed: () async {
                final next = switch (player.loopMode) {
                  LoopMode.off => LoopMode.all,
                  LoopMode.all => LoopMode.one,
                  LoopMode.one => LoopMode.off,
                };
                await player.setLoopMode(next);
              },
              icon: icon,
            );
          },
        ),
      ],
    );
  }
}
