// -----------------------------------------------------------------------------
// crpm_tb.sv - block-level testbench for crpm_top
//
// The core is replaced by a bus-functional model (register bus in the core
// clock domain) and a WFI / core_sleep model. Tests:
//   T1  power-on reset sequence (ordering + timing)
//   T2  register reset values, RW, ID, byte enables, bad-address error
//   T3  clock divider: all ratios on both domains, period measurement
//   T4  random on-the-fly divider changes (glitch / pulse-width checker)
//   T5  software clock enables
//   T6  IDLE entry / wake by timer, wake masking
//   T7  SLEEP power-down / power-up sequence (event order) + slow switch
//   T8  DEEP sleep: peripheral clock gated, ext wake pin
//   T9  software reset (bad key / good key) + reset cause
//   T10 watchdog: kick, pause in low power, expiry
//   T11 external reset pin (held low -> held in reset)
//   T12 DFT test mode: clocks ungated, resets controlled by por_n
// SVA from crpm_sva.sv are bound into the DUT.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module crpm_tb;
  import crpm_pkg::*;

  localparam realtime TCLK = 10ns;
  localparam logic [31:0] KEY = WDT_KEY;

  // ------------------------------------------------------------- DUT I/O
  logic        clk_ref = 1'b0;
  logic        por_n, ext_rst_n, test_mode;
  logic        aon_clk, core_clk, periph_clk;
  logic        sys_rst_n, periph_rst_n, core_rst_n;
  logic        req, we, gnt, rvalid, err;
  logic [3:0]  be;
  logic [7:0]  addr;
  logic [31:0] wdata, rdata;
  logic        core_sleep;
  logic [15:0] irq;
  logic        ext_wake, pwr_en, pwr_ack, iso_en, ret_save, ret_restore, wake_irq;
  logic [3:0]  pm_state;

  int unsigned errors = 0, checks = 0;
  string       cur_test = "";

  always #(TCLK/2) clk_ref = ~clk_ref;

  crpm_top dut (
    .clk_ref_i    (clk_ref),
    .por_ni       (por_n),
    .ext_rst_ni   (ext_rst_n),
    .test_mode_i  (test_mode),
    .aon_clk_o    (aon_clk),
    .core_clk_o   (core_clk),
    .periph_clk_o (periph_clk),
    .sys_rst_no   (sys_rst_n),
    .periph_rst_no(periph_rst_n),
    .core_rst_no  (core_rst_n),
    .reg_req_i    (req),
    .reg_we_i     (we),
    .reg_be_i     (be),
    .reg_addr_i   (addr),
    .reg_wdata_i  (wdata),
    .reg_gnt_o    (gnt),
    .reg_rvalid_o (rvalid),
    .reg_rdata_o  (rdata),
    .reg_err_o    (err),
    .core_sleep_i (core_sleep),
    .irq_i        (irq),
    .ext_wake_i   (ext_wake),
    .pwr_ack_i    (pwr_ack),
    .pwr_en_o     (pwr_en),
    .iso_en_o     (iso_en),
    .ret_save_o   (ret_save),
    .ret_restore_o(ret_restore),
    .wake_irq_o   (wake_irq),
    .pm_state_o   (pm_state)
  );

  // power switch with programmable ramp
  realtime t_on = 100ns, t_off = 60ns;
  initial pwr_ack = 1'b0;
  always @(pwr_en) begin
    if (pwr_en === 1'b1) begin #(t_on);  if (pwr_en === 1'b1) pwr_ack = 1'b1; end
    else                 begin #(t_off); if (pwr_en !== 1'b1) pwr_ack = 1'b0; end
  end

  // ----------------------------------------------------------- core model
  // core_sleep: high while in reset (like Ibex) or after WFI until the core
  // sees the wake interrupt on a running clock.
  logic wfi_q;
  bit   wfi_req = 1'b0;
  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n)            wfi_q <= 1'b0;
    else if (wfi_req)           wfi_q <= 1'b1;
    else if (wfi_q && wake_irq) wfi_q <= 1'b0;
  end
  assign core_sleep = !core_rst_n || wfi_q;

  task automatic do_wfi();
    @(posedge core_clk); #1;
    wfi_req = 1'b1;
    @(posedge core_clk); #1;
    wfi_req = 1'b0;
  endtask

  // ------------------------------------------------------------ utilities
  task automatic check(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $display("[%0t] ERROR [%s] %s", $time, cur_test, msg);
    end
  endtask

  task automatic start_test(input string name);
    cur_test = name;
    $display("[%0t] ==== %s", $time, name);
  endtask

  // register bus BFM (core clock domain, Ibex LSU timing)
  task automatic bus_write(input logic [7:0] a, input logic [31:0] d, input logic [3:0] b = 4'hF);
    @(posedge core_clk); #1;
    req = 1'b1; we = 1'b1; addr = a; wdata = d; be = b;
    @(posedge core_clk); #1;
    check(rvalid, $sformatf("write 0x%02h: rvalid one core cycle after grant", a));
    req = 1'b0; we = 1'b0;
  endtask

  task automatic bus_read(input logic [7:0] a, output logic [31:0] d);
    logic e;
    @(posedge core_clk); #1;
    req = 1'b1; we = 1'b0; addr = a; be = 4'hF;
    @(posedge core_clk); #1;
    check(rvalid, $sformatf("read 0x%02h: rvalid one core cycle after grant", a));
    d = rdata; e = err;
    req = 1'b0;
  endtask

  task automatic read_check(input logic [7:0] a, input logic [31:0] exp,
                            input logic [31:0] mask = '1, input string what = "");
    logic [31:0] d;
    bus_read(a, d);
    check((d & mask) == (exp & mask),
          $sformatf("%s reg 0x%02h = 0x%08h, expected 0x%08h (mask 0x%08h)", what, a, d, exp, mask));
  endtask

  task automatic wait_pm(input pm_state_e s, input int max_cycles = 5000);
    int n = 0;
    while (pm_state_e'(pm_state) != s && n < max_cycles) begin
      @(posedge clk_ref); n++;
    end
    check(pm_state_e'(pm_state) == s, $sformatf("PMU reached %s", s.name()));
  endtask

  task automatic measure(input bit periph, output realtime p);
    realtime t0;
    if (!periph) begin @(posedge core_clk);   t0 = $realtime; @(posedge core_clk);   end
    else         begin @(posedge periph_clk); t0 = $realtime; @(posedge periph_clk); end
    p = $realtime - t0;
  endtask

  task automatic count_edges(input bit periph, input int cycles, output int n);
    n = 0;
    fork
      begin : cnt
        forever begin
          if (!periph) @(posedge core_clk); else @(posedge periph_clk);
          n++;
        end
      end
      begin #(cycles*TCLK); disable cnt; end
    join
  endtask

  task automatic wait_core_up();
    #1;  // let an asynchronous reset that was just triggered propagate
    wait (core_rst_n === 1'b1 && pm_state_e'(pm_state) == PM_RUN);
    repeat (4) @(posedge core_clk);
  endtask

  // ----------------------------------------------- clock pulse checkers
  // every high and low phase of a derived clock must be >= half a ref period
  realtime c_rise, c_fall, p_rise, p_fall;
  int unsigned glitches = 0;
  always @(posedge core_clk)   begin c_rise = $realtime;
    if (c_fall > 0 && $realtime - c_fall < TCLK/2 - 0.01) begin glitches++; errors++;
      $display("[%0t] ERROR core_clk short low phase", $time); end end
  always @(negedge core_clk)   begin c_fall = $realtime;
    if (c_rise > 0 && $realtime - c_rise < TCLK/2 - 0.01) begin glitches++; errors++;
      $display("[%0t] ERROR core_clk short high phase", $time); end end
  always @(posedge periph_clk) begin p_rise = $realtime;
    if (p_fall > 0 && $realtime - p_fall < TCLK/2 - 0.01) begin glitches++; errors++;
      $display("[%0t] ERROR periph_clk short low phase", $time); end end
  always @(negedge periph_clk) begin p_fall = $realtime;
    if (p_rise > 0 && $realtime - p_rise < TCLK/2 - 0.01) begin glitches++; errors++;
      $display("[%0t] ERROR periph_clk short high phase", $time); end end

  // ------------------------------------------- power-sequence event log
  string ev_log[$];
  bit    log_en = 1'b0;
  always @(posedge iso_en)       if (log_en) ev_log.push_back("ISO_ON");
  always @(negedge iso_en)       if (log_en) ev_log.push_back("ISO_OFF");
  always @(posedge ret_save)     if (log_en) ev_log.push_back("SAVE");
  always @(posedge ret_restore)  if (log_en) ev_log.push_back("RESTORE");
  always @(negedge core_rst_n)   if (log_en) ev_log.push_back("RST_ON");
  always @(posedge core_rst_n)   if (log_en) ev_log.push_back("RST_OFF");
  always @(negedge pwr_en)       if (log_en) ev_log.push_back("PWR_OFF");
  always @(posedge pwr_en)       if (log_en) ev_log.push_back("PWR_ON");
  always @(negedge pwr_ack)      if (log_en) ev_log.push_back("ACK_OFF");
  always @(posedge pwr_ack)      if (log_en) ev_log.push_back("ACK_ON");
  always @(negedge dut.core_tick) if (log_en) ev_log.push_back("CLK_OFF");
  always @(posedge dut.core_tick) if (log_en) ev_log.push_back("CLK_ON");

  // time spent waiting for the power-switch acknowledge
  realtime t_pwron_in, t_pwron_out;
  always @(pm_state) begin
    if (pm_state_e'(pm_state) == PM_WK_PWRON) t_pwron_in  = $realtime;
    else if (t_pwron_in > t_pwron_out)        t_pwron_out = $realtime;
  end

  function automatic string join_q(string q[$]);
    string s = "";
    foreach (q[i]) s = {s, (i ? " " : ""), q[i]};
    return s;
  endfunction

  // ================================================================ tests
  realtime t_por, t_sys, t_per, t_core;
  always @(posedge sys_rst_n)    t_sys  = $realtime;
  always @(posedge periph_rst_n) t_per  = $realtime;
  always @(posedge core_rst_n)   t_core = $realtime;

  task automatic t1_por();
    start_test("T1 power-on reset sequence");
    por_n = 1'b0;
    #(7*TCLK);
    check(!sys_rst_n && !periph_rst_n && !core_rst_n, "all resets asserted during POR");
    @(negedge clk_ref); por_n = 1'b1; t_por = $realtime;
    wait (core_rst_n === 1'b1);
    $display("    sys released  %0.0f cycles after POR", (t_sys - t_por) / TCLK);
    $display("    periph        %0.0f cycles after sys",  (t_per - t_sys) / TCLK);
    $display("    core          %0.0f cycles after periph", (t_core - t_per) / TCLK);
    check(t_sys > t_por && t_per > t_sys && t_core > t_per, "release order sys -> periph -> core");
    check((t_sys - t_por) >= 16*TCLK, "sys reset held >= HOLD_CYCLES");
    check((t_per - t_sys) == 8*TCLK,  "periph released PERIPH_DLY after sys");
    check((t_core - t_per) >= 8*TCLK, "core released >= CORE_DLY after periph");
    check(pwr_ack && !iso_en, "core domain powered and de-isolated after boot");
    wait_core_up();
  endtask

  task automatic t2_regs();
    logic [31:0] d;
    start_test("T2 registers");
    read_check(REG_ID,        CRPM_ID,       '1, "ID");
    read_check(REG_CLK_CTRL,  32'h0000_0300, '1, "CLK_CTRL reset");
    read_check(REG_RST_CAUSE, 32'h1,         '1, "RST_CAUSE after POR");
    read_check(REG_PM_CTRL,   32'h0,         '1, "PM_CTRL reset");
    read_check(REG_PM_STATUS, 32'h100,       '1, "PM_STATUS (RUN, ack)");
    read_check(REG_WAKE_MASK, 32'h3_FFFF,    '1, "WAKE_MASK reset");
    read_check(REG_WDT_CTRL,  32'h0,         '1, "WDT_CTRL reset");
    read_check(REG_WDT_LOAD,  32'h0000_FFFF, '1, "WDT_LOAD reset");
    read_check(REG_LP_STATS,  32'h0,         '1, "LP_STATS reset");
    read_check(REG_SCRATCH0,  32'h0,         '1, "SCRATCH0 reset");
    // RW + byte enables
    bus_write(REG_SCRATCH0, 32'hDEAD_BEEF);
    read_check(REG_SCRATCH0, 32'hDEAD_BEEF, '1, "SCRATCH0 rw");
    bus_write(REG_SCRATCH0, 32'h1122_3344, 4'b0101);
    read_check(REG_SCRATCH0, 32'hDE22_BE44, '1, "SCRATCH0 byte enables");
    bus_write(REG_CLK_CTRL, 32'hFFFF_FFFF);
    read_check(REG_CLK_CTRL, 32'h0000_0333, 32'h0000_FFFF, "CLK_CTRL writable bits");
    bus_write(REG_CLK_CTRL, 32'h0000_0300);
    bus_write(REG_RST_CAUSE, 32'h1);
    read_check(REG_RST_CAUSE, 32'h0, '1, "RST_CAUSE W1C");
    // unmapped address -> error response
    @(posedge core_clk); #1; req = 1; we = 0; addr = 8'hF0;
    @(posedge core_clk); #1;
    check(rvalid && err, "unmapped register returns bus error");
    req = 0;
    bus_read(REG_ID, d);
    check(!err, "error flag clears on next access");
  endtask

  task automatic t3_div();
    realtime p;
    start_test("T3 clock dividers");
    for (int c = 0; c < 4; c++) begin
      for (int pd = 0; pd < 4; pd += 3) begin
        bus_write(REG_CLK_CTRL, 32'h300 | (pd << 4) | c);
        repeat (3) @(posedge core_clk);
        measure(0, p);
        check(p == TCLK * (1 << c), $sformatf("core /%0d period = %0t", 1 << c, p));
        repeat (2) @(posedge periph_clk);
        measure(1, p);
        check(p == TCLK * (1 << pd), $sformatf("periph /%0d period = %0t", 1 << pd, p));
        read_check(REG_CLK_CTRL, (c << 16) | (pd << 20), 32'h0033_0000, "active ratio");
      end
    end
    bus_write(REG_CLK_CTRL, 32'h300);
  endtask

  task automatic t4_rand_div();
    int unsigned g0 = glitches;
    start_test("T4 random divider changes (glitch check)");
    repeat (60) begin
      logic [1:0] c = $urandom_range(0, 3), pd = $urandom_range(0, 3);
      bus_write(REG_CLK_CTRL, 32'h300 | (pd << 4) | c, 4'b0001);
      repeat ($urandom_range(0, 12)) @(posedge clk_ref);
    end
    bus_write(REG_CLK_CTRL, 32'h300);
    repeat (10) @(posedge core_clk);
    check(glitches == g0, "no clock glitches during random ratio changes");
  endtask

  task automatic t5_sw_gate();
    int n;
    start_test("T5 software clock enables");
    bus_write(REG_CLK_CTRL, 32'h100);               // periph clock off
    repeat (4) @(posedge clk_ref);
    count_edges(1, 50, n);
    check(n == 0, $sformatf("periph clock gated by CLK_CTRL[9] (%0d edges)", n));
    bus_write(REG_CLK_CTRL, 32'h300);
    repeat (4) @(posedge clk_ref);
    count_edges(1, 50, n);
    check(n == 50, $sformatf("periph clock restored (%0d edges)", n));
  endtask

  task automatic t6_idle();
    int n;
    start_test("T6 IDLE mode + wake masking");
    bus_write(REG_WAKE_MASK, 1 << WK_TMR);
    bus_write(REG_WAKE_PEND, '1);
    bus_write(REG_PM_CTRL, LP_IDLE);
    bus_write(REG_WKT, 300);
    do_wfi();
    wait_pm(PM_IDLE, 50);
    // masked line: must not wake
    irq[3] = 1'b1; @(posedge clk_ref); irq[3] = 1'b0;
    repeat (5) @(posedge clk_ref);
    check(pm_state_e'(pm_state) == PM_IDLE, "masked irq[3] does not wake IDLE");
    check(pwr_ack && !iso_en && core_rst_n, "IDLE keeps the core powered");
    count_edges(0, 100, n);
    check(n == 0, "core clock stopped in IDLE");
    wait_pm(PM_RUN, 400);
    wait (!core_sleep);
    read_check(REG_WAKE_PEND, (1 << WK_TMR) | (1 << 3), '1, "WAKE_PEND timer + masked irq3");
    read_check(REG_PM_CTRL, LP_NONE, '1, "PM_CTRL auto-cleared");
    read_check(REG_LP_STATS, 32'h0000_0001, '1, "IDLE counted");
    bus_write(REG_WAKE_PEND, '1);
    // LP_NONE: WFI does not involve the PMU
    bus_write(REG_WAKE_MASK, 1 << 5);
    do_wfi();
    repeat (20) @(posedge clk_ref);
    check(pm_state_e'(pm_state) == PM_RUN, "LP_NONE WFI keeps PMU in RUN");
    irq[5] = 1'b1; @(posedge clk_ref); irq[5] = 1'b0;
    wait (!core_sleep);
    bus_write(REG_WAKE_PEND, '1);
  endtask

  task automatic sleep_cycle(input lp_mode_e mode, input bit use_ext);
    string exp_entry, exp_wake;
    log_en = 1'b1; ev_log.delete();
    bus_write(REG_WAKE_MASK, use_ext ? (1 << WK_EXT) : (1 << WK_TMR));
    bus_write(REG_WAKE_PEND, '1);
    bus_write(REG_PM_CTRL, mode);
    if (!use_ext) bus_write(REG_WKT, 600);
    do_wfi();
    wait_pm(PM_SLEEP, 200);
    check(!pwr_en && !pwr_ack && iso_en && !core_rst_n, "core domain off, isolated, in reset");
    exp_entry = "CLK_OFF ISO_ON SAVE RST_ON PWR_OFF ACK_OFF";
    check(join_q(ev_log) == exp_entry,
          $sformatf("entry sequence '%s' (expected '%s')", join_q(ev_log), exp_entry));
    ev_log.delete();
    if (use_ext) begin
      repeat (300) @(posedge clk_ref);
      check(pm_state_e'(pm_state) == PM_SLEEP, "stays asleep until ext wake");
      ext_wake = 1'b1; repeat (3) @(posedge clk_ref); ext_wake = 1'b0;
    end
    wait_pm(PM_RUN, 2000);
    exp_wake = "PWR_ON ACK_ON RESTORE RST_OFF ISO_OFF CLK_ON";
    check(join_q(ev_log) == exp_wake,
          $sformatf("wake sequence '%s' (expected '%s')", join_q(ev_log), exp_wake));
    log_en = 1'b0;
    wait_core_up();
  endtask

  task automatic t7_sleep();
    start_test("T7 SLEEP power-down / power-up");
    sleep_cycle(LP_SLEEP, 1'b0);
    read_check(REG_PM_STATUS, 32'h1000, 32'h3000, "slept flag");
    read_check(REG_LP_STATS, 32'h0001_0001, '1, "SLEEP counted");
    bus_write(REG_PM_STATUS, 32'h3800);
    // slow power switch: PMU must wait for the acknowledge
    t_on = 1500ns;
    sleep_cycle(LP_SLEEP, 1'b0);
    check(t_pwron_out - t_pwron_in >= 1500ns,
          $sformatf("PMU waited %0t in WK_PWRON for a slow power switch", t_pwron_out - t_pwron_in));
    t_on = 100ns;
    bus_write(REG_PM_STATUS, 32'h3800);
  endtask

  task automatic t8_deep();
    int n;
    start_test("T8 DEEP sleep");
    fork
      sleep_cycle(LP_DEEP, 1'b1);
      begin
        wait_pm(PM_SLEEP, 400);
        repeat (5) @(posedge clk_ref);
        count_edges(1, 100, n);
        check(n == 0, "periph clock gated in DEEP sleep");
      end
    join
    read_check(REG_PM_STATUS, 32'h3000, 32'h3000, "slept + deep flags");
    count_edges(1, 20, n);
    check(n == 20, "periph clock running again after DEEP wake");
    bus_write(REG_PM_STATUS, 32'h3800);
    bus_write(REG_WAKE_PEND, '1);
  endtask

  task automatic t9_swrst();
    start_test("T9 software reset");
    bus_write(REG_RST_CAUSE, 32'hF);
    bus_write(REG_SCRATCH1, 32'h0BAD_F00D);
    bus_write(REG_RST_CTRL, 32'h0000_0123);           // wrong key
    repeat (10) @(posedge clk_ref);
    check(sys_rst_n && core_rst_n, "wrong key ignored");
    bus_write(REG_RST_CTRL, SW_RST_KEY);
    repeat (3) @(posedge clk_ref);
    check(!sys_rst_n && !periph_rst_n && !core_rst_n, "SW reset asserts all functional resets");
    wait_core_up();
    read_check(REG_RST_CAUSE, 32'h4, '1, "cause = SW");
    read_check(REG_SCRATCH1, 32'h0BAD_F00D, '1, "SCRATCH1 survives SW reset");
    read_check(REG_CLK_CTRL, 32'h300, 32'hFFFF, "CLK_CTRL back to reset value");
    bus_write(REG_RST_CAUSE, 32'hF);
  endtask

  task automatic t10_wdt();
    logic [31:0] c0, c1;
    start_test("T10 watchdog");
    bus_write(REG_WDT_LOAD, 200);
    bus_write(REG_WDT_CTRL, 1);
    repeat (5) begin
      repeat (120) @(posedge clk_ref);
      bus_write(REG_WDT_KICK, KEY);
    end
    check(sys_rst_n, "kicked watchdog does not fire");
    bus_write(REG_WDT_KICK, 32'h1234);                // wrong key: no reload
    // paused in IDLE
    bus_write(REG_WAKE_MASK, 1 << WK_TMR);
    bus_write(REG_WAKE_PEND, '1);
    bus_write(REG_WDT_KICK, KEY);
    bus_write(REG_PM_CTRL, LP_IDLE);
    bus_write(REG_WKT, 500);
    do_wfi();
    wait_pm(PM_IDLE, 50);
    c0 = dut.u_regs.wdt_cnt_q;
    repeat (300) @(posedge clk_ref);
    c1 = dut.u_regs.wdt_cnt_q;
    check(c0 == c1 && sys_rst_n, "watchdog paused while IDLE (500 > 200 cycles)");
    wait_pm(PM_RUN, 400);
    wait (!core_sleep);
    bus_write(REG_WAKE_PEND, '1);
    // expiry
    wait (!sys_rst_n);
    check(1, "watchdog expired");
    wait_core_up();
    read_check(REG_RST_CAUSE, 32'h8, '1, "cause = WDT");
    read_check(REG_WDT_CTRL, 32'h0, '1, "watchdog disabled after reset");
    bus_write(REG_RST_CAUSE, 32'hF);
  endtask

  task automatic t11_ext();
    start_test("T11 external reset pin");
    @(negedge clk_ref); ext_rst_n = 1'b0;
    repeat (200) @(posedge clk_ref);
    check(!sys_rst_n && !core_rst_n, "held in reset while ext_rst_n low");
    @(negedge clk_ref); ext_rst_n = 1'b1;
    wait_core_up();
    read_check(REG_RST_CAUSE, 32'h2, '1, "cause = EXT");
    read_check(REG_SCRATCH1, 32'h0BAD_F00D, '1, "SCRATCH1 survives EXT reset");
    bus_write(REG_RST_CAUSE, 32'hF);
  endtask

  task automatic t12_test_mode();
    int n;
    start_test("T12 DFT test mode");
    bus_write(REG_CLK_CTRL, 32'h0000_0003);          // both clocks disabled, /8
    repeat (20) @(posedge clk_ref);
    count_edges(0, 40, n);
    check(n == 0, "core clock off in functional mode (SW disable)");
    @(negedge clk_ref); test_mode = 1'b1;
    count_edges(0, 40, n);
    check(n == 40, $sformatf("test mode: core clock = ref clock (%0d/40)", n));
    count_edges(1, 40, n);
    check(n == 40, $sformatf("test mode: periph clock = ref clock (%0d/40)", n));
    @(negedge clk_ref); por_n = 1'b0; #1;
    check(!sys_rst_n && !periph_rst_n && !core_rst_n, "test mode: resets follow por_n (assert)");
    @(negedge clk_ref); por_n = 1'b1; #1;
    check(sys_rst_n && periph_rst_n && core_rst_n, "test mode: resets follow por_n (release)");
    @(negedge clk_ref); test_mode = 1'b0; por_n = 1'b0;
    repeat (5) @(posedge clk_ref);
    @(negedge clk_ref); por_n = 1'b1;
    wait_core_up();
    read_check(REG_RST_CAUSE, 32'h1, '1, "cause = POR after re-power");
    read_check(REG_SCRATCH1, 32'h0, '1, "SCRATCH1 cleared by POR");
  endtask

  // ================================================================ main
  initial begin
    if ($test$plusargs("WAVES")) begin
      $shm_open("waves_crpm.shm");
      $shm_probe(crpm_tb, "AS");
    end
    por_n = 0; ext_rst_n = 1; test_mode = 0; ext_wake = 0; irq = '0;
    req = 0; we = 0; be = '0; addr = '0; wdata = '0;

    t1_por();
    t2_regs();
    t3_div();
    t4_rand_div();
    t5_sw_gate();
    t6_idle();
    t7_sleep();
    t8_deep();
    t9_swrst();
    t10_wdt();
    t11_ext();
    t12_test_mode();

    repeat (20) @(posedge clk_ref);
    $display("");
    $display("==================================================================");
    $display(" CRPM block test : %0d checks, %0d errors, %0d clock glitches", checks, errors, glitches);
    if (errors == 0) $display(" RESULT: *** TEST PASSED ***");
    else             $display(" RESULT: *** TEST FAILED ***");
    $display("==================================================================");
    $finish;
  end

  initial begin
    #(1ms);
    $display("ERROR: TIMEOUT in %s", cur_test);
    $display(" RESULT: *** TEST FAILED ***");
    $finish;
  end
endmodule
