# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Setup

PhotoSync uses XcodeGen to generate the Xcode project. After cloning or modifying `project.yml`, regenerate the project with:

```bash
./start        # closes Xcode, runs xcodegen, reopens project
# or manually:
xcodegen
```

Never edit `PhotoSync.xcodeproj` directly — it is regenerated from `project.yml`.

SwiftLint runs automatically as a post-compile build phase. To run manually:
```bash
/opt/homebrew/bin/swiftlint
```

There are no automated tests in this project.

## What PhotoSync Does

An iOS app that backs up the device photo library to Dropbox. It maintains a local CoreData cache of both local photos and remote Dropbox files, compares them, and uploads new/changed photos while deleting remotely what was removed locally.

## Architecture

### Sync Flow

The master orchestrator is `SyncCoordinator`. A sync run proceeds as:

1. `PhotoKitManager` — reads all local photos from PhotoKit, inserts/updates `Photo` records in CoreData
2. `DropboxManager` — fetches the remote file list via paginated Dropbox API, updates `DropboxFile` records; subsequent syncs use a stored cursor for incremental updates
3. `UploadManager` — compares `Photo` vs `DropboxFile` records, categorizes work (new/replacement/unknown/deleted), runs batch uploads (max 2 parallel), then deletes remote files that no longer exist locally
4. Final re-sync of Dropbox to reconcile newly uploaded files

### Key Components

- **`SyncCoordinator`** (`Managers/`) — orchestrates all three phases, manages app-level UI state, handles Dropbox OAuth, background task registration
- **`PhotoKitManager`** — fetches from PhotoKit, persists to `Photo` CoreData entities in batches of 1000 (200 on incremental syncs)
- **`DropboxManager`** — paginated Dropbox folder listing with cursor-based incremental syncs stored in `SyncToken`
- **`UploadManager`** / **`UploadOperation`** — photo upload logic, SHA256 content hashing to detect changes, collision-aware file naming
- **`Database`** — `actor`-based CoreData wrapper providing thread-safe async/await access; handles automatic DB recreation on corruption
- **`TimezoneMapper`** — converts a GPS coordinate to a `TimeZone` for folder-path generation. Implemented as a 0.25° lookup grid in `PhotoSync/Resources/timezone_polygons.bin` (40KB zlib-compressed; decompresses to a 2MB flat uint16 grid). To regenerate: `pip3 install timezonefinder && python3 scripts/generate_timezone_grid.py`

### Data Model

Three CoreData entities:
- **`Photo`** — mirrors a `PHAsset`; tracks `photoKitId`, creation/modification dates, computed filename and Dropbox path (organized by month), content hash cache
- **`DropboxFile`** — local cache of remote Dropbox state; indexed by `pathLower` for case-insensitive lookups
- **`SyncToken`** — stores the Dropbox pagination cursor to enable incremental syncs

### File Path Logic

Photos are organized under a month folder (`YYYY-MM/filename.ext`). When a filename would collide, a suffix is appended (`photo (1).jpg`, etc.). Path generation is deterministic so the same photo always maps to the same path across app runs. Dropbox is treated as case-insensitive throughout.

### Concurrency

- All CoreData access goes through the `Database` actor
- `SyncCoordinator` and managers are `@Observable` classes on the main actor
- `CollectionConcurrencyKit` is used for `asyncMap`/`asyncForEach` on sequences
- Background task support via `BGAppRefreshTask`; screen kept awake during active sync

### External Dependencies (SPM)

- **SwiftyDropbox** — Dropbox API client
- **KeychainSwift** — secure token storage
