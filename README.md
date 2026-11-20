# CRPM — Clock, Reset and Power Management Controller for a 32-bit RISC-V (Ibex) SoC

This project continues Lab 4. The Ibex core RTL from `soc_lab4/ibex` is reused **without modification**,
and the simple Lab 4 wrapper is replaced by a small SoC. In that SoC the core sits in a switchable power
domain, and a new CRPM controller provides all of its clocks, resets and power-management sequencing.

Server location: `~/cadence_chipin_work/soc_crpm_project` (`ibex -> ../soc_lab4/ibex` is a symlink).

```
soc_crpm_project/
├── rtl/   crpm_pkg, crpm_cells, crpm_rst_ctrl, crpm_pmu, crpm_regs, crpm_top   (CRPM IP)
│          soc_core_pd, soc_ram, soc_ret_regs, soc_top                         (SoC integration)
├── tb/    crpm_tb (block level), crpm_sva (bound assertions),
│          soc_tb + pwr_switch_model (SoC level, Ibex runs firmware)
├── sw/    crpm_test.S (firmware), rvasm.py (RV32I assembler; no RISC-V GCC on the server)
├── syn/   genus_crpm.tcl + crpm.sdc (synthesis + scan insertion), rpt/, out/ (netlist, scandef, ATPG)
├── scripts/ run.csh, *.f file lists
└── sim/   unit/, soc/  (Xcelium run directories and logs)
```

## How to run

```csh
csh
cd ~/cadence_chipin_work
source cshrc
cd soc_crpm_project
csh -f scripts/run.csh all          # unit + SoC regression  (or: unit | soc)
csh -f scripts/run.csh soc gui      # SimVision with waveforms
cd syn ; genus -batch -files genus_crpm.tcl -log genus_crpm    # synthesis + DFT
```

`run.csh` prints `ALL REQUESTED TESTS PASSED` only if both testbenches report PASS **and** no assertion
(CRPM SVA or Ibex internal) failed.

---

## 1. Architecture

```
                         ┌──────────────────────────── CRPM (always-on, clk_ref) ─────────────────────────┐
 clk_ref_i ─────────────►│──────────────────────────────────────────────────────────────► aon_clk          │
                         │ clk_en_gen(core div 1/2/4/8) ─► ICG ─────────────────────────► core_clk         │
                         │ clk_en_gen(periph div)       ─► ICG ─────────────────────────► periph_clk       │
 por_ni ─► rst_sync ────►│ reset sequencer: HOLD ─► sys ─(8)─► periph ─(8)─► core ──────► sys/periph/core_rst_n│
 ext_rst_ni ─► 2FF ─────►│   sources: POR, ext pin, SW (keyed), watchdog; sticky RST_CAUSE                │
                         │ PMU FSM ─► core_clk_en, periph_clk_en, iso_en, ret_save/restore, pwr_en, rst   │
 pwr_ack ─► 2FF ────────►│ wake-up controller: irq[15:0], ext_wake (2FF), wake timer ─► WAKE_PEND ─► wake │
                         │ registers (bus sampled on core ticks), watchdog, POR-only scratch             │
                         └────────────────────────────────────────────────────────────────────────────────┘
        PD_CORE (switchable)                                   PD_AON
   ┌──────────────────────────┐ iso cells  ┌──────────────────────────────────────────────┐
   │ ibex_top (unmodified)    │──clamp 0──►│ data/instr interconnect, SRAM 64 KiB, CRPM   │
   │ retention registers      │◄───────────│ ext bus port (TB sim-control @0x2000_0000)   │
   └──────────────────────────┘            └──────────────────────────────────────────────┘
```

Key design decisions:

* **No generated clocks and no CDC between derived domains.** Each divider is a counter that makes an *enable*
  for a latch-based ICG. Every core and peripheral clock edge is therefore also a `clk_ref` edge, and the
  derived domains stay fully synchronous. The CRPM register file runs on `clk_ref` but only samples the bus
  when `core_tick` is high. It then behaves like a core-domain flop and needs no synchroniser.
* **Glitch-free clocking.** The ICG enable is captured while the clock is low. A new divide ratio is only
  taken at the end of a full divided period, so no shortened pulse is ever produced. This is checked by a
  pulse-width monitor in the testbench.
* **Reset strategy.** Every reset is asserted asynchronously and released synchronously. Release is ordered:
  sys → periph → core. All reset outputs are driven from flops, so they cannot glitch.
