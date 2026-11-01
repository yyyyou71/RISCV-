// 50MHz quad FSPI, mode 3 (also mode 0), MS nibble first.
// 00=RK->CPU, 80=CPU->RK. Independent RAMs, exactly one writer per RAM.
// CPU ARM_RX / COMMIT_TX supplies length before RK starts. No implicit echo.
// Require >=1us CS-high gap and >=1us after CPU publication before first SCK.
module rk_fspi_adapter (
 input wire clk, rst_n, spi_clk, spi_cs,
 inout wire [3:0] spi_data,
 input wire cpu_we, cpu_re,
 input wire [31:0] cpu_addr, cpu_wdata,
 output wire [31:0] cpu_rdata
);
 localparam CMD=2'd0, WRITE=2'd1, READ=2'd2, INVALID=2'd3;
 reg [7:0] rx_mem[0:2047], tx_mem[0:2047];
 reg [10:0] cpu_index;
 reg [11:0] rx_length,tx_length;
 reg rx_req,tx_req,rx_ever_armed;
 reg rx_done,tx_done;
 (* ASYNC_REG="TRUE" *) reg rx_req_meta,rx_req_sync,tx_req_meta,tx_req_sync;
 (* ASYNC_REG="TRUE" *) reg rx_done_meta,rx_done_sync,tx_done_meta,tx_done_sync;
 (* ASYNC_REG="TRUE" *) reg cs_meta,cs_sync,frame_meta,frame_sync;
 reg [2:0] idle_count;
 reg frame_seen,frame_pending;
 reg protocol_error,overflow,cpu_rejected;
 reg [11:0] last_count;
 reg [31:0] reg_rdata;
 reg data_selected;
 reg [7:0] rx_q,tx_q;
 wire tx_pending=tx_req!=tx_done_sync;
 wire rx_ready=rx_ever_armed && rx_req==rx_done_sync;
 wire rx_armed=rx_ever_armed && rx_req!=rx_done_sync;
 wire active=!spi_cs || !cs_sync || idle_count<4 || frame_pending;
 wire data_write=cpu_we && cpu_addr==32'h00030304;
 assign cpu_rdata=data_selected ? {24'b0,rx_q} : reg_rdata;
 // No RAM reset: inferred independent-clock read/write ports.
 always @(posedge clk) begin
  if(cpu_re && cpu_addr==32'h00030304) rx_q<=rx_mem[cpu_index];
  if(rst_n && data_write && !active && !tx_pending)
   tx_mem[cpu_index]<=cpu_wdata[7:0];
 end
 // SCK may stop indefinitely: synchronizers are never reset by CS.
 always @(posedge spi_clk or negedge rst_n) begin
  if(!rst_n)begin rx_req_meta<=0;rx_req_sync<=0;tx_req_meta<=0;tx_req_sync<=0;end
  else begin
   rx_req_meta<=rx_req;rx_req_sync<=rx_req_meta;
   tx_req_meta<=tx_req;tx_req_sync<=tx_req_meta;
  end
 end
 wire frame_reset=spi_cs || !rst_n;
 reg [1:0] state=CMD;
 reg half=0;
 reg [3:0] hi=0;
 reg [11:0] count=0;
 reg rx_accept=0,tx_accept=0;
 reg [3:0] tx_nibble /* synthesis syn_useioff=1 */ =15;
 // Active-high tri-state controls connect directly to the four I/O enables.
 // Preserve one register per pad so placement need not fan out a fabric OE.
 reg [3:0] tx_disable /* synthesis syn_useioff=1 syn_preserve=1 */ =4'hf;
 wire [11:0] fetch_index=(state==READ && half) ? count+12'd1 : count;
 wire rx_allowed=(count==0 && !half) ? rx_req_sync!=rx_done : rx_accept;
 always @(posedge spi_clk) begin
  tx_q<=tx_mem[(state==READ) ? fetch_index[10:0] : 11'd0];
  if(!frame_reset && state==WRITE && half && rx_accept && count<rx_length)
   rx_mem[count[10:0]]<={hi,spi_data};
 end
 always @(posedge spi_clk or posedge frame_reset) begin
  if(frame_reset)begin state<=CMD;half<=0;hi<=0;count<=0;rx_accept<=0;end
  else if(state==CMD || state==WRITE)begin
   if(!half)begin
    hi<=spi_data;half<=1;
    if(state==WRITE && count==0)rx_accept<=rx_req_sync!=rx_done;
   end else begin
    half<=0;
    if(state==CMD)begin
     case({hi,spi_data})
      8'h00:state<=WRITE;
      8'h80:state<=READ;
      default:state<=INVALID;
     endcase
    end else if(count<2048)count<=count+1'b1;
   end
  end else if(state==READ)begin
   half<=!half;
   if(half && count<2048)count<=count+1'b1;
  end
 end
 // Completion survives CS and needs no subsequent SCK pulses.
 always @(posedge spi_clk or negedge rst_n)begin
  if(!rst_n)begin rx_done<=0;tx_done<=0;end
  else if(!spi_cs && half)begin
   if(state==WRITE && rx_accept && count+12'd1==rx_length)rx_done<=rx_req_sync;
   if(state==READ && tx_accept && count+12'd1==tx_length)tx_done<=tx_req_sync;
  end
 end
 always @(negedge spi_clk or posedge frame_reset)begin
  if(frame_reset)begin tx_nibble<=15;tx_disable<=4'hf;tx_accept<=0;end
  else if(state==READ)begin
   tx_disable<=0;
   if(count==0 && !half)begin
    tx_accept<=tx_req_sync!=tx_done;
    tx_nibble<=(tx_req_sync!=tx_done) ? tx_q[7:4] : 4'hf;
   end else if(tx_accept && count<tx_length)
    tx_nibble<=half ? tx_q[3:0] : tx_q[7:4];
   else tx_nibble<=15;
  end else tx_disable<=4'hf;
 end
 // CS/global reset asynchronously sets these registers, including when SCK
 // has stopped. No additional LUT is needed between their Q and each pad T.
 genvar dq_pin;
 generate for(dq_pin=0;dq_pin<4;dq_pin=dq_pin+1)begin:g_dq
  assign spi_data[dq_pin]=tx_disable[dq_pin]?1'bz:tx_nibble[dq_pin];
 end endgenerate
 // Held bundled summary; sample after synchronized CS-high + four CPU clocks.
 reg frame_toggle;
 reg [11:0] report_count;
 reg report_half,report_bad,report_over,report_reject;
 reg [1:0] report_kind;
 always @(posedge spi_clk or negedge rst_n)begin
  if(!rst_n)begin
   frame_toggle<=0;report_count<=0;report_half<=0;report_bad<=0;
   report_over<=0;report_reject<=0;report_kind<=CMD;
  end else if(!spi_cs)begin
   if(state==CMD && !half)begin
    frame_toggle<=!frame_toggle;report_count<=0;report_half<=1;
    report_bad<=0;report_over<=0;report_reject<=0;report_kind<=CMD;
   end else if(state==CMD && half)begin
    report_half<=0;
    case({hi,spi_data})
     8'h00:report_kind<=WRITE;
     8'h80:report_kind<=READ;
     default:begin report_kind<=INVALID;report_bad<=1;end
    endcase
   end else if(state==WRITE || state==READ)begin
    report_half<=!half;
    if(half && count<2048)report_count<=count+1'b1;
    if(state==WRITE)begin
     if(!rx_allowed)report_reject<=1;
     if(half && rx_accept && count>=rx_length)report_over<=1;
    end else begin
     if(!tx_accept)report_reject<=1;
     if(half && tx_accept && count>=tx_length)report_over<=1;
    end
   end
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   rx_done_meta<=0;rx_done_sync<=0;tx_done_meta<=0;tx_done_sync<=0;
   cs_meta<=1;cs_sync<=1;frame_meta<=0;frame_sync<=0;
  end else begin
   rx_done_meta<=rx_done;rx_done_sync<=rx_done_meta;
   tx_done_meta<=tx_done;tx_done_sync<=tx_done_meta;
   cs_meta<=spi_cs;cs_sync<=cs_meta;frame_meta<=frame_toggle;frame_sync<=frame_meta;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   cpu_index<=0;rx_length<=0;tx_length<=0;rx_req<=0;tx_req<=0;rx_ever_armed<=0;
   protocol_error<=0;overflow<=0;cpu_rejected<=0;last_count<=0;
   reg_rdata<=0;data_selected<=0;idle_count<=0;frame_seen<=0;frame_pending<=0;
  end else begin
   if(!cs_sync)idle_count<=0;else if(idle_count<4)idle_count<=idle_count+1'b1;
   if(frame_sync!=frame_seen)begin frame_seen<=frame_sync;frame_pending<=1;end
   if(cpu_we && cpu_addr==32'h0003030c)begin
    if(cpu_wdata[1])protocol_error<=0;
    if(cpu_wdata[2])overflow<=0;
    if(cpu_wdata[3])cpu_rejected<=0;
   end
   if(frame_pending && cs_sync && idle_count==4)begin
    frame_pending<=0;last_count<=report_count;
    if(report_bad || report_half ||
       (report_kind==WRITE && !report_reject && report_count<rx_length) ||
       (report_kind==READ && !report_reject && report_count<tx_length))protocol_error<=1;
    if(report_over)overflow<=1;
    if(report_reject)cpu_rejected<=1;
   end
   if(cpu_we)case(cpu_addr)
    32'h00030300:cpu_index<=cpu_wdata[10:0];
    32'h00030304:if(active || tx_pending)cpu_rejected<=1;
    32'h00030310:begin
     if(active || rx_armed || cpu_wdata==0 || cpu_wdata>2048)cpu_rejected<=1;
     else begin rx_length<=cpu_wdata[11:0];rx_req<=!rx_req;rx_ever_armed<=1;end
    end
    32'h00030314:begin
     if(active || tx_pending || cpu_wdata==0 || cpu_wdata>2048)cpu_rejected<=1;
     else begin tx_length<=cpu_wdata[11:0];tx_req<=!tx_req;end
    end
    default:;
   endcase
   if(cpu_re)begin
    data_selected<=0;
    case(cpu_addr)
     32'h00030300:reg_rdata<={21'b0,cpu_index};
     32'h00030304:begin
      reg_rdata<=0;
      if(!active && rx_ready)data_selected<=1;else cpu_rejected<=1;
     end
     32'h00030308:reg_rdata<={16'b0,last_count,cpu_rejected,overflow,protocol_error,active};
     32'h00030310:reg_rdata<={20'b0,rx_length};
     32'h00030314:reg_rdata<={20'b0,tx_length};
     32'h00030318:reg_rdata<={29'b0,rx_armed,tx_pending,rx_ready};
     32'h0003031c:reg_rdata<=32'h46535032; // FSP2 ownership ABI
     default:reg_rdata<=0;
    endcase
   end
  end
 end
endmodule
