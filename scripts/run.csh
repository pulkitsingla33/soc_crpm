#!/bin/csh -f
# -----------------------------------------------------------------------------
# run.csh  <unit|soc|all> [gui] [seed=N]
#   unit : CRPM block-level testbench (crpm_tb)
#   soc  : Ibex SoC testbench running sw/crpm_test.S (soc_tb)
#   gui  : open SimVision with waveforms
# Run from the project root after:  csh ; source ../cshrc   (in cadence_chipin_work)
# -----------------------------------------------------------------------------
# must be started from the project root (the folder holding rtl/ tb/ sw/)
set root = $cwd
if (! -d $root/rtl || ! -d $root/tb) then
  echo "run.csh: please run from the project root:  csh -f scripts/run.csh <unit|soc|all>"
  exit 2
endif
set target = "all"
set gui = ""
set seed = 1
foreach a ($argv)
  if ("$a" == "gui") then
    set gui = "-gui -access +rwc +WAVES"
  else if ("$a" =~ seed=*) then
    set seed = `echo $a | sed 's/seed=//'`
  else
    set target = $a
  endif
end
set common = "-64bit -sv -timescale 1ns/1ps -access +r -nowarn DSEMEL -nowarn DSEM2009 -svseed $seed"
set status_all = 0

if ("$target" == "unit" || "$target" == "all") then
  mkdir -p $root/sim/unit
  cd $root/sim/unit
  xrun $common $gui -f ../../scripts/crpm_rtl.f ../../tb/crpm_sva.sv ../../tb/crpm_tb.sv \
       -top crpm_tb -l xrun_unit.log
  grep -q "TEST PASSED" xrun_unit.log
  if ($status != 0) set status_all = 1
  grep -q '\*E,ASRTST' xrun_unit.log
  if ($status == 0) then
    echo "run.csh: assertion failures in unit run"
    set status_all = 1
  endif
  cd $root
endif

if ("$target" == "soc" || "$target" == "all") then
  mkdir -p $root/sim/soc
  python3 $root/sw/rvasm.py $root/sw/crpm_test.S $root/sim/soc/fw.hex $root/sim/soc/fw.lst
  cd $root/sim/soc
  xrun $common $gui -f ../../scripts/crpm_rtl.f -f ../../scripts/ibex.f -f ../../scripts/soc_rtl.f \
       ../../tb/crpm_sva.sv ../../tb/pwr_switch_model.sv ../../tb/soc_tb.sv \
       -top soc_tb +FW=fw.hex -l xrun_soc.log
  grep -q "TEST PASSED" xrun_soc.log
  if ($status != 0) set status_all = 1
  grep -q '\*E,ASRTST' xrun_soc.log
  if ($status == 0) then
    echo "run.csh: assertion failures in soc run"
    set status_all = 1
  endif
  cd $root
endif

if ($status_all == 0) then
  echo "run.csh: ALL REQUESTED TESTS PASSED"
else
  echo "run.csh: FAILURES - see sim/*/xrun_*.log"
endif
exit $status_all
