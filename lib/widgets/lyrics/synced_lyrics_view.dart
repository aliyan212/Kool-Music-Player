import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../utils/lyrics.dart';
import 'lyric_line_tile.dart';

/// Full lyrics presentation widget with backdrop blur, alpha gradient edge masks,
/// and smooth synchronized scrolling.
class SyncedLyricsView extends StatelessWidget {
  final String? rawLyrics;
  final bool isSynced;
  final List<LyricLine> lrcLines;
  final ValueListenable<int> activeLyricIndex;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final Uint8List? displayedArtworkBytes;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onUserScroll;
  final int initialScrollIndex;
  final double initialAlignment;

  const SyncedLyricsView({
    super.key,
    required this.rawLyrics,
    required this.isSynced,
    required this.lrcLines,
    required this.activeLyricIndex,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.displayedArtworkBytes,
    required this.onSeek,
    required this.onUserScroll,
    this.initialScrollIndex = 0,
    this.initialAlignment = 0.36,
  });

  @override
  Widget build(BuildContext context) {
    Widget lyricsContent;
    if (rawLyrics == null) {
      lyricsContent = Container(
        alignment: Alignment.center,
        child: const Text(
          "No Lyrics Found",
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
      );
    } else if (!isSynced || lrcLines.isEmpty) {
      lyricsContent = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Text(
            rawLyrics!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ),
      );
    } else {
      lyricsContent = LayoutBuilder(
        builder: (context, constraints) {
          final topPadding = constraints.maxHeight * 0.32;
          final bottomPadding = constraints.maxHeight * 0.48;

          return ShaderMask(
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, 0.12, 0.88, 1.0],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification ||
                    notification is UserScrollNotification) {
                  onUserScroll();
                }
                return false;
              },
              child: ScrollablePositionedList.builder(
                itemScrollController: itemScrollController,
                itemPositionsListener: itemPositionsListener,
                initialScrollIndex: initialScrollIndex.clamp(
                  0,
                  lrcLines.isNotEmpty ? lrcLines.length - 1 : 0,
                ),
                initialAlignment: initialAlignment,
                itemCount: lrcLines.length,
                padding: EdgeInsets.only(
                  top: topPadding,
                  bottom: bottomPadding,
                  left: 20,
                  right: 20,
                ),
                physics: const BouncingScrollPhysics(),
                itemBuilder: (context, index) {
                  final line = lrcLines[index];
                  return LyricLineTile(
                    index: index,
                    line: line,
                    activeIndex: activeLyricIndex,
                    onTap: () {
                      onUserScroll();
                      onSeek(line.time);
                    },
                  );
                },
              ),
            ),
          );
        },
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (displayedArtworkBytes != null)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                child: Opacity(
                  opacity: 0.18,
                  child: Image.memory(
                    displayedArtworkBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        lyricsContent,
      ],
    );
  }
}

