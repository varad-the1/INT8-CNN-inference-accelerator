@echo off
rem Runs the whole regression with ModelSim/Questa. Run from the repository ROOT:  sim\run_all.bat
rem (memory files are read from data\ with relative paths, so the working directory matters)
if exist sim\work rmdir /s /q sim\work
vlib sim/work
vmap work sim/work
vlog -quiet -work sim/work rtl/*.v tb/tb_*.v
for %%t in (tb_requantizer tb_maxpool4 tb_argmax10 tb_tile_engine tb_layer_seq tb_pool_seq tb_cnn_top tb_board_top) do (
    echo === %%t ===
    vsim -c -quiet work.%%t -do "run -all; quit -f"
)
