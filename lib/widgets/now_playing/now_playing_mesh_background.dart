import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

/// Animated multi-point ambient mesh gradient background with isolated RepaintBoundary
/// and decal Gaussian blur filter.
class NowPlayingMeshBackground extends StatelessWidget {
  final Color targetTopColor;
  final Color targetMidColor;
  final Color targetAccentColor;
  final Animation<double> animation;
  final bool isDark;
  final Widget child;

  const NowPlayingMeshBackground({
    super.key,
    required this.targetTopColor,
    required this.targetMidColor,
    required this.targetAccentColor,
    required this.animation,
    required this.isDark,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      tween: ColorTween(end: targetTopColor),
      builder: (context, topColor, _) {
        return TweenAnimationBuilder<Color?>(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          tween: ColorTween(end: targetMidColor),
          builder: (context, midColor, _) {
            return TweenAnimationBuilder<Color?>(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              tween: ColorTween(end: targetAccentColor),
              builder: (context, accentColor, _) {
                final c1 = topColor ?? targetTopColor;
                final c2 = midColor ?? targetMidColor;
                final c3 = accentColor ?? targetAccentColor;

                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) {
                    final size = MediaQuery.of(context).size;
                    final isLandscape = size.width > size.height;
                    final baseBlobSize =
                        (isLandscape ? size.height : size.width) * 1.35;

                    final t = animation.value;

                    // Orientation-aware paths ensuring animation stays balanced and visible on screen
                    final double x1, y1, x2, y2, x3, y3, x4, y4;
                    if (isLandscape) {
                      x1 = 0.12 + 0.32 * ((math.sin(t * math.pi * 2) + 1) / 2);
                      y1 = 0.20 + 0.60 * ((math.cos(t * math.pi * 2) + 1) / 2);

                      x2 = 0.56 + 0.34 * ((math.cos(t * math.pi * 2 + math.pi) + 1) / 2);
                      y2 = 0.20 + 0.60 * ((math.sin(t * math.pi * 4) + 1) / 2);

                      x3 = 0.28 + 0.44 * ((math.sin(t * math.pi * 4 + math.pi / 4) + 1) / 2);
                      y3 = 0.15 + 0.70 * ((math.cos(t * math.pi * 2 + math.pi / 4) + 1) / 2);

                      x4 = 0.15 + 0.70 * ((math.cos(t * math.pi * 2 + math.pi / 2) + 1) / 2);
                      y4 = 0.25 + 0.50 * ((math.sin(t * math.pi * 2 + math.pi / 2) + 1) / 2);
                    } else {
                      x1 = 0.20 + 0.60 * ((math.sin(t * math.pi * 2) + 1) / 2);
                      y1 = 0.12 + 0.34 * ((math.cos(t * math.pi * 2) + 1) / 2);

                      x2 = 0.20 + 0.60 * ((math.cos(t * math.pi * 2 + math.pi) + 1) / 2);
                      y2 = 0.55 + 0.35 * ((math.sin(t * math.pi * 4) + 1) / 2);

                      x3 = 0.10 + 0.55 * ((math.sin(t * math.pi * 4 + math.pi / 4) + 1) / 2);
                      y3 = 0.30 + 0.42 * ((math.cos(t * math.pi * 2 + math.pi / 4) + 1) / 2);

                      x4 = 0.35 + 0.55 * ((math.cos(t * math.pi * 2 + math.pi / 2) + 1) / 2);
                      y4 = 0.25 + 0.45 * ((math.sin(t * math.pi * 2 + math.pi / 2) + 1) / 2);
                    }

                    Widget buildBlob(
                      double xOffset,
                      double yOffset,
                      Color color,
                      double scale,
                    ) {
                      final effectiveBlobSize = baseBlobSize * scale;
                      return Positioned(
                        left: xOffset * size.width - effectiveBlobSize / 2,
                        top: yOffset * size.height - effectiveBlobSize / 2,
                        child: Container(
                          width: effectiveBlobSize,
                          height: effectiveBlobSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                color.withValues(alpha: 0.90),
                                color.withValues(alpha: 0.55),
                                color.withValues(alpha: 0.20),
                                color.withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.35, 0.70, 1.0],
                            ),
                          ),
                        ),
                      );
                    }

                    final gradientLayer = DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: isLandscape
                              ? Alignment.centerLeft
                              : Alignment.topCenter,
                          end: isLandscape
                              ? Alignment.centerRight
                              : Alignment.bottomCenter,
                          colors: [c1, c3],
                        ),
                      ),
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: ImageFiltered(
                                imageFilter: ImageFilter.blur(
                                  sigmaX: 42,
                                  sigmaY: 42,
                                  tileMode: TileMode.decal,
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    buildBlob(x1, y1, c1, 1.25),
                                    buildBlob(x2, y2, c2, 1.30),
                                    buildBlob(x3, y3, c3, 1.15),
                                    buildBlob(x4, y4, c2, 1.35),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );

                    final vignette = DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.topCenter,
                          radius: 1.1,
                          colors: [
                            Colors.transparent,
                            (isDark ? Colors.black : Colors.white)
                                .withValues(alpha: isDark ? 0.22 : 0.16),
                          ],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    );

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        gradientLayer,
                        IgnorePointer(child: vignette),
                        child,
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
