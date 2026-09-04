import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

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

class _SquigglySeekBarState extends State<SquigglySeekBar>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late AnimationController _seekBackController;
  double? _dragProgress;
  double _smoothProgress = 0.0;
  double _seekBackFrom = 0.0;
  double _seekBackTo = 0.0;

  static const Duration _animateBackMinDelta = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _seekBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _seekBackController.addListener(() {
      if (!mounted) return;
      if (_dragProgress != null) return;
      final t = Curves.easeOutCubic.transform(_seekBackController.value);
      final v = lerpDouble(_seekBackFrom, _seekBackTo, t) ?? _seekBackTo;
      setState(() => _smoothProgress = v);
    });
    if (widget.isPlaying) _animController.repeat();

    final denom = widget.duration.inMilliseconds == 0
        ? 1
        : widget.duration.inMilliseconds;
    _smoothProgress = (widget.position.inMilliseconds / denom).clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant SquigglySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_animController.isAnimating) {
      _animController.repeat();
    } else if (!widget.isPlaying && _animController.isAnimating) {
      _animController.stop();
    }

    if (_dragProgress != null) return;

    final denom = widget.duration.inMilliseconds == 0
        ? 1
        : widget.duration.inMilliseconds;
    final newActual = (widget.position.inMilliseconds / denom).clamp(0.0, 1.0);

    final isBackwards = widget.position < oldWidget.position;
    final backDelta = oldWidget.position - widget.position;
    final shouldAnimateBack = isBackwards && backDelta >= _animateBackMinDelta;

    if (!shouldAnimateBack) {
      _seekBackController.stop();
      _smoothProgress = newActual;
      return;
    }

    _seekBackController.stop();
    _seekBackFrom = _smoothProgress;
    _seekBackTo = newActual;
    _seekBackController.forward(from: 0.0);
  }

  @override
  void dispose() {
    _animController.dispose();
    _seekBackController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _dragProgress ?? _smoothProgress;
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            _seekBackController.stop();
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            _dragProgress = (localPos.dx / constraints.maxWidth).clamp(0.0, 1.0);
            setState(() {});
          },
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            _dragProgress = (localPos.dx / constraints.maxWidth).clamp(0.0, 1.0);
            setState(() {});
          },
          onHorizontalDragEnd: (_) {
            final targetProgress = _dragProgress ?? _smoothProgress;
            _dragProgress = null;
            final target = Duration(
              milliseconds:
                  (widget.duration.inMilliseconds * targetProgress).round(),
            );
            widget.onChanged(target);
            setState(() {});
          },
          child: SizedBox(
            height: 20,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_animController, _seekBackController]),
                builder: (context, _) {
                  return CustomPaint(
                    painter: SquigglePainter(
                      progress: progress,
                      phase: _animController.value * 2 * math.pi,
                      color: widget.isDark ? Colors.white : Colors.black87,
                      baseColor: widget.isDark ? Colors.white24 : Colors.black26,
                    ),
                    child: const SizedBox.expand(),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
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
        ..shader = RadialGradient(
          colors: [color.withOpacity(0.5), color.withOpacity(0.0)],
        ).createShader(Rect.fromCircle(center: Offset(thumbX, thumbY), radius: 16));
      canvas.drawCircle(Offset(thumbX, thumbY), 16, glowPaint);

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