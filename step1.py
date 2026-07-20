import os
import glob

# Files that have 'part of'
part_files = [
    'lib/pages/queue_page.dart',
    'lib/dialogs/lyrics_editor_dialog.dart',
    'lib/dialogs/tag_editor_dialog.dart',
    'lib/utils/tag_write_access.dart',
    'lib/utils/lyrics.dart',
    'lib/widgets/song_search_delegate.dart',
    'lib/widgets/mini_player.dart'
]

imports_to_add = """
import 'package:flutter/material.dart';
import '../main.dart'; // We will refine imports later
"""

for pf in part_files:
    if os.path.exists(pf):
        with open(pf, 'r') as f:
            content = f.read()
        # naive replacement
        content = content.replace("part of music_player_app;", imports_to_add)
        with open(pf, 'w') as f:
            f.write(content)
        print(f"Updated {pf}")

# main.dart
if os.path.exists('lib/main.dart'):
    with open('lib/main.dart', 'r') as f:
        lines = f.readlines()
    
    with open('lib/main.dart', 'w') as f:
        for line in lines:
            if line.startswith("part '"):
                # We could replace with imports, but we will just comment them out or convert to import
                file_path = line.split("'")[1]
                f.write(f"import '{file_path}';\n")
            else:
                f.write(line)
    print("Updated main.dart")
