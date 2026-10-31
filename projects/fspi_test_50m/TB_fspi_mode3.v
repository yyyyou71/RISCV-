`timescale 1ns/1ps
module TB_fspi_mode3;
 reg clk=0,key=0,sck=1,cs=1,drive=0;
 reg [3:0] dq=0;
 wire [3:0] bus;
 wire led0,led1;
 reg [7:0] got;
 integer i,round;
 assign bus=drive?dq:4'bzzzz;
 always #20 clk=~clk;
 fspi_loopback_top dut(.sys_clk(clk),.key0_n(key),.spi_clk(sck),.spi_cs(cs),.spi_data(bus),.led0(led0),.led1(led1));
task begin_frame;begin sck=1;drive=1;cs=0;#1100;end endtask
 task end_frame;begin cs=1;drive=0;#1100;
  if(bus!==4'bzzzz) $fatal(1,"Bus not released after CS");
 end endtask
 task nibble;input [3:0] v;begin
  sck=0;drive=1;dq=v;#10;sck=1;#10;
 end endtask
 task send;input [7:0] v;begin nibble(v[7:4]);nibble(v[3:0]);end endtask
 task recv;output [7:0] v;begin
  drive=0;sck=0;#10;sck=1;#1;v[7:4]=bus;#9;
  sck=0;#10;sck=1;#1;v[3:0]=bus;#9;
 end endtask

 initial begin
  #201;key=1;wait(dut.rst_n===1'b1);#1100;
  for(round=0;round<2;round=round+1)begin
   begin_frame;send(0);
   for(i=0;i<2048;i=i+1)send(((i*37)^8'ha5)^round);
   end_frame;
   begin_frame;send(8'h80);drive=0;
   for(i=0;i<2048;i=i+1)begin
    recv(got);if(got!==((((i*37)^8'ha5)^round)&255))$fatal(1,"Mismatch index %0d got %h",i,got);
   end
   end_frame;
  end
  // Overflow must not overwrite byte zero, and overread must return FF.
  begin_frame;send(0);
  for(i=0;i<2048;i=i+1)send(8'h55);
  send(8'haa);end_frame;
  begin_frame;send(8'h80);drive=0;
  for(i=0;i<2048;i=i+1)begin recv(got);if(got!==8'h55)$fatal(1,"Overflow corrupted buffer");end
  recv(got);if(got!==8'hff)$fatal(1,"Overread wrapped");end_frame;
  // CS aborts without any deselected SCK clocks; partial writes are discarded.
  begin_frame;send(0);nibble(4'hf);end_frame;
  begin_frame;send(8'h80);drive=0;recv(got);end_frame;
  if(got!==8'h55)$fatal(1,"Partial write committed");
  begin_frame;send(8'h9f);drive=0;#100;
  if(bus!==4'bzzzz)$fatal(1,"Invalid command drove bus");end_frame;
  begin_frame;send(8'h80);drive=0;#10;sck=1;#10;sck=0;end_frame;
  begin_frame;send(8'h80);drive=0;recv(got);end_frame;
  if(got!==8'h55)$fatal(1,"Read abort lost alignment");
  if(led1!==1'b1)$fatal(1,"CS activity LED missing");
  key=0;#100;if(bus!==4'bzzzz)$fatal(1,"Reset did not release bus");
  $display("PASS: standalone top reset, mode3 50MHz 2KB loopbacks, overflow, abort recovery, invalid command, reset and CS activity");$finish;
 end
 initial begin #50000000;$fatal(1,"Timeout");end
endmodule
