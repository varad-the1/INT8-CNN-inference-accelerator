# INT8 CNN Inference Accelerator on FPGA (Verilog)

A complete hardware inference engine for a small quantised (INT8) CNN that recognises handwritten
digits (MNIST). Image in, digit out, entirely in Verilog on an **Eisler Artix-7 XC7A35T** board
(package CSG324), built around a **4x4 systolic array**. The hardware output is **bit-exact** with a
plain-Python reference model.

Track: *Verilog-based AI accelerator hardware project*.

## What it does

```
28x28 int8 image -> conv1 (8 filters 3x3) -> 2x2 max-pool -> conv2 (16 filters 3x3)
                 -> 2x2 max-pool -> flatten (400) -> fully connected (10) -> argmax -> digit
```

Every convolution and the fully connected layer is turned into 4x4 matrix tiles (im2col addressing)
and run on the systolic array. Between layers a pipelined requantiser converts the 32-bit sums back
to int8 using the same fixed-point arithmetic as the reference (TFLite/gemmlowp style).

Two ways to use it on the board:
- **Switches + button:** SW0..SW3 select one of 16 built-in test images, push-button 1 runs the
  inference, the right-most 7-segment digit shows the result.
- **PC drawing app** (`pc/draw_digit.py`): draw a digit with the mouse, it is sent over USB-UART
  (0xA5 + 784 bytes), and the board returns the digit and its clock count. The window shows the FPGA
  answer next to the same model run on the PC.

## Results (what was measured, and how)

| Item | Value | How measured |
|---|---|---|
| Functional match | 20/20 test images correct, **all 200 logits identical** to the Python reference | ModelSim, `tb_cnn_top` |
| Unit tests | requantiser 19,253 vectors, max-pool 7,515, argmax 3,033, 96 array tiles, whole layers, pooling: 0 mismatches | ModelSim (`sim/run_all.sh`) |
| Latency | **36,962 clocks** per inference = about **370 us** at 100 MHz | ModelSim cycle counter (`cycles` register in `cnn_top`) |
|  per stage | conv1 15,212 / pool1 5,418 / conv2 13,394 / pool2 1,610 / fc 1,310 | ModelSim |
| Timing | 100 MHz met, worst setup slack **+0.48 ns** (2 Mbaud build, XC7A35T) | Vivado 2025.2, `reports/timing_2Mbaud.rpt` |
| Resources | about 2,200 LUTs (10%), about 1,430 registers, 21 of 90 DSPs, 12 of 50 BRAM | Vivado, `reports/util_2Mbaud.rpt` |
| Power | about 0.15 W | Vivado **estimate** (not measured on the board) |
| On the board | the design was programmed on the board, the built-in images and the drawing app work | hardware run; see `demo/` |

Not measured / limits (stated deliberately):
- Accuracy was checked on the **20 supplied test images** only, not on the full MNIST set.
- The speed comparison in the PC window uses a Python/NumPy model, which is **not** an optimised
  CPU baseline, so it is a demonstration, not a benchmark.
- Latency (370 us) is the accelerator's compute time. The end-to-end round trip over UART is dominated
  by the serial cable (785 bytes in: about 68 ms at 115200 baud, about 4 ms at 2 Mbaud).
- Power is a tool estimate.

## Quick start

Everything is run **from the repository root** (the memory files are read from `data/` with relative paths).

**1. Simulate (no board needed)** - ModelSim/Questa (tested with ModelSim ASE 20.1):
```
sim\run_all.bat            
```
Each testbench prints `RESULT: PASS`. The main one is `tb_cnn_top` (all 20 images, all logits compared
with `data/ref_logits.hex`, prints the clock count).

**2. Python reference and PC app (no board needed)**
```
python reference/micro_cnn_ref.py          # reference model, must match data/ref_logits.hex
python pc/draw_digit.py                    # choose "SIMULATE" in the port list to try without a board
python pc/draw_digit.py --selftest         # image preparation self-check
```
Needs Python 3 with `numpy`, `pyserial`, `pillow`.

**3. Build the bitstream** - Vivado 2025.2 (any recent version should work):
```
vivado -mode batch -source vivado/build_bitstream.tcl -tclargs xc7a35tcsg324-1 2000000
```
Output: `vivado/out_xc7a35t_2000000/board_top.bit` (arguments: part, UART baud rate).
Or, to work in the Vivado GUI (project is generated, not stored):
```
vivado -mode batch -source vivado/create_project.tcl        # then open vivado/cnn_accel/cnn_accel.xpr
```
The project has `board_top` as design top, `board_top.xdc` as constraints and `tb_cnn_top` as the simulation top.
Ready-made bitstreams are in `bitstreams/`:
- `board_top_2Mbaud.bit` - normal use (UART 2,000,000 baud), pick **2000000** in the PC app
- `board_top_115200baud.bit` - fallback (UART 115200 baud)

**4. Run on the board:** program the bitstream (Vivado Hardware Manager), connect the USB-UART, run
`python pc/draw_digit.py`, select the COM port and the matching baud rate, draw a digit.
For the lowest round-trip time set the FTDI "Latency Timer" of the COM port to 1 ms.

Board pins are in `constraints/board_top.xdc` (only the pins used; derived from the vendor file, see "Reused material").

## Architecture (short)

In one table:

