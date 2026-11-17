# Runs inside the synthesis run folder just before synth_design (hooked up by create_project.tcl).
# $readmemh in the RTL uses relative paths (data/*.hex); copy the folder next to the run so they resolve.
set repo_root [file normalize [file join [file dirname [info script]] ..]]
file delete -force data
file copy -force $repo_root/data data
puts "synth_pre.tcl: copied $repo_root/data into [pwd]"
