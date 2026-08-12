# Kool Music Player

A sleek Flutter music player built for **offline, on-device listening** with a fast library experience and clean playback controls.

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="Kool Music Player app icon" width="120" />
</p>

---

## What this project is

Kool Music Player scans local audio files and turns them into a polished listening experience focused on:

- quick navigation through large libraries
- stable playback with queue support
- lyrics and metadata editing
- modern visuals with dynamic theming

It is designed primarily for Android, with support for other Flutter targets where platform capabilities allow.

## Highlights

### Library & discovery
- Browse by **Songs**, **Albums**, and **Artists**
- Built-in global search
- Album/artist-aware sorting modes
- Smart sections such as **Most Played**, **Recently Played**, and **Recently Added**

### Playback experience
- Background playback via `audio_service`
- Lock-screen / notification media controls
- Full queue management and mini player
- Shuffle, repeat, seek, and transport controls

### Personalization
- **Material You / Dynamic Color** integration on supported Android devices
- Artwork-based palette accents
- Theme mode support

### Editing & organization
- Lyrics support for plain text and synchronized **LRC**
- Tag editing for title, artist, album, and cover art
- User playlists with create, rename, delete, and import flow

## Screenshots

<p align="center">
  <img src="assets/screenshots/home.png" alt="Home Screen" width="30%" />
  <img src="assets/screenshots/playlist.png" alt="Playlist Screen" width="30%" />
</p>
<p align="center">
  <img src="assets/screenshots/now-playing.png" alt="Now Playing Screen" width="30%" />
  <img src="assets/screenshots/full-now-playing.png" alt="Full Screen Now Playing" width="100%" />
</p>

## Tech stack

- **Framework:** Flutter (Dart)
- **Audio:** `just_audio`, `audio_service`, `audio_session`
- **Library query:** `on_audio_query`
- **Storage:** `hive_flutter`, `shared_preferences`
- **Theming & UI:** `dynamic_color`, `palette_generator`, `google_fonts`
- **Utilities:** `permission_handler`, `file_picker`, `audiotags`

## Project structure

```text
lib/
├── main.dart                  # App shell, routing, major pages
├── services/                  # Playback and local persistence services
├── data/                      # Models and data-layer helpers
├── pages/                     # Route-level screens (e.g., queue page)
├── dialogs/                   # Lyrics/tag editing dialogs
├── widgets/                   # Reusable playback/search UI components
└── ui/shared/                 # Shared visual components
```

## Getting started

### Prerequisites
- Flutter SDK installed
- Android SDK / emulator (recommended target)

### Run locally

```bash
flutter pub get
flutter run
```

### Basic quality checks

```bash
flutter analyze
flutter test
```

## Platform notes

- **Android:** primary platform and best-supported experience
- **Web:** playback works, but direct file/tag editing is limited by browser file access constraints

## Permissions (Android)

- Music library access (`Permission.audio` / storage permission variants)
- Notification permission on Android 13+ for background media controls
- `MANAGE_EXTERNAL_STORAGE` may be required for certain metadata/tag write operations on newer Android versions

## Status

This project is actively being improved with UI refinements, playback reliability enhancements, and richer playlist/metadata workflows.
