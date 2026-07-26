import 'package:flutter/material.dart';
import 'dart:ui';

class FrostedCard extends StatelessWidget {
  final Widget child;
  const FrostedCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? Colors.white12 : Colors.black12;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: (isDark ? const Color(0xFF1A1A1A) : Colors.white)
                .withOpacity(isDark ? 0.55 : 0.72),
            border: Border.all(color: border),
          ),
          child: child,
        ),
      ),
    );
  }
}