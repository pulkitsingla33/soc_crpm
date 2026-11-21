# CRPM Controller for the Ibex RISC-V SoC

Clock, Reset and Power Management (CRPM) controller for the Ibex core, continuing from Lab 4.
The Ibex RTL is used unchanged from `soc_lab4/ibex` through the `ibex` symbolic link in this folder.

Location on the server: `~/cadence_chipin_work/soc_crpm_project`

## Files

| Folder | Files | Contents |
|---|---|---|
| rtl/ | crpm_pkg.sv, crpm_cells.sv, crpm_rst_ctrl.sv, crpm_pmu.sv, crpm_regs.sv, crpm_top.sv | CRPM controller |
| rtl/ | soc_top.sv, soc_core_pd.sv, soc_ram.sv, soc_ret_regs.sv | SoC: Ibex power domain with isolation, RAM, retention registers |
| tb/ | crpm_tb.sv, crpm_sva.sv | Block-level testbench and assertions |
| tb/ | soc_tb.sv, pwr_switch_model.sv | SoC testbench and power switch model |
| sw/ | crpm_test.S, rvasm.py | Test firmware and RV32I assembler (no RISC-V GCC on the server) |
| syn/ | genus_crpm.tcl, crpm.sdc, modus_atpg.tcl | Synthesis with scan insertion, and ATPG |
| scripts/ | run.csh, crpm_rtl.f, ibex.f, soc_rtl.f | Run script and file lists |

## How to run

Set up the tools:

```
csh
cd ~/cadence_chipin_work
source cshrc
cd soc_crpm_project
```

Simulation (Xcelium):

```
csh -f scripts/run.csh unit     # CRPM block test
csh -f scripts/run.csh soc      # Ibex SoC test (assembles sw/crpm_test.S first)
csh -f scripts/run.csh all      # both
csh -f scripts/run.csh soc gui  # open SimVision with waveforms
```

The script prints `ALL REQUESTED TESTS PASSED` only if both tests pass and no assertion failed.
Logs: `sim/unit/xrun_unit.log`, `sim/soc/xrun_soc.log`.

Synthesis and ATPG (run from `syn/`):

```
cd syn
genus -batch -files genus_crpm.tcl -log genus_crpm
modus -file modus_atpg.tcl
```

Reports go to `syn/rpt`, and the scan netlist goes to `syn/out`. Synthesis uses the gsclib045 library,
because the course `typical.lib` has no scan cell models.
