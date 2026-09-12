import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/format_utils.dart';

/// A unified, highly-optimized song & media item tile used across the app
/// (Library, Playlists, Albums, Artists, and Queue).
///
/// Features:
/// - Support for circular or rounded-rect artwork via [FastArtworkWidget]
/// - Custom leading widget slot (e.g. track numbers, reorder handles)
/// - Flexible trailing slot (e.g. popups, checkboxes, play/pause buttons, reorder handles)
/// - Active/playing and selection styling (tints, borders, glow shadows, badges)
/// - Optional metadata row with tabular figure duration formatting
class UniversalSongTile extends StatelessWidget {
  /// The song model to display. If provided, title, subtitle, artworkId,
  /// and duration are inferred from it unless explicitly overridden.
  final SongModel? song;

  /// Custom artwork ID. Defaults to `song?.id` or `song?.albumId`.
  final int? artworkId;

  /// Artwork type for [FastArtworkWidget]. Defaults to [ArtworkType.AUDIO].
  final ArtworkType artworkType;

  /// Custom leading widget replacing the artwork.
  final Widget? leading;

  /// Custom widget placed before the artwork (e.g. a reorder handle or track number).
  final Widget? prefixLeading;

  /// Main title text. Defaults to `song?.title`.
  final String? title;

  /// Subtitle text. Defaults to `song?.artist`.
  final String? subtitle;

  /// Additional metadata line text (e.g. album name or track count).
  final String? meta;

  /// Duration in milliseconds to format and display. Defaults to `song?.duration`.
  final int? durationMs;

  /// Trailing widget (e.g. [PopupMenuButton], [Checkbox], action button).
  final Widget? trailing;

  /// Primary tap callback.
  final VoidCallback? onTap;

  /// Long press callback.
  final VoidCallback? onLongPress;

  /// Whether this song is currently loaded in the player.
  final bool isCurrent;

  /// Whether this song is actively playing audio.
  final bool isPlaying;

  /// Whether this song is selected in multi-select mode.
  final bool isSelected;

  /// Whether the parent screen is in multi-selection mode.
  final bool isSelectionMode;

  /// Dimensions for the artwork thumbnail.
  final double artworkSize;

  /// Corner radius for the artwork image. Ignored if [circularArtwork] is true.
  final BorderRadius? artworkBorderRadius;

  /// Whether the artwork should be clipped to a circle.
  final bool circularArtwork;

  /// Whether to show status badges (selection checkmark, playing equalizer) over artwork.
  final bool showArtworkBadges;

  /// Fallback icon to display when no artwork is available.
  final IconData? fallbackIcon;

  /// Inner padding of the tile content.
  final EdgeInsetsGeometry? padding;

  /// Outer margin around the tile container.
  final EdgeInsetsGeometry? margin;

  /// Explicit background color override.
  final Color? backgroundColor;

  /// Explicit border color override.
  final Color? borderColor;

  /// Corner radius for the tile container. Defaults to 20 if shadows enabled, 14 otherwise.
  final BorderRadius? borderRadius;

  /// Whether to render elevation / depth shadows when active or on light mode.
  final bool showShadows;

  const UniversalSongTile({
    super.key,
    this.song,
    this.artworkId,
    this.artworkType = ArtworkType.AUDIO,
    this.leading,
    this.prefixLeading,
    this.title,
    this.subtitle,
    this.meta,
    this.durationMs,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.isCurrent = false,
    this.isPlaying = false,
    this.isSelected = false,
    this.isSelectionMode = false,
    this.artworkSize = 50,
    this.artworkBorderRadius,
    this.circularArtwork = false,
    this.showArtworkBadges = false,
    this.fallbackIcon,
    this.padding,
    this.margin,
    this.backgroundColor,
    this.borderColor,
    this.borderRadius,
    this.showShadows = false,
    this.showMetaDuration = true,
  });

  /// Whether to show the duration in the meta line under the title/artist.
  /// Set to false when duration is shown in trailing or not needed.
  final bool showMetaDuration;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final resolvedTitle = (title ?? song?.title ?? 'Unknown').trim();
    final resolvedSubtitle = (subtitle ?? song?.artist ?? 'Unknown Artist').trim();
    final resolvedMeta = meta?.trim();
    final resolvedDuration = durationMs ?? song?.duration;
    final effectiveArtworkId = artworkId ?? song?.id ?? 0;

    // Background color resolution
    final Color resolvedBgColor;
    if (backgroundColor != null) {
      resolvedBgColor = backgroundColor!;
    } else if (isSelectionMode && isSelected) {
      resolvedBgColor = Color.alphaBlend(
        cs.primaryContainer.withValues(alpha: isDark ? 0.28 : 0.55),
        cs.surface,
      );
    } else if (isCurrent) {
      resolvedBgColor = Color.alphaBlend(
        cs.secondaryContainer.withValues(alpha: isDark ? 0.35 : 0.55),
        cs.surface,
      );
    } else {
      resolvedBgColor = cs.surfaceContainerLow;
    }

