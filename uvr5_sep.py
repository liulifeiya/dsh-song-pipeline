import os
import sys
import time

UVR = r"D:\AI\GPT-SoVITS\tools\uvr5"
sys.path.insert(0, UVR)

import torch
from vr import AudioPre

inp = sys.argv[1]
out_root = sys.argv[2]
agg = int(sys.argv[3]) if len(sys.argv) > 3 else 10

model = os.path.join(UVR, "uvr5_weights", "HP2_all_vocals.pth")
assert os.path.isfile(model), model

device = "cuda" if torch.cuda.is_available() else "cpu"
is_half = device == "cuda"
print("device:", device, "half:", is_half, flush=True)

t0 = time.time()
pre = AudioPre(agg=agg, model_path=model, device=device, is_half=is_half)
print("model loaded in %.1fs" % (time.time() - t0), flush=True)

vocal_root = os.path.join(out_root, "vocals")
ins_root = os.path.join(out_root, "instrumental")

t0 = time.time()
pre._path_audio_(inp, ins_root=ins_root, vocal_root=vocal_root, format="wav", is_hp3=False)
print("separated in %.1fs" % (time.time() - t0), flush=True)
print("vocals:", vocal_root)
print("inst  :", ins_root)
