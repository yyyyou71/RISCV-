`timescale 1ns/1ps
module TB_fspi;
 reg clk=0,rst_n=0,sck=0,cs=1,drive=0;
 reg [3:0] dq=0;
 wire [3:0] bus;
 assign bus=drive ? dq : 4'bzzzz;
 reg we=0,re=0;
 reg [31:0] wa=0,ra=0,wd=0;
 wire [31:0] rd;
 reg [7:0] got;
 integer i;
 always #20 clk=~clk;
 peripheral_bus #(.ENABLE_FSPI(1)) dut(
  .clk(clk),.rst_n(rst_n),.dev_we(we),.dev_re(re),.dev_addr_wr(wa),.dev_addr_rd(ra),
  .dev_wdata(wd),.dev_size(2'b10),.dev_rdata(rd),
  .spi_clk(sck),.spi_cs(cs),.spi_data(bus),
  .rk_tx_data(),.rk_tx_valid(),.rk_tx_ready(1'b0),.rk_param_data(32'b0),
  .rk_param_update(1'b0),.uart_txd(),.gpio_out());
 task wr; input [31:0] a,v;begin
  @(negedge clk);wa=a;wd=v;we=1;@(negedge clk);we=0;
 end endtask
 task check;input [31:0] a,mask,expected;begin
  @(negedge clk);ra=a;re=1;@(negedge clk);re=0;
  if((rd&mask)!==expected) $fatal(1,"MMIO %h got %h expected %h mask %h",a,rd,expected,mask);
 end endtask
 // First SCK rise follows 500 ns later; no extra CS setup delay.
task begin_frame;begin sck=0;drive=1;cs=0;end endtask
 task end_frame;begin cs=1;drive=0;#1100;
  if(bus!==4'bzzzz) $fatal(1,"Bus not released after CS");
 end endtask
 task nibble;input [3:0] v;begin
  drive=1;dq=v;#500;sck=1;#500;sck=0;
 end endtask
 task send;input [7:0] v;begin nibble(v[7:4]);nibble(v[3:0]);end endtask
 task recv;output [7:0] v;begin
  drive=0;#500;sck=1;#1;v[7:4]=bus;#499;sck=0;
  #500;sck=1;#1;v[3:0]=bus;#499;sck=0;
 end endtask
 initial begin
  #201;rst_n=1;#1100;
  // Original 2 KB loopback, varied command-like data included.
  begin_frame;send(0);
  for(i=0;i<2048;i=i+1) send(i[7:0]^8'h80);
  end_frame;check(32'h30308,32'hffff,32'h8000);
  begin_frame;send(8'h80);drive=0;
  for(i=0;i<2048;i=i+1) begin
   recv(got);if(got!==(i[7:0]^8'h80)) $fatal(1,"Loopback index %0d got %h",i,got);
  end
  end_frame;check(32'h30308,32'hffff,32'h8000);
  // CPU sees RK bytes, then sends its own buffer through the same memory.
  wr(32'h30300,7);check(32'h30304,255,8'h87);
  wr(32'h30300,0);wr(32'h30304,8'h5a);
  begin_frame;send(8'h80);drive=0;recv(got);
  if(got!==8'h5a) $fatal(1,"CPU -> RK failed");
  // Block CPU memory write while RK holds CS.
  wr(32'h30304,8'hff);check(32'h30308,9,9);
  end_frame;check(32'h30304,255,8'h5a);
  wr(32'h3030c,8);
  // Abort half a byte; no clocks while deselected; next command must realign.
  begin_frame;send(0);nibble(4'hf);end_frame;
  check(32'h30308,2,2);wr(32'h3030c,2);
  begin_frame;send(0);send(8'h23);end_frame;
  begin_frame;send(8'h80);drive=0;recv(got);end_frame;
  if(got!==8'h23) $fatal(1,"Abort recovery failed");
  begin_frame;send(8'h9f);drive=0;#1000;
  if(bus!==4'bzzzz) $fatal(1,"Unsupported command drives bus");
  end_frame;check(32'h30308,2,2);wr(32'h3030c,2);
  // Overflow cannot wrap and overwrite byte zero.
  begin_frame;send(0);
  for(i=0;i<2048;i=i+1) send(8'h55);
  send(8'haa);end_frame;check(32'h30308,4,4);
  check(32'h30304,255,8'h55);wr(32'h3030c,4);
  // Over-read returns FF rather than wrapping.
  begin_frame;send(8'h80);drive=0;
  for(i=0;i<2048;i=i+1) recv(got);
  recv(got);if(got!==8'hff) $fatal(1,"Overread wrapped");end_frame;
  check(32'h30308,4,4);
  // Reset immediately releases read output; memory content intentionally persists.
  begin_frame;send(8'h80);drive=0;#500;rst_n=0;#100;
  if(bus!==4'bzzzz) $fatal(1,"Reset did not release bus");
  cs=1;#1000;rst_n=1;#1000;check(32'h30308,32'hffff,0);
  begin_frame;send(8'h80);drive=0;recv(got);end_frame;
  if(got!==8'h55) $fatal(1,"Reset memory persistence failed");
  $display("PASS: FSPI 2KB quad loopback, CPU MMIO, arbitration, short CS, invalid command, overflow, reset");
  $finish;
 end
 initial begin #30000000;$fatal(1,"FSPI timeout");end
endmodule
