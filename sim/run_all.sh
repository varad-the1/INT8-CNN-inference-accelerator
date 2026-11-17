#!/bin/sh
# Runs the whole regression with ModelSim/Questa. Run from the repository ROOT:
#     sh sim/run_all.sh
# (the memory files are read from data/ with relative paths, so the working directory matters).
# Needs vlib / vlog / vsim on the PATH.
set -e
rm -rf sim/work modelsim.ini && vlib sim/work >/dev/null && vmap work sim/work >/dev/null
vlog -quiet -work sim/work rtl/*.v tb/tb_*.v
for t in tb_requantizer tb_maxpool4 tb_argmax10 tb_tile_engine tb_layer_seq tb_pool_seq tb_cnn_top tb_board_top; do
    echo "=== $t ==="
    vsim -c -quiet work.$t -do "run -all; quit -f" | grep -v -E "^(#|VSIM)? *$" | tail -n 8
done
