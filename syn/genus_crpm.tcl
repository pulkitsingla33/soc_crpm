# -----------------------------------------------------------------------------
# genus_crpm.tcl - synthesis + scan insertion of the CRPM (45nm typical lib)
# run from syn/:  genus -batch -files genus_crpm.tcl -log genus_crpm
# -----------------------------------------------------------------------------
# gsclib045 slow corner: has scan test_cell models (the course typical.lib has none)
set LIB /opt/cadence/FOUNDRY/lan/flow/t1u1/reference_libs/GPDK045/gsclib045_svt_v4.4/gsclib045/timing/slow_vdd1v0_basicCells.lib
set RTL ../rtl
file mkdir out rpt

set_db init_lib_search_path [file dirname $LIB]
set_db information_level 2
read_libs $LIB

read_hdl -sv -define CRPM_USE_LIB_ICG [list \
  $RTL/crpm_pkg.sv $RTL/crpm_cells.sv $RTL/crpm_rst_ctrl.sv \
  $RTL/crpm_pmu.sv $RTL/crpm_regs.sv  $RTL/crpm_top.sv]
elaborate crpm_top
check_design -unresolved
read_sdc crpm.sdc

# ------------------------------------------------------------------ DFT setup
set_db dft_scan_style muxed_scan
set_db dft_prefix DFT_
define_shift_enable -name scan_en   -active high -create_port scan_en
define_test_mode    -name test_mode -active high test_mode_i
define_test_clock   -name clk_ref   -period 20000 clk_ref_i
check_dft_rules > rpt/dft_rules_pre.rpt

# ----------------------------------------------------------------- synthesis
syn_generic
syn_map
check_dft_rules > rpt/dft_rules_mapped.rpt
convert_to_scan
define_scan_chain -name chain0 -sdi scan_in -sdo scan_out -create_ports -shift_enable scan_en
connect_scan_chains -auto_create_chains
syn_opt
report_scan_chains -summary

# ------------------------------------------------------------------- reports
report_area                 > rpt/area.rpt
report_gates                > rpt/gates.rpt
report_timing -nworst 5     > rpt/timing.rpt
report_power                > rpt/power.rpt
report_scan_chains          > rpt/scan_chains.rpt
report_scan_setup           > rpt/dft_setup.rpt
check_dft_rules             > rpt/dft_rules_final.rpt
report_qor                  > rpt/qor.rpt

write_hdl                   > out/crpm_top_scan.v
write_sdc                   > out/crpm_top_scan.sdc
write_scandef               > out/crpm_top.scandef
write_dft_atpg -library $LIB -directory out/atpg
puts "GENUS_CRPM_DONE"
exit
