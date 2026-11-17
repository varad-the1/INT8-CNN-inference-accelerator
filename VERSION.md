# v1 (frozen) - INT8 CNN accelerator on the Eisler Artix-7 35T

Frozen on 5 Nov 2026.
Everything here was tested in simulation (ModelSim), built in Vivado 2025.2 and run on the board.

## What it is
Image in -> conv1 -> pool -> conv2 -> pool -> fc -> argmax -> digit, all in Verilog around the
workshop's 4x4 systolic array (PE.v, SystolicArrayMod.v). Bit-exact with the Python reference
(reference/micro_cnn_ref.py): 20/20 samples, all 200 logits identical to ref_logits.hex.

## Measured results
| Item | Value |
|---|---|
| Clocks per inference | 36,962 (about 370 us at 100 MHz) |
|   conv1 / pool1 / conv2 / pool2 / fc | 15,212 / 5,418 / 13,394 / 1,610 / 1,310 |
| Timing at 100 MHz (XC7A35T) | met, worst slack +0.48 ns (2 Mbaud build) |
| LUTs / registers | about 2,200 of 20,800 / about 1,430 of 41,600 |
| DSPs / block RAM | 21 of 90 / 12 of 50 |
| Power (Vivado estimate) | about 0.15 W |

## Bitstreams (vivado\)
| File | UART | Use |
|---|---|---|
| out_xc7a35t\board_top.bit | 115200 baud | fallback |
| out_xc7a35t_2000000\board_top.bit | 2,000,000 baud | normal; round trip is dominated by the cable otherwise |

Board: slide switches SW0..SW3 select one of 16 built-in images, push button 1 runs it, the
right-most 7-segment digit shows the answer. PC: pc\draw_digit.py (draw a digit; FPGA and PC model
answer side by side). Set the FTDI latency timer of the COM port to 1 ms for the lowest round trip.

## Files (rtl\)
PE, SystolicArrayMod                 the 4x4 systolic array (from the workshop)
requantizer, maxpool4, argmax10      the small arithmetic blocks
act_mem4, wrom4, bias_rom, out_ram   memories
tile_engine                          feeds the array: addresses, skew, one 4x4 tile
layer_seq, pool_seq                  loop a whole layer / pool a whole layer
cnn_top                              chains the five stages, argmax
uart_rx, uart_tx, demo_rom, board_top   board wrapper

## Run the tests (ModelSim) from this folder
tb\tb_requantizer, tb_maxpool4, tb_argmax10, tb_tile_engine, tb_layer_seq, tb_pool_seq,
tb_cnn_top, tb_board_top   (expected values come from reference\*.py)
