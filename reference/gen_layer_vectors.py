"""Bias ROM contents and full-layer expected outputs for tb_layer_seq.v.

Writes into data/:
  bias.hex          34 x int32 : conv1 (8), conv2 (16), fc (10)
  expect_conv1.hex  8*26*26 int8, channel-major (index = o*676 + pos)
  expect_conv2.hex  16*11*11 int8              (index = o*121 + pos)
  expect_fc.hex     10 int8 logits
All taken from the reference model for sample 0 (the same data that is in
act_init.hex).

Run:  python gen_layer_vectors.py
"""
import os
import micro_cnn_ref as m

D = m.DATA
image = m.load_hex("image.hex", 16).reshape(20, 28, 28)
c1w = m.load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
c1b = m.load_hex("conv1_b.hex", 32)
c2w = m.load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
c2b = m.load_hex("conv2_b.hex", 32)
fcw = m.load_hex("fc_w.hex", 16).reshape(400, 10)
fcb = m.load_hex("fc_b.hex", 32)

a1 = m.conv(image[0][None], c1w, c1b, m.CONV1)
p1 = m.maxpool2(a1)
a2 = m.conv(p1, c2w, c2b, m.CONV2)
p2 = m.maxpool2(a2)
lg = m.fc(p2.reshape(-1), fcw, fcb, m.FC)


def dump(name, vals, width):
    with open(os.path.join(D, name), "w") as f:
        for v in vals:
            f.write(f"{int(v) & ((1 << width) - 1):0{width // 4}x}\n")


dump("bias.hex", list(c1b) + list(c2b) + list(fcb), 32)
dump("expect_conv1.hex", a1.reshape(-1), 8)
dump("expect_conv2.hex", a2.reshape(-1), 8)
dump("expect_fc.hex", lg.reshape(-1), 8)
print("wrote bias.hex and expected outputs:",
      a1.size, "conv1,", a2.size, "conv2,", lg.size, "fc values")
print("fc logits:", list(lg), " -> predicted", int(lg.argmax()), "label", int(m.load_hex('test_labels.hex', 16)[0]))

# pooled outputs (for tb_pool_seq.v)
dump("expect_pool1.hex", p1.reshape(-1), 8)     # 8*13*13 = 1352
dump("expect_pool2.hex", p2.reshape(-1), 8)     # 16*5*5  = 400
print("wrote pooled expected outputs:", p1.size, "pool1,", p2.size, "pool2 values")
