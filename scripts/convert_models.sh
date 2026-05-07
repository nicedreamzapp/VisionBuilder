#!/usr/bin/env bash
# convert_models.sh
# One-shot model conversion for Vision Builder upgrades.
# Run on Mac Mini / Mac with Apple Silicon.
#
# Usage:
#   bash scripts/convert_models.sh [mobileclip2|yolo26|all]
#
# Produces:
#   mobileclip2_s0_image.mlpackage
#   mobileclip2_s0_text.mlpackage
#   yolo26n.mlpackage
# in the project root, ready to drag into Xcode.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

TARGET="${1:-all}"

ensure_venv() {
    # coremltools 8.x doesn't have wheels for Python 3.14+ yet — pin to 3.12.
    PY="$(command -v python3.12 || command -v python3.11 || command -v python3.10 || command -v python3)"
    if [ ! -d ".venv-models" ]; then
        echo "Creating Python venv at .venv-models using $PY ..."
        "$PY" -m venv .venv-models
    fi
    # shellcheck disable=SC1091
    source .venv-models/bin/activate
}

# coremltools 8.x has a bug casting 1-element numpy arrays to int when
# tracing aten::Int ops (see _cast in torch/ops.py). Patch in place — the
# venv is gitignored so this is local-only.
apply_coremltools_patch() {
    local OPS_FILE
    OPS_FILE="$(python -c 'import coremltools, os; print(os.path.join(os.path.dirname(coremltools.__file__), "converters/mil/frontend/torch/ops.py"))')"
    if grep -q "scalar_val = x.val.item()" "$OPS_FILE"; then
        return
    fi
    python - <<'PY'
import re, sys, coremltools, os
path = os.path.join(os.path.dirname(coremltools.__file__),
                    "converters/mil/frontend/torch/ops.py")
src = open(path).read()
old = "        if not isinstance(x.val, dtype):\n            res = mb.const(val=dtype(x.val), name=node.name)\n        else:\n            res = x"
new = ("        if not isinstance(x.val, dtype):\n"
       "            scalar_val = x.val.item() if hasattr(x.val, \"item\") and getattr(x.val, \"size\", 1) == 1 else x.val\n"
       "            res = mb.const(val=dtype(scalar_val), name=node.name)\n"
       "        else:\n"
       "            res = x")
if old not in src:
    print("coremltools _cast patch: site already differs, skipping (was probably patched).")
    sys.exit(0)
open(path, "w").write(src.replace(old, new))
print("coremltools _cast patched at", path)
PY
}

convert_mobileclip2() {
    echo "==> Converting MobileCLIP 2 (S0) → CoreML"
    ensure_venv
    pip install --quiet --upgrade pip
    pip install --quiet "torch>=2.4" "coremltools>=8.0" "open_clip_torch>=2.26" "Pillow" "huggingface_hub"
    apply_coremltools_patch
    python3 scripts/convert_mobileclip2.py
    echo "MobileCLIP 2 conversion complete."
}

convert_yolo26() {
    echo "==> Converting YOLO26 → CoreML"
    ensure_venv
    pip install --quiet --upgrade pip
    pip install --quiet "ultralytics>=8.4" "coremltools>=8.0"
    apply_coremltools_patch
    python3 scripts/convert_yolo26.py
    echo "YOLO26 conversion complete."
}

convert_efficientsam3() {
    echo "==> EfficientSAM3 conversion is UPSTREAM-PENDING."
    echo "    Watch https://github.com/SimonZeng7108/efficientsam3 for the CoreML export script."
    echo "    The Swift skeleton (SAM3ConceptService.swift) will auto-enable once you bundle the .mlpackage."
}

case "$TARGET" in
    mobileclip2)    convert_mobileclip2 ;;
    yolo26)         convert_yolo26 ;;
    sam3)           convert_efficientsam3 ;;
    all)
        convert_mobileclip2
        convert_yolo26
        convert_efficientsam3
        ;;
    *)
        echo "Unknown target: $TARGET"
        echo "Usage: bash scripts/convert_models.sh [mobileclip2|yolo26|sam3|all]"
        exit 1
        ;;
esac

echo ""
echo "Done. Drag any new .mlpackage files into Xcode and add them to the Vision Builder target."
