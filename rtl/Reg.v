// 触发器模板
module Reg #(parameter WIDTH = 1, parameter RESET_VAL = 0) (
  input clk,
  input rst_n,
  input [WIDTH-1:0] din,
  output reg [WIDTH-1:0] dout,
  input wen
);
  always @(posedge clk) begin
    if (!rst_n) dout <= RESET_VAL;
    else if (wen) dout <= din;
  end
endmodule
