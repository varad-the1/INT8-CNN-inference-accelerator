"""Make the memory files and tile test vectors for tb_tile_engine.v.

Writes into data/:
  wbank0..3.hex      weight ROM banks (filter o -> bank o%4), 2048 lines each
  act_init.hex       activation memory image for sample 0:
                       [0:784) input image, [784:2136) pool1, [2136:2536) pool2
  tile_vectors.txt   one line per test tile:  layer pos0 py0 px0 obase  acc0..acc15

Expected sums are built the way the TESTBENCH builds its A and B matrices
(tb_microcnn.v run_conv1 / run_conv2 / run_fc), then multiplied in plain
Python, so the hardware address generator is checked against an independent
derivation.   Sums are WITHOUT bias.

Run:  python gen_tile_vectors.py
"""
import os
import random
import numpy as np
import micro_cnn_ref as m

random.seed(3)
D = m.DATA
ZP = -128

image = m.load_hex("image.hex", 16).reshape(20, 28, 28)
c1w = m.load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
c1b = m.load_hex("conv1_b.hex", 32)
c2w = m.load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
c2b = m.load_hex("conv2_b.hex", 32)
fcw = m.load_hex("fc_w.hex", 16).reshape(400, 10)

x0 = image[0]
a1 = m.conv(x0[None], c1w, c1b, m.CONV1)
p1 = m.maxpool2(a1)                     # (8,13,13)
a2 = m.conv(p1, c2w, c2b, m.CONV2)
p2 = m.maxpool2(a2)                     # (16,5,5)

# ---------------- weight ROM banks ----------------
DEPTH = 2048
banks = [[0] * DEPTH for _ in range(4)]
LAYER_BASE = {0: 0, 1: 18, 2: 306}      # conv1, conv2, fc  (must match the testbench)


def put(layer, nfilters, K, getw):
    for o in range(((nfilters + 3) // 4) * 4):          # pad filters up to a multiple of 4
        for k in range(K):
            val = getw(o, k) if o < nfilters else 0
            banks[o % 4][LAYER_BASE[layer] + (o // 4) * K + k] = int(val)


put(0, 8, 9, lambda o, k: c1w[o, 0, k // 3, k % 3])
put(1, 16, 72, lambda o, k: c2w[o, k // 9, (k % 9) // 3, k % 3])
put(2, 10, 400, lambda o, k: fcw[k, o])

for b in range(4):
    with open(os.path.join(D, f"wbank{b}.hex"), "w") as f:
        for v in banks[b]:
            f.write(f"{v & 0xFF:02x}\n")

# ---------------- activation memory image ----------------
act = list(x0.reshape(-1)) + list(p1.reshape(-1)) + list(p2.reshape(-1))
assert len(act) == 784 + 1352 + 400
with open(os.path.join(D, "act_init.hex"), "w") as f:
    for v in act:
        f.write(f"{int(v) & 0xFF:02x}\n")

# ---------------- expected tile sums ----------------
LAYER = {
    0: dict(K=9,   OW=26, npos=676, nf=8),
    1: dict(K=72,  OW=11, npos=121, nf=16),
    2: dict(K=400, OW=0,  npos=4,   nf=10),
}


def expected(layer, pos0, obase):
    L = LAYER[layer]
    K = L["K"]
    A = np.zeros((4, K), dtype=np.int64)
    B = np.zeros((K, 4), dtype=np.int64)
    for r in range(4):
        pos = pos0 + r
        if pos >= L["npos"]:
            continue                                      # padding row stays 0
        if layer == 2:
            A[r, :] = p2.reshape(-1) - ZP
        else:
            py, px = divmod(pos, L["OW"])
            src = x0[None] if layer == 0 else p1
            kk = 0
            for ch in range(src.shape[0]):
                for kh in range(3):
                    for kw in range(3):
                        A[r, kk] = src[ch, py + kh, px + kw] - ZP
                        kk += 1
    for c in range(4):
        o = obase + c
        if o >= L["nf"]:
            continue
        for kk in range(K):
            if layer == 0:
                B[kk, c] = c1w[o, 0, kk // 3, kk % 3]
            elif layer == 1:
                B[kk, c] = c2w[o, kk // 9, (kk % 9) // 3, kk % 3]
            else:
                B[kk, c] = fcw[kk, o]
    return A @ B                                          # (4,4)


tiles = []
# conv1: hand-picked (first, row wrap at 24, last) + random, both filter groups
for pos0 in (0, 4, 20, 24, 48, 672):
    for obase in (0, 4):
        tiles.append((0, pos0, obase))
for _ in range(30):
    tiles.append((0, 4 * random.randrange(169), 4 * random.randrange(2)))
tiles.append((0, 25, 0))                                  # not a multiple of 4: still must work
# conv2: first, wrap (pos 8 -> 8,9,10,11), only-one-valid-patch at 120, + random
for pos0 in (0, 8, 40, 116, 120):
    for obase in (0, 4, 8, 12):
        tiles.append((1, pos0, obase))
for _ in range(30):
    tiles.append((1, 4 * random.randrange(31), 4 * random.randrange(4)))
# fc: the three filter groups (last one is padded: only filters 8, 9 are real)
for obase in (0, 4, 8):
    tiles.append((2, 0, obase))

with open(os.path.join(D, "tile_vectors.txt"), "w") as f:
    for layer, pos0, obase in tiles:
        if layer == 2:
            py = px = 0
        else:
            py, px = divmod(pos0, LAYER[layer]["OW"])
        e = expected(layer, pos0, obase)
        accs = " ".join(f"{int(e[r, c]) & 0xFFFFFFFF:08x}" for r in range(4) for c in range(4))
        f.write(f"{layer:x} {pos0:x} {py:x} {px:x} {obase:x} {accs}\n")
print(f"wrote 4 weight banks, act_init.hex ({len(act)} words), {len(tiles)} tile vectors")
