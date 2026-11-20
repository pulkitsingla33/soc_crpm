// -----------------------------------------------------------------------------
// soc_top.sv
// 32-bit RISC-V SoC: Ibex core (switchable power domain PD_CORE) managed by
// the Clock, Reset and Power Management controller (CRPM).
//
//  Memory map (data side)
//    0x0000_0000 - 0x0000_FFFF  SRAM 64 KiB (also instruction memory)
//    0x1000_0000 - 0x1000_00FF  CRPM registers
//    0x1001_0000 - 0x1001_000F  retention registers (PD_CORE)
//    0x2000_0000 - 0x2FFF_FFFF  external bus port (testbench / off-chip)
//    anything else              bus error
//
//  Power domains
//    PD_AON  : CRPM, SRAM, interconnect, wake logic        (always on)
//    PD_CORE : Ibex + retention registers                  (switchable)
// -----------------------------------------------------------------------------
module soc_top #(
  parameter logic [31:0] BOOT_ADDR = 32'h0000_0000
) (
  input  logic        clk_ref_i,      // reference clock (100 MHz)
  input  logic        por_ni,         // power-on reset
  input  logic        ext_rst_ni,     // external reset pin
  input  logic        test_mode_i,    // DFT test mode
  input  logic        ext_wake_i,     // asynchronous wake-up pin
  input  logic [15:0] ext_irq_i,      // asynchronous interrupt / wake lines
  // core power switch
  output logic        core_pwr_en_o,
  input  logic        core_pwr_ack_i,
  // external bus port (core clock domain)
  output logic        ext_req_o,
  output logic        ext_we_o,
  output logic [3:0]  ext_be_o,
  output logic [31:0] ext_addr_o,
  output logic [31:0] ext_wdata_o,
  input  logic        ext_rvalid_i,
  input  logic [31:0] ext_rdata_i,
  // observability
  output logic        core_clk_o,
  output logic        periph_clk_o,
  output logic        sys_rst_no,
  output logic        periph_rst_no,
  output logic        core_rst_no,
  output logic [3:0]  pm_state_o
);
  // =============================================================== CRPM
  logic        aon_clk, core_clk, periph_clk;
  logic        sys_rst_n, periph_rst_n, core_rst_n;
  logic        iso_en, ret_save, ret_restore, wake_irq, core_sleep;
  logic        crpm_req, crpm_gnt, crpm_rvalid, crpm_err;
  logic [31:0] crpm_rdata;
  logic [15:0] irq_sync;

  // asynchronous interrupt lines -> clk_ref domain
  for (genvar i = 0; i < 16; i++) begin : g_irq_sync
    crpm_sync u_sync (.clk_i(aon_clk), .rst_ni(sys_rst_n), .d_i(ext_irq_i[i]), .q_o(irq_sync[i]));
  end

  logic        d_req, d_gnt, d_rvalid, d_we, d_err;
  logic [3:0]  d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;

  crpm_top u_crpm (
    .clk_ref_i    (clk_ref_i),
    .por_ni       (por_ni),
    .ext_rst_ni   (ext_rst_ni),
    .test_mode_i  (test_mode_i),
    .aon_clk_o    (aon_clk),
    .core_clk_o   (core_clk),
    .periph_clk_o (periph_clk),
    .sys_rst_no   (sys_rst_n),
    .periph_rst_no(periph_rst_n),
    .core_rst_no  (core_rst_n),
    .reg_req_i    (crpm_req),
    .reg_we_i     (d_we),
    .reg_be_i     (d_be),
    .reg_addr_i   (d_addr[7:0]),
    .reg_wdata_i  (d_wdata),
    .reg_gnt_o    (crpm_gnt),
    .reg_rvalid_o (crpm_rvalid),
    .reg_rdata_o  (crpm_rdata),
    .reg_err_o    (crpm_err),
    .core_sleep_i (core_sleep),
    .irq_i        (irq_sync),
    .ext_wake_i   (ext_wake_i),
    .pwr_ack_i    (core_pwr_ack_i),
    .pwr_en_o     (core_pwr_en_o),
    .iso_en_o     (iso_en),
    .ret_save_o   (ret_save),
    .ret_restore_o(ret_restore),
    .wake_irq_o   (wake_irq),
    .pm_state_o   (pm_state_o)
  );

  // ============================================================ PD_CORE
  logic        i_req, i_gnt, i_rvalid, i_err;
  logic [31:0] i_addr, i_rdata;

  soc_core_pd u_core_pd (
    .clk_i          (core_clk),
    .rst_ni         (core_rst_n),
    .test_en_i      (test_mode_i),
    .pwr_ok_i       (core_pwr_ack_i),
    .iso_en_i       (iso_en),
    .boot_addr_i    (BOOT_ADDR),
    .instr_req_o    (i_req),
    .instr_gnt_i    (i_gnt),
    .instr_rvalid_i (i_rvalid),
    .instr_addr_o   (i_addr),
    .instr_rdata_i  (i_rdata),
    .instr_err_i    (i_err),
    .data_req_o     (d_req),
    .data_gnt_i     (d_gnt),
    .data_rvalid_i  (d_rvalid),
    .data_we_o      (d_we),
    .data_be_o      (d_be),
    .data_addr_o    (d_addr),
    .data_wdata_o   (d_wdata),
    .data_rdata_i   (d_rdata),
    .data_err_i     (d_err),
    .irq_wake_i     (wake_irq),
    .core_sleep_o   (core_sleep),
    .raw_instr_req_o(),
    .raw_data_req_o ()
  );

  // ========================================================= interconnect
  typedef enum logic [2:0] {S_RAM, S_CRPM, S_RET, S_EXT, S_ERR} slave_e;
  slave_e d_sel, d_sel_q;
  logic   i_inrange, i_err_q;

  always_comb begin
    if      (d_addr[31:16] == 16'h0000)      d_sel = S_RAM;
    else if (d_addr[31:8]  == 24'h1000_00)   d_sel = S_CRPM;
    else if (d_addr[31:8]  == 24'h1001_00)   d_sel = S_RET;
    else if (d_addr[31:28] == 4'h2)          d_sel = S_EXT;
    else                                     d_sel = S_ERR;
  end

  logic ram_b_req, ram_b_rvalid, ret_req, ret_rvalid, err_rvalid_q;
  logic [31:0] ram_b_rdata, ret_rdata;

  assign ram_b_req = d_req && (d_sel == S_RAM);
  assign crpm_req  = d_req && (d_sel == S_CRPM);
  assign ret_req   = d_req && (d_sel == S_RET);
  assign ext_req_o = d_req && (d_sel == S_EXT);
  assign d_gnt     = d_req;               // every slave accepts immediately

  assign ext_we_o    = d_we;
  assign ext_be_o    = d_be;
  assign ext_addr_o  = d_addr;
  assign ext_wdata_o = d_wdata;

  always_ff @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      d_sel_q      <= S_RAM;
      err_rvalid_q <= 1'b0;
      i_err_q      <= 1'b0;
    end else begin
      if (d_req) d_sel_q <= d_sel;
      err_rvalid_q <= d_req && (d_sel == S_ERR);
      i_err_q      <= i_req && !i_inrange;
    end
  end

  always_comb begin
    d_rvalid = 1'b0;
    d_rdata  = '0;
    d_err    = 1'b0;
    unique case (d_sel_q)
      S_RAM:  begin d_rvalid = ram_b_rvalid; d_rdata = ram_b_rdata; end
      S_CRPM: begin d_rvalid = crpm_rvalid;  d_rdata = crpm_rdata; d_err = crpm_err; end
      S_RET:  begin d_rvalid = ret_rvalid;   d_rdata = ret_rdata;  end
      S_EXT:  begin d_rvalid = ext_rvalid_i; d_rdata = ext_rdata_i; end
      default: begin d_rvalid = err_rvalid_q; d_err = err_rvalid_q; end
    endcase
  end

  // instruction side: SRAM only
  logic ram_a_rvalid;
  assign i_inrange = (i_addr[31:16] == 16'h0000);
  assign i_gnt     = i_req;
  assign i_rvalid  = ram_a_rvalid | i_err_q;
  assign i_err     = i_err_q;

  // ============================================================ memories
  soc_ram u_ram (
    .clk_i     (core_clk),
    .rst_ni    (core_rst_n),
    .a_req_i   (i_req && i_inrange),
    .a_addr_i  (i_addr),
    .a_rvalid_o(ram_a_rvalid),
    .a_rdata_o (i_rdata),
    .b_req_i   (ram_b_req),
    .b_we_i    (d_we),
    .b_be_i    (d_be),
    .b_addr_i  (d_addr),
    .b_wdata_i (d_wdata),
    .b_rvalid_o(ram_b_rvalid),
    .b_rdata_o (ram_b_rdata)
  );

  soc_ret_regs u_ret (
    .clk_i        (core_clk),
    .sys_rst_ni   (sys_rst_n),
    .pwr_ok_i     (core_pwr_ack_i),
    .ret_save_i   (ret_save),
    .ret_restore_i(ret_restore),
    .req_i        (ret_req),
    .we_i         (d_we),
    .be_i         (d_be),
    .addr_i       (d_addr[3:0]),
    .wdata_i      (d_wdata),
    .rvalid_o     (ret_rvalid),
    .rdata_o      (ret_rdata)
  );

  // ================================================== peripheral domain
  // Placeholder peripheral logic on the peripheral clock / reset: a free
  // running activity counter. It must freeze while the peripheral clock is
  // gated (DEEP sleep) - checked by the testbench.
  logic [31:0] periph_cnt_q;
  always_ff @(posedge periph_clk or negedge periph_rst_n) begin
    if (!periph_rst_n) periph_cnt_q <= '0;
    else               periph_cnt_q <= periph_cnt_q + 1'b1;
  end

  // ========================================================= observability
  assign core_clk_o    = core_clk;
  assign periph_clk_o  = periph_clk;
  assign sys_rst_no    = sys_rst_n;
  assign periph_rst_no = periph_rst_n;
  assign core_rst_no   = core_rst_n;
endmodule
