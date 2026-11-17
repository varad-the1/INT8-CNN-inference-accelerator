"""Draw a digit with the mouse; the FPGA recognizes it live.

  python draw_digit.py              # window: pick the COM port, click Connect, draw
  python draw_digit.py --selftest   # no window, no board: checks the image preparation

Every stroke is turned into a 28x28 image the way MNIST digits are prepared
(cropped, scaled to 20x20, centred by centre of mass), sent to the board over
the USB-UART (0xA5 + 784 bytes), and the board answers with the digit and its
clock count. "SIMULATE" in the port list runs the same model on the PC instead,
so the window can be tried without a board.

Needs:  python -m pip install pyserial pillow numpy
"""
import os
import sys
import time
import threading

import numpy as np
from PIL import Image, ImageDraw, ImageTk

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference"))
import micro_cnn_ref as m                      # the bit-exact model that the FPGA reproduces

CANVAS = 280                                   # drawing area in pixels
BRUSH = 22                                     # pen width in pixels
CLOCK_HZ = 100e6
SIMULATE = "SIMULATE (PC model only)"

# ---------------------------------------------------------------- the model on the PC
_c1w = m.load_hex("conv1_w.hex", 16).reshape(8, 1, 3, 3)
_c1b = m.load_hex("conv1_b.hex", 32)
_c2w = m.load_hex("conv2_w.hex", 16).reshape(16, 8, 3, 3)
_c2b = m.load_hex("conv2_b.hex", 32)
_fcw = m.load_hex("fc_w.hex", 16).reshape(400, 10)
_fcb = m.load_hex("fc_b.hex", 32)


def pc_predict(img28):
    """img28: uint8 28x28, 0 = black, 255 = white ink. Returns (digit, logits)."""
    x = (img28.astype(np.int64) - 128)[None]               # model input: int8 = pixel - 128
    a1 = m.conv(x, _c1w, _c1b, m.CONV1)
    a2 = m.conv(m.maxpool2(a1), _c2w, _c2b, m.CONV2)
    lg = m.fc(m.maxpool2(a2).reshape(-1), _fcw, _fcb, m.FC)
    return int(np.argmax(lg)), [int(v) for v in lg]


# ---------------------------------------------------------------- image preparation
def prepare(pil_img):
    """Drawing (white ink on black) -> 28x28 uint8 like an MNIST digit, or None if empty."""
    a = np.asarray(pil_img.convert("L"), dtype=np.uint8)
    ys, xs = np.where(a > 30)
    if len(ys) == 0:
        return None
    crop = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = crop.shape
    s = 20.0 / max(h, w)                                    # longest side -> 20 pixels
    nh, nw = max(1, round(h * s)), max(1, round(w * s))
    small = np.asarray(Image.fromarray(crop).resize((nw, nh), Image.LANCZOS))
    out = np.zeros((28, 28), dtype=np.uint8)
    top, left = (28 - nh) // 2, (28 - nw) // 2
    out[top:top + nh, left:left + nw] = small
    # move the centre of mass to the middle of the 28x28 image
    tot = float(out.sum())
    if tot > 0:
        cy = float((out.sum(axis=1) * np.arange(28)).sum() / tot)
        cx = float((out.sum(axis=0) * np.arange(28)).sum() / tot)
        out = shift(out, int(round(14 - cy)), int(round(14 - cx)))
    return out


def shift(a, dy, dx):
    r = np.zeros_like(a)
    h, w = a.shape
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    r[yd, xd] = a[ys, xs]
    return r


def frame_bytes(img28):
    """What the board expects: 0xA5, then 784 pixel bytes (int8, row by row)."""
    return bytes([0xA5]) + bytes(((img28.astype(np.int16) - 128) & 0xFF).astype(np.uint8).ravel())


