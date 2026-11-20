// -----------------------------------------------------------------------------
// crpm_cells.sv
// Low-level CRPM building blocks:
//   crpm_rst_sync  - async-assert / sync-deassert reset synchroniser (2 FF)
//                    with test-mode bypass (reset directly controllable in scan)
//   crpm_sync      - 2-FF single-bit CDC synchroniser
//   crpm_clk_gate  - glitch-free latch-based integrated clock gate (ICG)
//                    with test enable (clock always on in test mode)
//   crpm_clk_en_gen- programmable divide-by-1/2/4/8 clock-enable generator
//                    (divider realised as an ICG enable -> no generated clocks)
// -----------------------------------------------------------------------------

// ============================================================================
module crpm_rst_sync (
  input  logic clk_i,
  input  logic rst_ni,       // asynchronous, active-low
  input  logic test_mode_i,  // 1: bypass synchroniser (DFT controllability)
  output logic rst_no
);
  logic [1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sync_q <= 2'b00;
    else         sync_q <= {sync_q[0], 1'b1};
  end

  assign rst_no = test_mode_i ? rst_ni : sync_q[1];
endmodule

// ============================================================================
module crpm_sync #(
  parameter logic RESET_VAL = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic d_i,
  output logic q_o
);
  logic [1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sync_q <= {2{RESET_VAL}};
    else         sync_q <= {sync_q[0], d_i};
  end

  assign q_o = sync_q[1];
endmodule

// ============================================================================
// Latch-based ICG. The enable is captured while clk_i is LOW, so it can only
// change while the gated clock is low -> no glitches / truncated pulses.
// Define CRPM_USE_LIB_ICG to map onto the 45nm library ICG cell (TLATNCAX2,
// positive-edge latch-based ICG without a dedicated test pin) instead.
module crpm_clk_gate (
  input  logic clk_i,
  input  logic en_i,
  input  logic test_en_i,
  output logic clk_o
);
`ifdef CRPM_USE_LIB_ICG
  logic en_or_test;
  assign en_or_test = en_i | test_en_i;
  TLATNCAX2 u_icg (.CK(clk_i), .E(en_or_test), .ECK(clk_o));
`else
  logic en_latch;

  always_latch begin
    if (!clk_i) en_latch = en_i | test_en_i;
  end

  assign clk_o = clk_i & en_latch;
`endif
endmodule

// ============================================================================
// Produces a registered enable that is high for one reference cycle out of
// every 2^div_sel cycles. Feeding it into crpm_clk_gate gives a clock whose
// rising edges are a subset of the reference rising edges, i.e. the derived
// domains stay fully synchronous to clk_ref (no CDC between them).
//
// en_o is valid during reference cycle k and gates the clock edge that ends
// cycle k, so the CRPM can use en_o as "a derived clock edge happens now".
// A new div_sel value is only taken at the end of a full divided period, so
// ratio changes never produce a short clock period.
module crpm_clk_en_gen (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic [1:0] div_sel_i,
  input  logic       gate_en_i,   // functional enable (SW & PM)
  output logic       en_o,        // enable for the ICG
  output logic [1:0] div_sel_o    // ratio currently in use
);
  logic [2:0] cnt_q, cnt_d;
  logic [1:0] sel_q, sel_d;
  logic       wrap;

  function automatic logic [2:0] limit(input logic [1:0] sel);
    case (sel)
      2'd0:    limit = 3'd0;
      2'd1:    limit = 3'd1;
      2'd2:    limit = 3'd3;
      default: limit = 3'd7;
    endcase
  endfunction

  assign wrap  = (cnt_q >= limit(sel_q));
  assign sel_d = wrap ? div_sel_i : sel_q;
  assign cnt_d = wrap ? 3'd0 : cnt_q + 3'd1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_q <= 3'd0;
      sel_q <= 2'd0;
      en_o  <= 1'b1;
    end else begin
      cnt_q <= cnt_d;
      sel_q <= sel_d;
      en_o  <= (cnt_d == limit(sel_d)) & gate_en_i;
    end
  end

  assign div_sel_o = sel_q;
endmodule

// ============================================================================
// Isolation cell (clamp-to-0, AND type) placed on every output of the
// switchable core power domain. Lives in the always-on domain.
module crpm_iso_cell #(
  parameter int W = 1
) (
  input  logic [W-1:0] d_i,
  input  logic         iso_en_i,
  output logic [W-1:0] q_o
);
  assign q_o = iso_en_i ? '0 : d_i;
endmodule
