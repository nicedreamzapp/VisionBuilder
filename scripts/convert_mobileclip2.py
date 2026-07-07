"""Convert MobileCLIP 2 S0 (image + text encoders) to CoreML mlpackages.

Output:
    mobileclip2_s0_image.mlpackage
    mobileclip2_s0_text.mlpackage

Both produce a 512-dim L2-normalizable embedding, matching the existing
MobileCLIPService.swift contract. Drop-in replacement for mobileclip_s0_*.
"""
from __future__ import annotations

from pathlib import Path

import coremltools as ct
import numpy as np
import open_clip
import torch
from huggingface_hub import hf_hub_download

PROJECT_ROOT = Path(__file__).resolve().parent.parent
IMAGE_OUT = PROJECT_ROOT / "mobileclip2_s0_image.mlpackage"
TEXT_OUT = PROJECT_ROOT / "mobileclip2_s0_text.mlpackage"

IMG_SIZE = 256  # MobileCLIP-S0 / 2-S0 input
EMB_DIM = 512
TOKEN_LEN = 77

IMAGENET_MEAN = (0.4815, 0.4578, 0.4082)
IMAGENET_STD = (0.2686, 0.2613, 0.2758)


def load_mobileclip2_s0() -> tuple[torch.nn.Module, callable]:
    """Load MobileCLIP2-S0 weights via open_clip + Apple HF."""
    ckpt = hf_hub_download(repo_id="apple/MobileCLIP2-S0", filename="mobileclip2_s0.pt")
    model, _, _ = open_clip.create_model_and_transforms("MobileCLIP2-S0", pretrained=ckpt)
    tokenizer = open_clip.get_tokenizer("MobileCLIP2-S0")
    model.eval()
    return model, tokenizer


class ImageEncoderWrapper(torch.nn.Module):
    """Bake ImageNet normalization into the model so Swift can pass raw [0,1] BGRA."""

    def __init__(self, base: torch.nn.Module):
        super().__init__()
        self.base = base
        mean = torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1)
        std = torch.tensor(IMAGENET_STD).view(1, 3, 1, 1)
        self.register_buffer("mean", mean)
        self.register_buffer("std", std)

    def forward(self, image_rgb01: torch.Tensor) -> torch.Tensor:
        x = (image_rgb01 - self.mean) / self.std
        feats = self.base.encode_image(x)
        feats = feats / feats.norm(dim=-1, keepdim=True).clamp(min=1e-8)
        return feats


class TextEncoderWrapper(torch.nn.Module):
    def __init__(self, base: torch.nn.Module):
        super().__init__()
        self.base = base

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        feats = self.base.encode_text(tokens)
        feats = feats / feats.norm(dim=-1, keepdim=True).clamp(min=1e-8)
        return feats


def export_image_encoder(model: torch.nn.Module) -> None:
    print("Exporting image encoder ...")
    wrapper = ImageEncoderWrapper(model).eval()
    dummy = torch.rand(1, 3, IMG_SIZE, IMG_SIZE)
    traced = torch.jit.trace(wrapper, dummy)

    image_input = ct.ImageType(
        name="input_image",
        shape=(1, 3, IMG_SIZE, IMG_SIZE),
        scale=1.0 / 255.0,  # raw 0-255 → 0-1; ImageNet normalize happens inside model
        bias=[0, 0, 0],
        color_layout=ct.colorlayout.RGB,
    )
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        outputs=[ct.TensorType(name="final_emb_1")],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
        # FLOAT32 is required: the S0 image tower overflows fp16 (verified —
        # torch fp16 inference also NaNs), so the default fp16 conversion
        # produced NaN embeddings for every image
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "MobileCLIP2-S0 image encoder, 256x256, 512-dim L2-normalized, fp32"
    mlmodel.save(str(IMAGE_OUT))
    print(f"  → {IMAGE_OUT}")


def export_text_encoder(model: torch.nn.Module, tokenizer) -> None:
    print("Exporting text encoder ...")
    wrapper = TextEncoderWrapper(model).eval()
    dummy_tokens = tokenizer(["a photo of a coffee mug"]).to(torch.int32)
    # check_trace=False: CLIP text encoders use argmax-over-EOT which
    # confuses trace's sanity check, but the resulting graph is correct
    # for fixed-shape inputs (we always feed [1, 77] int32).
    traced = torch.jit.trace(wrapper, dummy_tokens, check_trace=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_text", shape=(1, TOKEN_LEN), dtype=np.int32)],
        outputs=[ct.TensorType(name="final_emb_1")],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "MobileCLIP2-S0 text encoder, 77 tokens, 512-dim L2-normalized"
    mlmodel.save(str(TEXT_OUT))
    print(f"  → {TEXT_OUT}")


def main() -> None:
    model, tokenizer = load_mobileclip2_s0()
    export_image_encoder(model)
    export_text_encoder(model, tokenizer)
    print("MobileCLIP 2 export complete.")


if __name__ == "__main__":
    main()
