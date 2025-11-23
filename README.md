<p align="center">
  <img src="Vision Builder/Assets.xcassets/AppIcon.appiconset/AppIcon1.png" width="120" height="120" alt="Vision Builder Icon">
</p>

<h1 align="center">Vision Builder</h1>

<p align="center">
  <strong>Train AI to recognize objects in your life — privately, on your device</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2018%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="Swift">
  <img src="https://img.shields.io/badge/status-work%20in%20progress-yellow" alt="Status">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

> **⚠️ Work in Progress**
> This project is actively being developed. Features may be incomplete, and things might break. We're building this in the open and welcome feedback!

---

## What is Vision Builder?

Vision Builder is an iOS app that helps you create personalized object recognition datasets from your own photos — completely on-device, with no data leaving your phone.

**The idea is simple:** Your phone already has thousands of photos of the objects in your life — your coffee mug, your car keys, your dog. Why not use those photos to teach AI what *your* specific objects look like?

### How It Works

```
📸 Scan Photo Library → 🔍 AI Finds Objects → 📦 Groups Similar Items → 🏷️ You Label Once → ✨ AI Learns
```

1. **Scan** — The app scans your photo library using SAM2 (Segment Anything Model 2) to find and segment individual objects
2. **Cluster** — Similar objects are automatically grouped together using embedding similarity
3. **Label** — You review clusters and label them with a single tap ("Coffee Mug", "Car Keys", etc.)
4. **Learn** — The app learns from your labels and can auto-label similar objects it finds later

### Why On-Device?

- **Privacy** — Your photos never leave your device
- **Speed** — No network latency, instant results
- **Ownership** — Your dataset belongs to you

---

## Features

### 🎯 SAM2 Segmentation
State-of-the-art object segmentation powered by Meta's Segment Anything Model 2, running entirely on-device via CoreML.

### 🧠 Active Learning
Smart clustering groups similar objects together. Label one example, and the app learns to recognize the rest.

### 📊 Batch Review Interface
Review entire clusters of objects at once — see 20 similar items in a grid, type a label once, done.

### 📁 Dataset Export
Export your labeled dataset in standard formats (COCO JSON, CSV) for use in other ML projects.

### 🎨 Beautiful UI
Native SwiftUI interface with smooth animations, haptic feedback, and dark mode support.

---

## Screenshots

*Coming soon — we're still polishing the UI!*

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| **UI Framework** | SwiftUI |
| **Data Persistence** | SwiftData |
| **Object Segmentation** | SAM2 (CoreML) |
| **Embeddings** | Vision Framework |
| **Clustering** | DBSCAN Algorithm |
| **Image Processing** | CoreImage, CoreGraphics |

---

## Requirements

- iOS 18.0+
- iPhone with A14 chip or later (for Neural Engine)
- Xcode 15.0+

---

## Getting Started

```bash
# Clone the repository
git clone https://github.com/nicedreamzapp/VisionBuilder.git

# Open in Xcode
cd VisionBuilder
open "Vision Builder.xcodeproj"

# Build and run on your device
# (Simulator works but SAM2 runs slower without Neural Engine)
```

### First Run

1. Grant photo library access when prompted
2. Go to the **Dataset** tab
3. Tap **"Scan Photo Library"**
4. Wait for the scan to complete (this may take a few minutes)
5. Go to the **Inbox** tab to review and label discovered objects

---

## Project Structure

```
Vision Builder/
├── Models/
│   ├── ObjectIdentity.swift      # Core data models
│   ├── LabelingSession.swift     # Session persistence
│   └── CoreTypes.swift           # Shared types
├── Views/
│   ├── MorningInboxView.swift    # Batch review interface
│   ├── DatasetTabView.swift      # Dataset browser
│   ├── LabelingEditorView.swift  # Manual labeling
│   └── DesignSystem.swift        # UI components
├── Services/
│   ├── SAM2CoreMLProcessor.swift # SAM2 integration
│   ├── EmbeddingService.swift    # Feature extraction
│   ├── PhotoLibraryIndexer.swift # Photo scanning
│   └── SimilaritySearchService.swift
├── Controllers/
│   ├── ActiveLearningController.swift
│   └── ActiveLearningManager.swift
└── Resources/
    ├── SAM2_1SmallImageEncoderFLOAT16.mlpackage
    ├── SAM2_1SmallMaskDecoderFLOAT16.mlpackage
    └── SAM2_1SmallPromptEncoderFLOAT16.mlpackage
```

---

## Roadmap

We're actively working on this project. Here's what's on our radar:

- [ ] **Performance** — Optimize SAM2 inference speed
- [ ] **Accuracy** — Improve clustering quality
- [ ] **Export** — More export format options
- [ ] **Sync** — iCloud sync for datasets
- [ ] **Watch** — Apple Watch companion for quick labeling
- [ ] **Widgets** — Home screen widgets showing labeling progress
- [ ] **Shortcuts** — Siri Shortcuts integration

---

## Contributing

We'd love your help! This project is in early stages and there's plenty to do.

- **Found a bug?** Open an issue
- **Have an idea?** Start a discussion
- **Want to contribute code?** PRs welcome!

Please be patient with us — we're a small team learning as we go.

---

## Acknowledgments

- **Meta AI** for the incredible [Segment Anything Model 2](https://github.com/facebookresearch/segment-anything-2)
- **Apple** for SwiftUI, CoreML, and the Vision framework
- The open source community for inspiration and guidance

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with ❤️ by humans who believe AI should work for you, privately.</sub>
</p>

<p align="center">
  <sub>⭐ Star us on GitHub if you find this interesting!</sub>
</p>
