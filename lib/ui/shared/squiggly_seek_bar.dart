import 'package:flutter/material.dart';
import 'dart:math' as math;

class SquigglySeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final Function(Duration) onChanged;
  final bool isDark;
  const SquigglySeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.onChanged,
    this.isDark = true,
  });
  @override
  State<SquigglySeekBar> createState() => _SquigglySeekBarState();
}

class SquigglePainter extends CustomPainter {
  final double progress;
  final double phase;
  final Color color;
  final Color baseColor;

  // Cache the paths so we only calculate math.sin() once, not 120 times a second!
  static Path? _cachedBgPath;
  static double _cachedWidth = 0;

  SquigglePainter({
    required this.progress,
    this.phase = 0,
    required this.color,
    required this.baseColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double midHeight = size.height / 2;
    const double amplitude = 5.0;
    const double wavelength = 18.0;
    const double frequency = 2 * math.pi / wavelength;

    // We make the path slightly longer than the screen so we can slide it
    final double extendedWidth = size.width + (wavelength * 2);

    // Only rebuild the path if the screen size physically changes
    if (_cachedBgPath == null || _cachedWidth != size.width) {
      _cachedWidth = size.width;

      final path = Path();
      path.moveTo(0, midHeight + amplitude * math.sin(0));
      
      // Step by 2 pixels instead of 1 (visually identical, halves memory/math)
      for (double x = 0; x <= extendedWidth; x += 2) {
        final y = midHeight + amplitude * math.sin(x * frequency);
        path.lineTo(x, y);
      }
      _cachedBgPath = path;
    }

    // Mathematically shift the canvas left based on the animation phase
    final shiftX = -(phase / (2 * math.pi)) * wavelength;

    final bgPaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // Draw background squiggle
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.translate(shiftX, 0);
    canvas.drawPath(_cachedBgPath!, bgPaint);
    canvas.restore();

    // Draw progress squiggle
    final progressWidth = size.width * progress;
    if (progressWidth > 0) {
      final progressPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      canvas.save();
      // Clip exactly to the progress width
      canvas.clipRect(Rect.fromLTWH(0, 0, progressWidth, size.height));
      canvas.translate(shiftX, 0);
      canvas.drawPath(_cachedBgPath!, progressPaint);
      canvas.restore();

      // Draw thumb
      final thumbX = progressWidth;
      // We only need ONE math.sin calculation per frame for the thumb's Y position
      final thumbY = midHeight + amplitude * math.sin(thumbX * frequency + phase);

      final glowPaint = Paint()
        ..color = color.withOpacity(0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(Offset(thumbX, thumbY), 10, glowPaint);

      final thumbPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(thumbX, thumbY), 7, thumbPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SquigglePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.phase != phase;
}