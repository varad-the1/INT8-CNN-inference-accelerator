# Builds the bitstream for the Eisler Artix-7 board (non-project batch flow).
#
#   vivado -mode batch -source vivado/build_bitstream.tcl -tclargs xc7a35tcsg324-1 2000000
#
# Arguments (both optional):
#   1: FPGA part.  Default xc7a35tcsg324-1 (the board used here, XC7A35T).
#                  For the 100T version of the board use xc7a100tcsg324-1.
#   2: UART baud rate. Default 115200. The demo app is normally used at 2000000.
# Output: vivado/out_<device>[_<baud>]/board_top.bit + timing / utilisation / power reports.
#
# The memory initialisation files are read with relative paths (data/*.hex), so this script
# changes into the repository root first. Run it from anywhere.

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root

set part [expr {$argc > 0 ? [lindex $argv 0] : "xc7a35tcsg324-1"}]
regexp {^(xc7a[0-9]+t)} $part -> tag
set baud [expr {$argc > 1 ? [lindex $argv 1] : 0}]
set sfx  [expr {$baud > 0 ? "_$baud" : ""}]
set out  $root/vivado/out_$tag$sfx
file mkdir $out
puts "Building for part $part into $out"

foreach f {PE SystolicArrayMod requantizer maxpool4 argmax10 act_mem4 wrom4 bias_rom
           out_ram tile_engine layer_seq pool_seq cnn_top uart_rx uart_tx demo_rom board_top} {
    read_verilog $root/rtl/$f.v
}
read_xdc $root/constraints/board_top.xdc

if {$baud > 0} {
    set clks [expr {int(round(100000000.0 / $baud))}]
    puts "UART: $baud baud -> CLKS_PER_BIT = $clks"
    synth_design -top board_top -part $part -generic CLKS_PER_BIT=$clks
} else {
    synth_design -top board_top -part $part
}
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/util_synth.rpt

opt_design
place_design
route_design

report_timing_summary -file $out/timing.rpt -max_paths 10
report_utilization    -file $out/util.rpt
report_power          -file $out/power.rpt
report_drc            -file $out/drc.rpt
write_checkpoint -force $out/post_route.dcp

write_bitstream -force $out/board_top.bit
puts "=== BITSTREAM DONE ==="
