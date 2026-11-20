// -----------------------------------------------------------------------------
// soc_core_pd.sv
// Switchable core power domain (PD_CORE): unmodified Ibex (ibex_top) reused
// from Lab 4, plus the domain-boundary isolation cells.
//
//  * clk_i / rst_ni come from the CRPM (gated core clock, sequenced reset).
//  * pwr_ok_i is the power-switch acknowledge. In simulation a collapsed
//    supply is modelled by driving every domain output to X; the isolation
//    cells (clamp 0, controlled by the always-on CRPM) must hide this from
//    the rest of the SoC.
// -----------------------------------------------------------------------------
module soc_core_pd (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        test_en_i,
  input  logic        pwr_ok_i,
  input  logic        iso_en_i,
  input  logic [31:0] boot_addr_i,
  // instruction bus
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,
  // data bus
  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,
  // interrupts / status
  input  logic        irq_wake_i,     // CRPM wake IRQ -> irq_fast_i[0]
  output logic        core_sleep_o,
  // raw (pre-isolation) outputs, for checking the isolation strategy
  output logic        raw_instr_req_o,
  output logic        raw_data_req_o
);
  // ---------------------------------------------------------- Ibex outputs
  logic        c_instr_req, c_data_req, c_data_we, c_core_sleep;
  logic [31:0] c_instr_addr, c_data_addr, c_data_wdata;
  logic [3:0]  c_data_be;

  ibex_top u_ibex (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .test_en_i              (test_en_i),
    .ram_cfg_icache_tag_i   ('0),
    .ram_cfg_icache_tag_o   (),
    .ram_cfg_icache_data_i  ('0),
    .ram_cfg_icache_data_o  (),
    .cheriot_enable_i       (ibex_pkg::IbexMuBiOff),
    .hart_id_i              (32'h0000_0000),
    .boot_addr_i            (boot_addr_i),
    .trvk_heap_base_addr_i  (32'h0000_0000),

    .instr_req_o            (c_instr_req),
    .instr_gnt_i            (instr_gnt_i),
    .instr_rvalid_i         (instr_rvalid_i),
    .instr_addr_o           (c_instr_addr),
    .instr_rdata_i          (instr_rdata_i),
    .instr_rdata_intg_i     ('0),
    .instr_err_i            (instr_err_i),

    .data_req_o             (c_data_req),
    .data_gnt_i             (data_gnt_i),
    .data_rvalid_i          (data_rvalid_i),
    .data_we_o              (c_data_we),
    .data_be_o              (c_data_be),
    .data_addr_o            (c_data_addr),
    .data_wdata_o           (c_data_wdata),
    .data_wdata_intg_o      (),
    .data_tag_o             (),
    .data_rdata_i           (data_rdata_i),
    .data_rdata_intg_i      ('0),
    .data_tag_i             (1'b0),
    .data_err_i             (data_err_i),

    .trvk_revbm_req_o       (),
    .trvk_revbm_gnt_i       (1'b0),
    .trvk_revbm_rvalid_i    (1'b0),
    .trvk_revbm_addr_o      (),
    .trvk_revbm_rdata_i     ('0),
    .trvk_revbm_rdata_intg_i('0),
    .trvk_revbm_err_i       (1'b0),

    .irq_software_i         (1'b0),
    .irq_timer_i            (1'b0),
    .irq_external_i         (1'b0),
    .irq_fast_i             ({14'd0, irq_wake_i}),
    .irq_nm_i               (1'b0),

    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (),

    .debug_req_i            (1'b0),
    .crash_dump_o           (),
    .double_fault_seen_o    (),

    .fetch_enable_i         (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i  (ibex_pkg::IbexMuBiOn),
    .alert_minor_o          (),
    .alert_major_internal_o (),
    .alert_major_bus_o      (),
    .core_sleep_o           (c_core_sleep),
    .lockstep_cmp_en_o      (),

    .data_req_shadow_o        (),
    .data_we_shadow_o         (),
    .data_be_shadow_o         (),
    .data_addr_shadow_o       (),
    .data_wdata_shadow_o      (),
    .data_wdata_intg_shadow_o (),
    .instr_req_shadow_o       (),
    .instr_addr_shadow_o      (),

    .scan_rst_ni            (1'b1)
  );

  // ------------------------------------------- supply-collapse corruption
  localparam int OW = 1 + 32 + 1 + 1 + 4 + 32 + 32 + 1;
  logic [OW-1:0] out_core, out_pd, out_iso;

  assign out_core = {c_instr_req, c_instr_addr, c_data_req, c_data_we, c_data_be,
                     c_data_addr, c_data_wdata, c_core_sleep};
`ifdef SYNTHESIS
  assign out_pd = out_core;
`else
  assign out_pd = pwr_ok_i ? out_core : 'x;   // unpowered domain -> unknown
`endif

  // ------------------------------------------------------ isolation cells
  crpm_iso_cell #(.W(OW)) u_iso (.d_i(out_pd), .iso_en_i(iso_en_i), .q_o(out_iso));

  assign {instr_req_o, instr_addr_o, data_req_o, data_we_o, data_be_o,
          data_addr_o, data_wdata_o, core_sleep_o} = out_iso;

  assign raw_instr_req_o = out_pd[OW-1];
  assign raw_data_req_o  = out_pd[OW-1-33];
endmodule
