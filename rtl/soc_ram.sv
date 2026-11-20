// -----------------------------------------------------------------------------
// soc_ram.sv - dual-port SRAM (port A: instruction fetch, port B: data)
// Always-on power (contents retained when PD_CORE is switched off), clocked
// by the core clock. One-cycle read latency, always granted.
// Initialised from the hex file given by +FW=<file> (default fw.hex).
// -----------------------------------------------------------------------------
module soc_ram #(
  parameter int Words = 16384          // 64 KiB
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  // port A
  input  logic        a_req_i,
  input  logic [31:0] a_addr_i,
  output logic        a_rvalid_o,
  output logic [31:0] a_rdata_o,
  // port B
  input  logic        b_req_i,
  input  logic        b_we_i,
  input  logic [3:0]  b_be_i,
  input  logic [31:0] b_addr_i,
  input  logic [31:0] b_wdata_i,
  output logic        b_rvalid_o,
  output logic [31:0] b_rdata_o
);
  localparam int AW = $clog2(Words);
  logic [31:0] mem [Words];
  logic [AW-1:0] a_idx, b_idx;

  assign a_idx = a_addr_i[AW+1:2];
  assign b_idx = b_addr_i[AW+1:2];

`ifndef SYNTHESIS
  initial begin
    string fw;
    for (int i = 0; i < Words; i++) mem[i] = 32'h0000_0013; // nop
    if (!$value$plusargs("FW=%s", fw)) fw = "fw.hex";
    $readmemh(fw, mem);
    $display("[SOC_RAM] loaded firmware image '%s'", fw);
  end
`endif

  always_ff @(posedge clk_i) begin
    if (a_req_i) a_rdata_o <= mem[a_idx];
    if (b_req_i) begin
      if (b_we_i) begin
        for (int i = 0; i < 4; i++)
          if (b_be_i[i]) mem[b_idx][8*i +: 8] <= b_wdata_i[8*i +: 8];
      end else begin
        b_rdata_o <= mem[b_idx];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_rvalid_o <= 1'b0;
      b_rvalid_o <= 1'b0;
    end else begin
      a_rvalid_o <= a_req_i;
      b_rvalid_o <= b_req_i;
    end
  end
endmodule
