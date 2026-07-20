# music_player

A Flutter music player focused on on-device playback.

This app scans your local music library, lets you browse by songs/albums/artists, and plays audio via `just_audio` + `audio_service` (background playback + media controls).

## Features

- Library browsing: songs, albums, artists
- Search across library
- Background playback with system media controls / notifications
- Queue + mini player
- Lyrics support (plain text + synced LRC)
- Basic tag editing (title/artist/album/cover art)
- Dynamic colors (Material You on supported Android devices + artwork palette)

## Platform notes

- Android is the primary target.
- Web builds: tag/cover editing is disabled (no direct file access).
- Desktop builds: playback works, but library scanning behavior may vary depending on platform/file access.

## Permissions

- Library scanning uses Android runtime permissions (`Permission.audio` / `Permission.storage`).
- Android 13+: the app may request notification permission so media controls can appear.
- Tag editing on Android 11+: writing tags typically requires “All files access” (`MANAGE_EXTERNAL_STORAGE`).

## Run locally

Prereqs: Flutter SDK installed.

```bash
flutter pub get
flutter run
```

## Project structure

`lib/main.dart` is the app entrypoint. Larger UI/components are being split into `lib/dialogs/`, `lib/widgets/`, and `lib/utils/` to keep changes reviewable.
