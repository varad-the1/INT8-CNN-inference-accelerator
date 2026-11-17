"""Make test vectors for tb_requantizer.v from the Python reference.

Each line of data/requant_vectors.txt (all hex, two's complement):
    acc  m0  shift_r  out_zp  expected_int8
The expected value comes from requantize() in micro_cnn_ref.py, so the
hardware is checked against the same maths that already passed 20/20.

Run:  python gen_requant_vectors.py
"""
import os
import random
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
import micro_cnn_ref as m

OUT = os.path.join(m.DATA, "requant_vectors.txt")
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
vectors = []


def add(acc, p):
    """p = dict(m0, shift, out_zp). Stores one test line."""
    exp = m.requantize(acc, p["m0"], p["shift"], p["out_zp"])
    vectors.append((acc, p["m0"], -p["shift"], p["out_zp"], exp))


def acc_conv(x, w, b, p):
    x = x - p["in_zp"]
    win = sliding_window_view(x, (3, 3), axis=(1, 2))
    return np.einsum("chwkl,ockl->ohw", win, w) + b[:, None, None]


# 1) real accumulators from the model (first two images, all three layers)
image = m.load_hex("image.hex", 16).reshape(20, 28, 28)
c1w = m.load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
c1b = m.load_hex("conv1_b.hex", 32)
c2w = m.load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
c2b = m.load_hex("conv2_b.hex", 32)
fcw = m.load_hex("fc_w.hex", 16).reshape(400, 10)
fcb = m.load_hex("fc_b.hex", 32)

for t in range(2):
    x = image[t][None]
    acc1 = acc_conv(x, c1w, c1b, m.CONV1)
    for v in acc1.ravel():
        add(int(v), m.CONV1)
    p1 = m.maxpool2(m.requant_array(acc1, m.CONV1))
    acc2 = acc_conv(p1, c2w, c2b, m.CONV2)
    for v in acc2.ravel():
        add(int(v), m.CONV2)
    p2 = m.maxpool2(m.requant_array(acc2, m.CONV2))
    accf = (p2.reshape(-1) - m.FC["in_zp"]) @ fcw + fcb
    for v in accf.ravel():
        add(int(v), m.FC)

# 2) edge cases for every layer's constants
for p in (m.CONV1, m.CONV2, m.FC):
    for a in (INT32_MIN, INT32_MIN + 1, -(1 << 20), -1000, -1, 0, 1, 1000,
              1 << 20, INT32_MAX - 1, INT32_MAX):
        add(a, p)

# 3) the one saturation case (MIN * MIN) and a few odd shifts / zero-points
add(INT32_MIN, dict(m0=INT32_MIN, shift=-9, out_zp=-128))
add(INT32_MAX, dict(m0=INT32_MAX, shift=-9, out_zp=0))
for sh in (0, 1, 7, 15, 31):
    add(123456789, dict(m0=1500000000, shift=-sh, out_zp=5))
    add(-123456789, dict(m0=1500000000, shift=-sh, out_zp=-5))

# 4) random values, wide range, with each layer's constants
random.seed(1)
for p in (m.CONV1, m.CONV2, m.FC):
    for _ in range(1500):
        bits = random.choice((8, 12, 16, 20, 24, 31))
        add(random.randint(-(1 << bits), (1 << bits) - 1), p)

with open(OUT, "w") as f:
    for acc, m0, sh, zp, exp in vectors:
        f.write(f"{acc & 0xFFFFFFFF:08x} {m0 & 0xFFFFFFFF:08x} "
                f"{sh:02x} {zp & 0xFFFFFFFF:08x} {exp & 0xFF:02x}\n")
print(f"wrote {len(vectors)} vectors to {OUT}")
