// -----------------------------------------------------------------------------
// crpm_pkg.sv
// Clock, Reset and Power Management (CRPM) controller - shared definitions
// -----------------------------------------------------------------------------
package crpm_pkg;

  // ---------------- Register map (word offsets, byte address = offset) -------
  localparam logic [7:0] REG_CLK_CTRL  = 8'h00; // RW  clock dividers / enables
  localparam logic [7:0] REG_RST_CTRL  = 8'h04; // WO  software reset request
  localparam logic [7:0] REG_RST_CAUSE = 8'h08; // RW1C reset cause (sticky)
  localparam logic [7:0] REG_PM_CTRL   = 8'h0C; // RW  low-power mode for next WFI
  localparam logic [7:0] REG_PM_STATUS = 8'h10; // RO  PM FSM status
  localparam logic [7:0] REG_WAKE_MASK = 8'h14; // RW  wake-up source mask
  localparam logic [7:0] REG_WDT_CTRL  = 8'h18; // RW  watchdog enable
  localparam logic [7:0] REG_WDT_LOAD  = 8'h1C; // RW  watchdog timeout (ref cycles)
  localparam logic [7:0] REG_WDT_KICK  = 8'h20; // WO  write WDT_KEY to reload
  localparam logic [7:0] REG_WDT_COUNT = 8'h24; // RO  current watchdog count
  localparam logic [7:0] REG_LP_STATS  = 8'h28; // RO  {sleep_cnt[15:0], idle_cnt[15:0]}
  localparam logic [7:0] REG_ID        = 8'h2C; // RO  IP identifier
  localparam logic [7:0] REG_WAKE_PEND = 8'h30; // RW1C latched wake events
  localparam logic [7:0] REG_WKT       = 8'h34; // RW  always-on wake-up timer
  localparam logic [7:0] REG_SCRATCH0  = 8'h38; // RW  POR-only reset (retained)
  localparam logic [7:0] REG_SCRATCH1  = 8'h3C; // RW  POR-only reset (retained)

  // Wake sources: [15:0] irq_i, [16] ext wake pin, [17] wake-up timer
  localparam int NUM_WAKE = 18;
  localparam int WK_EXT   = 16;
  localparam int WK_TMR   = 17;

  localparam logic [31:0] CRPM_ID      = 32'h4352_504D; // "CRPM"
  localparam logic [31:0] WDT_KEY      = 32'h5A5A_5A5A;
  localparam logic [31:0] SW_RST_KEY   = 32'h0000_0A5A; // RST_CTRL[11:0] key

  // CLK_CTRL fields
  //  [1:0] core_div_sel   : 0=/1 1=/2 2=/4 3=/8
  //  [5:4] periph_div_sel : 0=/1 1=/2 2=/4 3=/8
  //  [8]   core_clk_en    : software clock enable for core domain
  //  [9]   periph_clk_en  : software clock enable for peripheral domain
  localparam logic [31:0] CLK_CTRL_RST = 32'h0000_0300;
  localparam logic [31:0] CLK_CTRL_MSK = 32'h0000_0333;

  // Low-power modes (PM_CTRL[1:0])
  typedef enum logic [1:0] {
    LP_NONE  = 2'd0,   // WFI handled inside the core only
    LP_IDLE  = 2'd1,   // core clock gated
    LP_SLEEP = 2'd2,   // core power domain switched off (with retention)
    LP_DEEP  = 2'd3    // core off + peripheral clock gated
  } lp_mode_e;

  // Reset cause bits
  localparam int RC_POR = 0;
  localparam int RC_EXT = 1;
  localparam int RC_SW  = 2;
  localparam int RC_WDT = 3;

  // Power-management FSM
  typedef enum logic [3:0] {
    PM_RUN        = 4'd0,
    PM_IDLE       = 4'd1,
    PM_SLP_CLKOFF = 4'd2,
    PM_SLP_ISO    = 4'd3,
    PM_SLP_SAVE   = 4'd4,
    PM_SLP_RST    = 4'd5,
    PM_SLP_PWROFF = 4'd6,
    PM_SLEEP      = 4'd7,
    PM_WK_PWRON   = 4'd8,
    PM_WK_RESTORE = 4'd9,
    PM_WK_RSTREL  = 4'd10,
    PM_WK_DEISO   = 4'd11,
    PM_WK_CLKON   = 4'd12
  } pm_state_e;

  // Reset sequencer FSM
  typedef enum logic [1:0] {
    RS_HOLD   = 2'd0,  // every functional reset asserted
    RS_SYS    = 2'd1,  // always-on / CRPM register reset released
    RS_PERIPH = 2'd2,  // peripheral reset released
    RS_DONE   = 2'd3   // core reset released
  } rst_state_e;

endpackage