    // Border color resolution
    final Color resolvedBorderColor;
    if (borderColor != null) {
      resolvedBorderColor = borderColor!;
    } else if (isSelectionMode && isSelected) {
      resolvedBorderColor = cs.primary.withValues(alpha: isDark ? 0.35 : 0.30);
    } else if (isCurrent) {
      resolvedBorderColor = cs.secondary.withValues(alpha: isDark ? 0.30 : 0.22);
    } else {
      resolvedBorderColor = cs.outlineVariant.withValues(alpha: isDark ? 0.28 : 0.35);
    }

    // Border radius resolution
    final resolvedRadius = borderRadius ?? BorderRadius.circular(showShadows ? 20 : 14);

    // Shadows
    final List<BoxShadow> shadows = [];
    if (showShadows) {
      if (!isDark) {
        shadows.add(
          BoxShadow(
            blurRadius: 10,
            spreadRadius: -6,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: isCurrent ? 0.12 : 0.08),
          ),
        );
      }
      if (isCurrent) {
        shadows.add(
          BoxShadow(
            blurRadius: 18,
            spreadRadius: -8,
            offset: const Offset(0, 10),
            color: cs.primary.withValues(alpha: isDark ? 0.28 : 0.18),
          ),
        );
      }
    }

    // Build Artwork / Leading widget
    Widget leadingWidget;
    if (leading != null) {
      leadingWidget = leading!;
    } else {
      Widget artwork = FastArtworkWidget(
        id: effectiveArtworkId,
        type: artworkType,
        width: artworkSize,
        height: artworkSize,
        artworkFit: BoxFit.cover,
        nullArtworkWidget: Container(
          width: artworkSize,
          height: artworkSize,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            shape: circularArtwork ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: circularArtwork
                ? null
                : (artworkBorderRadius ?? BorderRadius.circular(10)),
          ),
          child: Icon(
            fallbackIcon ?? (artworkType == ArtworkType.ALBUM ? Icons.album_rounded : Icons.music_note_rounded),
            color: cs.onSurfaceVariant,
            size: artworkSize * 0.45,
          ),
        ),
      );

      if (circularArtwork) {
        artwork = ClipOval(child: artwork);
      } else {
        artwork = ClipRRect(
          borderRadius: artworkBorderRadius ?? BorderRadius.circular(10),
          child: artwork,
        );
      }

      if (isCurrent && circularArtwork) {
        artwork = AnimatedScale(
          scale: 1.03,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: artwork,
        );
      }

      if (showArtworkBadges) {
        leadingWidget = Stack(
          children: [
            artwork,
            if (isSelectionMode)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      cs.surface.withValues(alpha: 0.75),
                      cs.surfaceContainerHigh,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 14,
                    color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            if (isCurrent)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      cs.surface.withValues(alpha: 0.75),
                      cs.surfaceContainerHigh,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(
                    isPlaying
                        ? Icons.graphic_eq_rounded
                        : Icons.pause_circle_filled_rounded,
                    size: 14,
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
          ],
        );
      } else {
        leadingWidget = artwork;
      }
    }

    if (prefixLeading != null) {
      leadingWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          prefixLeading!,
          leadingWidget,
        ],
      );
    }

    // Title & Subtitle styling
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
      letterSpacing: -0.05,
      color: isCurrent ? cs.primary : null,
    );

    final subtitleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );

    final durationText = (showMetaDuration && resolvedDuration != null)
        ? formatTime(resolvedDuration)
        : null;

    final hasMetaLine = (resolvedMeta != null && resolvedMeta.isNotEmpty) || durationText != null;

    final content = Row(
      children: [
        leadingWidget,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                resolvedTitle.isEmpty ? 'Unknown Title' : resolvedTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              const SizedBox(height: 3),
              Text(
                resolvedSubtitle.isEmpty ? 'Unknown Artist' : resolvedSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: subtitleStyle,
              ),
              if (hasMetaLine) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (resolvedMeta != null && resolvedMeta.isNotEmpty)
                      Expanded(
                        child: Text(
                          resolvedMeta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.75),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (durationText != null) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 48,
                        child: Text(
                          durationText,
                          maxLines: 1,
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.visible,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );

    final effectivePadding = padding ??
        (showShadows
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 14)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 8));

    final effectiveMargin = margin ??
        (showShadows
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
            : EdgeInsets.zero);

    Widget tile = Padding(
      padding: effectiveMargin,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: ShapeDecoration(
          color: resolvedBgColor,
          shape: RoundedRectangleBorder(
            borderRadius: resolvedRadius,
            side: resolvedBorderColor == Colors.transparent
                ? BorderSide.none
                : BorderSide(color: resolvedBorderColor, width: 1),
          ),
          shadows: shadows,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: resolvedRadius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: effectivePadding,
              child: content,
            ),
          ),
        ),
      ),
    );

    return RepaintBoundary(
      key: song != null ? ValueKey(song!.id) : null,
      child: tile,
    );
  }
}
