# Creates a Vivado project for the accelerator (sources are referenced in place, not copied).
#
#   vivado -mode batch -source vivado/create_project.tcl                    (then open vivado/cnn_accel/cnn_accel.xpr)
#   vivado -mode batch -source vivado/create_project.tcl -tclargs <part> <project_dir>
#
# Arguments (optional): 1 = FPGA part (default xc7a35tcsg324-1, the XC7A35T board; xc7a100tcsg324-1 for the 100T)
#                       2 = folder to create the project in (default: vivado/)
#
# Design top: board_top.  Simulation top: tb_cnn_top (full network, 20 images).
# The memory files are read with relative paths (data/*.hex). Vivado resolves those against the run
# folder, so: synthesis runs vivado/synth_pre.tcl first (copies data/ into the synth run folder), and
# for simulation this script copies data/ into the simulator's run folder. Pick another testbench with
#   set_property top tb_requantizer [get_filesets sim_1]

set root     [file normalize [file join [file dirname [info script]] ..]]
set part     [expr {$argc > 0 ? [lindex $argv 0] : "xc7a35tcsg324-1"}]
set proj_dir [expr {$argc > 1 ? [lindex $argv 1] : "$root/vivado"}]
cd $root

create_project -force cnn_accel $proj_dir/cnn_accel -part $part

# design sources
add_files -norecurse [glob $root/rtl/*.v]
set_property file_type Verilog [get_files -of_objects [get_filesets sources_1]]
set_property top board_top [get_filesets sources_1]

# copy data/ into the synthesis run folder before synth_design
set_property STEPS.SYNTH_DESIGN.TCL.PRE $root/vivado/synth_pre.tcl [get_runs synth_1]

# constraints (the pins used by board_top)
add_files -fileset constrs_1 -norecurse $root/constraints/board_top.xdc

# simulation sources
add_files -fileset sim_1 -norecurse [glob $root/tb/tb_*.v]
set_property top tb_cnn_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# make data/ visible to the simulator (relative $readmemh paths)
launch_simulation -scripts_only
set simdir [glob $proj_dir/cnn_accel/cnn_accel.sim/sim_1/behav/xsim]
file copy -force $root/data $simdir
puts "Project created in $proj_dir/cnn_accel"
