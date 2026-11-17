"""Write data/demo_images.hex: the 20 test images as bytes (784 per image, 2 hex digits).
Run:  python gen_demo_images.py
"""
import os
import micro_cnn_ref as m

image = m.load_hex("image.hex", 16).reshape(20, 784)
with open(os.path.join(m.DATA, "demo_images.hex"), "w") as f:
    for img in image:
        for v in img:
            f.write(f"{int(v) & 0xFF:02x}\n")
print("wrote demo_images.hex:", image.size, "bytes")
