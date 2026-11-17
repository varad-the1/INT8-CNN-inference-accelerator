# Synthesis + implementation check of cnn_top at 100 MHz (no board pins yet).
#   vivado -mode batch -source vivado/synth_check.tcl
# Reports go to vivado/reports

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out  $root/vivado/reports
file mkdir $out

read_verilog [glob $root/rtl/*.v]

synth_design -top cnn_top -part xc7a100tcsg324-1 -mode out_of_context
create_clock -period 10.000 -name clk [get_ports clk]

report_utilization    -file $out/util_synth.rpt
report_timing_summary -file $out/timing_synth.rpt -max_paths 5
puts "=== SYNTH DONE ==="

opt_design
place_design
route_design
report_utilization    -file $out/util_impl.rpt
report_timing_summary -file $out/timing_impl.rpt -max_paths 10
report_power          -file $out/power_impl.rpt
puts "=== IMPL DONE ==="
