

class UserPlaylist {
  const UserPlaylist({
    required this.id,
    required this.name,
    required this.songIds,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String name;
  final List<int> songIds;
  final int createdAtMs;
  final int updatedAtMs;

  UserPlaylist copyWith({
    String? id,
    String? name,
    List<int>? songIds,
    int? createdAtMs,
    int? updatedAtMs,
  }) {
    return UserPlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      songIds: songIds ?? this.songIds,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songIds': songIds,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  static UserPlaylist? fromJson(dynamic json) {
    try {
      if (json is! Map) return null;
      final id = json['id']?.toString();
      final name = json['name']?.toString();
      final songIdsRaw = json['songIds'];
      final createdAt = json['createdAtMs'];
      final updatedAt = json['updatedAtMs'];
      if (id == null || id.trim().isEmpty) return null;
      if (name == null || name.trim().isEmpty) return null;

      final songIds = <int>[];
      if (songIdsRaw is List) {
        for (final v in songIdsRaw) {
          final id = v is int ? v : int.tryParse(v.toString());
          if (id == null) continue;
          songIds.add(id);
        }
      }

      final createdAtMs = createdAt is int
          ? createdAt
          : int.tryParse(createdAt?.toString() ?? '');
      final updatedAtMs = updatedAt is int
          ? updatedAt
          : int.tryParse(updatedAt?.toString() ?? '');
      final now = DateTime.now().millisecondsSinceEpoch;

      return UserPlaylist(
        id: id,
        name: name,
        songIds: songIds,
        createdAtMs: createdAtMs ?? now,
        updatedAtMs: updatedAtMs ?? (createdAtMs ?? now),
      );
    } catch (_) {
      return null;
    }
  }
}

enum SmartPlaylistKind { mostPlayed, recentlyPlayed, recentlyAdded }

enum UserPlaylistAction { rename, delete }