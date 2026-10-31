`timescale 1ns/1ps
module TB_comm_service;
 reg clk=0,key0_n=0,spi_clk=1,spi_cs=1,drive=0;
 reg [3:0] dq=0;wire [3:0] spi_data;assign spi_data=drive?dq:4'bzzzz;
 reg [31:0] param=0;reg update=0;
 wire led0,led1;tri1 sda;
 reg [7:0] replies[0:255],packet[0:2047],response_data[0:2047];
 integer rp=0,wp=0,k,n;reg [31:0] hash,state;reg [7:0] token=0;
 always #20 clk=~clk;
 board_top #(.RESET_HOLD_CYCLES(8),.ENABLE_DUAL(1),.ENABLE_FSPI(1)) dut(
 .sys_clk(clk),.key0_n(key0_n),.uart_tx(),.led0(led0),.led1(led1),
 .iic_scl(1'b1),.iic_sda(sda),.spi_clk(spi_clk),.spi_cs(spi_cs),.spi_data(spi_data));
 // Exercise the real CPU mailbox/FIFO. Physical IIC frontend is covered by
 // existing IIC regressions; this test substitutes its application signals.
 initial begin force dut.rk_param_data=param;force dut.rk_param_update=update;force dut.rk_uplink_ready=1'b1;end
 always @(posedge clk)begin
 if(dut.rst_n && dut.cpu_rk_tx_valid)begin replies[wp]=dut.cpu_rk_tx_data;wp=wp+1;end
 if(dut.rst_n && dut.bus_err)$fatal(1,"CPU unmapped access");
 end
 task control;input [7:0] op;input [15:0] arg;output [31:0] value;integer timeout;begin
 token=token+1;@(negedge clk);param={op,token,arg};update=1;@(negedge clk);update=0;
 timeout=0;while(wp-rp<8 && timeout<100000)begin @(negedge clk);timeout=timeout+1;end
 if(wp-rp<8)$fatal(1,"CPU control timeout pc=%h pending=%b seq=%h wp=%d rp=%d stall=%b dev_rd=%h",dut.u_soc.u_core.pc,dut.u_soc.u_peripheral_bus.param_pending,dut.u_soc.u_peripheral_bus.param_seq,wp,rp,dut.u_soc.u_core.stall,dut.u_soc.dev_rdata);
 if(replies[rp]!==8'hc3 || replies[rp+1]!==token || replies[rp+2]!==0 || replies[rp+3]!==1)$fatal(1,"CPU reply error %h",replies[rp+2]);
 value={replies[rp+7],replies[rp+6],replies[rp+5],replies[rp+4]};rp=rp+8;
 end endtask
 task put32;input integer offset;input [31:0] value;begin
 packet[offset]=value[7:0];packet[offset+1]=value[15:8];packet[offset+2]=value[23:16];packet[offset+3]=value[31:24];end endtask
 task prepare;input [15:0] op,len;integer i;begin
 put32(0,32'h31435652);put32(4,32'h12345678);packet[8]=op[7:0];packet[9]=op[15:8];packet[10]=len[7:0];packet[11]=len[15:8];
 hash=32'd2166136261;for(i=0;i<16+len;i=i+1)if(i<12 || i>=16)hash=(hash^packet[i])*32'd16777619;
 put32(12,hash);n=16+len;
 end endtask
 task send;input [7:0] b;begin
 drive=1;spi_clk=0;dq=b[7:4];#10;spi_clk=1;#10;
 spi_clk=0;dq=b[3:0];#10;spi_clk=1;#10;end endtask
 task recv;output [7:0] b;begin
 drive=0;spi_clk=0;#10;spi_clk=1;#1;b[7:4]=spi_data;#9;
 spi_clk=0;#10;spi_clk=1;#1;b[3:0]=spi_data;#9;end endtask
 task exchange;input [15:0] expected_status;integer i,tries,rlen;begin
 control(8'ha1,n,state);if(state!==n)$fatal(1,"ARM length");#1100;
 spi_cs=0;#7;send(0);for(i=0;i<n;i=i+1)send(packet[i]);#3;spi_cs=1;drive=0;#1100;
 tries=0;state=1;while(state[15:0]==1 && tries<30)begin control(8'ha2,0,state);tries=tries+1;end
 if(state[15:0]!==2)$fatal(1,"No CPU response %h",state);
 rlen=state>>16;if(rlen<16 || rlen>2048)$fatal(1,"Bad response size");
 #1100;spi_cs=0;#7;send(8'h80);for(i=0;i<rlen;i=i+1)recv(response_data[i]);#3;spi_cs=1;drive=0;#1100;
 if({response_data[9],response_data[8]}!==expected_status)$fatal(1,"Application status %h expected %h",{response_data[9],response_data[8]},expected_status);
 if({response_data[7],response_data[6],response_data[5],response_data[4]}!==32'h12345678)$fatal(1,"Sequence");
 hash=32'd2166136261;for(i=0;i<rlen;i=i+1)if(i<12 || i>=16)hash=(hash^response_data[i])*32'd16777619;
 if(hash!=={response_data[15],response_data[14],response_data[13],response_data[12]})$fatal(1,"Response checksum");
 control(8'ha2,0,state);if(state[15:0]!==0)$fatal(1,"TX not released");
 end endtask
 initial begin
 #201;key0_n=1;wait(dut.rst_n);
 @(negedge clk);key0_n=0;repeat(12)@(negedge clk);key0_n=1;wait(dut.rst_n);
 repeat(12000)@(negedge clk);
 control(8'ha0,0,state);if(state!==32'h00010001)$fatal(1,"ABI");
 put32(16,0);put32(20,3);prepare(1,8);exchange(0);
 if(led0!==1 || led1!==1)$fatal(1,"Parameter not applied to GPIO");
 put32(16,0);prepare(2,4);exchange(0);if(response_data[16]!==3)$fatal(1,"Parameter read");
 put32(16,0);put32(20,0);prepare(1,8);packet[12]=packet[12]^1;exchange(1);
 if(led0!==1 || led1!==1)$fatal(1,"Bad checksum changed parameter");
 put32(16,16);prepare(2,4);exchange(2);
 prepare(16'hffff,0);exchange(3);
 put32(16,512);prepare(3,4);exchange(0);
 if(response_data[16]!=="R" || response_data[17]!=="V")$fatal(1,"CPU log output");
 put32(16,512);prepare(3,4);exchange(0);if({response_data[11],response_data[10]}!==0)$fatal(1,"Log consume");
 prepare(4,0);exchange(0);if(response_data[16]!==1 || response_data[18]!==1)$fatal(1,"Status ABI");
 $display("PASS: real dual RV32 communication firmware, parameter apply/get, invalid packet no side effect, logs consume, status, ownership, no bus errors");$finish;
 end
 initial begin #50000000;$fatal(1,"service timeout");end
endmodule