# ---------------------------------------------------------------- self test (no window, no board)
def selftest():
    print("1) a real test image goes through the same path:")
    img = m.load_hex("image.hex", 16).reshape(20, 28, 28)
    ok = 0
    labels = m.load_hex("test_labels.hex", 16)
    for n in range(20):
        a = (img[n] + 128).astype(np.uint8)                 # int8 -> 0..255 pixel
        d, _ = pc_predict(a)
        ok += (d == labels[n])
    print(f"   model gets {ok}/20 right with pixel = int8 + 128")
    assert len(frame_bytes(a)) == 785
    assert frame_bytes(a)[0] == 0xA5

    print("2) hand-drawn-style digits (lines drawn with the same brush):")
    def canvas():
        im = Image.new("L", (CANVAS, CANVAS), 0)
        return im, ImageDraw.Draw(im)

    def stroke(d, pts):
        for p, q in zip(pts[:-1], pts[1:]):
            d.line([p, q], fill=255, width=BRUSH)
        for p in pts:
            d.ellipse([p[0] - BRUSH // 2, p[1] - BRUSH // 2, p[0] + BRUSH // 2, p[1] + BRUSH // 2], fill=255)

    shapes = {
        1: [[(140, 50), (140, 240)]],
        7: [[(70, 60), (210, 60), (120, 240)]],
        0: None,
        4: [[(190, 50), (190, 240)], [(190, 50), (60, 170), (230, 170)]],
    }
    for want, pts in shapes.items():
        im, d = canvas()
        if want == 0:
            d.ellipse([70, 50, 210, 240], outline=255, width=BRUSH)
        else:
            for s in pts:
                stroke(d, s)
        p = prepare(im)
        t0 = time.time()
        got, lg = pc_predict(p)
        print(f"   drew {want}: model says {got}   (PC inference {1000 * (time.time() - t0):.0f} ms)")

    print("3) empty canvas:", prepare(Image.new("L", (CANVAS, CANVAS), 0)))
    print("selftest finished")


# ---------------------------------------------------------------- the window
class Mailbox:
    """Holds only the NEWEST item, so a slow consumer never works through stale drawings."""
    def __init__(self):
        self.v, self.ev, self.lock = None, threading.Event(), threading.Lock()

    def put(self, v):
        with self.lock:
            self.v = v
            self.ev.set()

    def get(self, timeout):
        if not self.ev.wait(timeout):
            return None
        with self.lock:
            v, self.v = self.v, None
            self.ev.clear()
        return v


def run_gui(hook=None):
    import queue
    from collections import deque
    import tkinter as tk
    from tkinter import ttk
    try:
        import serial
        from serial.tools import list_ports
    except ImportError:
        sys.exit("pyserial is missing:  python -m pip install pyserial")

    root = tk.Tk()
    root.title("FPGA vs PC digit recogniser")
    root.configure(bg="#111")
    root.geometry("1010x640")

    img = Image.new("L", (CANVAS, CANVAS), 0)               # the real drawing (white on black)
    pen = ImageDraw.Draw(img)
    lock = threading.Lock()
    changed = threading.Event()
    stop = threading.Event()
    state = {"ser": None, "sim": False}
    q = queue.Queue()                                       # worker threads -> window
    box_fpga, box_pc = Mailbox(), Mailbox()
    hist = {"fpga_cmp": deque(maxlen=20), "fpga_rt": deque(maxlen=20), "pc": deque(maxlen=20)}
    last = {"fpga": None, "pc": None}                       # (frame id, digit)

    # ---- layout
    left = tk.Frame(root, bg="#111"); left.grid(row=0, column=0, padx=12, pady=12, sticky="n")
    right = tk.Frame(root, bg="#111"); right.grid(row=0, column=1, padx=6, pady=12, sticky="n")

    cv = tk.Canvas(left, width=CANVAS, height=CANVAS, bg="black", highlightthickness=2,
                   highlightbackground="#555", cursor="pencil")
    cv.pack()
    tk.Label(left, text="draw with the mouse  |  right-click or C = clear", bg="#111", fg="#888").pack(pady=4)
    tk.Label(left, text="what both sides see (28x28):", bg="#111", fg="#888").pack(anchor="w", pady=(10, 0))
    prev = tk.Canvas(left, width=140, height=140, bg="#222", highlightthickness=0); prev.pack(anchor="w")
    tk.Button(left, text="Clear", command=lambda: clear(), width=12).pack(anchor="w", pady=8)

    top = tk.Frame(right, bg="#111"); top.pack(anchor="w")
    port_var = tk.StringVar()
    combo = ttk.Combobox(top, textvariable=port_var, width=30, state="readonly"); combo.pack(side="left")
    baud_var = tk.StringVar(value="2000000")
    ttk.Combobox(top, textvariable=baud_var, values=["115200", "921600", "1000000", "2000000"],
                 width=8, state="readonly").pack(side="left", padx=(4, 0))
    btn = tk.Button(top, text="Connect"); btn.pack(side="left", padx=4)
    tk.Button(top, text="Refresh", command=lambda: refresh()).pack(side="left")
    info = tk.Label(right, text="pick a port and click Connect", bg="#111", fg="#ccc",
                    font=("Segoe UI", 10)); info.pack(anchor="w", pady=(4, 6))

    def panel(parent, title, accent):
        f = tk.Frame(parent, bg="#1b1b1b", padx=12, pady=8)
        tk.Label(f, text=title, bg="#1b1b1b", fg=accent, font=("Segoe UI", 12, "bold")).pack(anchor="w")
        d = tk.Label(f, text="?", font=("Segoe UI", 90, "bold"), width=2, bg="#1b1b1b", fg=accent); d.pack()
        t = tk.Label(f, text="", bg="#1b1b1b", fg="#ddd", font=("Consolas", 10), justify="left", width=34, anchor="w")
        t.pack(anchor="w")
        return f, d, t

    row = tk.Frame(right, bg="#111"); row.pack(anchor="w")
    f_fpga, d_fpga, t_fpga = panel(row, "FPGA  (Artix-7 35T, 100 MHz)", "#39ff14")
    f_pc, d_pc, t_pc = panel(row, "PC  (Python / NumPy model)", "#4fc3f7")
    f_fpga.grid(row=0, column=0, padx=(0, 8)); f_pc.grid(row=0, column=1)

    agree = tk.Label(right, text="", bg="#111", fg="#888", font=("Segoe UI", 11, "bold")); agree.pack(anchor="w", pady=(8, 0))
    cmp_ = tk.Label(right, text="", bg="#111", fg="#ddd", font=("Consolas", 10), justify="left"); cmp_.pack(anchor="w")
    tk.Label(right, text=("FPGA 'compute' = its own clock counter; 'round trip' also includes the serial cable.\n"
                          "PC time = the model only (the Python/NumPy version, not hand-optimised C)."),
             bg="#111", fg="#777", font=("Segoe UI", 9), justify="left").pack(anchor="w", pady=(6, 0))

    def refresh():
        ports = [p.device + "  " + (p.description or "") for p in list_ports.comports()]
        combo["values"] = [SIMULATE] + ports
        if not port_var.get():
            combo.current(1 if len(ports) == 1 else 0)
    refresh()

    # ---- drawing
    last_pt = [None]

    def dot(x, y):
        r = BRUSH // 2
        cv.create_oval(x - r, y - r, x + r, y + r, fill="white", outline="white")
        with lock:
            pen.ellipse([x - r, y - r, x + r, y + r], fill=255)
        changed.set()

    def down(e):
        last_pt[0] = (e.x, e.y); dot(e.x, e.y)

    def move(e):
        p = last_pt[0]
        if p is None:
            return
        cv.create_line(p[0], p[1], e.x, e.y, fill="white", width=BRUSH, capstyle="round")
        with lock:
            pen.line([p, (e.x, e.y)], fill=255, width=BRUSH)
        dot(e.x, e.y)
        last_pt[0] = (e.x, e.y)

    def up(e):
        last_pt[0] = None
        changed.set()

    def reset_panels():
        for d, t in ((d_fpga, t_fpga), (d_pc, t_pc)):
            d.config(text="?"); t.config(text="")
        agree.config(text=""); cmp_.config(text="")
        prev.delete("all")
        for h in hist.values():
            h.clear()
        last["fpga"] = last["pc"] = None

    def clear(*_):
        with lock:
            pen.rectangle([0, 0, CANVAS, CANVAS], fill=0)
        cv.delete("all")
        reset_panels()
        changed.set()

    cv.bind("<Button-1>", down); cv.bind("<B1-Motion>", move); cv.bind("<ButtonRelease-1>", up)
    cv.bind("<Button-3>", clear); root.bind("c", clear); root.bind("C", clear)

    # ---- connect
    def connect():
        if state["ser"] is not None:
            state["ser"].close(); state["ser"] = None
        sel = port_var.get()
        if sel == SIMULATE:
            state["sim"] = True
            info.config(text="SIMULATE: the FPGA side is the PC model too (no board)", fg="#ffd54f")
        else:
            try:
                state["ser"] = serial.Serial(sel.split()[0], int(baud_var.get()), timeout=1.0)
                state["sim"] = False
                info.config(text=f"connected to {sel.split()[0]} at {baud_var.get()} baud", fg="#7fdc7f")
            except Exception as ex:
                info.config(text=f"cannot open the port: {ex}", fg="#ff6b6b")
                return
        changed.set()
    btn.config(command=connect)

    # ---- worker threads: newest drawing -> (FPGA | PC model) -> answer queue
    def dispatcher():
        fid = 0
        while not stop.is_set():
            if not changed.wait(0.1):
                continue
            changed.clear()
            with lock:
                snap = img.copy()
            a = prepare(snap)
            if a is None:
                q.put(("empty",)); continue
            fid += 1
            q.put(("prep", fid, a))
            box_fpga.put((fid, a)); box_pc.put((fid, a))

    def fpga_worker():
        while not stop.is_set():
            item = box_fpga.get(0.1)
            if item is None or (state["ser"] is None and not state["sim"]):
                continue
            fid, a = item
            t0 = time.perf_counter()
            if state["sim"]:
                d, _ = pc_predict(a)
                q.put(("fpga", fid, d, 36962, 1000 * (time.perf_counter() - t0))); continue
            ser = state["ser"]
            try:
                ser.reset_input_buffer()
                ser.write(frame_bytes(a))
                rep = ser.read(5)
            except Exception as ex:
                q.put(("error", f"serial error: {ex}")); continue
            rt = 1000 * (time.perf_counter() - t0)
            if len(rep) != 5:
                q.put(("error", "no answer from the board (wrong port? not programmed? the baud rate must match the bitstream)")); continue
            q.put(("fpga", fid, rep[0], int.from_bytes(rep[1:], "big"), rt))

    def pc_worker():
        while not stop.is_set():
            item = box_pc.get(0.1)
            if item is None:
                continue
            fid, a = item
            t0 = time.perf_counter()
            d, _ = pc_predict(a)
            q.put(("pc", fid, d, 1000 * (time.perf_counter() - t0)))

    # ---- window updates (always on the main thread)
    def mean(dq):
        return sum(dq) / len(dq) if dq else 0.0

    def update_compare():
        if not (hist["fpga_cmp"] and hist["pc"]):
            return
        fc_us, rt_ms, pc_ms = mean(hist["fpga_cmp"]), mean(hist["fpga_rt"]), mean(hist["pc"])
        cmp_.config(text=(f"compute only    FPGA {fc_us:8.1f} us   PC {pc_ms * 1000:9.1f} us"
                          f"   ->  FPGA {pc_ms * 1000 / fc_us:5.1f}x faster\n"
                          f"end to end      FPGA {rt_ms:8.1f} ms   PC {pc_ms:9.1f} ms"
                          f"   (the serial cable limits the FPGA side)"))

    def update_agree():
        if last["fpga"] and last["pc"] and last["fpga"][0] == last["pc"][0]:
            same = last["fpga"][1] == last["pc"][1]
            agree.config(text="both give the same answer" if same else "DIFFERENT ANSWERS",
                         fg="#7fdc7f" if same else "#ff6b6b")

    def handle(msg):
        kind = msg[0]
        if kind == "empty":
            reset_panels()
        elif kind == "error":
            info.config(text=msg[1], fg="#ff6b6b")
        elif kind == "prep":
            ph = ImageTk.PhotoImage(Image.fromarray(msg[2]).resize((140, 140), Image.NEAREST))
            prev.delete("all"); prev.create_image(0, 0, anchor="nw", image=ph); prev.image = ph
        elif kind == "fpga":
            _, fid, d, cycles, rt = msg
            us = cycles / CLOCK_HZ * 1e6
            hist["fpga_cmp"].append(us); hist["fpga_rt"].append(rt)
            d_fpga.config(text=str(d))
            t_fpga.config(text=(f"compute   {us:8.1f} us  ({cycles} clocks)\n"
                                f"round trip{rt:8.1f} ms\n"
                                f"avg of {len(hist['fpga_cmp'])}: {mean(hist['fpga_cmp']):.1f} us / {mean(hist['fpga_rt']):.1f} ms"))
            last["fpga"] = (fid, d); update_agree(); update_compare()
        elif kind == "pc":
            _, fid, d, ms = msg
            hist["pc"].append(ms)
            d_pc.config(text=str(d))
            t_pc.config(text=(f"compute   {ms * 1000:8.1f} us\n"
                              f"          {ms:8.2f} ms\n"
                              f"avg of {len(hist['pc'])}: {mean(hist['pc']):.2f} ms"))
            last["pc"] = (fid, d); update_agree(); update_compare()

    def poll():
        try:
            while True:
                handle(q.get_nowait())
        except queue.Empty:
            pass
        if not stop.is_set():
            root.after(30, poll)

    pc_predict(np.zeros((28, 28), dtype=np.uint8))          # warm up NumPy so the first timing is fair
    for fn in (dispatcher, fpga_worker, pc_worker):
        threading.Thread(target=fn, daemon=True).start()
    poll()

    def close():
        stop.set()
        if state["ser"] is not None:
            state["ser"].close()
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", close)
    if hook:
        root.after(300, lambda: hook(dict(root=root, cv=cv, port_var=port_var, combo=combo, connect=connect,
                                          d_fpga=d_fpga, d_pc=d_pc, t_fpga=t_fpga, t_pc=t_pc,
                                          agree=agree, cmp_=cmp_, info=info, close=close)))
    root.mainloop()


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        run_gui()
