#!/usr/bin/env python3
"""Convert DINOv2-small to CoreML for instance identity.

Why this model: measured 2026-09-14 on 4,959 real camera-roll photos, DINOv2 keeps
Matt's three dogs apart (Shanti 26/26, Theo 28/28, Rupert 8/9 at cosine 0.75) where
CLIP cannot separate individuals at ANY threshold. Small matches base to within one
crop at a quarter the size.

Normalisation is baked INTO the graph so the Swift side hands over a plain RGB image.
Output is the L2-normalised CLS token, 384-dim.

Precision: fp16 is attempted, then verified against fp32 PyTorch. MobileCLIP2 silently
NaN'd in fp16 and cost months (see July findings) — never ship a conversion unverified.
"""
import numpy as np, torch, torch.nn as nn, coremltools as ct
from transformers import AutoModel

MODEL_ID = "facebook/dinov2-small"
SIDE = 224
MEAN = [0.485, 0.456, 0.406]
STD  = [0.229, 0.224, 0.225]

class Embedder(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = AutoModel.from_pretrained(MODEL_ID).eval()
        # DINOv2 interpolates its position encoding at runtime with bicubic upsampling,
        # which CoreML cannot convert. The input size is fixed, so do it ONCE here in
        # eager PyTorch and return the result as a constant.
        emb = self.net.embeddings
        with torch.no_grad():
            baked = emb.interpolate_pos_encoding(
                torch.zeros(1, (SIDE // emb.patch_embeddings.patch_size[0]) ** 2 + 1,
                            self.net.config.hidden_size),
                SIDE, SIDE)
        self.register_buffer("baked_pos", baked)
        emb.interpolate_pos_encoding = lambda x, h, w: self.baked_pos
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std",  torch.tensor(STD).view(1, 3, 1, 1))
    def forward(self, image):           # image: 0..1 RGB, N,3,224,224
        x = (image - self.mean) / self.std
        cls = self.net(pixel_values=x).last_hidden_state[:, 0]
        return cls / cls.norm(dim=-1, keepdim=True).clamp_min(1e-9)

m = Embedder().eval()
ex = torch.rand(1, 3, SIDE, SIDE)
with torch.no_grad():
    ref = m(ex).numpy()
traced = torch.jit.trace(m, ex)

for precision, tag in ((ct.precision.FLOAT16, "fp16"), (ct.precision.FLOAT32, "fp32")):
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE),
                             scale=1/255.0, bias=[0, 0, 0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=precision,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    out = f"dinov2_small_{tag}.mlpackage"
    mlmodel.save(out)
    # verify against PyTorch on the SAME input
    from PIL import Image
    pil = Image.fromarray((ex[0].permute(1,2,0).numpy()*255).astype(np.uint8))
    got = mlmodel.predict({"image": pil})["embedding"].reshape(-1)
    nan = bool(np.isnan(got).any())
    cos = float(np.dot(got, ref[0]) / (np.linalg.norm(got)*np.linalg.norm(ref[0]) + 1e-9))
    print(f"{tag}: saved {out}  nan={nan}  cosine_vs_pytorch={cos:.4f}")
    if not nan and cos > 0.99:
        print(f"  -> {tag} VERIFIED, use this one")
        break
    print(f"  -> {tag} FAILED verification, trying higher precision")
