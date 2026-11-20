// -----------------------------------------------------------------------------
// soc_ret_regs.sv
// Four 32-bit registers inside PD_CORE built from retention flops
// (balloon-latch style behavioural model):
//   * main flop  : core clock, switched supply -> lost (X) on power-down
//   * shadow     : always-on supply, captured on the CRPM ret_save pulse,
//                  copied back into the main flop on ret_restore
//   * reset      : system reset only (the core reset that is asserted around
//                  power-down must not destroy retained state)
// Bus slave, one-cycle response, mapped at 0x1001_0000.
// -----------------------------------------------------------------------------
module soc_ret_regs (
  input  logic        clk_i,          // core clock
  input  logic        sys_rst_ni,
  input  logic        pwr_ok_i,
  input  logic        ret_save_i,
  input  logic        ret_restore_i,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [3:0]  addr_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);
  logic [31:0] q      [4];
  logic [31:0] shadow [4];
  logic [1:0]  idx;
  assign idx = addr_i[3:2];

`ifdef SYNTHESIS
  // Synthesis: plain registers (the real design maps these to retention
  // flops through the UPF retention strategy).
  always_ff @(posedge clk_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) q <= '{default: '0};
    else if (req_i && we_i)
      for (int b = 0; b < 4; b++) if (be_i[b]) q[idx][8*b +: 8] <= wdata_i[8*b +: 8];
  end
  assign shadow = q;
`else
  always @(posedge ret_save_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) shadow <= '{default: '0};
    else             shadow <= q;
  end

  always @(posedge clk_i or posedge ret_restore_i or negedge pwr_ok_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni)        q <= '{default: '0};
    else if (!pwr_ok_i)     q <= '{default: 'x};        // supply collapsed
    else if (ret_restore_i) q <= shadow;                // restore from balloon
    else if (req_i && we_i)
      for (int b = 0; b < 4; b++) if (be_i[b]) q[idx][8*b +: 8] <= wdata_i[8*b +: 8];
  end
`endif

  always_ff @(posedge clk_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      rvalid_o <= 1'b0;
      rdata_o  <= '0;
    end else begin
      rvalid_o <= req_i;
      rdata_o  <= (req_i && !we_i) ? q[idx] : '0;
    end
  end
endmodule