* **Power intent (modelled in RTL).** PD_CORE outputs pass through clamp-0 isolation cells (`crpm_iso_cell`).
  In simulation an unpowered domain drives X (`soc_core_pd`), so any isolation hole is visible.
  `soc_ret_regs` models balloon-latch retention flops (save/restore pulses from the PMU).
  `pwr_switch_model` models the power switch, with ramp-up and ramp-down delays.
* **DFT.** `test_mode_i` makes all ICGs transparent (every clock = `clk_ref`) and bypasses the reset
  synchroniser/sequencer, so all asynchronous resets are directly controllable from `por_ni`.

## 2. Register map (CRPM base `0x1000_0000`)

| Off | Name | Access | Description |
|---|---|---|---|
| 0x00 | CLK_CTRL | RW | [1:0] core div (/1,/2,/4,/8), [5:4] periph div, [8] core_clk_en, [9] periph_clk_en; RO [17:16]/[21:20] = ratio currently applied |
| 0x04 | RST_CTRL | WO | write `0xA5A` to [11:0] → software reset of the whole SoC (other values are ignored) |
| 0x08 | RST_CAUSE | RW1C | [0] POR, [1] EXT pin, [2] SW, [3] WDT (sticky; POR sets only bit 0) |
| 0x0C | PM_CTRL | RW | low-power mode used by the next WFI: 0 NONE, 1 IDLE, 2 SLEEP, 3 DEEP (cleared automatically on entry) |
| 0x10 | PM_STATUS | RO/W1C | [3:0] PMU state, [8] pwr_ack, [9] iso_en, [10] deep, [11] wake_seen, [12] slept, [13] deep_slept |
| 0x14 | WAKE_MASK | RW | [15:0] irq lines, [16] ext wake pin, [17] wake-up timer |
| 0x18 | WDT_CTRL | RW | [0] enable (enabling reloads the counter) |
| 0x1C | WDT_LOAD | RW | timeout in ref cycles (a write reloads the counter) |
| 0x20 | WDT_KICK | WO | write `0x5A5A5A5A` to reload |
| 0x24 | WDT_COUNT | RO | current watchdog count (paused in every low-power state) |
| 0x28 | LP_STATS | RO | {sleep entries[15:0], idle entries[15:0]} |
| 0x2C | ID | RO | `0x4352504D` ("CRPM") |
| 0x30 | WAKE_PEND | RW1C | latched wake events (same bits as WAKE_MASK); pending & mask = IRQ to Ibex (`irq_fast_i[0]`) |
| 0x34 | WKT | RW | always-on wake-up timer: write N → wake event after N ref cycles; reads the remaining count |
| 0x38/0x3C | SCRATCH0/1 | RW | reset **only by POR**: survive SW, WDT and EXT resets and power-down |

## 3. Power modes and PMU sequences

Firmware programs `PM_CTRL` and executes `WFI`. When Ibex raises `core_sleep_o`, the PMU starts the
sequence. Every step lasts at least `PM_STEP_CYCLES`. All PMU outputs are registered.

| Mode | Core clock | Core power | Periph clock | Wake |
|---|---|---|---|---|
| IDLE | gated | on | on | any unmasked wake → clock on; Ibex leaves WFI on the wake IRQ |
| SLEEP | gated | **off** (state retained in retention regs and SRAM) | on | power-up sequence, then Ibex reboots (warm boot) |
| DEEP | gated | off | **gated** | as SLEEP |

```
Power-down : CLK_OFF → ISO_ON → RET_SAVE → CORE_RST → PWR_OFF → (wait ack=0) → SLEEP
Wake       : PWR_ON → (wait ack=1) → RET_RESTORE → RST_RELEASE → ISO_OFF → CLK_ON → RUN
```

## 4. Verification

### 4.1 Block level — `tb/crpm_tb.sv` (BFM for the core bus and WFI behaviour)

