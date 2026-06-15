# CLAUDE.md — Vision Builder

On-device iOS app that turns your photo library into a labeled object-detection
dataset. "Roboflow on your phone." Everything runs locally on the Neural Engine;
nothing leaves the device.

## Build

- **Target:** iOS 26.0+, SwiftUI + SwiftData. Build to a **real device** (Neural
  Engine); the Simulator works but is slow.
- Open `Vision Builder.xcodeproj`. App entry: `Vision Builder/Vision_BuilderApp.swift`.
- The large `*.mlpackage` ML models (MobileCLIP 2, YOLO 26) are **gitignored** —
  regenerate them with `bash scripts/convert_models.sh all` (needs Python 3.12).

## Project layout

Source files live at the **repo root** (flat layout), not in a nested group.
`Vision Builder/` holds only the app entry point + assets. Nothing but
`project.pbxproj` / `project.xcworkspace` belongs inside `Vision Builder.xcodeproj/`.

## The pipeline (this is the whole app)

```
Photo library → SAM 2.1 segment → MobileCLIP 2 embed → DBSCAN cluster → label once per cluster → export COCO/YOLO/CSV
```

| Stage | Key files |
| --- | --- |
| Scan library | `PhotoLibraryIndexer.swift` |
| Segment (SAM 2.1) | `SAM2CoreMLProcessor.swift`, `SAM2DetectionManager.swift`, `SAM2ImageAnalysis.swift` |
| Embed (MobileCLIP 2) | `MobileCLIPService.swift`, `EmbeddingService.swift`, `CLIPTokenizer.swift` |
| Detect (YOLO 26) | `YOLOObjectDetector.swift`, `ObjectRecognitionEngine.swift` |
| Cluster + review | `MorningInboxView.swift`, `LabelNavigationView.swift`, `Activelearning*.swift` |
| Concept search | `ConceptSearchService.swift`, `ConceptSearchView.swift` |
| Export | `ExportManager.swift`, `ExportOptionsView.swift` |
| Data model | `CoreTypes.swift`, `ObjectIdentity.swift`, `LabeledBox.swift` |

## Feature status (see README for the full table)

- ✅ Working: SAM 2.1, MobileCLIP 2, YOLO 26, DBSCAN, library scan, COCO/CSV export
- 🟡 Rough: Inbox review, manual labeling, concept search
- 💤 Dormant (gated off, models not bundled): **SAM 3** text-prompted segmentation
  (`SAM3ConceptService.swift` — `isAvailable` is false until
  `efficient_sam3_*.mlmodelc` exist), Foundation Models cluster naming (needs A17 Pro+)

## Conventions

- 100% on-device. Never add a cloud/network dependency for inference.
- Gate dormant features behind an `isAvailable` check before exposing UI — don't
  ship buttons that silently do nothing.
