// Quad-only, mode 0, MS nibble first: 00 write / 80 read, no address/dummy.
// 25 MHz system clock: use SCK <= 1 MHz, CS idle >= 1 us.
// SCK/CS/data are sampled together; no vendor PLL or RAM primitive required.
module rk_fspi_adapter (
 input wire clk, rst_n, spi_clk, spi_cs,
 inout wire [3:0] spi_data,
 input wire cpu_we, cpu_re,
 input wire [31:0] cpu_addr, cpu_wdata,
 output reg [31:0] cpu_rdata
);
 reg [7:0] mem [0:2047];
 reg [1:0] sck_sync, cs_sync;
 reg [3:0] dq_meta, dq_sync;
 reg sck_old, cs_old;
 reg [1:0] state;
 localparam CMD=0, WRITE=1, READ=2, INVALID=3;
 reg half;
 reg [3:0] high_nibble;
 reg [11:0] count;
 reg [7:0] tx_byte;
 reg [3:0] dq_out;
 reg tx_low, read_started;
 reg protocol_error, overflow, cpu_rejected;
 reg [10:0] cpu_index;
 reg [11:0] last_count;
 wire rise=sck_sync[1] && !sck_old;
 wire fall=!sck_sync[1] && sck_old;
 wire active=!cs_sync[1] || !spi_cs;
 // Raw CS releases the pins even when the system clock is stopped/reset.
 assign spi_data=(!spi_cs && !cs_sync[1] && rst_n && state==READ && read_started) ? dq_out : 4'bzzzz;
 always @(posedge clk) begin
  if(!rst_n) begin
   sck_sync<=0;cs_sync<=3;sck_old<=0;cs_old<=1;dq_meta<=0;dq_sync<=0;
  end else begin
   sck_sync<={sck_sync[0],spi_clk};cs_sync<={cs_sync[0],spi_cs};
   dq_meta<=spi_data;dq_sync<=dq_meta;
   sck_old<=sck_sync[1];cs_old<=cs_sync[1];
  end
 end
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=CMD;half<=0;high_nibble<=0;count<=0;last_count<=0;
   tx_byte<=0;dq_out<=0;tx_low<=0;read_started<=0;
   protocol_error<=0;overflow<=0;cpu_rejected<=0;cpu_index<=0;cpu_rdata<=0;
  end else begin
   if(cpu_we && cpu_addr==32'h0003030c) begin
    if(cpu_wdata[1]) protocol_error<=0;
    if(cpu_wdata[2]) overflow<=0;
    if(cpu_wdata[3]) cpu_rejected<=0;
   end
   if(cpu_we && cpu_addr==32'h00030300) cpu_index<=cpu_wdata[10:0];
   if(cpu_we && cpu_addr==32'h00030304) begin
    if(active) cpu_rejected<=1;
    else mem[cpu_index]<=cpu_wdata[7:0];
   end
   if(cpu_re) begin
    case(cpu_addr)
     32'h00030300:cpu_rdata<={21'b0,cpu_index};
     32'h00030304:begin
      cpu_rdata<=active ? 32'b0 : {24'b0,mem[cpu_index]};
      if(active) cpu_rejected<=1;
     end
     32'h00030308:cpu_rdata<={16'b0,last_count,cpu_rejected,overflow,protocol_error,active};
     default:cpu_rdata<=0;
    endcase
   end
   if(cs_sync[1]) begin
    if(!cs_old) begin
     last_count<=count;
     if(half || (state==CMD && count!=0)) protocol_error<=1;
    end
    state<=CMD;half<=0;count<=0;read_started<=0;tx_low<=0;
   end else if(cs_old) begin
    state<=CMD;half<=0;count<=0;read_started<=0;tx_low<=0;
   end else begin
    if(rise) begin
     if(state==CMD || state==WRITE) begin
      if(!half) begin high_nibble<=dq_sync;half<=1;end
      else begin
       half<=0;
       if(state==CMD) begin
        case({high_nibble,dq_sync})
         8'h00:state<=WRITE;
         8'h80:begin state<=READ;tx_byte<=mem[0];end
         default:begin state<=INVALID;protocol_error<=1;end
        endcase
       end else if(count<2048) begin
        mem[count[10:0]]<={high_nibble,dq_sync};count<=count+1'b1;
       end else overflow<=1;
      end
     end else if(state==READ && read_started) begin
      if(!half) half<=1;
      else begin
       half<=0;
       if(count<2048) count<=count+1'b1;
       else overflow<=1;
      end
     end
    end
    if(fall && state==READ) begin
     read_started<=1;
     if(!tx_low) begin dq_out<=tx_byte[7:4];tx_low<=1;end
     else begin
      dq_out<=tx_byte[3:0];tx_low<=0;
      if(count<2047) tx_byte<=mem[count[10:0]+11'd1];
      else tx_byte<=8'hff;
     end
    end
   end
  end
 end
endmodule
