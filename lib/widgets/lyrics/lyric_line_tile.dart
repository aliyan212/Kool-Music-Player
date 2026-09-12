import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/lyrics.dart';

enum LyricTileMode { active, adjacent, near, far }

class LyricLineTile extends StatefulWidget {
  final int index;
  final LyricLine line;
  final ValueListenable<int> activeIndex;
  final VoidCallback onTap;

  const LyricLineTile({
    super.key,
    required this.index,
    required this.line,
    required this.activeIndex,
    required this.onTap,
  });

  @override
  State<LyricLineTile> createState() => _LyricLineTileState();
}

class _LyricLineTileState extends State<LyricLineTile> {
  late LyricTileMode _mode;

  LyricTileMode _computeMode(int active) {
    final diff = (widget.index - active).abs();
    if (diff == 0) return LyricTileMode.active;
    if (diff == 1) return LyricTileMode.adjacent;
    if (diff == 2) return LyricTileMode.near;
    return LyricTileMode.far;
  }

  void _handleActiveChanged() {
    final next = _computeMode(widget.activeIndex.value);
    if (next == _mode) return;
    if (!mounted) return;
    setState(() => _mode = next);
  }

  @override
  void initState() {
    super.initState();
    _mode = _computeMode(widget.activeIndex.value);
    widget.activeIndex.addListener(_handleActiveChanged);
  }

  @override
  void didUpdateWidget(covariant LyricLineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      oldWidget.activeIndex.removeListener(_handleActiveChanged);
      widget.activeIndex.addListener(_handleActiveChanged);
    }
    final next = _computeMode(widget.activeIndex.value);
    if (next != _mode) _mode = next;
  }

  @override
  void dispose() {
    widget.activeIndex.removeListener(_handleActiveChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _mode == LyricTileMode.active;
    final double opacity;
    final double scale;
    switch (_mode) {
      case LyricTileMode.active:
        opacity = 1.0;
        scale = 1.0;
        break;
      case LyricTileMode.adjacent:
        opacity = 0.56;
        scale = 0.97;
        break;
      case LyricTileMode.near:
        opacity = 0.36;
        scale = 0.94;
        break;
      case LyricTileMode.far:
        opacity = 0.22;
        scale = 0.92;
        break;
    }

    final shadows = isActive
        ? <Shadow>[
            Shadow(
              color: Colors.white.withValues(alpha: 0.45),
              blurRadius: 18,
              offset: Offset.zero,
            ),
            Shadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ]
        : <Shadow>[
            Shadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(18),
        splashColor: Colors.white12,
        highlightColor: Colors.white.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            opacity: opacity,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              scale: scale,
              child: Text(
                widget.line.content,
                textAlign: TextAlign.center,
                softWrap: true,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  height: 1.38,
                  shadows: shadows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

