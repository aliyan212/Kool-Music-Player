import 'package:flutter/widgets.dart';

/// Snappy scroll physics for album artwork PageView/carousel.
/// Commits to next/previous page on natural thumb swipe (~18% width) or velocity > 150.
class SnappyArtworkScrollPhysics extends ScrollPhysics {
  final int itemCount;

  const SnappyArtworkScrollPhysics({
    required this.itemCount,
    super.parent = const BouncingScrollPhysics(),
  });

  @override
  SnappyArtworkScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return SnappyArtworkScrollPhysics(
      itemCount: itemCount,
      parent: buildParent(ancestor),
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }

    final double page = position.pixels / position.viewportDimension;
    final int currentPage = page.floor();
    final double fraction = page - currentPage;

    // A natural thumb swipe of ~18% width (~55px) or velocity > 150 commits to next/prev
    int targetPage = currentPage;
    if (velocity > 150 || (velocity >= -150 && fraction > 0.18)) {
      targetPage = currentPage + 1;
    } else if (velocity < -150 || (velocity <= 150 && fraction < 0.82)) {
      targetPage = currentPage;
    } else {
      targetPage = page.round();
    }

    if (itemCount > 0) {
      targetPage = targetPage.clamp(0, itemCount - 1);
    }

    final double targetPixels = targetPage * position.viewportDimension;
    if ((targetPixels - position.pixels).abs() > 0.1) {
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        targetPixels,
        velocity,
        tolerance: toleranceFor(position),
      );
    }
    return null;
  }
}

