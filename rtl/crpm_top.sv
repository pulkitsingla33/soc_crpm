// -----------------------------------------------------------------------------
// crpm_top.sv
// Clock, Reset and Power Management controller for a 32-bit RISC-V (Ibex) SoC
//
//   clk_ref_i ──┬──────────────────────────────────────────► aon_clk_o
//               ├─[en_gen core]──►[ICG]────────────────────► core_clk_o
//               └─[en_gen periph]►[ICG]────────────────────► periph_clk_o
//   por_ni ─►[rst_sync]─► reset sequencer ─► sys / periph / core resets
//   PMU FSM ─► clock enables, isolation, retention, power switch, core reset
//
// DFT: test_mode_i forces every ICG transparent (all clocks = clk_ref) and
// makes every functional reset directly controllable from por_ni.
// -----------------------------------------------------------------------------
module crpm_top
  import crpm_pkg::*;
#(
  parameter int RST_HOLD_CYCLES = 16,
  parameter int RST_PERIPH_DLY  = 8,
  parameter int RST_CORE_DLY    = 8,
  parameter int PM_STEP_CYCLES  = 2
) (
  // reference clock / primary resets / test
  input  logic        clk_ref_i,
  input  logic        por_ni,
  input  logic        ext_rst_ni,
  input  logic        test_mode_i,
  // generated clocks
  output logic        aon_clk_o,
  output logic        core_clk_o,
  output logic        periph_clk_o,
  // generated resets (active low)
  output logic        sys_rst_no,
  output logic        periph_rst_no,
  output logic        core_rst_no,
  // register bus (core clock domain)
  input  logic        reg_req_i,
  input  logic        reg_we_i,
  input  logic [3:0]  reg_be_i,
  input  logic [7:0]  reg_addr_i,
  input  logic [31:0] reg_wdata_i,
  output logic        reg_gnt_o,
  output logic        reg_rvalid_o,
  output logic [31:0] reg_rdata_o,
  output logic        reg_err_o,
  // power management
  input  logic        core_sleep_i,
  input  logic [15:0] irq_i,
  input  logic        ext_wake_i,
  input  logic        pwr_ack_i,
  output logic        pwr_en_o,
  output logic        iso_en_o,
  output logic        ret_save_o,
  output logic        ret_restore_o,
  output logic        wake_irq_o,     // level IRQ to core (pending & unmasked wake)
  output logic [3:0]  pm_state_o
);
  // ----------------------------------------------------------- resets
  logic       por_rst_n;
  logic       seq_sys_rst_n, seq_periph_rst_n, seq_core_rst_n;
  logic       sys_rst_n, core_rst_n_q;
  logic       sw_rst_req, wdt_rst_req;
  logic [3:0] cause_clr, rst_cause;
  rst_state_e rst_state;

  crpm_rst_sync u_por_sync (
    .clk_i(clk_ref_i), .rst_ni(por_ni), .test_mode_i(test_mode_i), .rst_no(por_rst_n)
  );

  crpm_rst_ctrl #(
    .HOLD_CYCLES(RST_HOLD_CYCLES), .PERIPH_DLY(RST_PERIPH_DLY), .CORE_DLY(RST_CORE_DLY)
  ) u_rst_ctrl (
    .clk_i        (clk_ref_i),
    .por_rst_ni   (por_rst_n),
    .ext_rst_ni   (ext_rst_ni),
    .sw_rst_req_i (sw_rst_req),
    .wdt_rst_req_i(wdt_rst_req),
    .cause_clr_i  (cause_clr),
    .sys_rst_no   (seq_sys_rst_n),
    .periph_rst_no(seq_periph_rst_n),
    .core_rst_no  (seq_core_rst_n),
    .rst_cause_o  (rst_cause),
    .state_o      (rst_state)
  );

  // Reset outputs are flop-generated -> bypass with the primary reset pin in
  // test mode so the scan tool can control every asynchronous reset.
  assign sys_rst_n     = test_mode_i ? por_ni : seq_sys_rst_n;
  assign sys_rst_no    = sys_rst_n;
  assign periph_rst_no = test_mode_i ? por_ni : seq_periph_rst_n;

  // ----------------------------------------------------------- PMU
  logic        core_tick, periph_tick;
  logic        pm_core_clk_en, pm_periph_clk_en, pm_core_rst_hold, lp_clr;
  logic        pwr_ack_sync, ext_wake_sync, wake;
  logic        pm_deep;
  pm_state_e   pm_state;
  lp_mode_e    lp_mode;
  logic [15:0] idle_cnt, sleep_cnt;

  crpm_sync #(.RESET_VAL(1'b0)) u_ack_sync (
    .clk_i(clk_ref_i), .rst_ni(sys_rst_n), .d_i(pwr_ack_i), .q_o(pwr_ack_sync)
  );
  crpm_sync #(.RESET_VAL(1'b0)) u_wake_sync (
    .clk_i(clk_ref_i), .rst_ni(sys_rst_n), .d_i(ext_wake_i), .q_o(ext_wake_sync)
  );

  crpm_pmu #(.STEP_CYCLES(PM_STEP_CYCLES)) u_pmu (
    .clk_i          (clk_ref_i),
    .rst_ni         (sys_rst_n),
    .core_tick_i    (core_tick),
    .core_sleep_i   (core_sleep_i),
    .lp_mode_i      (lp_mode),
    .wake_i         (wake),
    .pwr_ack_i      (pwr_ack_sync),
    .core_clk_en_o  (pm_core_clk_en),
    .periph_clk_en_o(pm_periph_clk_en),
    .iso_en_o       (iso_en_o),
    .ret_save_o     (ret_save_o),
    .ret_restore_o  (ret_restore_o),
    .pwr_en_o       (pwr_en_o),
    .core_rst_hold_o(pm_core_rst_hold),
    .lp_clr_o       (lp_clr),
    .state_o        (pm_state),
    .deep_o         (pm_deep),
    .idle_cnt_o     (idle_cnt),
    .sleep_cnt_o    (sleep_cnt)
  );

  // Core reset = sequencer release AND PMU release (registered)
  always_ff @(posedge clk_ref_i or negedge sys_rst_n) begin
    if (!sys_rst_n) core_rst_n_q <= 1'b0;
    else            core_rst_n_q <= seq_core_rst_n & ~pm_core_rst_hold;
  end
  assign core_rst_no = test_mode_i ? por_ni : core_rst_n_q;

  // ----------------------------------------------------------- registers
  logic [1:0] core_div_sel, periph_div_sel, core_div_act, periph_div_act;
  logic       sw_core_clk_en, sw_periph_clk_en;

  crpm_regs u_regs (
    .clk_i           (clk_ref_i),
    .rst_ni          (sys_rst_n),
    .por_rst_ni      (por_rst_n),        // already bypassed in test mode
    .core_tick_i     (core_tick),
    .req_i           (reg_req_i),
    .we_i            (reg_we_i),
    .be_i            (reg_be_i),
    .addr_i          (reg_addr_i),
    .wdata_i         (reg_wdata_i),
    .gnt_o           (reg_gnt_o),
    .rvalid_o        (reg_rvalid_o),
    .rdata_o         (reg_rdata_o),
    .err_o           (reg_err_o),
    .core_div_sel_o  (core_div_sel),
    .periph_div_sel_o(periph_div_sel),
    .core_clk_en_o   (sw_core_clk_en),
    .periph_clk_en_o (sw_periph_clk_en),
    .lp_mode_o       (lp_mode),
    .sw_rst_req_o    (sw_rst_req),
    .cause_clr_o     (cause_clr),
    .wdt_rst_req_o   (wdt_rst_req),
    .irq_i           (irq_i),
    .ext_wake_i      (ext_wake_sync),
    .wake_o          (wake),
    .irq_o           (wake_irq_o),
    .rst_cause_i     (rst_cause),
    .pm_state_i      (pm_state),
    .pm_deep_i       (pm_deep),
    .pwr_ack_i       (pwr_ack_sync),
    .iso_en_i        (iso_en_o),
    .lp_clr_i        (lp_clr),
    .idle_cnt_i      (idle_cnt),
    .sleep_cnt_i     (sleep_cnt),
    .core_div_act_i  (core_div_act),
    .periph_div_act_i(periph_div_act)
  );

  // ----------------------------------------------------------- clocks
  // core_tick / periph_tick are the ICG enables; they are also used inside
  // the CRPM as "a derived clock edge occurs at the end of this cycle".
  crpm_clk_en_gen u_core_en (
    .clk_i    (clk_ref_i),
    .rst_ni   (sys_rst_n),
    .div_sel_i(core_div_sel),
    .gate_en_i(sw_core_clk_en & pm_core_clk_en),
    .en_o     (core_tick),
    .div_sel_o(core_div_act)
  );

  crpm_clk_en_gen u_periph_en (
    .clk_i    (clk_ref_i),
    .rst_ni   (sys_rst_n),
    .div_sel_i(periph_div_sel),
    .gate_en_i(sw_periph_clk_en & pm_periph_clk_en),
    .en_o     (periph_tick),
    .div_sel_o(periph_div_act)
  );

  crpm_clk_gate u_core_icg (
    .clk_i(clk_ref_i), .en_i(core_tick), .test_en_i(test_mode_i), .clk_o(core_clk_o)
  );

  crpm_clk_gate u_periph_icg (
    .clk_i(clk_ref_i), .en_i(periph_tick), .test_en_i(test_mode_i), .clk_o(periph_clk_o)
  );

  assign aon_clk_o  = clk_ref_i;
  assign pm_state_o = pm_state;
endmodule
