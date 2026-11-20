// -----------------------------------------------------------------------------
// soc_tb.sv - SoC-level testbench: Ibex + CRPM running crpm_test.S
//
//  * generates the 100 MHz reference clock and the power-on reset
//  * models the PD_CORE power switch
//  * provides a simulation-control slave on the external bus (0x2000_0000)
//      +0x00 END   : 1 = PASS, anything else = FAIL code
//      +0x04 STAGE : progress marker
//      +0x08 REQ   : 1 = pulse ext_wake, 2 = pulse ext_rst_n, 3 = pulse irq0
//      +0x0C CHKDIV: firmware changed the core divider -> measure period
//      +0x10 LOG   : print a value
//      +0x14 CHKPDIV: firmware changed the peripheral divider -> measure
//  * independent checkers: clock-period measurement, no core clock while in
//    a low-power state, isolation hides the unpowered domain, peripheral
//    logic frozen in DEEP sleep, reset release ordering.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module soc_tb;
  import crpm_pkg::*;

  localparam realtime TCLK = 10ns;

  logic        clk_ref = 1'b0;
  logic        por_n, ext_rst_n, test_mode, ext_wake;
  logic [15:0] ext_irq;
  logic        pwr_en, pwr_ack;
  logic        ext_req, ext_we, ext_rvalid;
  logic [3:0]  ext_be;
  logic [31:0] ext_addr, ext_wdata, ext_rdata;
  logic        core_clk, periph_clk, sys_rst_n, periph_rst_n, core_rst_n;
  logic [3:0]  pm_state;

  int unsigned errors = 0;
  int unsigned checks = 0;
  int unsigned stage  = 0;
  int unsigned core_clk_edges_in_lp = 0;

  always #(TCLK/2) clk_ref = ~clk_ref;

  soc_top dut (
    .clk_ref_i     (clk_ref),
    .por_ni        (por_n),
    .ext_rst_ni    (ext_rst_n),
    .test_mode_i   (test_mode),
    .ext_wake_i    (ext_wake),
    .ext_irq_i     (ext_irq),
    .core_pwr_en_o (pwr_en),
    .core_pwr_ack_i(pwr_ack),
    .ext_req_o     (ext_req),
    .ext_we_o      (ext_we),
    .ext_be_o      (ext_be),
    .ext_addr_o    (ext_addr),
    .ext_wdata_o   (ext_wdata),
    .ext_rvalid_i  (ext_rvalid),
    .ext_rdata_i   (ext_rdata),
    .core_clk_o    (core_clk),
    .periph_clk_o  (periph_clk),
    .sys_rst_no    (sys_rst_n),
    .periph_rst_no (periph_rst_n),
    .core_rst_no   (core_rst_n),
    .pm_state_o    (pm_state)
  );

  pwr_switch_model u_psw (.en_i(pwr_en), .ack_o(pwr_ack));

  // ------------------------------------------------------------ utilities
  function automatic string pm_name(input logic [3:0] s);
    pm_state_e e = pm_state_e'(s);
    return e.name();
  endfunction

  task automatic check(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $display("[%0t] TB_ERROR: %s", $time, msg);
    end else begin
      $display("[%0t] TB_CHECK ok : %s", $time, msg);
    end
  endtask

  // measure one period of the core / peripheral clock
  task automatic core_period(output realtime p);
    realtime t0;
    @(posedge core_clk); t0 = $realtime;
    @(posedge core_clk); p  = $realtime - t0;
  endtask
  task automatic periph_period(output realtime p);
    realtime t0;
    @(posedge periph_clk); t0 = $realtime;
    @(posedge periph_clk); p  = $realtime - t0;
  endtask

  // --------------------------------------------- simulation control slave
  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      ext_rvalid <= 1'b0;
      ext_rdata  <= '0;
    end else begin
      ext_rvalid <= ext_req;
      ext_rdata  <= ext_req && !ext_we && ext_addr[7:0] == 8'h04 ? stage : '0;
      if (ext_req && ext_we) handle_write(ext_addr[7:0], ext_wdata);
    end
  end

  task automatic handle_write(input logic [7:0] a, input logic [31:0] d);
    case (a)
      8'h00: begin
        if (d == 1) begin
          $display("[%0t] FW reported PASS", $time);
          fork finish_test(); join_none
        end else begin
          errors++;
          $display("[%0t] TB_ERROR: firmware FAIL code 0x%0h (stage %0d)", $time, d, stage);
          fork finish_test(); join_none
        end
      end
      8'h04: begin
        stage = d;
        $display("[%0t] ---------------- FW stage %0d ----------------", $time, d);
      end
      8'h08: fork tb_request(d); join_none
      8'h0C: if (d != 0) fork check_core_div(d[1:0]); join_none
      8'h10: $display("[%0t] FW LOG: 0x%08h", $time, d);
      8'h14: if (d != 0) fork check_periph_div(d[1:0]); join_none
      default: ;
    endcase
  endtask

  task automatic check_core_div(input logic [1:0] div);
    realtime p;
    // new ratio is taken at the end of the current divided period
    repeat (3) @(posedge core_clk);
    core_period(p);
    check(p == TCLK * (1 << div),
          $sformatf("core clock /%0d : period %0t (expected %0t)", 1 << div, p, TCLK * (1 << div)));
  endtask

  task automatic check_periph_div(input logic [1:0] div);
    realtime p;
    repeat (3) @(posedge periph_clk);
    periph_period(p);
    check(p == TCLK * (1 << div),
          $sformatf("periph clock /%0d : period %0t (expected %0t)", 1 << div, p, TCLK * (1 << div)));
  endtask

  task automatic tb_request(input logic [31:0] req);
    case (req)
      1: begin   // DEEP-sleep wake via external pin
        wait (pm_state == PM_SLEEP);
        $display("[%0t] TB: core domain is OFF (DEEP), waiting before ext wake", $time);
        check_deep_frozen();
        ext_wake = 1'b1;
        #(5*TCLK);
        ext_wake = 1'b0;
      end
      2: begin   // external reset pin
        #(50*TCLK);
        $display("[%0t] TB: pulsing ext_rst_n", $time);
        ext_rst_n = 1'b0;
        #(30*TCLK);
        ext_rst_n = 1'b1;
      end
      3: begin   // external interrupt line 0 while IDLE
        wait (pm_state == PM_IDLE);
        #(40*TCLK);
        check(core_clk_edges_in_lp == 0, "no core clock edge while IDLE");
        $display("[%0t] TB: pulsing ext_irq[0]", $time);
        ext_irq[0] = 1'b1;
        #(3*TCLK);
        ext_irq[0] = 1'b0;
      end
      default: ;
    endcase
  endtask

  // DEEP sleep: the peripheral domain is frozen and the masked wake timer
  // must not have woken the PMU
  task automatic check_deep_frozen();
    logic [31:0] c0;
    #(20*TCLK);
    c0 = dut.periph_cnt_q;
    #(400*TCLK);
    check(dut.periph_cnt_q == c0, "peripheral domain frozen in DEEP sleep");
    check(pm_state == PM_SLEEP, "masked wake-up timer did not wake the SoC");
    check(!pwr_ack, "core domain power switch is OFF in DEEP sleep");
  endtask

  // ---------------------------------------------------- global checkers
  // 1) no core clock edge while the PMU has been in a low-power state
  pm_state_e   pm_q1, pm_q2;
  always @(posedge clk_ref) begin pm_q2 <= pm_q1; pm_q1 <= pm_state_e'(pm_state); end
  always @(posedge core_clk) begin
    if (pm_state_e'(pm_state) inside {PM_IDLE, PM_SLEEP} &&
        pm_q2 inside {PM_IDLE, PM_SLEEP} && !test_mode) begin
      core_clk_edges_in_lp++;
      errors++;
      $display("[%0t] TB_ERROR: core clock edge in low-power state %s", $time, pm_name(pm_state));
    end
  end
  always @(pm_state) if (!(pm_state_e'(pm_state) inside {PM_IDLE, PM_SLEEP})) core_clk_edges_in_lp = 0;

  // 2) isolation: an unpowered core must never leak X / requests to the bus
  always @(posedge clk_ref) begin
    if (sys_rst_n && !pwr_ack) begin
      if ($isunknown({dut.d_req, dut.i_req, dut.u_core_pd.core_sleep_o}) ||
          dut.d_req || dut.i_req) begin
        errors++;
        $display("[%0t] TB_ERROR: unpowered core leaks through isolation", $time);
      end
    end
  end
  // the X model really is active while the domain is off
  logic saw_x_behind_iso = 1'b0;
  always @(posedge clk_ref) if (!pwr_ack && $isunknown(dut.u_core_pd.raw_data_req_o)) saw_x_behind_iso = 1'b1;

  // 3) PMU state trace
  always @(pm_state) $display("[%0t] PMU -> %s", $time, pm_name(pm_state));

  // 4) reset release ordering on every reset
  realtime t_sys, t_per, t_core;
  always @(posedge sys_rst_n)    t_sys = $realtime;
  always @(posedge periph_rst_n) begin
    t_per = $realtime;
    check(sys_rst_n && (t_per - t_sys) >= 8*TCLK, "periph reset released >= 8 cycles after sys reset");
  end
  always @(posedge core_rst_n) begin
    t_core = $realtime;
    if (pm_state_e'(pm_state) != PM_WK_RSTREL)
      check(periph_rst_n && (t_core - t_per) >= 8*TCLK, "core reset released >= 8 cycles after periph reset");
    else
      check(periph_rst_n && pwr_ack, "core reset released after power-up (wake)");
  end

  // ------------------------------------------------------------- stimulus
  bit finishing = 1'b0;
  task automatic finish_test();
    if (finishing) return;
    finishing = 1'b1;
    #(20*TCLK);
    check(saw_x_behind_iso, "power-down X model observed behind isolation cells");
    $display("");
    $display("==================================================================");
    $display(" SoC CRPM test : %0d checks, %0d errors, final FW stage %0d", checks, errors, stage);
    $display(" LP_STATS: idle entries=%0d sleep entries=%0d",
             dut.u_crpm.idle_cnt, dut.u_crpm.sleep_cnt);
    if (errors == 0) $display(" RESULT: *** TEST PASSED ***");
    else             $display(" RESULT: *** TEST FAILED ***");
    $display("==================================================================");
    $finish;
  endtask

  initial begin
    if ($test$plusargs("WAVES")) begin
      $shm_open("waves_soc.shm");
      $shm_probe(soc_tb, "AS");
    end
    por_n     = 1'b0;
    ext_rst_n = 1'b1;
    test_mode = 1'b0;
    ext_wake  = 1'b0;
    ext_irq   = '0;
    #(10*TCLK + 3ns);
    por_n = 1'b1;
    $display("[%0t] TB: POR released", $time);
  end

  // global timeout
  initial begin
    #(2ms);
    errors++;
    $display("[%0t] TB_ERROR: TIMEOUT in FW stage %0d (PMU %s)", $time, stage, pm_name(pm_state));
    finish_test();
  end
endmodule
