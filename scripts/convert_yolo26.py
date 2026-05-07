"""Convert YOLO26-nano to CoreML mlpackage.

YOLO26 is NMS-free; we let Ultralytics emit the standard mlpackage and
do post-processing on the Swift side (kept compatible with the existing
YOLOObjectDetector decode path).

Output:
    yolo26n.mlpackage
"""
from __future__ import annotations

from pathlib import Path
import shutil

from ultralytics import YOLO

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = PROJECT_ROOT / "yolo26n.mlpackage"


def main() -> None:
    print("Loading YOLO26n (will download on first run) ...")
    model = YOLO("yolo26n.pt")  # Open Images V7 weights via Ultralytics hub

    print("Exporting to CoreML (FP16, NMS-free) ...")
    exported_path = model.export(
        format="coreml",
        imgsz=640,
        half=True,
        nms=False,            # Swift-side postprocessing matches existing detector
        int8=False,
    )
    exported = Path(exported_path).resolve()
    target = OUTPUT.resolve()

    if exported == target:
        print(f"  → {target} (already at target path)")
    else:
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(exported), str(target))
        print(f"  → {target}")
    print("YOLO26 export complete.")


if __name__ == "__main__":
    main()
