# modus_atpg.tcl - run the Genus-generated stuck-at ATPG flow (FULLSCAN) and exit
# run from syn/:  modus -file modus_atpg.tcl
# Modus needs Verilog cell models for -techlib, so the Liberty path written by
# Genus is swapped for the gsclib045 Verilog library before the flow is run.
set GSC /opt/cadence/FOUNDRY/lan/flow/t1u1/reference_libs/GPDK045/gsclib045_svt_v4.4/gsclib045
set fh [open out/atpg/runmodus.atpg.tcl r]; set flow [read $fh]; close $fh
set flow [string map [list $GSC/timing/slow_vdd1v0_basicCells.lib $GSC/verilog/slow_vdd1v0_basicCells.v] $flow]
if {[catch {eval $flow} msg]} { puts "MODUS_FLOW_ERROR: $msg" }
puts "MODUS_ATPG_DONE"
exit
