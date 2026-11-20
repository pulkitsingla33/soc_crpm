// -----------------------------------------------------------------------------
// crpm_pmu.sv
// Power-management unit FSM (always-on domain, clocked by clk_ref)
//
// The core requests a low-power state by programming PM_CTRL.lp_mode and then
// executing WFI (Ibex raises core_sleep_o). The PMU then performs:
//
//   IDLE  : gate the core clock; any enabled wake event ungates it.
//   SLEEP : clock off -> isolate -> retention save -> core reset ->
//           power switch off (wait ack=0) -> SLEEP
//           wake: power on (wait ack=1) -> restore -> release reset ->
//           remove isolation -> clock on -> RUN
//   DEEP  : as SLEEP, and the peripheral clock is also gated.
//
// Every step dwells for at least STEP_CYCLES reference cycles so that
// isolation / retention controls settle before the next control changes.
// All control outputs are registered (glitch-free) since they drive power
// switches, isolation cells and retention flops.
// Out of reset the PMU starts in WK_PWRON so the core domain is powered up
// through the same handshake as a wake from SLEEP (without the restore).
// -----------------------------------------------------------------------------
module crpm_pmu
  import crpm_pkg::*;
#(
  parameter int STEP_CYCLES = 2
) (
  input  logic        clk_i,
  input  logic        rst_ni,          // sys reset
  input  logic        core_tick_i,     // a core clock edge happens this cycle
  input  logic        core_sleep_i,    // Ibex core_sleep_o (core domain)
  input  lp_mode_e    lp_mode_i,
  input  logic        wake_i,          // masked wake event (level)
  input  logic        pwr_ack_i,       // synchronised power-switch ack
  output logic        core_clk_en_o,
  output logic        periph_clk_en_o,
  output logic        iso_en_o,
  output logic        ret_save_o,
  output logic        ret_restore_o,
  output logic        pwr_en_o,
  output logic        core_rst_hold_o,
  output logic        lp_clr_o,        // one-shot: clear PM_CTRL.lp_mode
  output pm_state_e   state_o,
  output logic        deep_o,
  output logic [15:0] idle_cnt_o,
  output logic [15:0] sleep_cnt_o
);
  pm_state_e  state_q, state_d;
  logic [3:0] step_q;
  logic       step_done;
  logic       armed_q;
  logic       deep_q, deep_d;
  logic       from_sleep_q, from_sleep_d;
  logic       sleep_req;

  assign step_done = (step_q >= 4'(STEP_CYCLES-1));
  // Only accept a new request once the core has been seen awake (core_sleep_o
  // stays high for a few cycles after a wake-up until the core resumes).
  assign sleep_req = core_tick_i & armed_q & core_sleep_i;

  always_comb begin
    state_d      = state_q;
    deep_d       = deep_q;
    from_sleep_d = from_sleep_q;
    case (state_q)
      PM_RUN: begin
        if (sleep_req) begin
          case (lp_mode_i)
            LP_IDLE:  state_d = PM_IDLE;
            LP_SLEEP: begin state_d = PM_SLP_CLKOFF; deep_d = 1'b0; end
            LP_DEEP:  begin state_d = PM_SLP_CLKOFF; deep_d = 1'b1; end
            default:  state_d = PM_RUN;
          endcase
        end
      end
      PM_IDLE:       if (wake_i)                 state_d = PM_RUN;
      PM_SLP_CLKOFF: if (step_done)              state_d = PM_SLP_ISO;
      PM_SLP_ISO:    if (step_done)              state_d = PM_SLP_SAVE;
      PM_SLP_SAVE:   if (step_done)              state_d = PM_SLP_RST;
      PM_SLP_RST:    if (step_done)              state_d = PM_SLP_PWROFF;
      PM_SLP_PWROFF: if (step_done && !pwr_ack_i) begin
                       state_d      = PM_SLEEP;
                       from_sleep_d = 1'b1;
                     end
      PM_SLEEP:      if (wake_i)                 state_d = PM_WK_PWRON;
      PM_WK_PWRON:   if (step_done && pwr_ack_i)
                       state_d = from_sleep_q ? PM_WK_RESTORE : PM_WK_RSTREL;
      PM_WK_RESTORE: if (step_done)              state_d = PM_WK_RSTREL;
      PM_WK_RSTREL:  if (step_done)              state_d = PM_WK_DEISO;
      PM_WK_DEISO:   if (step_done)              state_d = PM_WK_CLKON;
      PM_WK_CLKON:   if (step_done) begin
                       state_d      = PM_RUN;
                       deep_d       = 1'b0;
                       from_sleep_d = 1'b0;
                     end
      default:                                   state_d = PM_RUN;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q         <= PM_WK_PWRON;
      step_q          <= '0;
      armed_q         <= 1'b0;
      deep_q          <= 1'b0;
      from_sleep_q    <= 1'b0;
      core_clk_en_o   <= 1'b0;
      periph_clk_en_o <= 1'b1;
      iso_en_o        <= 1'b1;
      ret_save_o      <= 1'b0;
      ret_restore_o   <= 1'b0;
      pwr_en_o        <= 1'b1;
      core_rst_hold_o <= 1'b1;
      lp_clr_o        <= 1'b0;
      idle_cnt_o      <= '0;
      sleep_cnt_o     <= '0;
    end else begin
      state_q      <= state_d;
      deep_q       <= deep_d;
      from_sleep_q <= from_sleep_d;
      step_q       <= (state_d != state_q) ? '0 :
                      (step_done ? step_q : step_q + 1'b1);

      if (state_d != PM_RUN)                       armed_q <= 1'b0;
      else if (core_tick_i && !core_sleep_i)       armed_q <= 1'b1;

      // ---- registered Moore outputs, decoded from the next state --------
      core_clk_en_o   <= (state_d == PM_RUN) || (state_d == PM_WK_CLKON);
      periph_clk_en_o <= !(deep_d && (state_d inside {PM_SLP_PWROFF, PM_SLEEP}));
      iso_en_o        <= (state_d inside {PM_SLP_ISO, PM_SLP_SAVE, PM_SLP_RST,
                                          PM_SLP_PWROFF, PM_SLEEP, PM_WK_PWRON,
                                          PM_WK_RESTORE, PM_WK_RSTREL});
      ret_save_o      <= (state_d == PM_SLP_SAVE);
      ret_restore_o   <= (state_d == PM_WK_RESTORE);
      pwr_en_o        <= !(state_d inside {PM_SLP_PWROFF, PM_SLEEP});
      core_rst_hold_o <= (state_d inside {PM_SLP_RST, PM_SLP_PWROFF, PM_SLEEP,
                                          PM_WK_PWRON, PM_WK_RESTORE});
      lp_clr_o        <= (state_q == PM_RUN) && (state_d != PM_RUN);

      if (state_q == PM_RUN && state_d == PM_IDLE)       idle_cnt_o  <= idle_cnt_o  + 1'b1;
      if (state_q == PM_RUN && state_d == PM_SLP_CLKOFF) sleep_cnt_o <= sleep_cnt_o + 1'b1;
    end
  end

  assign state_o = state_q;
  assign deep_o  = deep_q;
endmodule
