`default_nettype none
// Read-only writer observation. A request freezes one coherent DDR-clock snapshot;
// no capture reset, frame ownership or DDR command is generated here.
module video_writer_diagnostic (
    input wire clk,core_clk,rst_n,dev_we,
    input wire [7:0] addr_wr,addr_rd,
    input wire [31:0] wdata,
    input wire [383:0] diagnostic,
    output reg [31:0] rdata
);
    reg request,ack,busy,valid;
    reg [383:0] frozen,result;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync,ack_meta,ack_sync;
    always @(posedge core_clk or negedge rst_n)begin
        if(!rst_n)begin req_meta<=0;req_sync<=0;ack<=0;frozen<=0;end
        else begin
            req_meta<=request;req_sync<=req_meta;
            if(req_sync!=ack)begin frozen<=diagnostic;ack<=req_sync;end
        end
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin request<=0;busy<=0;valid<=0;ack_meta<=0;ack_sync<=0;result<=0;end
        else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(busy && ack_sync==request)begin result<=frozen;busy<=0;valid<=1;end
            if(dev_we && addr_wr==8'hc0 && wdata==1 && !busy)begin
                request<=!request;busy<=1;valid<=0;
            end
        end
    end
    always @*begin
        rdata=0;
        if(addr_rd==8'hc0)rdata={30'b0,valid,busy};
        else if(addr_rd>=8'hc4 && addr_rd<=8'hf0 && addr_rd[1:0]==0)
            rdata=result[(addr_rd-8'hc4)*8+:32];
    end
endmodule
`default_nettype wire
