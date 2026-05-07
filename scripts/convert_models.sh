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
    if [ ! -d ".venv-models" ]; then
        echo "Creating Python venv at .venv-models ..."
        python3 -m venv .venv-models
    fi
    # shellcheck disable=SC1091
    source .venv-models/bin/activate
}

convert_mobileclip2() {
    echo "==> Converting MobileCLIP 2 (S0) → CoreML"
    ensure_venv
    pip install --quiet --upgrade pip
    pip install --quiet "torch>=2.4" "coremltools>=8.0" "open_clip_torch>=2.26" "Pillow" "huggingface_hub"
    python3 scripts/convert_mobileclip2.py
    echo "MobileCLIP 2 conversion complete."
}

convert_yolo26() {
    echo "==> Converting YOLO26 → CoreML"
    ensure_venv
    pip install --quiet --upgrade pip
    pip install --quiet "ultralytics>=8.4" "coremltools>=8.0"
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
