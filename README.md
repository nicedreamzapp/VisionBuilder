<div align="center">

<img src="Vision Builder/Assets.xcassets/AppIcon.appiconset/AppIcon1.png" width="128" height="128" alt="Vision Builder">

# 🪄 Vision Builder

### **Roboflow on your phone — for training your own robot.**

*Privately. On-device. With photos you already took.*

<br/>

[![Platform](https://img.shields.io/badge/iOS-26%2B-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9-FA7343?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![CoreML](https://img.shields.io/badge/CoreML-on--device-5856D6?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/machine-learning/core-ml/)
[![License](https://img.shields.io/badge/license-MIT-34C759?style=for-the-badge)](LICENSE)

[![Status](https://img.shields.io/badge/status-very%20much%20a%20WIP-FF9500?style=for-the-badge&logo=hammer&logoColor=white)](#-heads-up--nothing-here-is-done)
[![SAM 2.1](https://img.shields.io/badge/SAM-2.1-FF2D55?style=for-the-badge)](https://ai.meta.com/sam2/)
[![MobileCLIP 2](https://img.shields.io/badge/MobileCLIP-2-AF52DE?style=for-the-badge&logo=apple)](https://huggingface.co/apple/MobileCLIP2-S0)
[![YOLO 26](https://img.shields.io/badge/YOLO-26-00C7BE?style=for-the-badge)](https://docs.ultralytics.com/)

</div>

<br/>

> [!WARNING]
> ## 🚧 Heads up — nothing here is "done"
>
> This is an **ongoing project**. Things are half-built. Buttons sometimes lie. Empty states are awkward. The roadmap is longer than the README. We're shipping in the open because the core idea is too good to wait for "done."
>
> **If you find rough edges — that's the point.** Tell us. Or fix it. PRs welcome.

<br/>

---

## ✨ The vision (what "finished" actually looks like)

Imagine you just bought a robot. Or you're building one. It needs to recognize **your** stuff — your kitchen, your tools, your kid's toys, the specific objects in your house. Not generic ImageNet "person / car / dog." ***Your*** specific stuff.

The classical pipeline goes something like this:

```diff
- 1. Photograph thousands of objects from every angle
- 2. Upload to Roboflow / V7 / Scale AI
- 3. Pay someone to draw bounding boxes for weeks
- 4. Wait
- 5. Pay more
- 6. Train a model
- 7. Deploy
```

```diff
+ Vision Builder collapses steps 1–5 into:
+ "Open the app. Walk around your house. Done."
```

When this thing is "done" (it never will be — software is forever), here's what it'll do:

| Step | What happens |
| --- | --- |
| 📸 **Capture** | Take photos, or aim at your existing library — your phone already has thousands of pictures of your life |
| ✂️ **Auto-segment** | SAM 2 (or 3, when Apple ships it) cuts every object out of every photo, automatically |
| 🧠 **Auto-cluster** | MobileCLIP 2 fingerprints each cut-out and groups them by visual similarity — *"hey, here are 14 photos of what looks like the same coffee mug"* |
| 🏷️ **Label once** | You tap one cluster, type "coffee mug," and **all 14 instances inherit that label**. Big-batch instead of one-photo-at-a-time grinding |
| 🤖 **Export** | Spit out a clean labeled dataset in **COCO JSON, YOLO TXT, or CSV**. Drop it straight into your model training pipeline |
| 🔒 **Stay private** | Nothing leaves the device. No cloud. No upload. No "free tier." Your photos, your data, your dataset |

The end state is a tool you walk around your space with for an afternoon and walk away with a personalized object-detection dataset ready to train a model that actually knows your world.

<br/>

---

## 🤔 Why we're building it

> Because every "AI for robotics" tutorial assumes you have a labeling team.
>
> Most people don't. They have a phone and 15 minutes between things.

> Because Roboflow is great, but uploading 4,000 photos of your living room to a cloud service feels insane.

> Because the iPhone Neural Engine is faster than most cloud GPUs were five years ago, and it's just **sitting in your pocket.**

> Because the future of robots learning to operate in *your* environment shouldn't require a SaaS subscription.

<br/>

---

## ⚙️ How it works (today)

```mermaid
flowchart LR
    A[📸 Photo Library] -->|scan| B[✂️ SAM 2.1<br/>segment objects]
    B --> C[🧠 MobileCLIP 2<br/>embed each crop]
    C --> D[📊 DBSCAN<br/>cluster similar]
    D --> E[🏷️ Inbox<br/>label once per cluster]
    E --> F[🤖 Export<br/>COCO / YOLO / CSV]
    F --> G[🦾 Train your robot]

    style A fill:#FF9500,stroke:#fff,color:#fff
    style B fill:#FF2D55,stroke:#fff,color:#fff
    style C fill:#AF52DE,stroke:#fff,color:#fff
    style D fill:#5856D6,stroke:#fff,color:#fff
    style E fill:#007AFF,stroke:#fff,color:#fff
    style F fill:#34C759,stroke:#fff,color:#fff
    style G fill:#00C7BE,stroke:#fff,color:#fff
```

<br/>

---

## 📦 What's actually working right now

> [!NOTE]
> Status legend — ✅ working · 🟡 functional but rough · 💤 scaffolded, dormant · ❌ not yet

| Component | Status | Notes |
| :--- | :---: | :--- |
| SAM 2.1 segmentation | ✅ | Solid, runs on Neural Engine |
| MobileCLIP 2 embeddings | ✅ | fp32 (the fp16 tower NaNs — see convert script), center-crop preprocessing |
| YOLOE detection | ✅ | **4,585 classes**, prompt-free open-vocab, decode baked into the CoreML graph (YOLO 26 / v8 fallback) |
| Live recognition tab | ✅ | Point the camera — objects *you've labeled* get named on screen, on-device |
| Bird's-eye dataset mosaic | ✅ | Whole dataset on one zoomable wall (Dataset → ⋯) |
| DBSCAN clustering | ✅ | Euclidean on unit vectors, eps measured against real embeddings (not vibes) |
| Photo library scan | ✅ | Working but slow on big libraries |
| Inbox cluster review | 🟡 | Functional, UX still rough |
| Manual labeling flow | 🟡 | Has back/next now, editor is busy |
| Concept search | 🟡 | "Find all my cups" — works, sometimes underwhelming |
| COCO / CSV export | ✅ | Ready for any standard pipeline, real zips, share sheet |
| Foundation Models smart-naming | 💤 | Scaffolded — needs A17 Pro+ device |
| SAM 3 text-prompted segmentation | 💤 | Skeleton ready — waiting on Meta CoreML |
| iCloud sync | ❌ | On the list |
| Apple Watch quick-label | ❌ | On the list |
| Siri Shortcuts | ❌ | On the list |

<br/>

---

## 🛠️ Tech stack

<table>
<tr>
<td>

**Framework layer**
- 🎨 SwiftUI
- 💾 SwiftData
- 🖼️ CoreImage / Vision

</td>
<td>

**ML layer**
- ✂️ SAM 2.1 (CoreML)
- 🧠 MobileCLIP 2 (Apple)
- 🎯 YOLO 26 (Ultralytics)
- 📊 DBSCAN

</td>
<td>

**Apple Intelligence**
- 🤖 Foundation Models
- ⚡ Neural Engine
- 🔒 100% on-device

</td>
</tr>
</table>

<br/>

---

## 🧰 Requirements

> [!IMPORTANT]
> - **iOS 26.0+** (Foundation Models APIs + iOS 26 SwiftUI bits)
> - **iPhone with A14 chip or later** for Neural Engine acceleration
> - **Apple Intelligence device (iPhone 15 Pro+)** *only* for the on-device LLM cluster-naming — everything else runs on older iPhones
> - **Xcode 15+** to build

<br/>

---

## 🚀 Build it yourself

```bash
git clone https://github.com/nicedreamzapp/VisionBuilder.git
cd VisionBuilder

# Generate the upgraded mlpackages (MobileCLIP 2 + YOLO 26)
# Takes ~5 min on Apple Silicon
bash scripts/convert_models.sh all

# Open in Xcode and build to a real device
# (Simulator works but it's slow — no Neural Engine)
open "Vision Builder.xcodeproj"
```

> [!TIP]
> The conversion script auto-creates a Python 3.12 venv (coremltools 8 hates Python 3.14), patches a known coremltools bug for newer numpy, and produces:
> - `mobileclip2_s0_image.mlpackage` (22 MB)
> - `mobileclip2_s0_text.mlpackage` (121 MB)
> - `yolo26n.mlpackage` (4.8 MB)
>
> These are gitignored — too big for GitHub's 100MB file limit, but reproducibly regenerated by the script.

<br/>

---

## 🎬 First-run flow

```
1. Grant photo library access
2. Dataset tab → "Scan Photo Library"
3. Wait — you'll see objects fly by in the live feed
4. Inbox tab → label each cluster (one tap per cluster of N similar objects)
5. Dataset tab → menu → "Export All" → COCO/YOLO/CSV
6. Feed the dataset into your training pipeline
7. Train. Deploy. Profit. (lol, jk, you'll iterate forever)
```

<br/>

---

## 🗺️ Roadmap

> [!NOTE]
> Rough priority order. Subject to change every time we open the app and trip over a bug.

- [ ] Make the **Inbox flow buttery** — it's the heart of the app
- [ ] Better **SAM 3** integration when Meta ships CoreML
- [ ] **iCloud sync** so you can label across iPhone + iPad
- [ ] **Apple Watch** companion for "label this object" in the wild
- [ ] **Siri Shortcuts** ("scan my latest 100 photos")
- [ ] **On-device YOLO finetuning** — start with COCO, finetune to your dataset right on the phone
- [ ] **Multi-project support** — one dataset for kitchen, another for shop, another for the robot's path
- [ ] **Smarter cluster auto-naming** with Foundation Models when device supports
- [ ] **Collaborative datasets** without cloud — maybe AirDrop the `.mlpackage`?
- [ ] **Robot-specific export presets** — URDF-aware? object pose? still scoping

<br/>

---

## 🙋 Contributing

> Genuinely, please.

| If you... | Do this |
| --- | --- |
| Found a 🐛 bug | Open an issue — even rough notes help |
| Have a 💡 idea | Start a discussion |
| Want to 🔧 code | PRs welcome — file structure is mostly self-explanatory, see `CLAUDE.md` |

We're a small team learning as we go. If you're a **robotics person** with opinions about training-data formats, an **iOS dev** who's done CoreML in anger, or just someone who's tried to **label 400 photos of their dog** and hated it — you'd add value here.

<br/>

---

## 🙏 Acknowledgments

| Who | What for |
| --- | --- |
| 🦾 [Meta AI](https://ai.meta.com/) | SAM 2 (and SAM 3) — segmenting anything is wild |
| 🍎 [Apple ML Research](https://machinelearning.apple.com/) | MobileCLIP 2 + FastVLM — vision-language tiny enough for a phone |
| 🚀 [Ultralytics](https://ultralytics.com/) | YOLO 26 + actually shipping CoreML exports |
| 🤖 [Roboflow](https://roboflow.com/) / Scale AI / V7 | Showing what good labeling tools look like, even if we do it on-device instead |

<br/>

---

## 📜 License

**MIT.** Do what you want with it. If you build something cool, tell us — we want to see the robot.

<br/>

<div align="center">

<sub>Built with ❤️ + 🤖 + a healthy distrust of cloud services.</sub>

<sub>⭐ Star us on GitHub if you want to follow along — this is going to get fun.</sub>

</div>