| Test | What is checked |
|---|---|
| T1 POR | reset ordering sys → periph → core; HOLD = 16, sys → periph = 8 cycles; core powered and de-isolated |
| T2 registers | reset values of all registers, RW, byte enables, W1C, unmapped address → bus error |
| T3 dividers | all 4 core ratios × periph /1 and /8: measured periods and read-back of the applied ratio |
| T4 random | 60 random on-the-fly ratio changes; checker requires every high/low phase ≥ ½ T<sub>ref</sub> |
| T5 SW gating | CLK_CTRL enables stop and restart the peripheral clock |
| T6 IDLE | entry, masked irq does not wake, 0 core edges while IDLE, timer wake, one-shot mode, LP_NONE WFI |
| T7 SLEEP | exact event order of power-down and wake-up; slow power switch (1.5 µs) → PMU waits for ack |
| T8 DEEP | peripheral clock gated, stays asleep until the ext pin, flags |
| T9 SW reset | wrong key ignored, correct key resets everything, cause = SW, scratch kept |
| T10 WDT | kicks prevent reset, wrong kick key ignored, paused in IDLE, expiry → cause = WDT |
| T11 EXT reset | held in reset while the pin is low, cause = EXT |
| T12 test mode | clocks forced on, resets follow `por_ni` directly, POR clears scratch |

`tb/crpm_sva.sv` is bound into `crpm_top` and adds assertions that check:

* power is removed only from a domain that is isolated and held in reset
* no core clock while the domain is unpowered
* isolation is released only after the power acknowledge
* save and restore happen with the clock stopped and in reset
* deep sleep gates the peripheral clock
* reset ordering is respected
* the bus response arrives one core cycle after the request
* no X on control outputs

Cover properties track IDLE, SLEEP, wake and DEEP.

### 4.2 SoC level — `tb/soc_tb.sv` (unmodified Ibex executes `sw/crpm_test.S`)

The firmware runs through 8 stages across 2 power-downs and 3 resets. Its progress is stored in
POR-only `SCRATCH0`.

1. cold boot: ID, POR cause, W1C, RW checks, core divider sweep /2 /4 /8 and periph /4 (TB measures the periods)
2. IDLE, woken by the wake-up timer
3. SLEEP: retention registers and SRAM checked after the warm reboot
4. DEEP: masked timer must not wake, ext pin wakes; TB checks the peripheral counter is frozen
5. watchdog kicks, wrong-key and correct-key SW reset
6. cause = SW; watchdog expiry
7. cause = WDT; TB pulses the external reset pin
8. cause = EXT, `SCRATCH1` survived every reset, IDLE woken by external irq line 0, PASS

The TB also checks that:

* no core clock edge appears in a low-power state
* nothing (X or a request) leaks from the unpowered core through the isolation cells
* the X-corruption model really is active behind the isolation cells
* reset release ordering holds after every reset

### 4.3 Results (Xcelium 22.09)

| Run | Result |
|---|---|
| `crpm_tb` | **262 checks, 0 errors, 0 clock glitches, 0 assertion failures — PASSED** |
| `soc_tb` | **19 TB checks + 30 firmware self-checks, 0 errors, final stage 7, 0 Ibex/CRPM assertion failures — PASSED** |
| Fault injection (isolation forced off during SLEEP) | detected by `a_off_state`, `a_deiso_safe` and the TB sequence checker |

## 5. Synthesis and DFT (Genus 21.1, gsclib045 slow 1.0 V)

The course `typical.lib` has no scan `test_cell` models, so it cannot be used for scan replacement.
The script therefore uses the GPDK045 `gsclib045` library, which has them.

| Item | Value |
|---|---|
| Cells / area | 1520 cells, 4990 µm² |
| Timing @ 100 MHz | worst slack +3.8 ns (no violations) |
| ICGs | 2 × `TLATNCAX2` (enable = func_en OR test_mode) |
| DFT rule check | 0 violations, 100 % of registers scannable, 1 test clock domain |
| Scan | 1 muxed-scan chain, 335 flops (`scan_in` → `scan_out`, `scan_en`) |
| Outputs | `syn/out/crpm_top_scan.v`, `.sdc`, `.scandef`, Modus ATPG scripts in `syn/out/atpg` |

### 5.1 ATPG (Modus 23.1, stuck-at, FULLSCAN test mode)

`cd syn ; modus -file modus_atpg.tcl` runs the Genus-generated flow. The wrapper swaps in the gsclib045
Verilog cell models, because Modus cannot build cell models from the Liberty file.

| Item | Value |
|---|---|
| Scan chains | 1 controllable + observable chain (`scan_in` → `scan_out`) |
| Patterns | 132 simulated, 122 effective |
| Test coverage (test mode) | **99.81 %** |
| Global coverage | **99.61 %** |
| Untested faults | 26 |
| Note (power-aware test) | Modus TBM-099: scan-shift switching > 30 % → low-power shift (X-fill, chain segmentation, shift-clock gating) would be the next step |

Patterns and the Verilog test bench are written to `syn/out/atpg/testresults/verilog`.
