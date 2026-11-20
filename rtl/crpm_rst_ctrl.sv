// -----------------------------------------------------------------------------
// crpm_rst_ctrl.sv
// Reset controller / sequencer (power-on-reset domain, clocked by clk_ref)
//
//  Sources : POR (por_n_i, async), external reset pin (ext_rst_ni, async,
//            synchronised), software reset request, watchdog expiry.
//  Sequence: all resets held for HOLD_CYCLES (and as long as ext reset is low)
//            -> release sys  (CRPM registers / always-on logic)
//            -> PERIPH_DLY cycles -> release peripheral reset
//            -> CORE_DLY   cycles -> release core reset
//  Records the reset cause in a sticky register (cleared by W1C, POR sets
//  only the POR bit).
// -----------------------------------------------------------------------------
module crpm_rst_ctrl
  import crpm_pkg::*;
#(
  parameter int HOLD_CYCLES = 16,
  parameter int PERIPH_DLY  = 8,
  parameter int CORE_DLY    = 8
) (
  input  logic       clk_i,
  input  logic       por_rst_ni,     // synchronised POR
  input  logic       ext_rst_ni,     // raw external reset pin (async)
  input  logic       sw_rst_req_i,   // 1-cycle pulse
  input  logic       wdt_rst_req_i,  // 1-cycle pulse
  input  logic [3:0] cause_clr_i,    // W1C clear strobe
  output logic       sys_rst_no,
  output logic       periph_rst_no,
  output logic       core_rst_no,
  output logic [3:0] rst_cause_o,
  output rst_state_e state_o
);
  localparam int CW = 8;

  rst_state_e  state_q, state_d;
  logic [CW-1:0] cnt_q, cnt_d;
  logic        ext_rst_req;
  logic        any_req;
  logic [3:0]  cause_q;

  // External reset pin: synchronise the (inverted) request into clk_ref
  crpm_sync #(.RESET_VAL(1'b0)) u_ext_sync (
    .clk_i (clk_i), .rst_ni(por_rst_ni), .d_i(~ext_rst_ni), .q_o(ext_rst_req)
  );

  assign any_req = ext_rst_req | sw_rst_req_i | wdt_rst_req_i;

  always_comb begin
    state_d = state_q;
    cnt_d   = cnt_q;
    if (any_req) begin
      state_d = RS_HOLD;
      cnt_d   = '0;
    end else begin
      case (state_q)
        RS_HOLD: begin
          if (cnt_q == CW'(HOLD_CYCLES-1)) begin state_d = RS_SYS;    cnt_d = '0; end
          else                                    cnt_d = cnt_q + 1'b1;
        end
        RS_SYS: begin
          if (cnt_q == CW'(PERIPH_DLY-1))  begin state_d = RS_PERIPH; cnt_d = '0; end
          else                                    cnt_d = cnt_q + 1'b1;
        end
        RS_PERIPH: begin
          if (cnt_q == CW'(CORE_DLY-1))    begin state_d = RS_DONE;   cnt_d = '0; end
          else                                    cnt_d = cnt_q + 1'b1;
        end
        default: cnt_d = '0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge por_rst_ni) begin
    if (!por_rst_ni) begin
      state_q       <= RS_HOLD;
      cnt_q         <= '0;
      sys_rst_no    <= 1'b0;
      periph_rst_no <= 1'b0;
      core_rst_no   <= 1'b0;
    end else begin
      state_q       <= state_d;
      cnt_q         <= cnt_d;
      // registered (glitch-free) reset outputs
      sys_rst_no    <= (state_d != RS_HOLD);
      periph_rst_no <= (state_d == RS_PERIPH) || (state_d == RS_DONE);
      core_rst_no   <= (state_d == RS_DONE);
    end
  end

  // Sticky reset cause. POR clears everything and sets the POR bit.
  always_ff @(posedge clk_i or negedge por_rst_ni) begin
    if (!por_rst_ni) begin
      cause_q <= 4'b0001;
    end else begin
      cause_q <= (cause_q & ~cause_clr_i)
               | {wdt_rst_req_i, sw_rst_req_i, ext_rst_req, 1'b0};
    end
  end

  assign rst_cause_o = cause_q;
  assign state_o     = state_q;
endmodule
