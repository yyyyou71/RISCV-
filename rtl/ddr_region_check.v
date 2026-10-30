`default_nettype none
// Qualify each held native request one cycle before arbitration. Producers
// must retain address/length until accepted, as on the original DDR interface.
module ddr_region_check (
    input wire clk,rst_n,
    input wire [1:0] valid,accepted,
    input wire [55:0] address,
    input wire [7:0] length,
    output wire [1:0] qualified,
    output reg fault
);
    reg [1:0] checked,allowed;
    assign qualified=valid&checked&allowed;
    genvar channel;
    generate for(channel=0;channel<2;channel=channel+1)begin:g_channel
        wire [28:0] end_address={1'b0,address[channel*28+:28]}+
            (({25'b0,length[channel*4+:4]}+29'd1)<<3);
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)begin checked[channel]<=0;allowed[channel]<=0;end
            else if(!valid[channel]||accepted[channel])begin checked[channel]<=0;allowed[channel]<=0;end
            else if(!checked[channel])begin
                checked[channel]<=1;allowed[channel]<=end_address<=29'h2000000;
            end
        end
    end endgenerate
    always @(posedge clk or negedge rst_n)
        if(!rst_n)fault<=0;
        else if(|(valid&checked&~allowed))fault<=1;
endmodule
`default_nettype wire
