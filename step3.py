import re
import os

with open('lib/main.dart', 'r') as f:
    code = f.read()

def extract_block(text, start_pattern, allow_class=True):
    match = re.search(start_pattern, text)
    if not match:
        return text, None
    start_idx = match.start()
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
                end_idx = i + 1
                block = text[start_idx:end_idx]
                new_text = text[:start_idx] + text[end_idx:]
                return new_text, block
    return text, None

# 1. ThemeNotifier -> core/theme/app_theme.dart
code, theme_block = extract_block(code, r'class ThemeNotifier\b')
if theme_block:
    os.makedirs('lib/core/theme', exist_ok=True)
    with open('lib/core/theme/app_theme.dart', 'w') as f:
        f.write("import 'package:flutter/material.dart';\nimport 'package:shared_preferences/shared_preferences.dart';\n\n" + theme_block)

# 2. Add CachingService -> data/services/caching_service.dart
# The prompt says: Move the LinkedHashMap artwork caching logic to a dedicated CachingService singleton in data/services/
os.makedirs('lib/data/services', exist_ok=True)
with open('lib/data/services/caching_service.dart', 'w') as f:
    f.write("""import 'dart:collection';
import 'dart:typed_data';

class CachingService {
  static final CachingService _instance = CachingService._internal();
  factory CachingService() => _instance;
  CachingService._internal();

  final LinkedHashMap<String, Uint8List?> thumbnailCache = LinkedHashMap<String, Uint8List?>();
  final LinkedHashMap<String, Uint8List?> highResCache = LinkedHashMap<String, Uint8List?>();

  void clearOldThumbnails(int max) {
    while (thumbnailCache.length > max) {
      thumbnailCache.remove(thumbnailCache.keys.first);
    }
  }

  void clearOldHighRes(int max) {
    while (highResCache.length > max) {
      highResCache.remove(highResCache.keys.first);
    }
  }
}
""")

# We need to replace usages in main.dart:
code = re.sub(r'\b_thumbnailCache\b', 'CachingService().thumbnailCache', code)
code = re.sub(r'\b_highResCache\b', 'CachingService().highResCache', code)

# Remove the old declarations
code = re.sub(r'final LinkedHashMap<String, Uint8List\?> _thumbnailCache\s*=\s*LinkedHashMap<String, Uint8List\?>\(\);', '', code)
code = re.sub(r'final LinkedHashMap<String, Uint8List\?> _highResCache\s*=\s*LinkedHashMap<String, Uint8List\?>\(\);', '', code)


# 3. SquigglySeekBar -> ui/shared/squiggly_seek_bar.dart
code, squiggly_block = extract_block(code, r'class SquigglySeekBar\b')
code, painter_block = extract_block(code, r'class SquigglePainter\b')
if squiggly_block or painter_block:
    os.makedirs('lib/ui/shared', exist_ok=True)
    with open('lib/ui/shared/squiggly_seek_bar.dart', 'w') as f:
        f.write("import 'package:flutter/material.dart';\nimport 'dart:math' as math;\n\n")
        f.write((squiggly_block or "") + "\n\n" + (painter_block or ""))

# 4. _FrostedCard -> ui/shared/frosted_card.dart
code, frosted_block = extract_block(code, r'class _FrostedCard\b')
if frosted_block:
    with open('lib/ui/shared/frosted_card.dart', 'w') as f:
        f.write("import 'package:flutter/material.dart';\nimport 'dart:ui';\n\n")
        # Rename to FrostedCard
        f.write(frosted_block.replace('class _FrostedCard', 'class FrostedCard'))
    # Replace usages
    code = code.replace('_FrostedCard', 'FrostedCard')

# 5. Extract Theme builder? The prompt: "ThemeNotifier, _buildTheme logic"
# Let's search for _buildTheme
code, build_theme_block = extract_block(code, r'ThemeData _buildTheme\(')
if build_theme_block:
    with open('lib/core/theme/app_theme.dart', 'a') as f:
        f.write("\n\n" + build_theme_block)
    # Replace usage
    code = code.replace('_buildTheme(', 'buildTheme(')

# Save code
with open('lib/main.dart', 'w') as f:
    f.write(code)

