"""Make test vectors for tb_maxpool4.v and tb_argmax10.v from the Python reference.

data/maxpool_vectors.txt : a b c d expected          (int8, hex)
data/argmax_vectors.txt  : s0 s1 ... s9 expected_digit

Run:  python gen_pool_argmax_vectors.py
"""
import os
import random
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
import micro_cnn_ref as m

random.seed(2)
h = lambda v: f"{v & 0xFF:02x}"

# ---------------- max-pool vectors -----------------
pool = []

# real 2x2 windows from conv1 / conv2 outputs of the first two images,
# expected value taken from the reference maxpool2()
image = m.load_hex("image.hex", 16).reshape(20, 28, 28)
c1w = m.load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
c1b = m.load_hex("conv1_b.hex", 32)
c2w = m.load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
c2b = m.load_hex("conv2_b.hex", 32)


def windows(a):
    p = m.maxpool2(a)
    c, hh, ww = p.shape
    for ch in range(c):
        for r in range(hh):
            for k in range(ww):
                pool.append((int(a[ch, 2*r, 2*k]), int(a[ch, 2*r, 2*k+1]),
                             int(a[ch, 2*r+1, 2*k]), int(a[ch, 2*r+1, 2*k+1]),
                             int(p[ch, r, k])))


for t in range(2):
    a1 = m.conv(image[t][None], c1w, c1b, m.CONV1)
    windows(a1)
    a2 = m.conv(m.maxpool2(a1), c2w, c2b, m.CONV2)
    windows(a2)

# edge cases: ties, extremes, max in each position
for pos in range(4):
    v = [-128] * 4
    v[pos] = 127
    pool.append((*v, 127))
    v = [127] * 4
    v[pos] = -128
    pool.append((*v, 127))
pool.append((-128, -128, -128, -128, -128))
pool.append((0, 0, 0, 0, 0))
pool.append((127, 127, 127, 127, 127))

# random
for _ in range(4000):
    v = [random.randint(-128, 127) for _ in range(4)]
    pool.append((*v, max(v)))

with open(os.path.join(m.DATA, "maxpool_vectors.txt"), "w") as f:
    for a, b, c, d, e in pool:
        f.write(f"{h(a)} {h(b)} {h(c)} {h(d)} {h(e)}\n")
print(f"wrote {len(pool)} maxpool vectors")

# ---------------- argmax vectors -----------------
arg = []

# the 20 real logit sets from the reference (expected = what the testbench decides)
ref = m.load_hex("ref_logits.hex", 16).reshape(20, 10)
for row in ref:
    arg.append(([int(v) for v in row], int(np.argmax(row))))

# the maximum placed at each position, then ties, then random
for pos in range(10):
    v = [random.randint(-128, 100) for _ in range(10)]
    v[pos] = 127
    arg.append((v, int(np.argmax(v))))
arg.append(([0] * 10, 0))
arg.append(([-128] * 10, 0))
arg.append(([127] * 10, 0))
for _ in range(3000):
    lo = random.choice((-128, -3, 0))              # small ranges give many ties
    hi = random.choice((127, 3, 0)) if lo != 0 else random.choice((127, 3))
    v = [random.randint(lo, hi) for _ in range(10)]
    arg.append((v, int(np.argmax(v))))              # numpy: first max wins

with open(os.path.join(m.DATA, "argmax_vectors.txt"), "w") as f:
    for v, e in arg:
        f.write(" ".join(h(x) for x in v) + f" {e:02x}\n")
print(f"wrote {len(arg)} argmax vectors")
