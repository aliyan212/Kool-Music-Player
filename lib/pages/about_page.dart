import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import '../ui/shared/frosted_card.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bg;

  static const List<String> _taglines = [
    'You found the About page. Nice.',
    'Yes, these lines are here on purpose.',
    'Tap the note. I promise it’s not a trap.',
    'This app is listening… to your taps.',
    'Fourth wall? Consider it gently removed.',
    'Built with love, caffeine, and suspiciously many gradients.',
    'If something breaks, it’s not a bug. It’s a feature audition.',
  ];

  int _taglineIndex = 0;

  int _vibeIndex = 0;
  static const List<
    ({String name, Duration duration, double intensity, double midOpacity})
  >
  _vibes = [
    (
      name: 'Chill',
      duration: Duration(seconds: 14),
      intensity: 0.9,
      midOpacity: 0.10,
    ),
    (
      name: 'Vibe',
      duration: Duration(seconds: 10),
      intensity: 1.0,
      midOpacity: 0.12,
    ),
    (
      name: 'Chaos',
      duration: Duration(seconds: 7),
      intensity: 1.25,
      midOpacity: 0.16,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _bg = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _bg.dispose();
    super.dispose();
  }

  void _shuffleTagline() {
    HapticFeedback.selectionClick();
    setState(() => _taglineIndex = (_taglineIndex + 1) % _taglines.length);
  }

  void _cycleVibe() {
    HapticFeedback.mediumImpact();
    setState(() => _vibeIndex = (_vibeIndex + 1) % _vibes.length);

    final v = _vibes[_vibeIndex];
    final pos = _bg.value;
    _bg
      ..stop()
      ..duration = v.duration
      ..value = pos
      ..repeat();

    _capsuleTap(
      title: 'About page vibe: ${v.name}',
      description: v.name == 'Chill'
          ? 'Slow gradients, gentle bubbles. Good for pretending you have your life together.'
          : v.name == 'Vibe'
          ? 'The default. Smooth motion, just enough drama.'
          : 'Faster motion, louder colors. For demo day energy.',
    );
  }

  void _capsuleTap({required String title, required String description}) {
    HapticFeedback.lightImpact();
    final cs = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2200),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: cs.onInverseSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onInverseSurface.withValues(alpha: 0.92),
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _copyCredits() async {
    await Clipboard.setData(
      const ClipboardData(
        text:
            'Made by Muhammad Aliyan\nTester: Affan Iqbal\nSpecial thanks: you (For using ;))',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Credits copied. Yes, I watched you do it.'),
        duration: Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white70 : Colors.black54;

    final vibe = _vibes[_vibeIndex];

    return Scaffold(
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: _bg,
            builder: (context, _) {
              final t = _bg.value;
              final a1 =
                  Alignment.lerp(
                    Alignment.topLeft,
                    Alignment.topRight,
                    (math.sin(t * math.pi * 2) + 1) / 2,
                  ) ??
                  Alignment.topLeft;
              final a2 =
                  Alignment.lerp(
                    Alignment.bottomRight,
                    Alignment.bottomLeft,
                    (math.cos(t * math.pi * 2) + 1) / 2,
                  ) ??
                  Alignment.bottomRight;
              final top = isDark
                  ? const Color(0xFF121016)
                  : const Color(0xFFF7F3FF);
              final mid = cs.primary.withValues(alpha: 
                isDark ? 0.26 : vibe.midOpacity,
              );
              final bottom = isDark
                  ? const Color(0xFF0B0A0E)
                  : const Color(0xFFFFFFFF);
              return Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: a1,
                    end: a2,
                    colors: [top, mid, bottom],
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: -40,
            left: -30,
            child: _Bubble(
              color: cs.primary.withValues(alpha: isDark ? 0.18 : 0.12),
              size: 180,
              animation: _bg,
              phase: 0.15,
              intensity: vibe.intensity,
            ),
          ),
          Positioned(
            bottom: -50,
            right: -40,
            child: _Bubble(
              color: cs.secondary.withValues(alpha: isDark ? 0.18 : 0.10),
              size: 220,
              animation: _bg,
              phase: 0.55,
              intensity: vibe.intensity,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.arrow_back_rounded, color: subColor),
                      ),
                          Expanded(
                        child: Text(
                          'About',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Licenses',
                        onPressed: () {
                          showLicensePage(
                            context: context,
                            applicationName: 'Expressive Music',
                          );
                        },
                        icon: Icon(Icons.description_rounded, color: subColor),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Material(
                              color: cs.primaryContainer.withValues(alpha: 
                                isDark ? 0.25 : 0.80,
                              ),
                              borderRadius: BorderRadius.circular(22),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(22),
                                onTap: _shuffleTagline,
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    color: cs.onPrimaryContainer,
                                    size: 26,
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
                                    'Expressive Music',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _taglines[_taglineIndex],
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: subColor),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Tip: tap the music note to change this line. You’re literally doing UI testing right now.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: subColor.withValues(alpha: 0.9),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FrostedCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Credits',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: textColor,
                                    ),
                              ),
                              const SizedBox(height: 10),
                              RichText(
                                text: TextSpan(
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(color: textColor),
                                  children: [
                                    TextSpan(
                                      text: 'Made by: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'Muhammad Aliyan',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                    const TextSpan(text: '\n'),
                                    TextSpan(
                                      text: 'Tester: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'Affan Iqbal',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                    const TextSpan(text: '\n'),
                                    TextSpan(
                                      text: 'Special thanks: ',
                                      style: TextStyle(color: subColor),
                                    ),
                                    TextSpan(
                                      text: 'You ( For using ;) )',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _AboutPill(
                                    text: 'Vibe: ${vibe.name}',
                                    icon: Icons.graphic_eq_rounded,
                                    onTap: _cycleVibe,
                                  ),
                                  _AboutPill(
                                    text: 'Drag & reorder queue',
                                    icon: Icons.drag_handle_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Queue reordering',
                                      description:
                                          'Long-press and drag songs to change the play order. The queue updates live, so your next track is always what you see.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Synced lyrics editor',
                                    icon: Icons.lyrics_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Synced lyrics',
                                      description:
                                          'Lyrics can follow the song in real-time. Toggle lyrics on Now Playing and the view jumps to the current line automatically.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Edit tags & cover',
                                    icon: Icons.edit_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Tag editing',
                                      description:
                                          'Update metadata like title/artist and embed cover art into the file. It’s basically a tiny music “makeover” studio.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Palette vibes',
                                    icon: Icons.auto_awesome_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Dynamic colors',
                                      description:
                                          'The UI picks colors from the current artwork to paint the background. It’s cached and throttled to keep it smooth and battery-friendly.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Swipe, tap, repeat',
                                    icon: Icons.swipe_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Gestures',
                                      description:
                                          'Swipe down to dismiss Now Playing, tap controls for play/pause/skip, and use the mini player for quick navigation.',
                                    ),
                                  ),
                                  _AboutPill(
                                    text: 'Plays in background',
                                    icon: Icons.notifications_active_rounded,
                                    onTap: () => _capsuleTap(
                                      title: 'Background playback',
                                      description:
                                          'Keep listening while you do other things. Playback stays controllable via system media controls and notifications.',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _copyCredits,
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Copy credits'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: _shuffleTagline,
                                      icon: const Icon(
                                        Icons.casino_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Shuffle'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        FrostedCard(
                          child: Row(
                            children: [
                              Icon(
                                Icons.waving_hand_rounded,
                                color: cs.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Thanks for trying the app. If you’re reading this, the About page is doing its job.',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: subColor),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback? onTap;
  const _AboutPill({required this.text, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 
          Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.55,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white12
              : Colors.black12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: cs.onSecondaryContainer.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSecondaryContainer.withValues(alpha: 0.92),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return pill;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Color color;
  final double size;
  final Animation<double> animation;
  final double phase;
  final double intensity;
  const _Bubble({
    required this.color,
    required this.size,
    required this.animation,
    required this.phase,
    this.intensity = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = (animation.value + phase) % 1.0;
        final y = math.sin(t * math.pi * 2) * 10 * intensity;
        final x = math.cos(t * math.pi * 2) * 8 * intensity;
        return Transform.translate(
          offset: Offset(x, y),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [color, Colors.transparent],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}

