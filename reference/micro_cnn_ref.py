"""Python reference for the micro-CNN used by tb_microcnn.v.

Same maths as the testbench, written plainly so every step can be read:
  image -> conv1 -> maxpool -> conv2 -> maxpool -> flatten -> fc -> argmax
It must reproduce ref_logits.hex exactly (bit for bit).

Run:  python micro_cnn_ref.py
"""
import os
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "data")

# Constants copied from tb_microcnn.v (they come from model_data.h)
CONV1 = dict(m0=2023435029, shift=-9,  in_zp=-128, out_zp=-128)
CONV2 = dict(m0=1672637759, shift=-8,  in_zp=-128, out_zp=-128)
FC    = dict(m0=1586550534, shift=-10, in_zp=-128, out_zp=-8)
N_TESTS = 20


def load_hex(name, bits):
    """Read a .hex file of two's-complement values into an int64 array."""
    vals = []
    with open(os.path.join(DATA, name)) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if v >= 1 << (bits - 1):
                v -= 1 << bits
            vals.append(v)
    return np.array(vals, dtype=np.int64)


def wrap32(x):
    """Wrap to a signed 32-bit value, like a 32-bit register would."""
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x >= (1 << 31) else x


# ---- requantization: turn the 32-bit sum back into an int8 value ----------
def sat_round_doubling_high_mul(a, b):
    """(a * b) / 2^31, rounded, saturated. The 'multiply by M0' step."""
    if a == -(1 << 31) and b == -(1 << 31):
        return (1 << 31) - 1
    ab = a * b
    nudge = (1 << 30) if ab >= 0 else 1 - (1 << 30)
    num = ab + nudge
    result = abs(num) // (1 << 31)          # Verilog '/' truncates toward zero
    if num < 0:
        result = -result
    return max(-(1 << 31), min((1 << 31) - 1, result))


def rounding_divide_by_pot(x, exponent):
    """x / 2^exponent with rounding to nearest (the 'shift' step)."""
    if exponent == 0:
        return x
    mask = (1 << exponent) - 1
    remainder = x & mask
    threshold = (mask >> 1) + (1 if x < 0 else 0)
    return (x >> exponent) + (1 if remainder > threshold else 0)


def requantize(acc, m0, shift, out_zp):
    left, right = (shift, 0) if shift > 0 else (0, -shift)
    x = wrap32(acc << left)
    high = sat_round_doubling_high_mul(x, m0)
    out = rounding_divide_by_pot(high, right) + out_zp
    return max(-128, min(127, out))


def requant_array(acc, p):
    flat = [requantize(wrap32(int(v)), p["m0"], p["shift"], p["out_zp"])
            for v in acc.ravel()]
    return np.array(flat, dtype=np.int64).reshape(acc.shape)


# ---- layers ---------------------------------------------------------------
def conv(x, w, b, p):
    """x: (C,H,W) int8 values, w: (O,C,3,3), b: (O). Stride 1, no padding."""
    x = x - p["in_zp"]                                    # remove zero-point
    win = sliding_window_view(x, (3, 3), axis=(1, 2))    # (C, H-2, W-2, 3, 3)
    acc = np.einsum("chwkl,ockl->ohw", win, w) + b[:, None, None]
    return requant_array(acc, p)


def maxpool2(x):
    """2x2 max pool, stride 2. Odd leftover row/column is dropped."""
    c, h, w = x.shape
    h2, w2 = h // 2, w // 2
    x = x[:, :h2 * 2, :w2 * 2].reshape(c, h2, 2, w2, 2)
    return x.max(axis=(2, 4))


def fc(x_flat, w, b, p):
    """x_flat: (400,), w: (400,10), b: (10)."""
    acc = (x_flat - p["in_zp"]) @ w + b
    return requant_array(acc, p)


def main():
    image = load_hex("image.hex", 16).reshape(N_TESTS, 28, 28)
    c1w = load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
    c1b = load_hex("conv1_b.hex", 32)
    c2w = load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
    c2b = load_hex("conv2_b.hex", 32)
    fcw = load_hex("fc_w.hex", 16).reshape(400, 10)      # [in_feature][out]
    fcb = load_hex("fc_b.hex", 32)
    labels = load_hex("test_labels.hex", 16)
    ref = load_hex("ref_logits.hex", 16).reshape(N_TESTS, 10)

    correct = exact = 0
    for t in range(N_TESTS):
        x = image[t][None, :, :]                         # (1,28,28)
        a1 = conv(x, c1w, c1b, CONV1)                    # (8,26,26)
        p1 = maxpool2(a1)                                # (8,13,13)
        a2 = conv(p1, c2w, c2b, CONV2)                   # (16,11,11)
        p2 = maxpool2(a2)                                # (16,5,5)
        flat = p2.reshape(-1)                            # (400,) channel-major
        logits = fc(flat, fcw, fcb, FC)                  # (10,)
        pred = int(np.argmax(logits))                    # first max wins

        if t == 0:
            print("shapes: image", x.shape, "conv1", a1.shape, "pool1", p1.shape,
                  "conv2", a2.shape, "pool2", p2.shape, "flat", flat.shape)

        same = np.array_equal(logits, ref[t])
        exact += same
        correct += pred == labels[t]
        print(f"sample {t:2d}: pred={pred} label={labels[t]} "
              f"logits match ref: {'YES' if same else 'NO'}")

    print(f"\naccuracy {correct}/{N_TESTS}   bit-exact logits {exact}/{N_TESTS}")
    print("RESULT:", "PASS" if exact == N_TESTS else "FAIL")


if __name__ == "__main__":
    main()
