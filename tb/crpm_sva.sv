// -----------------------------------------------------------------------------
// crpm_sva.sv  - protocol / safety assertions, bound into crpm_top
// -----------------------------------------------------------------------------
module crpm_sva
  import crpm_pkg::*;
(
  input logic      clk_ref_i,
  input logic      por_ni,
  input logic      test_mode_i,
  input logic      sys_rst_no,
  input logic      periph_rst_no,
  input logic      core_rst_no,
  input logic      pwr_en_o,
  input logic      iso_en_o,
  input logic      ret_save_o,
  input logic      ret_restore_o,
  input logic      pwr_ack_sync,
  input logic      core_tick,
  input logic      periph_tick,
  input logic      pm_deep,
  input logic      reg_req_i,
  input logic      reg_rvalid_o,
  input pm_state_e pm_state
);
  default clocking cb @(posedge clk_ref_i); endclocking
  default disable iff (!por_ni || test_mode_i);

  // ---------------- power sequencing ----------------------------------------
  // Power is only removed from an isolated core that is held in reset
  a_pwroff_safe:   assert property ($fell(pwr_en_o) |-> iso_en_o && !core_rst_no);
  // While the core is unpowered: isolated, in reset, no clock
  a_off_state:     assert property (!pwr_en_o |-> iso_en_o && !core_rst_no && !core_tick);
  // Isolation is removed only from a powered, acknowledged domain
  a_deiso_safe:    assert property ($fell(iso_en_o) |-> pwr_en_o && pwr_ack_sync);
  // Retention save: domain powered, isolated, clock stopped
  a_save_safe:     assert property (ret_save_o |-> pwr_en_o && iso_en_o && !core_tick);
  // Retention restore: power acknowledged, isolated, core still in reset
  a_restore_safe:  assert property (ret_restore_o |-> pwr_en_o && pwr_ack_sync &&
                                                      iso_en_o && !core_rst_no);
  a_save_restore_excl: assert property (!(ret_save_o && ret_restore_o));
  // Core clock is stopped once the PMU has been out of RUN for 3 cycles
  a_no_clk_lp:     assert property (disable iff (!por_ni || test_mode_i || !sys_rst_no)
                                    (!(pm_state inside {PM_RUN, PM_WK_CLKON}))[*3]
                                    |-> !core_tick);
  // Deep sleep gates the peripheral clock as well
  a_deep_pclk:     assert property (disable iff (!por_ni || test_mode_i || !sys_rst_no)
                                    (pm_deep && pm_state == PM_SLEEP)[*3] |-> !periph_tick);

  // ---------------- reset ordering ------------------------------------------
  a_core_after_periph: assert property ($rose(core_rst_no)   |-> periph_rst_no && sys_rst_no);
  a_periph_after_sys:  assert property ($rose(periph_rst_no) |-> sys_rst_no);
  a_core_rst_in_sysrst: assert property (!sys_rst_no |-> !periph_rst_no && !core_rst_no);

  // ---------------- register bus --------------------------------------------
  a_bus_rvalid:    assert property (disable iff (!sys_rst_no || !por_ni || test_mode_i)
                                    (core_tick && reg_req_i) |=> reg_rvalid_o);

  // ---------------- no X after reset ----------------------------------------
  a_no_x: assert property (sys_rst_no |-> !$isunknown({pwr_en_o, iso_en_o, ret_save_o,
                                                       ret_restore_o, core_rst_no,
                                                       periph_rst_no, core_tick}));

  // ---------------- coverage ------------------------------------------------
  c_idle:    cover property (pm_state == PM_RUN ##1 pm_state == PM_IDLE);
  c_sleep:   cover property (pm_state == PM_SLP_PWROFF ##1 pm_state == PM_SLEEP);
  c_wake:    cover property (pm_state == PM_WK_CLKON ##1 pm_state == PM_RUN);
  c_deep:    cover property (pm_deep && pm_state == PM_SLEEP);
endmodule

bind crpm_top crpm_sva u_sva (
  .clk_ref_i    (clk_ref_i),
  .por_ni       (por_ni),
  .test_mode_i  (test_mode_i),
  .sys_rst_no   (sys_rst_no),
  .periph_rst_no(periph_rst_no),
  .core_rst_no  (core_rst_no),
  .pwr_en_o     (pwr_en_o),
  .iso_en_o     (iso_en_o),
  .ret_save_o   (ret_save_o),
  .ret_restore_o(ret_restore_o),
  .pwr_ack_sync (pwr_ack_sync),
  .core_tick    (core_tick),
  .periph_tick  (periph_tick),
  .pm_deep      (pm_deep),
  .reg_req_i    (reg_req_i),
  .reg_rvalid_o (reg_rvalid_o),
  .pm_state     (pm_state)
);
