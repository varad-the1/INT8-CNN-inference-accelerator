"""Drives the window with simulated mouse strokes in SIMULATE mode and prints what the panels show."""
import os
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ".")
import draw_digit as dd


def hook(c):
    root, cv = c["root"], c["cv"]
    c["combo"].current(0)                 # SIMULATE
    c["connect"]()

    def stroke(pts):
        x, y = pts[0]
        cv.event_generate("<Button-1>", x=x, y=y)
        for (x, y) in pts[1:]:
            cv.event_generate("<B1-Motion>", x=x, y=y)
        cv.event_generate("<ButtonRelease-1>", x=x, y=y)

    stroke([(140, 40), (140, 120), (140, 240)])          # a "1"

    def report():
        print("FPGA panel digit:", c["d_fpga"].cget("text"), "| PC panel digit:", c["d_pc"].cget("text"))
        print("agree label     :", c["agree"].cget("text"))
        print(c["t_fpga"].cget("text"))
        print(c["t_pc"].cget("text"))
        print(c["cmp_"].cget("text"))
        c["close"]()
    root.after(1500, report)


dd.run_gui(hook)
print("GUI test finished")
