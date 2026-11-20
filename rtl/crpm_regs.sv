// -----------------------------------------------------------------------------
// crpm_regs.sv
// Memory-mapped register file, watchdog timer and wake-up controller.
//
// Bus: Ibex LSU style (req/gnt/rvalid/we/be/addr/wdata/rdata/err).
// The register file lives in the always-on clk_ref domain, but the bus
// master runs on the derived core clock. Because core-clock rising edges are
// a subset of clk_ref rising edges, sampling the bus only in cycles where
// core_tick_i = 1 makes this slave behave exactly like a flop in the core
// domain (no synchroniser needed, rvalid one core cycle after the grant).
//
// Reset domains:
//   por_rst_ni : SCRATCH0/1 only  (survive SW / WDT / external resets & sleep)
//   rst_ni     : everything else  (sys reset from the reset sequencer)
// -----------------------------------------------------------------------------
module crpm_regs
  import crpm_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,         // sys reset
  input  logic        por_rst_ni,     // power-on reset only
  input  logic        core_tick_i,
  // bus
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [7:0]  addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,
  // control outputs
  output logic [1:0]  core_div_sel_o,
  output logic [1:0]  periph_div_sel_o,
  output logic        core_clk_en_o,
  output logic        periph_clk_en_o,
  output lp_mode_e    lp_mode_o,
  output logic        sw_rst_req_o,   // pulse
  output logic [3:0]  cause_clr_o,    // pulse
  output logic        wdt_rst_req_o,  // pulse
  // wake-up controller
  input  logic [15:0] irq_i,          // peripheral interrupt / wake lines
  input  logic        ext_wake_i,     // synchronised external wake pin
  output logic        wake_o,         // to PMU
  output logic        irq_o,          // to core (Ibex irq_fast_i[0])
  // status inputs
  input  logic [3:0]  rst_cause_i,
  input  pm_state_e   pm_state_i,
  input  logic        pm_deep_i,
  input  logic        pwr_ack_i,
  input  logic        iso_en_i,
  input  logic        lp_clr_i,
  input  logic [15:0] idle_cnt_i,
  input  logic [15:0] sleep_cnt_i,
  input  logic [1:0]  core_div_act_i,
  input  logic [1:0]  periph_div_act_i
);
  localparam logic [31:0] WAKE_MSK = (32'h1 << NUM_WAKE) - 1;

  logic [31:0]         clk_ctrl_q;
  logic [1:0]          lp_mode_q;
  logic [NUM_WAKE-1:0] wake_mask_q, wake_pend_q, wake_ev;
  logic                wdt_en_q;
  logic [31:0]         wdt_load_q, wdt_cnt_q;
  logic                wdt_fired_q;
  logic                wake_seen_q, slept_q, deep_slept_q;
  logic [31:0]         wkt_cnt_q;
  logic                wkt_fire_q;
  logic [31:0]         scratch0_q, scratch1_q;

  logic        access, wr, rd_err;
  logic [7:0]  waddr;
  logic [31:0] bmask, rdata_d;

  assign access = core_tick_i & req_i;
  assign wr     = access & we_i;
  assign waddr  = addr_i & 8'hFC;
  assign gnt_o  = req_i;           // always ready (single-cycle slave)
  assign bmask  = {{8{be_i[3]}}, {8{be_i[2]}}, {8{be_i[1]}}, {8{be_i[0]}}};

  function automatic logic [31:0] merge(input logic [31:0] old_v,
                                        input logic [31:0] new_v,
                                        input logic [31:0] m);
    merge = (old_v & ~m) | (new_v & m);
  endfunction

  // ---------------------------------------------------------------- writes
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      clk_ctrl_q   <= CLK_CTRL_RST;
      lp_mode_q    <= LP_NONE;
      wake_mask_q  <= '1;
      wdt_en_q     <= 1'b0;
      wdt_load_q   <= 32'h0000_FFFF;
      sw_rst_req_o <= 1'b0;
      cause_clr_o  <= 4'h0;
    end else begin
      sw_rst_req_o <= 1'b0;
      cause_clr_o  <= 4'h0;
      if (lp_clr_i) lp_mode_q <= LP_NONE;
      if (wr) begin
        case (waddr)
          REG_CLK_CTRL:  clk_ctrl_q  <= merge(clk_ctrl_q, wdata_i, bmask) & CLK_CTRL_MSK;
          REG_RST_CTRL:  sw_rst_req_o <= (wdata_i[11:0] == SW_RST_KEY[11:0]) && (&be_i[1:0]);
          REG_RST_CAUSE: cause_clr_o <= wdata_i[3:0] & {4{be_i[0]}};
          REG_PM_CTRL:   if (be_i[0]) lp_mode_q <= wdata_i[1:0];
          REG_WAKE_MASK: wake_mask_q <= NUM_WAKE'(merge(32'(wake_mask_q), wdata_i, bmask) & WAKE_MSK);
          REG_WDT_CTRL:  if (be_i[0]) wdt_en_q <= wdata_i[0];
          REG_WDT_LOAD:  wdt_load_q  <= merge(wdt_load_q, wdata_i, bmask);
          default: ;
        endcase
      end
    end
  end

  // POR-only scratch registers: firmware keeps boot state here across
  // software / watchdog / external resets and core power-down.
  always_ff @(posedge clk_i or negedge por_rst_ni) begin
    if (!por_rst_ni) begin
      scratch0_q <= '0;
      scratch1_q <= '0;
    end else if (wr) begin
      if (waddr == REG_SCRATCH0) scratch0_q <= merge(scratch0_q, wdata_i, bmask);
      if (waddr == REG_SCRATCH1) scratch1_q <= merge(scratch1_q, wdata_i, bmask);
    end
  end

  // -------------------------------------------------------------- watchdog
  // Counts down while enabled and the core is running (paused in any
  // low-power state). Reloaded by writing WDT_KEY to WDT_KICK, on enable and
  // on WDT_LOAD writes. Expiry issues a single reset request pulse.
  logic wdt_reload;
  assign wdt_reload = wr && ((waddr == REG_WDT_KICK && wdata_i == WDT_KEY) ||
                             (waddr == REG_WDT_LOAD) ||
                             (waddr == REG_WDT_CTRL && wdata_i[0] && !wdt_en_q));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wdt_cnt_q     <= 32'h0000_FFFF;
      wdt_fired_q   <= 1'b0;
      wdt_rst_req_o <= 1'b0;
    end else begin
      wdt_rst_req_o <= 1'b0;
      if (wdt_reload) begin
        wdt_cnt_q   <= (waddr == REG_WDT_LOAD) ? merge(wdt_load_q, wdata_i, bmask)
                                               : wdt_load_q;
        wdt_fired_q <= 1'b0;
      end else if (wdt_en_q && (pm_state_i == PM_RUN) && !wdt_fired_q) begin
        if (wdt_cnt_q == 32'd0) begin
          wdt_fired_q   <= 1'b1;
          wdt_rst_req_o <= 1'b1;
        end else begin
          wdt_cnt_q <= wdt_cnt_q - 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------ always-on wake-up timer
  // Writing N (>0) to WKT starts a one-shot countdown of N reference cycles;
  // expiry raises wake source WK_TMR. Runs in every power state.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wkt_cnt_q  <= '0;
      wkt_fire_q <= 1'b0;
    end else begin
      wkt_fire_q <= 1'b0;
      if (wr && waddr == REG_WKT) begin
        wkt_cnt_q <= wdata_i;
      end else if (wkt_cnt_q != '0) begin
        wkt_cnt_q <= wkt_cnt_q - 1'b1;
        if (wkt_cnt_q == 32'd1) wkt_fire_q <= 1'b1;
      end
    end
  end

  // ------------------------------------------------- wake-up controller
  // Events are latched in WAKE_PEND (W1C). Any pending, unmasked event wakes
  // the PMU and is presented to the core as a level interrupt so that Ibex
  // leaves WFI once its clock is running again.
  assign wake_ev = {wkt_fire_q, ext_wake_i, irq_i};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wake_pend_q <= '0;
    end else begin
      wake_pend_q <= (wake_pend_q &
                      ~((wr && waddr == REG_WAKE_PEND) ? NUM_WAKE'(wdata_i & bmask) : '0))
                     | wake_ev;
    end
  end

  assign wake_o = |((wake_pend_q | wake_ev) & wake_mask_q);
  assign irq_o  = |(wake_pend_q & wake_mask_q);

  // ---------------------------------------------------- sticky PM status
  logic pm_status_clr;
  assign pm_status_clr = wr && (waddr == REG_PM_STATUS);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wake_seen_q  <= 1'b0;
      slept_q      <= 1'b0;
      deep_slept_q <= 1'b0;
    end else begin
      if (wake_o && pm_state_i inside {PM_IDLE, PM_SLEEP}) wake_seen_q <= 1'b1;
      else if (pm_status_clr && wdata_i[11])               wake_seen_q <= 1'b0;
      if (pm_state_i == PM_SLEEP)                          slept_q     <= 1'b1;
      else if (pm_status_clr && wdata_i[12])               slept_q     <= 1'b0;
      if (pm_state_i == PM_SLEEP && pm_deep_i)             deep_slept_q <= 1'b1;
      else if (pm_status_clr && wdata_i[13])               deep_slept_q <= 1'b0;
    end
  end

  // ----------------------------------------------------------------- reads
  always_comb begin
    rdata_d = 32'h0;
    rd_err  = 1'b0;
    case (waddr)
      // [17:16]/[21:20] (RO): divide ratio currently applied by the divider
      REG_CLK_CTRL:  rdata_d = clk_ctrl_q | {10'd0, periph_div_act_i, 2'b00, core_div_act_i, 16'd0};
      REG_RST_CTRL:  rdata_d = 32'h0;
      REG_RST_CAUSE: rdata_d = {28'd0, rst_cause_i};
      REG_PM_CTRL:   rdata_d = {30'd0, lp_mode_q};
      REG_PM_STATUS: rdata_d = {18'd0, deep_slept_q, slept_q, wake_seen_q, pm_deep_i,
                               iso_en_i, pwr_ack_i, 4'd0, pm_state_i};
      REG_WAKE_MASK: rdata_d = 32'(wake_mask_q);
      REG_WDT_CTRL:  rdata_d = {31'd0, wdt_en_q};
      REG_WDT_LOAD:  rdata_d = wdt_load_q;
      REG_WDT_KICK:  rdata_d = 32'h0;
      REG_WDT_COUNT: rdata_d = wdt_cnt_q;
      REG_LP_STATS:  rdata_d = {sleep_cnt_i, idle_cnt_i};
      REG_ID:        rdata_d = CRPM_ID;
      REG_WAKE_PEND: rdata_d = 32'(wake_pend_q);
      REG_WKT:       rdata_d = wkt_cnt_q;
      REG_SCRATCH0:  rdata_d = scratch0_q;
      REG_SCRATCH1:  rdata_d = scratch1_q;
      default:       rd_err  = 1'b1;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
      rdata_o  <= 32'h0;
      err_o    <= 1'b0;
    end else if (core_tick_i) begin
      rvalid_o <= req_i;
      err_o    <= req_i & rd_err;
      rdata_o  <= (req_i && !we_i) ? rdata_d : 32'h0;
    end
  end

  assign core_div_sel_o   = clk_ctrl_q[1:0];
  assign periph_div_sel_o = clk_ctrl_q[5:4];
  assign core_clk_en_o    = clk_ctrl_q[8];
  assign periph_clk_en_o  = clk_ctrl_q[9];
  assign lp_mode_o        = lp_mode_e'(lp_mode_q);
endmodule
