import 'package:flutter/material.dart';

/// App bar action buttons shown during multi-selection mode.
class MultiSelectActionButtons extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final VoidCallback onToggleSelectAll;
  final VoidCallback? onRemove;
  final VoidCallback onCancel;
  final String removeTooltip;

  const MultiSelectActionButtons({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.onToggleSelectAll,
    this.onRemove,
    required this.onCancel,
    this.removeTooltip = 'Remove',
  });

  @override
  Widget build(BuildContext context) {
    final allSelected = totalCount > 0 && selectedCount == totalCount;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: allSelected ? 'Deselect all' : 'Select all',
          icon: Icon(
            allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          ),
          onPressed: onToggleSelectAll,
        ),
        IconButton(
          tooltip: removeTooltip,
          onPressed: selectedCount > 0 ? onRemove : null,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
        IconButton(
          tooltip: 'Cancel',
          onPressed: onCancel,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

