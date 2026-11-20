// -----------------------------------------------------------------------------
// pwr_switch_model.sv - behavioural header/footer power switch for PD_CORE.
// The acknowledge follows the enable after a ramp delay (ON) / discharge
// delay (OFF), like a daisy-chained switch network.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module pwr_switch_model #(
  parameter realtime T_ON  = 150ns,
  parameter realtime T_OFF = 80ns
) (
  input  logic en_i,
  output logic ack_o
);
  initial ack_o = 1'b0;
  always @(en_i) begin
    if (en_i === 1'b1) begin
      #(T_ON);
      if (en_i === 1'b1) ack_o = 1'b1;
    end else begin
      #(T_OFF);
      if (en_i !== 1'b1) ack_o = 1'b0;
    end
  end
endmodule
