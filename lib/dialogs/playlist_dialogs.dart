import 'package:flutter/material.dart';
import '../data/models/user_playlist.dart';

Future<void> showCreateOrImportPlaylistSheet(
  BuildContext context, {
  required VoidCallback onNewPlaylist,
  required VoidCallback onImportPlaylist,
}) async {
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('New playlist'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_rounded),
              title: const Text('Import .m3u playlist'),
              onTap: () => Navigator.pop(ctx, 'import'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (picked == null) return;
  if (picked == 'new') {
    onNewPlaylist();
  } else if (picked == 'import') {
    onImportPlaylist();
  }
}

Future<UserPlaylist?> promptCreatePlaylist(
  BuildContext context, {
  required Future<UserPlaylist?> Function(String playlistName) onPlaylistCreated,
}) async {
  final controller = TextEditingController();
  final createdName = await showDialog<String>(
    context: context,
    builder: (dctx) {
      return AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Playlist name',
            hintText: 'e.g. Roadtrip',
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      );
    },
  );

  final name = (createdName ?? '').trim();
  if (name.isEmpty) return null;

  return await onPlaylistCreated(name);
}

Future<void> promptRenamePlaylist(
  BuildContext context,
  UserPlaylist playlist, {
  required Future<void> Function(String newName) onPlaylistRenamed,
}) async {
  final controller = TextEditingController(text: playlist.name);
  final newNameRaw = await showDialog<String>(
    context: context,
    builder: (dctx) {
      return AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Playlist name'),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );

  final newName = (newNameRaw ?? '').trim();
  if (newName.isEmpty || newName == playlist.name) return;

  await onPlaylistRenamed(newName);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Renamed to "$newName"'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

Future<void> confirmAndDeletePlaylist(
  BuildContext context,
  UserPlaylist playlist, {
  required Future<void> Function() onPlaylistDeleted,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) {
      return AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          '"${playlist.name}" will be removed from your playlists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  ) ?? false;

  if (!confirmed) return;

  await onPlaylistDeleted();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted "${playlist.name}"'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

Future<void> showUserPlaylistActionsSheet(
  BuildContext context,
  UserPlaylist playlist, {
  required VoidCallback onRenameClicked,
  required VoidCallback onDeleteClicked,
}) async {
  final picked = await showModalBottomSheet<UserPlaylistAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, UserPlaylistAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, UserPlaylistAction.delete),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  if (picked == null) return;
  switch (picked) {
    case UserPlaylistAction.rename:
      onRenameClicked();
      break;
    case UserPlaylistAction.delete:
      onDeleteClicked();
      break;
  }
}
