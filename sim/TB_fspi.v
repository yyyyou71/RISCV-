`timescale 1ns/1ps
module TB_fspi;
 reg clk=0,rst_n=1,sck=1,cs=1,drive=0;
 reg [3:0] dq=0; wire [3:0] bus; assign bus=drive?dq:4'bzzzz;
 reg we=0,re=0; reg [31:0] wa=0,ra=0,wd=0; wire [31:0] rd;
 reg [7:0] got; integer i,n,round;
 always #20 clk=~clk;
 peripheral_bus #(.ENABLE_FSPI(1)) dut(
 .clk(clk),.rst_n(rst_n),.dev_we(we),.dev_re(re),.dev_addr_wr(wa),.dev_addr_rd(ra),
 .dev_wdata(wd),.dev_size(2'b10),.dev_rdata(rd),.spi_clk(sck),.spi_cs(cs),.spi_data(bus),
 .uart_txd(),.gpio_out());
 task wr;input [31:0] a,v;begin
 @(negedge clk);wa=a;wd=v;we=1;@(negedge clk);we=0;
 end endtask
 task check;input [31:0] a,mask,expected;begin
 @(negedge clk);ra=a;re=1;@(negedge clk);re=0;
 if((rd&mask)!==expected)$fatal(1,"MMIO %h got %h expected %h mask %h",a,rd,expected,mask);
 end endtask
 task begin_frame;begin sck=1;cs=0;#7;end endtask
 task end_frame;begin #3;cs=1;drive=0;#1100;
 if(bus!==4'bzzzz)$fatal(1,"CS did not release DQ");end endtask
 task nibble;input [3:0] v;begin
 sck=0;drive=1;dq=v;#10;sck=1;#10;
 end endtask
 task send;input [7:0] v;begin nibble(v[7:4]);nibble(v[3:0]);end endtask
 task recv;output [7:0] v;begin
 drive=0;sck=0;#10;sck=1;#1;v[7:4]=bus;#9;
 sck=0;#10;sck=1;#1;v[3:0]=bus;#9;
 end endtask
 initial begin
 #1;rst_n=0;#200;rst_n=1;#1100;
 check(32'h3031c,32'hffffffff,32'h46535032);
 check(32'h30318,7,0);
 // RK has no ownership until explicitly armed/published.
 begin_frame;send(8'h80);recv(got);end_frame;
 if(got!==8'hff)$fatal(1,"Unpublished TX data leaked got=%h",got);
 check(32'h30308,8,8);wr(32'h3030c,14);
 begin_frame;send(0);send(8'hbb);end_frame;
 check(32'h30318,7,0);check(32'h30308,8,8);wr(32'h3030c,14);
 wr(32'h30310,0);check(32'h30308,8,8);wr(32'h3030c,14);
 wr(32'h30314,2049);check(32'h30308,8,8);wr(32'h3030c,14);
 // Exact length and maximum length; multiple ownership toggle cycles.
 for(round=0;round<4;round=round+1)begin
 case(round)0:n=1;1:n=16;2:n=256;default:n=2048;endcase
 wr(32'h30310,n);check(32'h30318,5,4);#1000;
 begin_frame;send(0);
 for(i=0;i<n;i=i+1)send((i*37)^8'ha5);
 end_frame;check(32'h30318,5,1);check(32'h30308,65535,n<<4);
 for(i=0;i<n;i=i+1)begin
 wr(32'h30300,i);check(32'h30304,255,((i*37)^8'ha5)&255);
 end
 // A second unarmed write must not overwrite unread RX bytes.
 begin_frame;send(0);send(8'h55);end_frame;
 wr(32'h30300,0);check(32'h30304,255,8'ha5);wr(32'h3030c,14);
 // CPU writes separate TX RAM. Unread RX remains unchanged.
 for(i=0;i<n;i=i+1)begin wr(32'h30300,i);wr(32'h30304,(i*13)^8'h3c);end
 wr(32'h30314,n);check(32'h30318,3,3);
 wr(32'h30300,0);wr(32'h30304,8'hff);check(32'h30308,8,8);wr(32'h3030c,14);
 check(32'h30304,255,8'ha5);#1000;
 begin_frame;send(8'h80);
 for(i=0;i<n;i=i+1)begin recv(got);if(got!==(((i*13)^8'h3c)&255))$fatal(1,"TX %0d %h",i,got);end
 end_frame;check(32'h30318,3,1);check(32'h30308,65535,n<<4);
 end
 // Truncated RX remains armed; retry restarts at index zero.
 wr(32'h30310,2);#1000;begin_frame;send(0);send(8'h12);nibble(4'hf);end_frame;
 check(32'h30318,5,4);check(32'h30308,2,2);wr(32'h3030c,14);
 check(32'h30304,255,0);check(32'h30308,8,8);wr(32'h3030c,14);
 begin_frame;send(0);send(8'h23);send(8'h45);send(8'h67);end_frame;
 check(32'h30318,5,1);check(32'h30308,4,4);wr(32'h3030c,14);
 wr(32'h30300,0);check(32'h30304,255,8'h23);
 wr(32'h30300,1);check(32'h30304,255,8'h45);
 // TX short frame keeps ownership; complete retry then overread returns FF.
 wr(32'h30300,0);wr(32'h30304,8'h96);wr(32'h30300,1);wr(32'h30304,8'h78);wr(32'h30314,2);#1000;
 begin_frame;send(8'h80);recv(got);end_frame;check(32'h30318,2,2);
 check(32'h30308,2,2);wr(32'h3030c,14);
 begin_frame;send(8'h80);recv(got);if(got!==8'h96)$fatal(1,"TX retry first");
 recv(got);if(got!==8'h78)$fatal(1,"TX retry second");
 recv(got);if(got!==8'hff)$fatal(1,"TX overread");end_frame;
 check(32'h30318,2,0);check(32'h30308,4,4);wr(32'h3030c,14);
 begin_frame;send(8'h9f);drive=0;#100;if(bus!==4'bzzzz)$fatal(1,"Invalid command drives bus");end_frame;
 check(32'h30308,2,2);wr(32'h3030c,14);
 // Busy excludes CPU buffer writes and publications while CS remains low.
 wr(32'h30310,1);#1000;begin_frame;send(0);
 wr(32'h30304,8'hff);wr(32'h30314,1);check(32'h30308,9,9);
 send(8'h31);end_frame;wr(32'h3030c,14);
 // Global reset with CS active, SCK stopped: output releases immediately.
 wr(32'h30300,0);wr(32'h30304,8'h5a);wr(32'h30314,1);#1000;
 begin_frame;send(8'h80);drive=0;sck=0;#10;rst_n=0;#1;
 if(bus!==4'bzzzz)$fatal(1,"Reset output release");
 cs=1;#100;rst_n=1;#1100;check(32'h30318,7,0);check(32'h30308,65535,0);
 $display("PASS: FSPI 50MHz mode3 CPU/RK 1/16/256/2048 bytes, CDC stopped SCK, ownership, short retry, overflow, reset");$finish;
 end
 initial begin #10000000;$fatal(1,"Timeout");end
endmodule
