"""Convert YOLOE (prompt-free) to CoreML with on-ANE decode, then verify.

YOLOE-11s-seg-pf detects ~4,585 object classes with no prompting — a huge
jump from the 80-class COCO head in yolo26n. The "pf" (prompt-free) variant
re-parameterizes the open-vocabulary head into a plain YOLO head.

The exported graph bakes the per-anchor class max INTO the model:
  outputs: confidence [1,8400], class_id int32 [1,8400], boxes xywh [1,4,8400]
so the app never touches the raw [1,4621,8400] tensor (155 MB/frame — decoding
that app-side measured 231 ms/frame; this way it's ~0.01 ms).

Hard-won layout notes (measured on M4 Pro, 30-run averages):
  - topk/gather in-graph → data-dependent shapes → falls off ANE (99 ms)
  - max over dim=1 of [1,4585,8400]              → bad placement   (124 ms)
  - transpose then max over LAST axis            → stays on ANE    (22 ms, 45 fps)
  - class_id must be int32: fp16 can't represent ids > 2048 exactly
    (person=3299 came back as "humidifier")

Outputs:
    yoloe11s_pf.mlpackage
    yoloe_classes.json          (index → class name, 4585 entries)
"""
from __future__ import annotations

import json
import time
import urllib.request
from pathlib import Path

import numpy as np
import torch

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = PROJECT_ROOT / "yoloe11s_pf.mlpackage"
CLASSES_OUTPUT = PROJECT_ROOT / "yoloe_classes.json"
TEST_IMAGE = PROJECT_ROOT / "scripts" / "test_bus.jpg"
TEST_IMAGE_URL = "https://ultralytics.com/images/bus.jpg"
NC = 4585


class DecodedYOLOE(torch.nn.Module):
    """Wraps the net so the CoreML graph emits ready-to-filter detections."""

    def __init__(self, yolo_model):
        super().__init__()
        self.m = yolo_model

    @staticmethod
    def _find_pred(o):
        # Output structure is fixed at trace time — walk nested tuples
        if torch.is_tensor(o):
            return o if (o.ndim == 3 and o.shape[1] == 4 + NC + 32) else None
        if isinstance(o, (list, tuple)):
            for e in o:
                r = DecodedYOLOE._find_pred(e)
                if r is not None:
                    return r
        return None

    def forward(self, x):
        out = self.m(x)
        pred = self._find_pred(out)                # [1, 4621, 8400]
        boxes = pred[:, :4, :]                     # xywh, 640px space
        cls = pred[:, 4 : 4 + NC, :]
        # Static-shape reduce over the LAST axis only — see layout notes above
        conf, cls_id = cls.transpose(1, 2).max(dim=2)  # [1, 8400]
        return conf, cls_id.to(torch.int32), boxes


def ensure_test_image() -> Path:
    if not TEST_IMAGE.exists():
        print(f"Downloading test image → {TEST_IMAGE}")
        urllib.request.urlretrieve(TEST_IMAGE_URL, TEST_IMAGE)
    return TEST_IMAGE


def main() -> None:
    import coremltools as ct
    from PIL import Image
    from ultralytics import YOLOE

    print("Loading YOLOE-11s-seg-pf (downloads on first run) ...")
    y = YOLOE("yoloe-11s-seg-pf.pt")
    names = y.names
    print(f"Model vocabulary: {len(names)} classes")

    # PyTorch reference detections — ground truth for the agreement check
    results = y.predict(str(ensure_test_image()), imgsz=640, verbose=False)
    r = results[0]
    ref = sorted(
        ((r.names[int(b.cls)], float(b.conf)) for b in r.boxes),
        key=lambda d: -d[1],
    )
    print("\nPyTorch reference detections:")
    for name, conf in ref[:8]:
        print(f"  {name}: {conf:.3f}")

    net = y.model.eval().float().fuse()
    # Static-shape export mode, same as ultralytics' own exporter — without
    # this the head emits dynamic [1, ?, 4585] shapes that fall off the ANE
    for m in net.modules():
        if hasattr(m, "export"):
            m.export = True
        if hasattr(m, "format"):
            m.format = "coreml"

    wrapped = DecodedYOLOE(net).eval()
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, torch.zeros(1, 3, 640, 640), check_trace=False)

    print("\nConverting to CoreML (FP16, decode-in-graph) ...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 640, 640), scale=1 / 255.0)],
        outputs=[
            ct.TensorType(name="confidence"),
            ct.TensorType(name="class_id"),
            ct.TensorType(name="boxes"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "YOLOE-11s prompt-free, 4585 classes, decode-in-graph"
    mlmodel.save(str(OUTPUT))
    print(f"  → {OUTPUT}")

    CLASSES_OUTPUT.write_text(json.dumps([names[i] for i in range(len(names))]))
    print(f"  → {CLASSES_OUTPUT} ({len(names)} names)")

    # ---- Verify + benchmark ----
    img = Image.open(ensure_test_image()).convert("RGB").resize((640, 640))
    m = ct.models.MLModel(str(OUTPUT), compute_units=ct.ComputeUnit.ALL)
    m.predict({"image": img})
    m.predict({"image": img})
    t0 = time.perf_counter()
    n = 30
    for _ in range(n):
        out = m.predict({"image": img})
    dt = (time.perf_counter() - t0) / n * 1000
    print(f"\nCoreML inference incl. decode: {dt:.1f} ms/frame ({1000/dt:.0f} fps on this Mac)")

    conf = np.asarray(out["confidence"]).ravel()
    cls = np.asarray(out["class_id"]).ravel().astype(int)
    seen: dict[str, float] = {}
    for c, s in zip(cls[conf > 0.5], conf[conf > 0.5]):
        seen[names[c]] = max(seen.get(names[c], 0.0), float(s))
    print("CoreML detections >0.5:", {k: round(v, 3) for k, v in sorted(seen.items(), key=lambda kv: -kv[1])})

    ref_classes = {name for name, c in ref if c > 0.5}
    missing = ref_classes - set(seen)
    if missing:
        print(f"⚠️ MISMATCH — classes missing from CoreML output: {missing}")
        raise SystemExit(1)
    if dt > 60:
        # Advisory only: Mac timings are contention-noisy (ComfyUI etc. share
        # the GPU/ANE). Best observed on idle M4 Pro: 22 ms. Device is ground truth.
        print("⚠️ Timing above 60 ms — Mac may be contended; verify on iPhone")
    print("✅ CoreML output agrees with PyTorch. Export verified.")


if __name__ == "__main__":
    main()
