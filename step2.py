import re

def extract_block(text, start_pattern):
    match = re.search(start_pattern, text)
    if not match:
        return text, None
    start_idx = match.start()
    
    # Simple brace counting
    brace_count = 0
    in_block = False
    
    for i in range(start_idx, len(text)):
        if text[i] == '{':
            if not in_block:
                in_block = True
            brace_count += 1
        elif text[i] == '}':
            brace_count -= 1
            if in_block and brace_count == 0:
                # End of block found
                end_idx = i + 1
                block = text[start_idx:end_idx]
                new_text = text[:start_idx] + text[end_idx:]
                return new_text, block
                
    return text, None

with open('lib/main.dart', 'r') as f:
    code = f.read()

models = [
    (r'class _IsolateData\b', 'isolate_data.dart'),
    (r'class _UserPlaylist\b', 'user_playlist.dart'),
    (r'class _ArtistAlbum\b', 'album_stat.dart'),
    (r'class _AlbumArtistStat\b', 'album_stat.dart'),
    (r'class _AlbumTabStat\b', 'album_stat.dart'),
    (r'enum SortMode\b', 'sort_mode.dart'),
    (r'enum _AlbumArtistsSort\b', 'album_stat.dart'),
    (r'enum _AlbumsSort\b', 'album_stat.dart'),
    (r'enum _SmartPlaylistKind\b', 'user_playlist.dart'),
    (r'enum _UserPlaylistAction\b', 'user_playlist.dart')
]

file_contents = {}

for pattern, filename in models:
    code, block = extract_block(code, pattern)
    if block:
        # Strip leading underscores for public
        # A simple regex for class/enum names
        block = re.sub(r'class _', 'class ', block)
        block = re.sub(r'enum _', 'enum ', block)
        # Also clean up constructors
        block = re.sub(r'\b_([A-Z]\w+)\b', r'\1', block)
        
        file_contents[filename] = file_contents.get(filename, "") + "\n\n" + block

import os
os.makedirs('lib/data/models', exist_ok=True)

for filename, content in file_contents.items():
    path = f'lib/data/models/{filename}'
    with open(path, 'w') as f:
        f.write("import 'package:flutter/foundation.dart';\n" + content)
    print(f"Created {path}")

# Rewrite main.dart
# Also need to replace all usages of these private names in main.dart
names_to_replace = [
    '_IsolateData', '_UserPlaylist', '_ArtistAlbum', 
    '_AlbumArtistStat', '_AlbumTabStat', '_AlbumArtistsSort',
    '_AlbumsSort', '_SmartPlaylistKind', '_UserPlaylistAction'
]
for name in names_to_replace:
    public_name = name[1:]
    code = re.sub(r'\b' + name + r'\b', public_name, code)

# Prepend imports to main
imports = "\n".join([f"import 'data/models/{f}';" for f in set(f for _, f in models)])
code = imports + "\n" + code

with open('lib/main.dart', 'w') as f:
    f.write(code)
print("Updated main.dart for models.")
