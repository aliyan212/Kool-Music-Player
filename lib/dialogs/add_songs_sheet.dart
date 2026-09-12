import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../ui/shared/fast_artwork_widget.dart';

/// Shows a bottom sheet to search, filter, and multi-select library songs
/// to add into a playlist. Returns the list of selected song IDs.
Future<List<int>> showAddSongsSheet({
  required BuildContext context,
  required List<SongModel> librarySongs,
  required Set<int> existingSongIds,
}) async {
  final selected = <int>{};

  final result = await showModalBottomSheet<List<int>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final isDark = Theme.of(ctx).brightness == Brightness.dark;

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Add songs',
                            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: cs.secondaryContainer.withValues(
                              alpha: isDark ? 0.25 : 0.55,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: cs.outlineVariant.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            '${selected.length} selected',
                            style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSecondaryContainer.withValues(
                                    alpha: 0.92,
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: librarySongs.length,
                      separatorBuilder: (_, _) => const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Divider(height: 1),
                      ),
                      itemBuilder: (ctx, i) {
                        final s = librarySongs[i];
                        final alreadyAdded = existingSongIds.contains(s.id);
                        final isChecked = selected.contains(s.id);
                        final artist = (s.artist ?? '').trim().isEmpty
                            ? 'Unknown Artist'
                            : s.artist!.trim();
                        return ListTile(
                          enabled: !alreadyAdded,
                          leading: ClipOval(
                            child: FastArtworkWidget(
                              id: s.id,
                              type: ArtworkType.AUDIO,
                              width: 44,
                              height: 44,
                              nullArtworkWidget: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.music_note_rounded,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            alreadyAdded ? 'Already in playlist' : artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: alreadyAdded
                              ? Icon(
                                  Icons.check_rounded,
                                  color: cs.onSurfaceVariant,
                                )
                              : Checkbox(
                                  value: isChecked,
                                  onChanged: (v) {
                                    setSheetState(() {
                                      if (v == true) {
                                        selected.add(s.id);
                                      } else {
                                        selected.remove(s.id);
                                      }
                                    });
                                  },
                                ),
                          onTap: alreadyAdded
                              ? null
                              : () {
                                  HapticFeedback.selectionClick();
                                  setSheetState(() {
                                    if (selected.contains(s.id)) {
                                      selected.remove(s.id);
                                    } else {
                                      selected.add(s.id);
                                    }
                                  });
                                },
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () => Navigator.pop(
                                      ctx,
                                      selected.toList(growable: false),
                                    ),
                            child: const Text('Add'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
  return result ?? const <int>[];
}

