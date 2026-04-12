---
name: Uses XcodeGen for project management
description: The project uses XcodeGen (project.yml) to generate the .xcodeproj - do not manually edit project.pbxproj
type: feedback
---

This project uses XcodeGen. The Xcode project file (`.pbxproj`) is auto-generated from `project.yml`. The `PhotoSync` source directory uses `syncedFolder` type, so all files on disk are automatically included — no manual edits to `project.yml` needed when adding/removing Swift files.

**Why:** XcodeGen keeps the project file clean and merge-conflict-free.

**How to apply:** When adding or removing Swift files, just add/delete from the filesystem. Run `xcodegen generate` to regenerate the `.xcodeproj`. Never manually edit `project.pbxproj`.
