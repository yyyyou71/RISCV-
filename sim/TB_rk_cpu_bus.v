`timescale 1ns/1ps
module TB_rk_cpu_bus;
 reg clk=0,rst_n=0,we=0,re=0,ready=0,update=0;
 reg [31:0] wa=0,ra=0,wd=0,param=0;
 reg [1:0] size=2;
 wire [31:0] rd;
 wire [7:0] data;
 wire valid;
 integer i;
 always #20 clk=~clk;
 peripheral_bus dut(.clk(clk),.rst_n(rst_n),.dev_we(we),.dev_re(re),
  .dev_addr_wr(wa),.dev_addr_rd(ra),.dev_wdata(wd),.dev_size(size),.dev_rdata(rd),
  .rk_tx_data(data),.rk_tx_valid(valid),.rk_tx_ready(ready),
  .rk_param_data(param),.rk_param_update(update),.uart_txd(),.gpio_out());
 task wr; input [31:0] a,v; begin
  @(negedge clk); wa=a; wd=v; we=1;
  @(negedge clk); we=0;
 end endtask
 task check; input [31:0] a,expected; begin
  @(negedge clk); ra=a; re=1;
  @(negedge clk); re=0;
  if(rd!==expected) $fatal(1,"MMIO %h expected %h got %h",a,expected,rd);
 end endtask
 task putparam; input [31:0] v; begin
  @(negedge clk);param=v;update=1;
  @(negedge clk);update=0;
 end endtask
 initial begin
  repeat(3) @(negedge clk);rst_n=1;
  check(32'h30204,1);
  size=0;wr(32'h30200,99);size=2;check(32'h30204,1);
  wr(32'h30201,99);check(32'h30204,1);
  for(i=0;i<64;i=i+1) wr(32'h30200,i);
  check(32'h30204,32'h4000);
  wr(32'h30200,255);check(32'h30204,32'h4002);
  if(data!==0) $fatal(1,"Full write overwrote queue");
  wr(32'h30214,2);check(32'h30204,32'h4000);
  @(negedge clk);ready=1;
  for(i=0;i<64;i=i+1) begin
   @(posedge clk);if(!valid || data!==i[7:0]) $fatal(1,"FIFO order %0d",i);
  end
  @(negedge clk);ready=0;check(32'h30204,1);
  // Wrap and simultaneous push/pop, preserving old head and accepting new tail.
  wr(32'h30200,8'ha5);
  @(negedge clk);ready=1;we=1;wa=32'h30200;wd=8'h5a;
  @(posedge clk);if(data!==8'ha5 || !valid) $fatal(1,"Simultaneous old head");
  @(negedge clk);ready=0;we=0;
  if(data!==8'h5a || !valid) $fatal(1,"Simultaneous new tail");
  check(32'h30204,32'h101);
  putparam(32'h12345678);check(32'h30208,32'h12345678);check(32'h3020c,1);
  check(32'h30204,32'h105);
  wr(32'h30210,0);check(32'h30204,32'h105);
  // Update wins against ACK of old version on same edge.
  @(negedge clk);param=32'h87654321;update=1;we=1;wa=32'h30210;wd=1;
  @(negedge clk);update=0;we=0;
  check(32'h3020c,2);check(32'h30204,32'h105);
  putparam(42);check(32'h30204,32'h10d);
  wr(32'h30210,2);check(32'h30204,32'h10d);
  wr(32'h30210,3);wr(32'h30214,8);check(32'h30204,32'h101);
  @(negedge clk);rst_n=0;
  repeat(3) @(negedge clk);rst_n=1;
  check(32'h30204,1);check(32'h30208,0);check(32'h3020c,0);
  $display("PASS: CPU MMIO FIFO capacity/order/wrap/backpressure/overflow, parameter snapshot ACK race/reset");
  $finish;
 end
 initial begin #1000000;$fatal(1,"bus timeout");end
endmodule
