# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub: go to the **Security** tab of this repo and click **Report a vulnerability** ([direct link](https://github.com/nicedreamzapp/VisionBuilder/security/advisories/new)). Only the maintainer sees the report.

Helpful details: what you found, how to reproduce it, which commit, your iPhone model and iOS version, and your Xcode version.

I aim to reply within 3 days and to ship a fix or a clear plan within 30 days, depending on severity. You will be credited in the advisory unless you ask not to be.

## Supported versions

There is no App Store build yet. Fixes go into the latest code on `main`. Please update before reporting if you are on an older commit.

## What matters most here

The parts where a mistake could hurt someone:

- photo library access in `PhotoLibraryIndexer.swift`, which reads the whole camera roll and is meant to keep everything on the phone
- the developer hooks that act on request files dropped into the app's Documents folder: `PhotoCleanupView.swift` (deletes photos), `PhotoExportView.swift` (writes copies of every photo, with location, to pack files) and `RemoteCaptureView.swift` (takes camera shots)
- camera access in `LiveRecognitionView.swift`
- dataset export in `ExportManager.swift`, which writes zips that leave the phone through the share sheet
