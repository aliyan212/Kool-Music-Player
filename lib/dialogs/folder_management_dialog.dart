import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../services/local_audio_scanner.dart';

List<String> get _commonFolders {
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
    return LocalAudioScanner.getDefaultMusicDirectories();
  }
  return _androidCommonFolders;
}

const List<String> _androidCommonFolders = [
  '/storage/emulated/0/Music/',
  '/storage/emulated/0/Download/',
  '/storage/emulated/0/Podcasts/',
  '/storage/emulated/0/Ringtones/',
  '/storage/emulated/0/Alarms/',
  '/storage/emulated/0/Notifications/',
  '/storage/emulated/0/Recordings/',
  '/storage/emulated/0/DCIM/',
  '/storage/emulated/0/Audiobooks/',
];

String _commonFolderDisplayName(String path) {
  final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return trimmed;
  return parts.last;
}

String _normalizeFolderPath(String path) {
  var normalized = path.replaceAll('\\\\', '/');
  if (!normalized.endsWith('/')) normalized = '$normalized/';
  return normalized;
}

Widget _buildFolderTab(
  BuildContext ctx,
  StateSetter setModalState, {
  required Set<String> folders,
  required Set<String> otherFolders,
  required String title,
  required String emptyLabel,
  required String description,
  required bool isIncluded,
  required VoidCallback onClear,
}) {
  final cs = Theme.of(ctx).colorScheme;
  if (folders.isEmpty) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isIncluded ? Icons.folder_open : Icons.folder_off,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            emptyLabel,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
  return Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                description,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
            TextButton(
              onPressed: onClear,
              child: const Text('Clear all'),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders.elementAt(index);
            return ListTile(
              leading: Icon(isIncluded ? Icons.folder : Icons.folder_off_outlined),
              title: Text(folder, style: const TextStyle(fontSize: 14)),
              trailing: IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                color: cs.error,
                onPressed: () {
                  setModalState(() {
                    folders.remove(folder);
                  });
                },
              ),
            );
          },
        ),
      ),
    ],
  );
}

void showManageFoldersDialog({
  required BuildContext context,
  required Set<String> initialIncluded,
  required Set<String> initialExcluded,
  required Function(Set<String>, Set<String>) onSave,
}) {
  final included = Set<String>.from(initialIncluded);
  final excluded = Set<String>.from(initialExcluded);
  int activeTab = 0;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setModalState) {
            final cs = Theme.of(ctx).colorScheme;
            return SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.8,
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    TabBar(
                      onTap: (i) => activeTab = i,
                      labelColor: cs.primary,
                      unselectedLabelColor: cs.onSurfaceVariant,
                      tabs: const [
                        Tab(icon: Icon(Icons.folder_open_rounded), text: 'Included'),
                        Tab(icon: Icon(Icons.folder_off_rounded), text: 'Excluded'),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        'Quick-add common folders:',
                        style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: _commonFolders.map((folder) {
                          return ActionChip(
                            avatar: const Icon(Icons.folder, size: 18),
                            label: Text(
                              _commonFolderDisplayName(folder),
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () {
                              setModalState(() {
                                if (activeTab == 0) {
                                  included.add(folder);
                                } else {
                                  excluded.add(folder);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.folder_open, size: 18),
                              label: const Text("Browse folder…"),
                              onPressed: () async {
                                final folder = await FilePicker.platform.getDirectoryPath();
                                if (folder == null) return;
                                final normalized = _normalizeFolderPath(folder);
                                setModalState(() {
                                  if (activeTab == 0) {
                                    included.add(normalized);
                                  } else {
                                    excluded.add(normalized);
                                  }
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // ── Included tab ──
                          _buildFolderTab(
                            ctx,
                            setModalState,
                            folders: included,
                            otherFolders: excluded,
                            title: 'Included folders',
                            emptyLabel: 'No folders included — all songs are shown.',
                            description:
                                'Only songs inside these folders (and subfolders) are shown.',
                            isIncluded: true,
                            onClear: () => setModalState(() => included.clear()),
                          ),
                          // ── Excluded tab ──
                          _buildFolderTab(
                            ctx,
                            setModalState,
                            folders: excluded,
                            otherFolders: included,
                            title: 'Excluded folders',
                            emptyLabel: 'No folders excluded.',
                            description:
                                'Songs inside these folders are hidden from the library.',
                            isIncluded: false,
                            onClear: () => setModalState(() => excluded.clear()),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text("Cancel"),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              onSave(included, excluded);
                            },
                            child: const Text("Save"),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
