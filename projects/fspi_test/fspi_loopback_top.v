// Standalone RK quad-FSPI loopback. 25 MHz system clock, SCK <= 1 MHz.
// CPU ports are disabled; no firmware or vendor IP is needed.
module fspi_loopback_top (
 input wire sys_clk, key0_n,
 input wire spi_clk, spi_cs,
 inout wire [3:0] spi_data,
 output wire led0, led1
);
 wire rst_n;
 reg [23:0] heartbeat=0;
 reg seen_cs=0;
 reg [1:0] cs_sample=2'b11;
 board_reset u_reset(.clk(sys_clk),.key0_n(key0_n),.rst_n(rst_n));
 rk_fspi_adapter u_fspi(
  .clk(sys_clk),.rst_n(rst_n),.spi_clk(spi_clk),.spi_cs(spi_cs),.spi_data(spi_data),
  .cpu_we(1'b0),.cpu_re(1'b0),.cpu_addr(32'b0),.cpu_wdata(32'b0),.cpu_rdata());
 always @(posedge sys_clk) begin
  if(!rst_n) begin heartbeat<=0;cs_sample<=2'b11;seen_cs<=0;end
  else begin
   heartbeat<=heartbeat+1'b1;
   cs_sample<={cs_sample[0],spi_cs};
   if(!cs_sample[1]) seen_cs<=1;
  end
 end
 assign led0=heartbeat[23];
 assign led1=seen_cs;
endmodule
