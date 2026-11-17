"""Send a test image to the board over USB-UART and print the answer.

  python send_image.py COM5            # image 0 from the test set
  python send_image.py COM5 7          # image number 7
  python send_image.py COM5 --loop     # echo test: send 0x55 and show what comes back (needs a jumper
                                       #   between the board's UART TX and RX, otherwise nothing returns)

Needs pyserial:  python -m pip install pyserial
Protocol: 0xA5, then 784 pixel bytes (int8, row by row) -> reply 5 bytes:
          digit, cycles[31:24], cycles[23:16], cycles[15:8], cycles[7:0]
"""
import sys
import time
import micro_cnn_ref as m

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing:  python -m pip install pyserial")

if len(sys.argv) < 2:
    sys.exit(__doc__)
port = sys.argv[1]
baud = int(sys.argv[sys.argv.index("--baud") + 1]) if "--baud" in sys.argv else 115200
ser = serial.Serial(port, baud, timeout=3)

if "--loop" in sys.argv:
    ser.write(bytes([0x55]))
    print("received:", ser.read(1).hex() or "nothing")
    sys.exit()

n = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0
image = m.load_hex("image.hex", 16).reshape(20, 784)[n]
label = int(m.load_hex("test_labels.hex", 16)[n])
payload = bytes([0xA5]) + bytes(int(v) & 0xFF for v in image)

ser.reset_input_buffer()
t0 = time.time()
ser.write(payload)
reply = ser.read(5)
dt = time.time() - t0
if len(reply) != 5:
    sys.exit(f"expected 5 bytes back, got {len(reply)}: {reply.hex()}")
digit = reply[0]
cycles = int.from_bytes(reply[1:], "big")
print(f"image {n}: board says {digit}, label {label}  ->  {'OK' if digit == label else 'WRONG'}")
print(f"inference: {cycles} clocks = {cycles / 100:.1f} us at 100 MHz   (whole transfer took {dt * 1000:.0f} ms)")
