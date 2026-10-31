// Quad mode 0, high nibble first. 00=write, 80=read, no address/dummy.
// Entire data buffer and protocol run on SCK; sys_clk is not used here.
// RAM is intentionally not reset. Host must write before reading.
module fspi_sck_slave (
 input wire rst_n, spi_clk, spi_cs,
 inout wire [3:0] spi_data
);
 localparam CMD=2'd0, WRITE=2'd1, READ=2'd2, INVALID=2'd3;
 wire frame_reset=spi_cs || !rst_n;
 reg [1:0] state=CMD;
 reg half=0;
 reg [3:0] hi=0;
 reg [11:0] count=0;
 reg [7:0] mem[0:2047];
 reg [7:0] rd_data;
 reg [3:0] tx_nibble=15;
 reg drive=0;
 // Prefetch next byte on the rising edge that samples the current low nibble.
 wire [11:0] fetch_index=(state==READ && half) ? count+12'd1 : count;
 wire [10:0] ram_addr=(state==READ) ? fetch_index[10:0] : 11'd0;
 always @(posedge spi_clk) begin
  rd_data<=mem[ram_addr];
  if(!frame_reset && state==WRITE && half && count<2048)
   mem[count[10:0]]<={hi,spi_data};
 end
 always @(posedge spi_clk or posedge frame_reset) begin
  if(frame_reset)begin state<=CMD;half<=0;hi<=0;count<=0;end
  else begin
   if(state==CMD || state==WRITE)begin
    if(!half)begin hi<=spi_data;half<=1;end
    else begin
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
 end
 always @(negedge spi_clk or posedge frame_reset)begin
  if(frame_reset)begin tx_nibble<=4'hf;drive<=0;end
  else if(state==READ)begin
   drive<=1;
   if(count>=2048)tx_nibble<=4'hf;
   else tx_nibble<=half ? rd_data[3:0] : rd_data[7:4];
  end else drive<=0;
 end
 assign spi_data=(!frame_reset && drive) ? tx_nibble : 4'bzzzz;
endmodule