| File (`rtl/`) | Role |
|---|---|
| `PE.v`, `SystolicArrayMod.v` | 4x4 output-stationary systolic array (**workshop code, unchanged**) |
| `requantizer.v` | 5-stage pipeline: 32x32 multiply, rounding, divide by 2^31, rounding shift, zero-point and clamp to int8 |
| `maxpool4.v`, `argmax10.v` | 2x2 max; serial argmax over 10 scores (first maximum wins) |
| `act_mem4.v`, `wrom4.v`, `bias_rom.v`, `out_ram.v` | activation memory (4 copies, one read port per array row), weight ROM (4 banks), biases, conv/logit result memory |
| `tile_engine.v` | one 4x4 tile: im2col address generation, skew, zero-point subtraction, drives the array |
| `layer_seq.v`, `pool_seq.v` | loop the tiles of a whole layer / pool a whole layer |
| `cnn_top.v` | chains the five stages and argmax, image load port, clock counter |
| `uart_rx.v`, `uart_tx.v`, `demo_rom.v`, `board_top.v` | board wrapper: UART, 16 built-in images, switches, button, 7-segment |

## Reused material (not written for this project)

| What | Where | Source |
|---|---|---|
| 4x4 systolic array: `PE.v`, `SystolicArrayMod.v` | `rtl/` | Hackathon introductory workshop ("Day 4 AI Workshop: Systolic Array Design, Verilog RTL, FPGA"). Used **unchanged**. |
| `SystolicArrayMod_tb.v` (array testbench) | `tb/` | Same workshop. |
| `tb_microcnn.v` (full-network testbench: requantisation, pooling, argmax done in the testbench around the array) | `tb/` | Workshop supplied. Only the data path to the `.hex` files was changed to a relative one. It was the specification our hardware blocks were built to match. |
| The trained quantised model: weights, biases, requantisation constants (M0, shifts, zero-points), 20 test images, labels and golden logits | `data/`: `conv1_w.hex`, `conv1_b.hex`, `conv2_w.hex`, `conv2_b.hex`, `fc_w.hex`, `fc_b.hex`, `image.hex`, `test_labels.hex`, `ref_logits.hex`; constants in `reference/micro_cnn_ref.py` | Workshop supplied model (`model_data`). No training was done in this project. |
| Pin names and locations | `constraints/EISLER_MASTER_100T.xdc` (vendor file, unchanged); `constraints/board_top.xdc` (derived) | The board vendor's master constraints file (Eisler Artix-7 board files, written for the 100T; the 35T has the same pins). `board_top.xdc` is that file trimmed to the pins this design uses. |

Other files in this repository: `VERSION.md` (the freeze note for this version).

Everything else in this repository (all other RTL, testbenches, test-vector generators, the Python
reference breakdown, the PC application, the build script) was developed for this project.

## Directory structure

```
CNN_Accel/
├── bitstreams/
│   ├── board_top_115200baud.bit
│   └── board_top_2Mbaud.bit
├── constraints/
│   ├── board_top.xdc
│   └── EISLER_MASTER_100T.xdc
├── data/
│   ├── act_init.hex
│   ├── argmax_vectors.txt
│   ├── bias.hex
│   ├── conv1_b.hex
│   ├── conv1_w.hex
│   ├── conv2_b.hex
│   ├── conv2_w.hex
│   ├── demo_images.hex
│   ├── expect_conv1.hex
│   ├── expect_conv2.hex
│   ├── expect_fc.hex
│   ├── expect_pool1.hex
│   ├── expect_pool2.hex
│   ├── fc_b.hex
│   ├── fc_w.hex
│   ├── image.hex
│   ├── maxpool_vectors.txt
│   ├── ref_logits.hex
│   ├── requant_vectors.txt
│   ├── test_labels.hex
│   ├── tile_vectors.txt
│   ├── wbank0.hex
│   ├── wbank1.hex
│   ├── wbank2.hex
│   └── wbank3.hex
├── demo/
│   ├── demo.mp4
│   └── FPGA.jpeg
├── pc/
│   ├── _test_gui.py
│   └── draw_digit.py
├── reference/
│   ├── gen_demo_images.py
│   ├── gen_layer_vectors.py
│   ├── gen_pool_argmax_vectors.py
│   ├── gen_requant_vectors.py
│   ├── gen_tile_vectors.py
│   ├── micro_cnn_ref.py
│   └── send_image.py
├── reports/
│   ├── power_2Mbaud.rpt
│   ├── timing_2Mbaud.rpt
│   └── util_2Mbaud.rpt
├── rtl/
│   ├── act_mem4.v
│   ├── argmax10.v
│   ├── bias_rom.v
│   ├── board_top.v
│   ├── cnn_top.v
│   ├── demo_rom.v
│   ├── layer_seq.v
│   ├── maxpool4.v
│   ├── out_ram.v
│   ├── PE.v
│   ├── pool_seq.v
│   ├── requantizer.v
│   ├── SystolicArrayMod.v
│   ├── tile_engine.v
│   ├── uart_rx.v
│   ├── uart_tx.v
│   └── wrom4.v
├── sim/
│   ├── run_all.bat
│   └── run_all.sh
├── tb/
│   ├── SystolicArrayMod_tb.v
│   ├── tb_argmax10.v
│   ├── tb_board_top.v
│   ├── tb_cnn_top.v
│   ├── tb_layer_seq.v
│   ├── tb_maxpool4.v
│   ├── tb_microcnn.v
│   ├── tb_pool_seq.v
│   ├── tb_requantizer.v
│   └── tb_tile_engine.v
├── vivado/
│   ├── build_bitstream.tcl
│   ├── create_project.tcl
│   ├── synth_check.tcl
│   └── synth_pre.tcl
├── .gitignore
├── README.md
└── VERSION.md

(vivado/out_*/ is Vivado build output; it is git-ignored and recreated by the build script.
The shipped bitstreams and reports are copied to bitstreams/ and reports/.)
```

## Demo video

`demo/` contains the demonstration video (drawing digits in the PC app with the FPGA and PC answers side by side).

Also on YouTube: https://youtube.com/shorts/LEIRXNiKFF4
